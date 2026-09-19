//! Starting a child process on Windows: the command line `CreateProcessW`
//! takes, the standard handles it inherits, and the attribute list that
//! attaches it to a pseudoconsole.
//!
//! The public contract lives on `Child.spawn`; this file is the half of it
//! that only exists here.

const std = @import("std");
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

const Child = @import("Child.zig");
const Pty = @import("Pty.zig");
const trace = @import("trace.zig");
const win32 = @import("win32.zig");

const SpawnError = Child.SpawnError;
const SpawnOptions = Child.SpawnOptions;
const file = @import("handles.zig").file;

/// See `Child.spawn`.
pub fn spawn(io: std.Io, allocator: Allocator, options: SpawnOptions) SpawnError!Child {
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (isBatchFile(options.argv[0])) return error.UnsupportedBatchFile;

    // A pseudoconsole is attached through the attribute list, and Windows
    // documents `STARTF_USESTDHANDLES` as unsupported alongside it -- so there
    // is nowhere to put the caller's file. Refusing beats accepting the option
    // and quietly dropping it.
    if (options.stdio == .pty and options.stderr_to != null) return error.Unsupported;

    // A Windows process runs as the token it was created with. Changing the
    // user, the group or the file-creation mask are not steps between a fork
    // and an exec there -- there is no fork -- and there is nothing here that
    // could honour the option, so it is refused rather than accepted and
    // quietly not done.
    if (options.credentials.any()) return error.Unsupported;

    // Windows has no `setrlimit`, and `ResourceLimit` is a pair of POSIX types
    // with no counterpart here. The job object below is the Windows way to
    // bound what a child may use; `SpawnOptions.job_limits` is the option that
    // reaches it, and accepting the POSIX list and setting nothing would be
    // the worst of both.
    if (options.resource_limits.len != 0) return error.Unsupported;

    // The program is resolved by `CreateProcessW`, from the environment the
    // child is being given -- see the note on `lpApplicationName` below. That
    // is exactly `.child_environ`, and there is no argument to ask it for
    // anything else, so the other two are refused rather than accepted and
    // quietly not done.
    if (options.path_search != .child_environ) return error.Unsupported;

    // `CreateProcessW` writes to the command line it is given, so it must be a
    // mutable buffer. `lpApplicationName` is left null on purpose: the system
    // then resolves the program from the command line, searching the
    // application directory, the current directory, the system directories and
    // `PATH`, and appending `.exe` when there is no extension. That is what a
    // caller passing a bare program name means, and reimplementing it here
    // would only be a second, worse copy.
    const command_line = try commandLine(arena, options.argv);

    const environment: ?[*:0]const u16 = if (options.environ) |map| env: {
        const block = try map.createWindowsBlock(arena, .{});
        break :env block.slice.ptr;
    } else null;

    const cwd: ?[*:0]const u16 = if (options.cwd) |dir|
        (try std.unicode.wtf8ToWtf16LeAllocZ(arena, dir)).ptr
    else
        null;

    // Looked at here rather than left to `CreateProcessW`, which reports a
    // working directory that is not there with an error code it also uses for
    // other things -- a program at a path that does not exist is one of them
    // -- so the two would be indistinguishable afterwards. `spawn` promises
    // `BadWorkingDirectory` for one and `FileNotFound` for the other on both
    // systems, and on POSIX the fork child reports which step failed; this is
    // what keeps that promise here. A directory that goes away between this
    // and the spawn comes back as whatever `CreateProcessW` makes of it, which
    // is the ordinary cost of asking first.
    if (cwd) |dir| {
        const attributes = win32.GetFileAttributesW(dir);
        if (attributes == win32.INVALID_FILE_ATTRIBUTES) return error.BadWorkingDirectory;
        if (attributes & win32.FILE_ATTRIBUTE_DIRECTORY == 0) return error.BadWorkingDirectory;
    }

    var plan: Plan = try .init(options);
    errdefer plan.closeOwned(io);

    var startup: win32.STARTUPINFOEXW = std.mem.zeroes(win32.STARTUPINFOEXW);
    var flags: windows.CreateProcessFlags = .{
        .create_new_process_group = options.detach,
        .create_unicode_environment = environment != null,
    };

    // A pseudoconsole is attached through an attribute list rather than
    // through the standard handles, and the two are mutually exclusive:
    // `STARTF_USESTDHANDLES` alongside `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`
    // is documented as unsupported. Nothing needs to be inheritable in that
    // case, either, which is why `bInheritHandles` differs.
    var attributes: ?AttributeList = null;
    defer if (attributes) |*list| list.deinit();

    switch (options.stdio) {
        .pty => |pty| {
            const console = pty.slave.?;
            var list = try AttributeList.init(arena, 1);
            try list.setPseudoConsole(console);
            if (trace.enabled()) {
                trace.print("spawn: pseudoconsole attribute set, hpcon=0x{x}", .{@intFromPtr(console)});
            }
            attributes = list;
            startup.StartupInfo.cb = @sizeOf(win32.STARTUPINFOEXW);
            startup.lpAttributeList = list.raw;
            flags.extended_startupinfo_present = true;

            // And no standard handles, said out loud. `CreateProcessW` gives
            // a child the parent's standard handles even with
            // `bInheritHandles` false, when those handles are not console
            // handles: they are duplicated into the child as a special case.
            // So a program whose own streams are pipes -- which is every
            // program a build system, a service or a test harness starts --
            // would hand a child on a pseudoconsole the parent's pipes, and
            // everything the child wrote would go there rather than to the
            // console it is attached to. From a terminal it looks right,
            // because console handles are not duplicated and the child falls
            // back to its console; everywhere else it is wrong.
            //
            // `STARTF_USESTDHANDLES` with all three left null is how a child
            // is given none, and a child with none uses the console it has,
            // which is the pseudoconsole. This is not the combination Windows
            // documents as unsupported alongside a pseudoconsole -- that is
            // *naming* a handle, which is why `stderr_to` with `.pty` is
            // refused rather than merged in here.
            startup.StartupInfo.dwFlags = win32.STARTF_USESTDHANDLES;
        },
        else => {
            startup.StartupInfo.cb = @sizeOf(win32.STARTUPINFOW);
            startup.StartupInfo.dwFlags = win32.STARTF_USESTDHANDLES;
            startup.StartupInfo.hStdInput = plan.child[0];
            startup.StartupInfo.hStdOutput = plan.child[1];
            startup.StartupInfo.hStdError = plan.child[2];

            // And nothing else. `bInheritHandles` on its own hands the child
            // every inheritable handle this process holds -- which on a machine
            // where this program's own standard streams are inheritable pipes
            // means the child, and anything the child starts, keeps those pipes
            // open for as long as it lives. A handle list says exactly which
            // three the child is being given.
            if (try plan.inheritList(arena)) |inheritable| {
                var list = try AttributeList.init(arena, 1);
                try list.setHandleList(inheritable);
                attributes = list;
                startup.StartupInfo.cb = @sizeOf(win32.STARTUPINFOEXW);
                startup.lpAttributeList = list.raw;
                flags.extended_startupinfo_present = true;
            }
        },
    }
    const inherit_handles: windows.BOOL = switch (options.stdio) {
        .pty => .FALSE,
        else => .TRUE,
    };

    if (trace.enabled()) {
        trace.print(
            "spawn: child_windows.spawn, stdio={s}, cb={d}, flags=0x{x:0>8}, si_flags=0x{x:0>8}, inherit={s}, attributes={s}",
            .{
                @tagName(options.stdio),
                startup.StartupInfo.cb,
                @as(u32, @bitCast(flags)),
                startup.StartupInfo.dwFlags,
                // Not `@tagName`. A Windows `BOOL` names only `FALSE`; every
                // other value, `TRUE` included, is an unnamed one of a
                // non-exhaustive enum, and asking for the name of one of those
                // ends the process.
                if (inherit_handles.toBool()) "TRUE" else "FALSE",
                if (startup.lpAttributeList == null) "none" else "present",
            },
        );
        // Whether this process has a console of its own is the question behind
        // "where did the child's output go": a console child with no console
        // flags and no pseudoconsole inherits its parent's, and one whose
        // parent has none gets a new one nobody can see.
        const inherited = inheritedHandles();
        for (inherited, 0..) |slot, index| {
            const name = ([3][]const u8{ "stdin", "stdout", "stderr" })[index];
            if (slot) |handle| {
                trace.print("spawn: parent {s}=0x{x}, console: {s}", .{
                    name,
                    @intFromPtr(handle),
                    if (isConsole(handle)) "yes" else "no",
                });
            } else {
                trace.print("spawn: parent {s} is not there", .{name});
            }
        }
    }

    // The child is started suspended and put in its job before it runs, so
    // there is no moment in which it exists outside one -- a child that got as
    // far as starting something of its own first would have left that
    // something outside the job, which is the whole thing the job is for.
    flags.create_suspended = true;

    const job = win32.CreateJobObjectW(null, null) orelse return createError();
    errdefer windows.CloseHandle(job);
    {
        var limits: win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(
            win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        );
        limits.BasicLimitInformation.LimitFlags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        if (win32.SetInformationJobObject(
            job,
            win32.JobObjectExtendedLimitInformation,
            &limits,
            @sizeOf(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
        ) == .FALSE) return createError();
    }

    var information: windows.PROCESS.INFORMATION = undefined;
    if (windows.kernel32.CreateProcessW(
        null,
        command_line.ptr,
        null,
        null,
        inherit_handles,
        flags,
        environment,
        cwd,
        &startup.StartupInfo,
        &information,
    ) == .FALSE) return createError();

    // From here the child exists, so a failure has to end it rather than
    // return and leave it suspended forever.
    errdefer {
        _ = win32.TerminateProcess(information.hProcess, 1);
        windows.CloseHandle(information.hThread);
        windows.CloseHandle(information.hProcess);
    }

    if (win32.AssignProcessToJobObject(job, information.hProcess) == .FALSE) {
        return error.JobAssignmentFailed;
    }
    if (win32.ResumeThread(information.hThread) == std.math.maxInt(win32.DWORD)) {
        return createError();
    }

    plan.closeOwned(io);

    return .{
        .id = information.hProcess,
        .thread = information.hThread,
        .job = job,
        .handles_open = true,
        // `CREATE_NEW_PROCESS_GROUP` makes a group whose id is the process id,
        // which is what `GenerateConsoleCtrlEvent` is addressed to.
        .pgid = if (options.detach) information.dwProcessId else null,
        .stdin = plan.parent[0],
        .stdout = plan.parent[1],
        .stderr = plan.parent[2],
        .pty = switch (options.stdio) {
            .pty => |pty| pty.master(),
            else => null,
        },
        .term = null,
    };
}

//======================================================================
// Standard handles.
//======================================================================

/// The three handles the child starts with, which of them this package opened,
/// and the pipe ends the parent keeps.
const Plan = struct {
    /// What the child gets as its standard input, output and error. A handle
    /// the child is meant to inherit; `null` gives it nothing.
    child: [3]?windows.HANDLE = @splat(null),
    /// The subset of `child` this `Plan` opened and must close once the child
    /// has its own copies. A `NUL` shared by all three appears once.
    owned: [3]?windows.HANDLE = @splat(null),
    /// The parent's end of each pipe, by the stream it serves in the child.
    parent: [3]?std.Io.File = @splat(null),

    fn init(options: SpawnOptions) SpawnError!Plan {
        var plan: Plan = .{};
        errdefer plan.closeAllOnFailure();

        switch (options.stdio) {
            // Attached through the attribute list, not through handles.
            .pty => {},
            else => {
                const inherited = inheritedHandles();
                // One `NUL` serves every stream that asked for it.
                var nul: ?windows.HANDLE = null;
                for (options.stdio.perStream(), 0..) |stream, slot| switch (stream) {
                    // "The parent's" has to be said with the parent's handle:
                    // `STARTF_USESTDHANDLES` is all or nothing, so a null slot
                    // would hand the child no handle at all -- which is what
                    // `.close` means and not what `.inherit` does.
                    .inherit => plan.child[slot] = inherited[slot],
                    .close => plan.child[slot] = null,
                    .file => |f| {
                        // The caller's file has to be inheritable for the child
                        // to receive it, and this is the only way to say so
                        // about a handle somebody else opened.
                        _ = win32.SetHandleInformation(
                            f.handle,
                            win32.HANDLE_FLAG_INHERIT,
                            win32.HANDLE_FLAG_INHERIT,
                        );
                        plan.child[slot] = f.handle;
                    },
                    .ignore => {
                        const handle = nul orelse handle: {
                            const opened = try openNul();
                            plan.owned[slot] = opened;
                            nul = opened;
                            break :handle opened;
                        };
                        plan.child[slot] = handle;
                    },
                    .pipe => {
                        // Standard input is the one the child reads.
                        const ends = try makePipe(if (slot == 0) .to_child else .from_child);
                        plan.child[slot] = ends.child;
                        plan.owned[slot] = ends.child;
                        plan.parent[slot] = file(ends.parent);
                    },
                };
            },
        }

        if (options.stderr_to) |f| {
            // A stderr pipe that was planned is undone: the caller asked for
            // the file instead, and the file is theirs, not this `Plan`'s.
            if (plan.owned[2]) |handle| {
                windows.CloseHandle(handle);
                plan.owned[2] = null;
            }
            if (plan.parent[2]) |pipe_end| {
                windows.CloseHandle(pipe_end.handle);
                plan.parent[2] = null;
            }
            // The caller's file has to be inheritable for the child to receive
            // it, and this is the only way to say so about a handle somebody
            // else opened.
            _ = win32.SetHandleInformation(f.handle, win32.HANDLE_FLAG_INHERIT, win32.HANDLE_FLAG_INHERIT);
            plan.child[2] = f.handle;
        }

        return plan;
    }

    /// Closes the handles that exist only for the child, once `CreateProcessW`
    /// has duplicated them into it. Idempotent.
    fn closeOwned(plan: *Plan, io: std.Io) void {
        for (&plan.owned) |*slot| {
            const handle = slot.* orelse continue;
            file(handle).close(io);
            slot.* = null;
        }
    }

    /// The handles the child is being given, deduplicated, for the attribute
    /// list that stops it from inheriting anything else — or `null` when the
    /// child cannot be restricted that way.
    ///
    /// A `null` slot is `Stream.close`: there is nothing to inherit, and it is
    /// simply left out. A console handle is different. A child sharing this
    /// process's console reaches it through the console rather than through
    /// the handle table, and naming one in a handle list is how
    /// `CreateProcessW` comes back with `ERROR_INVALID_PARAMETER` — so a plan
    /// that hands the child a console gets no list at all, and inherits the
    /// way it always did. That is the case where this process is somebody's
    /// terminal rather than a program whose streams are pipes, and it is not
    /// the case the list is for.
    ///
    /// Every handle that does go in is marked inheritable first: a handle list
    /// may only name inheritable handles, and this process's own standard
    /// handles are whatever its parent made them. The list is what keeps that
    /// from meaning anything beyond this one spawn.
    fn inheritList(plan: *const Plan, arena: Allocator) Allocator.Error!?[]windows.HANDLE {
        var handles: std.ArrayList(windows.HANDLE) = .empty;
        for (plan.child) |slot| {
            const handle = slot orelse continue;
            if (isConsole(handle)) return null;
            if (std.mem.indexOfScalar(windows.HANDLE, handles.items, handle) != null) continue;
            _ = win32.SetHandleInformation(
                handle,
                win32.HANDLE_FLAG_INHERIT,
                win32.HANDLE_FLAG_INHERIT,
            );
            try handles.append(arena, handle);
        }
        if (handles.items.len == 0) return null;
        return handles.items;
    }

    /// The failure path inside `init`, which has no `std.Io` to hand.
    fn closeAllOnFailure(plan: *Plan) void {
        for (&plan.owned) |*slot| {
            const handle = slot.* orelse continue;
            windows.CloseHandle(handle);
            slot.* = null;
        }
        for (&plan.parent) |*slot| {
            const f = slot.* orelse continue;
            windows.CloseHandle(f.handle);
            slot.* = null;
        }
    }
};

/// Whether a handle is one of this process's console handles.
///
/// The console is the one thing a child gets without the handle table: a
/// process that shares this one's console has its console handles already, and
/// naming one in a handle list makes `CreateProcessW` fail.
fn isConsole(handle: windows.HANDLE) bool {
    var mode: win32.DWORD = undefined;
    return win32.GetConsoleMode(handle, &mode) != .FALSE;
}

/// This process's three standard handles, as a child inheriting them gets
/// them.
///
/// The process parameters rather than `GetStdHandle`, so a program whose own
/// standard streams were redirected by *its* parent passes on what it actually
/// has. A stream this process does not have is `null` here, and a child cannot
/// inherit what does not exist: that slot behaves as `Stream.close` does.
fn inheritedHandles() [3]?windows.HANDLE {
    const parameters = windows.peb().ProcessParameters;
    return .{
        parameters.hStdInput,
        parameters.hStdOutput,
        parameters.hStdError,
    };
}

const PipeDirection = enum { to_child, from_child };

const PipeEnds = struct {
    /// The end the child inherits.
    child: windows.HANDLE,
    /// The end this process keeps.
    parent: windows.HANDLE,
};

/// A pipe whose child end is inheritable and whose parent end is not.
///
/// Windows has no per-handle `O_CLOEXEC`: inheritance is a flag on the handle
/// and `CreateProcessW` takes every inheritable handle at once. So both ends
/// are created inheritable — there is no other way to ask — and the end this
/// process keeps has the flag cleared again immediately, which is what stops a
/// later, unrelated spawn from handing it to someone else.
fn makePipe(direction: PipeDirection) SpawnError!PipeEnds {
    var security: win32.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = .TRUE,
    };
    var read_end: windows.HANDLE = undefined;
    var write_end: windows.HANDLE = undefined;
    if (win32.CreatePipe(&read_end, &write_end, &security, 0) == .FALSE) return createError();

    const ends: PipeEnds = switch (direction) {
        .to_child => .{ .child = read_end, .parent = write_end },
        .from_child => .{ .child = write_end, .parent = read_end },
    };
    _ = win32.SetHandleInformation(ends.parent, win32.HANDLE_FLAG_INHERIT, 0);
    return ends;
}

/// The null device, opened for both directions and inheritable, so one handle
/// can serve all three of the child's streams.
fn openNul() SpawnError!windows.HANDLE {
    var security: win32.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = .TRUE,
    };
    const handle = win32.CreateFileW(
        std.unicode.wtf8ToWtf16LeStringLiteral("NUL"),
        win32.GENERIC_READ | win32.GENERIC_WRITE,
        win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
        &security,
        win32.OPEN_EXISTING,
        0,
        null,
    );
    if (handle == windows.INVALID_HANDLE_VALUE) return error.NoDevice;
    return handle;
}

//======================================================================
// The attribute list.
//======================================================================

/// A `PROC_THREAD_ATTRIBUTE_LIST`, whose size only the operating system knows.
///
/// The buffer is allocated from the caller's arena, but the list itself has to
/// be deleted with `DeleteProcThreadAttributeList` before that memory goes
/// away, which is what `deinit` is for.
const AttributeList = struct {
    raw: *win32.PROC_THREAD_ATTRIBUTE_LIST,

    fn init(arena: Allocator, count: u32) SpawnError!AttributeList {
        var size: win32.SIZE_T = 0;
        // Documented to fail with `ERROR_INSUFFICIENT_BUFFER` and report the
        // size it wants; a success here would mean a list of no bytes.
        _ = win32.InitializeProcThreadAttributeList(null, count, 0, &size);
        if (size == 0) return error.Unexpected;

        // Over-aligned rather than guessed at: the list holds pointers.
        const buffer = try arena.alignedAlloc(u8, .of(usize), size);
        const raw: *win32.PROC_THREAD_ATTRIBUTE_LIST = @ptrCast(buffer.ptr);
        if (win32.InitializeProcThreadAttributeList(raw, count, 0, &size) == .FALSE) {
            return createError();
        }
        return .{ .raw = raw };
    }

    /// Attaches a pseudoconsole to every process started with this list.
    ///
    /// `UpdateProcThreadAttribute` keeps a pointer to the value rather than
    /// copying it for some attributes, so the `HPCON` must stay put until
    /// `CreateProcessW` has returned. It does: the `Pty` outlives the spawn.
    fn setPseudoConsole(list: *AttributeList, console: win32.HPCON) SpawnError!void {
        if (win32.UpdateProcThreadAttribute(
            list.raw,
            0,
            win32.PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            console,
            @sizeOf(win32.HPCON),
            null,
            null,
        ) == .FALSE) return createError();
    }

    /// Limits what the child inherits to exactly these handles.
    ///
    /// `UpdateProcThreadAttribute` keeps a pointer to the array rather than
    /// copying it, so `handles` must outlive the `CreateProcessW` call. The
    /// arena it comes from does.
    fn setHandleList(list: *AttributeList, handles: []windows.HANDLE) SpawnError!void {
        if (win32.UpdateProcThreadAttribute(
            list.raw,
            0,
            win32.PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
            @ptrCast(handles.ptr),
            handles.len * @sizeOf(windows.HANDLE),
            null,
            null,
        ) == .FALSE) return createError();
    }

    fn deinit(list: *AttributeList) void {
        win32.DeleteProcThreadAttributeList(list.raw);
    }
};

//======================================================================
// The command line.
//======================================================================

/// Whether the program is a batch script, which this package refuses to run.
///
/// `cmd.exe` re-parses the command line of a `.bat` or `.cmd` with rules no
/// argument serialisation survives, so an argument containing the right
/// characters becomes a second command. Refusing is the only honest answer for
/// an API whose argument list is data; a caller who wants a script can invoke
/// `cmd.exe /c` themselves and take responsibility for what they pass it.
fn isBatchFile(program: []const u8) bool {
    return endsWithIgnoringCase(program, ".bat") or endsWithIgnoringCase(program, ".cmd");
}

fn endsWithIgnoringCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

/// Serialises `argv` into the single string `CreateProcessW` takes, by the
/// rules `CommandLineToArgvW` parses back.
///
/// The first argument is quoted differently from the rest: a backslash in it
/// has no special meaning, which makes a double quote in it impossible to
/// escape without letting characters leak into the arguments after it. Such an
/// `argv[0]` is refused rather than mangled. Every later argument is quoted
/// whenever it is empty or holds a space, a control character or a quote, with
/// backslashes doubled where they precede a quote.
fn commandLine(arena: Allocator, argv: []const []const u8) SpawnError![:0]u16 {
    var buffer: std.ArrayList(u8) = .empty;

    const program = argv[0];
    var program_needs_quotes = program.len == 0;
    for (program) |byte| {
        if (byte == '"') return error.InvalidArgv;
        if (byte <= ' ') program_needs_quotes = true;
    }
    if (program_needs_quotes) {
        try buffer.append(arena, '"');
        try buffer.appendSlice(arena, program);
        try buffer.append(arena, '"');
    } else {
        try buffer.appendSlice(arena, program);
    }

    for (argv[1..]) |argument| {
        try buffer.append(arena, ' ');

        const needs_quotes = for (argument) |byte| {
            if (byte <= ' ' or byte == '"') break true;
        } else argument.len == 0;
        if (!needs_quotes) {
            try buffer.appendSlice(arena, argument);
            continue;
        }

        try buffer.append(arena, '"');
        var backslashes: usize = 0;
        for (argument) |byte| switch (byte) {
            '\\' => backslashes += 1,
            '"' => {
                try buffer.appendNTimes(arena, '\\', backslashes * 2 + 1);
                try buffer.append(arena, '"');
                backslashes = 0;
            },
            else => {
                try buffer.appendNTimes(arena, '\\', backslashes);
                try buffer.append(arena, byte);
                backslashes = 0;
            },
        };
        // The run of backslashes before the closing quote is doubled, so the
        // quote stays a quote and the backslashes stay backslashes.
        try buffer.appendNTimes(arena, '\\', backslashes * 2);
        try buffer.append(arena, '"');
    }

    return std.unicode.wtf8ToWtf16LeAllocZ(arena, buffer.items);
}

//======================================================================
// Errors.
//======================================================================

/// `GetLastError` as one of `SpawnError`. Every call in this file that can
/// fail for a reason a caller might act on reports it this way.
fn createError() SpawnError {
    return switch (windows.GetLastError()) {
        .FILE_NOT_FOUND, .PATH_NOT_FOUND, .MOD_NOT_FOUND => error.FileNotFound,
        .ACCESS_DENIED => error.AccessDenied,
        .INVALID_NAME, .BAD_PATHNAME => error.FileNotFound,
        .FILENAME_EXCED_RANGE => error.NameTooLong,
        .DIRECTORY => error.BadWorkingDirectory,
        .BAD_EXE_FORMAT, .EXE_MACHINE_TYPE_MISMATCH, .INVALID_EXE_SIGNATURE => error.InvalidExe,
        .SHARING_VIOLATION => error.FileBusy,
        .NOT_ENOUGH_MEMORY, .OUTOFMEMORY => error.SystemResources,
        .TOO_MANY_OPEN_FILES => error.ProcessFdQuotaExceeded,
        .MAX_THRDS_REACHED => error.ResourceLimitReached,
        else => |err| win32.unexpected(err),
    };
}

//======================================================================
// Tests.
//======================================================================

const testing = std.testing;

fn expectCommandLine(expected: []const u8, argv: []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const line = try commandLine(arena_state.allocator(), argv);
    const utf8 = try std.unicode.wtf16LeToWtf8Alloc(testing.allocator, line);
    defer testing.allocator.free(utf8);
    try testing.expectEqualStrings(expected, utf8);
}

test "a command line quotes only what has to be quoted" {
    try expectCommandLine("cmd.exe", &.{"cmd.exe"});
    try expectCommandLine("cmd.exe /c echo", &.{ "cmd.exe", "/c", "echo" });
    try expectCommandLine("\"C:\\Program Files\\x.exe\"", &.{"C:\\Program Files\\x.exe"});
    try expectCommandLine("x.exe \"two words\"", &.{ "x.exe", "two words" });
    try expectCommandLine("x.exe \"\"", &.{ "x.exe", "" });
}

test "a command line escapes quotes and the backslashes before them" {
    try expectCommandLine("x.exe \"a\\\"b\"", &.{ "x.exe", "a\"b" });
    try expectCommandLine("x.exe \"a\\\\\\\"b\"", &.{ "x.exe", "a\\\"b" });
    try expectCommandLine("x.exe \"a b\\\\\\\\\"", &.{ "x.exe", "a b\\\\" });
    // A backslash that is not before a quote is left alone.
    try expectCommandLine("x.exe a\\b", &.{ "x.exe", "a\\b" });
}

test "a first argument containing a quote is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(
        error.InvalidArgv,
        commandLine(arena_state.allocator(), &.{"a\"b.exe"}),
    );
}

test "batch files are recognised whatever their case" {
    try testing.expect(isBatchFile("go.bat"));
    try testing.expect(isBatchFile("C:\\x\\GO.CMD"));
    try testing.expect(!isBatchFile("go.exe"));
    try testing.expect(!isBatchFile("bat"));
}
