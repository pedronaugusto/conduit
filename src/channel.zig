//! A two-way byte channel between a process and a child it starts.
//!
//! Standard streams go one way each and a pseudo-terminal is the child's
//! terminal, so a program that runs another and talks to it besides -- a host
//! telling its program the window's settings, a program asking back -- needs a
//! third stream that goes both ways. This is that stream and nothing more: the
//! bytes are the caller's, and so is whatever protocol they carry.
//!
//! The parent makes one with `open` and hands `child` to `Child.spawn` through
//! `SpawnOptions.channel`, which gives the child its end and names it in an
//! environment variable the caller chooses. The child opens its end with
//! `inherited`, from that variable.
//!
//! **POSIX**: a connected pair of Unix stream sockets. The child's end is one
//! of its descriptors above 2, placed the way `SpawnOptions.extra_fds` are,
//! and the variable holds its number.
//!
//! **Windows**: a duplex pipe with no name, made the way the standard library
//! makes a child's pipes (a pipe of the named-pipe device, opened again
//! relative to itself), so nothing else can open it. The child inherits its
//! end by handle, named in the attribute list beside a pseudoconsole when it
//! has one, and the variable holds the handle's value. Both ends are opened
//! for asynchronous I/O: a synchronous handle takes one call at a time, so a
//! read waiting on it would hold back a write to it.
//!
//! In the module of terminal primitives (`conduit.tty`), which links no C
//! library on Linux, because the child's half is wanted by a program that
//! draws its own screen and runs no child of its own.

const builtin = @import("builtin");
const std = @import("std");
const close_on_exec = @import("close_on_exec.zig");
const win32 = @import("win32");
const posix = std.posix;
const system = posix.system;
const windows = std.os.windows;

const is_windows = builtin.target.os.tag == .windows;

/// The two ends of a channel, each a stream both ways.
///
/// Both belong to the caller. `child` is handed to a spawn
/// (`SpawnOptions.channel`), which borrows it as it borrows `extra_fds`, and
/// is closed here once the spawn returns: a copy left open in this process
/// keeps the channel open after the child has gone, and `parent`'s reads
/// never see its end.
pub const Channel = struct {
    /// This process's end.
    parent: std.Io.File,
    /// The child's end, until a spawn has given the child its own.
    child: std.Io.File,

    pub const OpenError = error{
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        SystemResources,
    } || std.Io.UnexpectedError;

    /// A new channel. Neither end is inherited by any child but through
    /// `SpawnOptions.channel`: close-on-exec on POSIX, not inheritable on
    /// Windows.
    pub fn open() OpenError!Channel {
        return if (is_windows) openWindows() else openPosix();
    }

    pub const InheritedError = error{
        /// The variable names no channel: not a number, or nothing open at
        /// that number that a channel could be.
        NotAChannel,
    } || std.Io.UnexpectedError;

    /// The child's half: its end of the channel its parent named in
    /// `variable`, or `null` when the environment has no such variable, as in
    /// a child started by something that gave it no channel.
    ///
    /// The end is made private to this process here: close-on-exec on POSIX,
    /// not inheritable on Windows, so a program this one starts does not keep
    /// the channel open behind it. The variable is left in place.
    pub fn inherited(environ: *const std.process.Environ.Map, variable: []const u8) InheritedError!?std.Io.File {
        const value = environ.get(variable) orelse return null;
        return try fromValue(value);
    }

    /// The end a variable's value names: `inherited` without the lookup.
    pub fn fromValue(value: []const u8) InheritedError!std.Io.File {
        return if (is_windows) fromValueWindows(value) else fromValuePosix(value);
    }

    /// The variable's value for an end the child holds at `handle`: a decimal
    /// number, the descriptor on POSIX and the handle's value on Windows.
    pub fn valueOf(buffer: *[value_max]u8, handle: std.Io.File.Handle) []const u8 {
        const number: u64 = if (is_windows) @intFromPtr(handle) else @intCast(handle); // safe: the handle's value, written for the child to read, never dereferenced
        // unreachable: `value_max` is the length of the longest number
        return std.mem.print(buffer, "{d}", .{number}) catch unreachable;
    }

    /// The longest value `valueOf` writes.
    pub const value_max = std.fmt.count("{d}", .{std.math.maxInt(u64)});
};

//======================================================================
// POSIX
//======================================================================

/// Whether a socket is made close-on-exec in the one call. Darwin's headers
/// spell `SOCK_CLOEXEC` and its kernel refuses it.
const socket_flag = !is_windows and !builtin.target.os.tag.isDarwin() and @hasDecl(posix.SOCK, "CLOEXEC");

comptime {
    // Where the flag is a second call, `ForkGap` is what keeps conduit's
    // spawns out of the gap, and it holds only where a pipe needs it too.
    if (!is_windows and !socket_flag) std.debug.assert(close_on_exec.opening_is_two_calls);
}

fn openPosix() Channel.OpenError!Channel {
    var ends: [2]posix.fd_t = undefined;
    if (socket_flag) {
        try opened(system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &ends));
    } else {
        try close_on_exec.ForkGap.hold(pairMarked, .{&ends});
    }
    return .{ .parent = fileOf(ends[0]), .child = fileOf(ends[1]) };
}

fn pairMarked(ends: *[2]posix.fd_t) Channel.OpenError!void {
    try opened(system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM, 0, ends));
    errdefer for (ends) |fd| {
        _ = system.close(fd);
    };
    for (ends) |fd| try markPrivate(fd);
}

fn opened(rc: anytype) Channel.OpenError!void {
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOBUFS, .NOMEM => return error.SystemResources,
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn markPrivate(fd: posix.fd_t) std.Io.UnexpectedError!void {
    switch (posix.errno(system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC)))) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn fileOf(fd: posix.fd_t) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
}

fn fromValuePosix(value: []const u8) Channel.InheritedError!std.Io.File {
    const fd = std.fmt.parseInt(posix.fd_t, value, 10) catch return error.NotAChannel;
    if (fd < 0) return error.NotAChannel;
    // A stream socket is what `open` makes; anything else at that number --
    // nothing, a file, a pipe -- is not the channel the variable promises.
    var kind: i32 = undefined;
    var len: posix.socklen_t = @sizeOf(i32);
    switch (posix.errno(system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.TYPE, @ptrCast(&kind), &len))) { // aegis: boundary: the option is an int, its size beside it
        .SUCCESS => {},
        .BADF, .NOTSOCK => return error.NotAChannel,
        else => |err| return posix.unexpectedErrno(err),
    }
    if (kind != posix.SOCK.STREAM) return error.NotAChannel;
    try markPrivate(fd);
    return fileOf(fd);
}

//======================================================================
// Windows
//======================================================================

/// What each direction of a Windows channel holds before a write waits.
const pipe_quota = 64 * 1024;

fn openWindows() Channel.OpenError!Channel {
    const device = try namedPipeDevice();
    defer windows.CloseHandle(device);

    var server: windows.HANDLE = undefined;
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    // 120 s in NT's 100 ns units, negative for a time relative to now.
    const timeout: windows.LARGE_INTEGER = -1_200_000_000;
    switch (windows.ntdll.NtCreateNamedPipeFile(
        &server,
        .{
            .SPECIFIC = .{ .FILE_PIPE = .{ .READ_DATA = true, .WRITE_DATA = true, .WRITE_ATTRIBUTES = true } },
            .STANDARD = .{ .SYNCHRONIZE = true },
        },
        &.{ .RootDirectory = device, .Attributes = .{ .INHERIT = false } },
        &status_block,
        .{ .READ = true, .WRITE = true },
        .CREATE,
        .{ .IO = .ASYNCHRONOUS },
        .{ .TYPE = .BYTE_STREAM },
        .{ .MODE = .BYTE_STREAM },
        .{ .OPERATION = .QUEUE },
        1,
        pipe_quota,
        pipe_quota,
        &timeout,
    )) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => |status| return windows.unexpectedStatus(status),
    }
    errdefer windows.CloseHandle(server);

    var client: windows.HANDLE = undefined;
    switch (windows.ntdll.NtOpenFile(
        &client,
        .{
            .SPECIFIC = .{ .FILE_PIPE = .{ .READ_DATA = true, .WRITE_DATA = true, .WRITE_ATTRIBUTES = true } },
            .STANDARD = .{ .SYNCHRONIZE = true },
        },
        &.{ .RootDirectory = server, .Attributes = .{ .INHERIT = false } },
        &status_block,
        .{ .READ = true, .WRITE = true },
        .{ .IO = .ASYNCHRONOUS },
    )) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => |status| return windows.unexpectedStatus(status),
    }
    return .{
        .parent = .{ .handle = server, .flags = .{ .nonblocking = true } },
        .child = .{ .handle = client, .flags = .{ .nonblocking = true } },
    };
}

/// The named-pipe device, `\Device\NamedPipe\`, which a pipe with no name is
/// made relative to.
fn namedPipeDevice() Channel.OpenError!windows.HANDLE {
    var device: windows.HANDLE = undefined;
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    const name = std.unicode.wtf8ToWtf16LeStringLiteral("\\Device\\NamedPipe\\");
    switch (windows.ntdll.NtOpenFile(
        &device,
        .{ .STANDARD = .{ .SYNCHRONIZE = true } },
        &.{ .ObjectName = @constCast(&windows.UNICODE_STRING.init(name)) }, // aegis: boundary: the call reads the name and never writes it
        &status_block,
        .VALID_FLAGS,
        .{ .IO = .SYNCHRONOUS_NONALERT },
    )) {
        .SUCCESS => return device,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => |status| return windows.unexpectedStatus(status),
    }
}

fn fromValueWindows(value: []const u8) Channel.InheritedError!std.Io.File {
    const number = std.fmt.parseInt(usize, value, 10) catch return error.NotAChannel;
    if (number == 0) return error.NotAChannel;
    const handle: windows.HANDLE = @ptrFromInt(number); // aegis: boundary: a handle value the parent wrote, checked below as a pipe before any use
    if (win32.GetFileType(handle) != win32.file_type_pipe) return error.NotAChannel;

    // How the handle was opened decides how a read on it is made: a parent
    // that made the end synchronous gets a synchronous file.
    var mode: windows.FILE.MODE = undefined;
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    switch (windows.ntdll.NtQueryInformationFile(handle, &status_block, &mode, @sizeOf(windows.FILE.MODE), .Mode)) {
        .SUCCESS => {},
        .INVALID_HANDLE, .OBJECT_TYPE_MISMATCH => return error.NotAChannel,
        else => |status| return windows.unexpectedStatus(status),
    }
    switch (windows.ntdll.NtSetInformationObject(
        handle,
        .HandleFlag,
        &windows.OBJECT.HANDLE_FLAG{ .INHERIT = false },
        @sizeOf(windows.OBJECT.HANDLE_FLAG),
    )) {
        .SUCCESS => {},
        else => |status| return windows.unexpectedStatus(status),
    }
    return .{ .handle = handle, .flags = .{ .nonblocking = mode.IO == .ASYNCHRONOUS } };
}
