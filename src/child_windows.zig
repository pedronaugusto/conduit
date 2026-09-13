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
const win32 = @import("win32.zig");

const SpawnError = Child.SpawnError;
const SpawnOptions = Child.SpawnOptions;

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
            var list = try AttributeList.init(arena, 1);
            try list.setPseudoConsole(pty.slave.?);
            attributes = list;
            startup.StartupInfo.cb = @sizeOf(win32.STARTUPINFOEXW);
            startup.lpAttributeList = list.raw;
            flags.extended_startupinfo_present = true;
        },
        else => {
            startup.StartupInfo.cb = @sizeOf(win32.STARTUPINFOW);
            startup.StartupInfo.dwFlags = win32.STARTF_USESTDHANDLES;
            startup.StartupInfo.hStdInput = plan.child[0];
            startup.StartupInfo.hStdOutput = plan.child[1];
            startup.StartupInfo.hStdError = plan.child[2];
        },
    }
    const inherit_handles: windows.BOOL = switch (options.stdio) {
        .pty => .FALSE,
        else => .TRUE,
    };

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

    plan.closeOwned(io);

    return .{
        .id = information.hProcess,
        .thread = information.hThread,
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
            .inherit => plan.child = inheritedHandles(),
            .ignore => {
                const nul = try openNul();
                plan.child = @splat(nul);
                plan.owned[0] = nul;
            },
            .pipes => |which| {
                // A stream that is not piped is the parent's, which needs
                // saying here: `STARTF_USESTDHANDLES` is all or nothing, so
                // leaving a slot null would hand the child no handle at all
                // rather than this process's -- the same option meaning two
                // different things on the two systems.
                plan.child = inheritedHandles();
                if (which.stdin) {
                    const ends = try makePipe(.to_child);
                    plan.child[0] = ends.child;
                    plan.owned[0] = ends.child;
                    plan.parent[0] = file(ends.parent);
                }
                if (which.stdout) {
                    const ends = try makePipe(.from_child);
                    plan.child[1] = ends.child;
                    plan.owned[1] = ends.child;
                    plan.parent[1] = file(ends.parent);
                }
                if (which.stderr) {
                    const ends = try makePipe(.from_child);
                    plan.child[2] = ends.child;
                    plan.owned[2] = ends.child;
                    plan.parent[2] = file(ends.parent);
                }
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

/// This process's three standard handles, as a child inheriting them gets
/// them.
///
/// The process parameters rather than `GetStdHandle`, so a program whose own
/// standard streams were redirected by *its* parent passes on what it actually
/// has.
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

fn file(handle: windows.HANDLE) std.Io.File {
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
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
        else => |err| windows.unexpectedError(err),
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
