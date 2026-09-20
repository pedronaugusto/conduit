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
const command_line = @import("command_line.zig");
const Pty = @import("Pty.zig");
const stdio_plan = @import("stdio_plan.zig");
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

    try refuseWhatWindowsCannotDo(options);

    // `CreateProcessW` writes to the command line it is given, so it must be a
    // mutable buffer. `lpApplicationName` is left null on purpose: the system
    // then resolves the program from the command line, searching the
    // application directory, the current directory, the system directories and
    // `PATH`, and appending `.exe` when there is no extension. That is what a
    // caller passing a bare program name means, and reimplementing it here
    // would only be a second, worse copy.
    const line = try command_line.serialise(arena, options.argv);

    const environment: ?[*:0]const u16 = if (options.environ) |map| env: {
        const block = try map.createWindowsBlock(arena, .{});
        break :env block.slice.ptr;
    } else null;

    const cwd = try workingDirectory(arena, options.cwd);

    var plan: Plan = try .init(io, options, null);
    errdefer plan.closeAll(io);
    const given = childHandles(&plan);

    // The caller's handles get their inheritance flags back whatever happens
    // next, including on every path that returns an error below.
    var inheritance: Inheritance = .{};
    defer inheritance.restore();

    var startup: win32.STARTUPINFOEXW = std.mem.zeroes(win32.STARTUPINFOEXW);
    var flags: windows.CreateProcessFlags = .{
        .create_new_process_group = options.detach,
        .create_unicode_environment = environment != null,
    };

    // What the child is attached to or handed, in the shape `CreateProcessW`
    // takes it: a pseudoconsole through an attribute list, or three standard
    // handles and a list of what may be inherited.
    var attributes: ?AttributeList = null;
    defer if (attributes) |*list| list.deinit();
    try describeChild(arena, options, given, &inheritance, &startup, &flags, &attributes);

    // A console handle is already meaningful to a child sharing this
    // process's console and is not inherited through the handle table. Every
    // other handle is named in the restrictive attribute list below. With no
    // such handle there is nothing to inherit, so passing FALSE is what keeps
    // unrelated inheritable handles out of the child.
    const inherit_handles: windows.BOOL = switch (options.stdio) {
        .pty => .FALSE,
        else => inherit: {
            for (given) |slot| {
                const handle = slot orelse continue;
                if (!isConsole(handle)) break :inherit .TRUE;
            }
            break :inherit .FALSE;
        },
    };

    traceSpawn(options, &startup, flags, inherit_handles);

    // The child is started suspended and put in its job before it runs, so
    // there is no moment in which it exists outside one -- a child that got as
    // far as starting something of its own first would have left that
    // something outside the job, which is the whole thing the job is for.
    flags.create_suspended = true;

    const job = try createJob(options.job_limits);
    errdefer job.close();

    var information: windows.PROCESS.INFORMATION = undefined;
    if (windows.kernel32.CreateProcessW(
        null,
        line.ptr,
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

    if (win32.AssignProcessToJobObject(job.handle, information.hProcess) == .FALSE) {
        return error.JobAssignmentFailed;
    }
    if (win32.ResumeThread(information.hThread) == std.math.maxInt(win32.DWORD)) {
        return createError();
    }

    plan.closeChildSide(io);

    return .{
        .id = information.hProcess,
        .thread = information.hThread,
        .job = job.handle,
        .job_port = job.port,
        .tree_ended = false,
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

/// Says what the child is attached to or handed, in the two records
/// `CreateProcessW` takes them in.
///
/// A pseudoconsole is attached through an attribute list rather than through
/// the standard handles, and the two are mutually exclusive:
/// `STARTF_USESTDHANDLES` alongside `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` is
/// documented as unsupported. Nothing needs to be inheritable in that case
/// either, which is why `inheritHandles` differs.
fn describeChild(
    arena: Allocator,
    options: SpawnOptions,
    given: [3]?windows.HANDLE,
    inheritance: *Inheritance,
    startup: *win32.STARTUPINFOEXW,
    flags: *windows.CreateProcessFlags,
    attributes: *?AttributeList,
) SpawnError!void {
    switch (options.stdio) {
        .pty => |pty| {
            const console = pty.slave.?;
            var list = try AttributeList.init(arena, 1);
            try list.setPseudoConsole(console);
            if (trace.enabled()) {
                trace.print("spawn: pseudoconsole attribute set, hpcon=0x{x}", .{@intFromPtr(console)});
            }
            attributes.* = list;
            startup.StartupInfo.cb = @sizeOf(win32.STARTUPINFOEXW);
            startup.lpAttributeList = list.raw;
            flags.extended_startupinfo_present = true;

            // And no standard handles, said out loud. `CreateProcessW` gives a
            // child the parent's standard handles even with `bInheritHandles`
            // false, when those handles are not console handles: they are
            // duplicated into the child as a special case. So a program whose
            // own streams are pipes -- which is every program a build system, a
            // service or a test harness starts -- would hand a child on a
            // pseudoconsole the parent's pipes, and everything the child wrote
            // would go there rather than to the console it is attached to. From
            // a terminal it looks right, because console handles are not
            // duplicated and the child falls back to its console; everywhere
            // else it is wrong.
            //
            // `STARTF_USESTDHANDLES` with all three left null is how a child is
            // given none, and a child with none uses the console it has, which
            // is the pseudoconsole. This is not the combination Windows
            // documents as unsupported alongside a pseudoconsole -- that is
            // *naming* a handle, which is why `stderr_to` with `.pty` is
            // refused rather than merged in here.
            startup.StartupInfo.dwFlags = win32.STARTF_USESTDHANDLES;
        },
        else => {
            startup.StartupInfo.cb = @sizeOf(win32.STARTUPINFOW);
            startup.StartupInfo.dwFlags = win32.STARTF_USESTDHANDLES;
            startup.StartupInfo.hStdInput = given[0];
            startup.StartupInfo.hStdOutput = given[1];
            startup.StartupInfo.hStdError = given[2];

            // A handle the child is to inherit has to be marked inheritable,
            // and this is the only way to say so about one somebody else
            // opened. `Inheritance` is what puts the caller's flag back.
            for (given) |slot| if (slot) |handle| inheritance.take(handle);

            // And nothing else. `bInheritHandles` on its own hands the child
            // every inheritable handle this process holds -- which on a machine
            // where this program's own standard streams are inheritable pipes
            // means the child, and anything the child starts, keeps those pipes
            // open for as long as it lives. A handle list says exactly which
            // three the child is being given.
            if (try inheritList(given, arena)) |inheritable| {
                var list = try AttributeList.init(arena, 1);
                try list.setHandleList(inheritable);
                attributes.* = list;
                startup.StartupInfo.cb = @sizeOf(win32.STARTUPINFOEXW);
                startup.lpAttributeList = list.raw;
                flags.extended_startupinfo_present = true;
            }
        },
    }
}

/// The child's working directory, as `CreateProcessW` wants it, and `null` for
/// a child that inherits this process's.
///
/// The directory is looked at here rather than left to `CreateProcessW`, which
/// reports one that is not there with an error code it also uses for other
/// things -- a program at a path that does not exist is one of them -- so the
/// two would be indistinguishable afterwards. `spawn` promises
/// `BadWorkingDirectory` for one and `FileNotFound` for the other on both
/// systems, and on POSIX the fork child reports which step failed; this is what
/// keeps that promise here. A directory that goes away between this and the
/// spawn comes back as whatever `CreateProcessW` makes of it, which is the
/// ordinary cost of asking first.
fn workingDirectory(arena: Allocator, wanted: ?[]const u8) SpawnError!?[*:0]const u16 {
    const dir = wanted orelse return null;
    const wide = (try std.unicode.wtf8ToWtf16LeAllocZ(arena, dir)).ptr;
    const attributes = win32.GetFileAttributesW(wide);
    if (attributes == win32.INVALID_FILE_ATTRIBUTES) return error.BadWorkingDirectory;
    if (attributes & win32.FILE_ATTRIBUTE_DIRECTORY == 0) return error.BadWorkingDirectory;
    return wide;
}

/// The options this system has no way to honour, refused rather than accepted
/// and quietly dropped.
fn refuseWhatWindowsCannotDo(options: SpawnOptions) SpawnError!void {
    // The program is resolved by `CreateProcessW`, from the environment the
    // child is being given -- see the note on `lpApplicationName` in `spawn`.
    // That is exactly `.child_environ`, and there is no argument to ask it for
    // anything else, so the other two are refused rather than accepted and
    // quietly not done.
    if (options.path_search != .child_environ) return error.Unsupported;

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
    // with no counterpart here. The job object below is what bounds a child on
    // this system, and it bounds the whole tree rather than the one process;
    // `SpawnOptions.job_limits` is the option that reaches it. Accepting the
    // POSIX list and setting nothing would be the worst of both.
    if (options.resource_limits.len != 0) return error.Unsupported;
}

/// What this package asked the operating system for, when `CONDUIT_TRACE` says
/// to print it.
fn traceSpawn(
    options: SpawnOptions,
    startup: *const win32.STARTUPINFOEXW,
    flags: windows.CreateProcessFlags,
    inherit_handles: windows.BOOL,
) void {
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
}

//======================================================================
// The job object.
//======================================================================

/// A job object and the port it reports on.
const Job = struct {
    handle: windows.HANDLE,
    port: windows.HANDLE,

    fn close(job: Job) void {
        windows.CloseHandle(job.handle);
        windows.CloseHandle(job.port);
    }
};

/// The container the child and everything it starts will live in.
///
/// Every child on this system gets one, because it is what makes `kill` reach
/// the tree and what `deinit` closes to end whatever the child left behind.
/// `limits` is what the caller wants bounded inside it, and a caller who wants
/// nothing bounded pays for one extra call and no more.
///
/// The port is associated before anything is in the job, which is what makes
/// `Child.waitTree` possible: the message that says the job is empty is posted
/// on the transition to empty, so a port attached after the child had already
/// started and stopped would hear nothing and wait forever.
fn createJob(limits: Child.JobLimits) SpawnError!Job {
    const handle = win32.CreateJobObjectW(null, null) orelse return createError();
    errdefer windows.CloseHandle(handle);

    const port = win32.CreateIoCompletionPort(
        windows.INVALID_HANDLE_VALUE,
        null,
        0,
        1,
    ) orelse return createError();
    errdefer windows.CloseHandle(port);

    // The job handle as the key, so a message that arrives on this port can be
    // told to be this job's. One port per job makes that a formality; a key
    // that means nothing would not.
    var association: win32.JOBOBJECT_ASSOCIATE_COMPLETION_PORT = .{
        .CompletionKey = handle,
        .CompletionPort = port,
    };
    if (win32.SetInformationJobObject(
        handle,
        win32.JobObjectAssociateCompletionPortInformation,
        &association,
        @sizeOf(win32.JOBOBJECT_ASSOCIATE_COMPLETION_PORT),
    ) == .FALSE) return createError();

    const job: Job = .{ .handle = handle, .port = port };

    var extended: win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std.mem.zeroes(
        win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
    );
    var flags = win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    if (limits.active_processes) |most| {
        flags |= win32.JOB_OBJECT_LIMIT_ACTIVE_PROCESS;
        extended.BasicLimitInformation.ActiveProcessLimit = most;
    }
    if (limits.process_memory_bytes) |bytes| {
        flags |= win32.JOB_OBJECT_LIMIT_PROCESS_MEMORY;
        extended.ProcessMemoryLimit = bytes;
    }
    if (limits.job_memory_bytes) |bytes| {
        flags |= win32.JOB_OBJECT_LIMIT_JOB_MEMORY;
        extended.JobMemoryLimit = bytes;
    }
    extended.BasicLimitInformation.LimitFlags = flags;
    if (win32.SetInformationJobObject(
        job.handle,
        win32.JobObjectExtendedLimitInformation,
        &extended,
        @sizeOf(win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION),
    ) == .FALSE) return createError();

    // A second call, because the processor share is a different information
    // class from the rest -- it is scheduling rather than a limit on a
    // resource the job holds.
    if (limits.cpu_rate) |rate| {
        var control: win32.JOBOBJECT_CPU_RATE_CONTROL_INFORMATION = .{
            .ControlFlags = win32.JOB_OBJECT_CPU_RATE_CONTROL_ENABLE |
                win32.JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP,
            .Value = rate,
        };
        if (win32.SetInformationJobObject(
            job.handle,
            win32.JobObjectCpuRateControlInformation,
            &control,
            @sizeOf(win32.JOBOBJECT_CPU_RATE_CONTROL_INFORMATION),
        ) == .FALSE) return createError();
    }

    return job;
}

//======================================================================
// Standard handles.
//======================================================================

/// The handles a spawn involves. `stdio_plan` holds the policy; what is here
/// is the two calls that open a handle on this system.
const Plan = stdio_plan.Plan(struct {
    pub const Error = SpawnError;
    pub const openNull = openNul;

    pub fn openPipe(child_reads: bool) SpawnError!stdio_plan.Pipe {
        return makePipe(if (child_reads) .to_child else .from_child);
    }
});

/// The handles the child is being given, in the order `STARTF_USESTDHANDLES`
/// names them.
///
/// `Target.inherit` has to be said with the parent's own handle here: naming
/// the child's standard handles is all or nothing, so a null slot would hand
/// the child nothing at all -- which is what `.close` means and not what
/// `.inherit` does. A stream this process does not have is `null` either way,
/// and a child cannot inherit what does not exist.
fn childHandles(plan: *const Plan) [3]?windows.HANDLE {
    const inherited = inheritedHandles();
    var given: [3]?windows.HANDLE = @splat(null);
    for (plan.child, 0..) |target, slot| given[slot] = switch (target) {
        .inherit => inherited[slot],
        .place => |handle| handle,
        .close => null,
    };
    return given;
}

/// Every handle a child inherits has to be marked inheritable, and a handle
/// this package did not open is the caller's: leaving it marked would mean the
/// next spawn anywhere in the process handed it on to a child that was never
/// meant to have it.
///
/// So the flag is put back. This remembers what each handle had before
/// `CreateProcessW` was told about it, and `restore` puts that back afterwards
/// -- on the success path and on every failure path alike. The handles this
/// package opened itself are created inheritable and are closed rather than
/// restored, so they are not in here.
const Inheritance = struct {
    /// The handles whose flags were changed, and the flags they had.
    saved: [3]Saved = undefined,
    count: usize = 0,

    const Saved = struct { handle: windows.HANDLE, flags: win32.DWORD };

    /// Marks `handle` inheritable, remembering what it was.
    ///
    /// A handle already in the list is not saved twice: the first answer is
    /// the one from before anything here touched it.
    fn take(inheritance: *Inheritance, handle: windows.HANDLE) void {
        for (inheritance.saved[0..inheritance.count]) |already| {
            if (already.handle == handle) return;
        }
        var flags: win32.DWORD = 0;
        if (win32.GetHandleInformation(handle, &flags) == .FALSE) return;
        if (inheritance.count < inheritance.saved.len) {
            inheritance.saved[inheritance.count] = .{ .handle = handle, .flags = flags };
            inheritance.count += 1;
        }
        _ = win32.SetHandleInformation(
            handle,
            win32.HANDLE_FLAG_INHERIT,
            win32.HANDLE_FLAG_INHERIT,
        );
    }

    /// Puts every remembered flag back. Idempotent.
    fn restore(inheritance: *Inheritance) void {
        for (inheritance.saved[0..inheritance.count]) |already| {
            _ = win32.SetHandleInformation(
                already.handle,
                win32.HANDLE_FLAG_INHERIT,
                already.flags & win32.HANDLE_FLAG_INHERIT,
            );
        }
        inheritance.count = 0;
    }
};

/// The handles the child is being given, deduplicated, for the attribute list
/// that stops it from inheriting anything else — or `null` when there is no
/// handle-table handle to inherit.
///
/// A `null` slot is `Stream.close`: there is nothing to inherit, and it is
/// simply left out. A console handle is different. A child sharing this
/// process's console reaches it through the console rather than through the
/// handle table, and naming one in a handle list is how `CreateProcessW` comes
/// back with `ERROR_INVALID_PARAMETER`, so it too is left out. Any ordinary
/// handles beside it are still listed, and an all-console or all-closed plan
/// uses `bInheritHandles=FALSE`.
///
/// Every handle in the list is inheritable already: `Inheritance.take` has
/// been over them, and is what puts the caller's flags back afterwards.
fn inheritList(given: [3]?windows.HANDLE, arena: Allocator) Allocator.Error!?[]windows.HANDLE {
    var list: std.ArrayList(windows.HANDLE) = .empty;
    for (given) |slot| {
        const handle = slot orelse continue;
        if (isConsole(handle)) continue;
        if (std.mem.indexOfScalar(windows.HANDLE, list.items, handle) != null) continue;
        try list.append(arena, handle);
    }
    if (list.items.len == 0) return null;
    return list.items;
}

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

/// A pipe whose child end is inheritable and whose parent end is not.
///
/// Windows has no per-handle `O_CLOEXEC`: inheritance is a flag on the handle
/// and `CreateProcessW` takes every inheritable handle at once. So both ends
/// are created inheritable — there is no other way to ask — and the end this
/// process keeps has the flag cleared again immediately, which is what stops a
/// later, unrelated spawn from handing it to someone else.
fn makePipe(direction: PipeDirection) SpawnError!stdio_plan.Pipe {
    var security: win32.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = .TRUE,
    };
    var read_end: windows.HANDLE = undefined;
    var write_end: windows.HANDLE = undefined;
    if (win32.CreatePipe(&read_end, &write_end, &security, 0) == .FALSE) return createError();

    const ends: stdio_plan.Pipe = switch (direction) {
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
// The program.
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

test "batch files are recognised whatever their case" {
    try testing.expect(isBatchFile("go.bat"));
    try testing.expect(isBatchFile("C:\\x\\GO.CMD"));
    try testing.expect(!isBatchFile("go.exe"));
    try testing.expect(!isBatchFile("bat"));
}
