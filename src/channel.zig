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
const held = @import("held.zig");
const win32 = @import("win32");
const aegis = @import("aegis");
const posix = std.posix;
const system = posix.system;
const windows = std.os.windows;

const is_windows = builtin.target.os.tag == .windows;

/// The two ends of a channel, each a stream both ways.
///
/// Both belong to the caller, who closes each with `deinit(io)`. `child` is
/// lent to a spawn (`SpawnOptions.channel`), which borrows it as it borrows
/// `extra_fds`, and is closed here once the spawn returns: a copy left open
/// in this process keeps the channel open after the child has gone, and
/// `parent`'s reads never see its end.
pub const Channel = struct {
    /// This process's end.
    parent: held.OwnedFile,
    /// The child's end, until a spawn has given the child its own.
    child: held.OwnedFile,

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
    /// the channel open behind it. The variable is left in place. The end is
    /// the caller's, closed with `deinit(io)`.
    pub fn inherited(environ: *const std.process.Environ.Map, variable: []const u8) InheritedError!?held.OwnedFile {
        const value = environ.get(variable) orelse return null;
        return try fromValue(value);
    }

    /// The end a variable's value names: `inherited` without the lookup.
    pub fn fromValue(value: []const u8) InheritedError!held.OwnedFile {
        return if (is_windows) fromValueWindows(value) else fromValuePosix(value);
    }

    /// The variable's value for an end the child holds at `handle`: a decimal
    /// number, the descriptor on POSIX and the handle's value on Windows.
    pub fn valueOf(buffer: *[value_max]u8, handle: std.Io.File.Handle) []const u8 {
        const number: u64 = if (is_windows) @intFromPtr(handle) else @intCast(handle); // safe: the handle's value, written for the child to read, never dereferenced
        // `value_max` is the length of the longest number, so it always fits.
        return buffer[0..std.fmt.printInt(buffer, number, 10, .lower, .{})];
    }

    /// The longest value `valueOf` writes.
    pub const value_max = std.fmt.count("{d}", .{std.math.maxInt(u64)});

    /// An end of a channel, read and written as what it is: a connected
    /// stream socket on POSIX, through std's socket reader and writer, and a
    /// duplex pipe on Windows, through its file reader and writer. Each is
    /// handed out as aegis's stream end (`Reader.ends` an
    /// `aegis.io.ReadEnd`, `Writer.ends` an `aegis.io.WriteEnd`), so a
    /// failure keeps its cause beside it. The other side closing is told,
    /// however it closed: a reader ends (`error.EndOfStream`) where it
    /// closed cleanly, and a read or write it cuts short fails with the
    /// cause `Closed`, never the errno the system said it with. (On Linux a
    /// write to a socket whose other side closed with bytes unread is
    /// `ECONNRESET`, which std's file calls take for a descriptor that is
    /// no socket and stop the program on.) One task may read while another
    /// writes.
    pub const End = struct {
        file: held.OwnedFile,

        /// The cause a read or a write fails with once the other side has
        /// gone: what was not read is lost, what was not written is never
        /// read.
        pub const Closed = error.Closed;

        /// The end `file` is: `Channel.parent`, or what `inherited` gives.
        pub fn of(file: held.OwnedFile) End {
            return .{ .file = file };
        }

        pub fn deinit(end: *End, io: std.Io) void {
            end.file.deinit(io);
            end.* = undefined;
        }

        /// A reader of the end, over `buffer`.
        pub fn reader(end: *End, io: std.Io, buffer: []u8) Reader {
            return .{ .inner = if (is_windows) .initStreaming(end.file.borrow().*, io, buffer) else .init(end.stream(), io, buffer) };
        }

        /// A writer to the end, over `buffer`.
        pub fn writer(end: *End, io: std.Io, buffer: []u8) Writer {
            return .{ .inner = if (is_windows) .initStreaming(end.file.borrow().*, io, buffer) else .init(end.stream(), io, buffer) };
        }

        /// The socket the end is, as std's stream: a pair's socket has no
        /// address, so it is none of an internet socket's.
        fn stream(end: *End) std.Io.net.Stream {
            return .{ .socket = .{ .handle = end.file.borrow().handle, .address = .{ .ip4 = .unspecified(0) } } };
        }

        pub const Reader = struct {
            inner: if (is_windows) std.Io.File.Reader else std.Io.net.Stream.Reader,

            /// The reader's end: its interface, and why its last read
            /// failed, `Closed` where the other side cut it short.
            pub fn ends(r: *Reader) aegis.io.ReadEnd {
                return .init(&r.inner.interface, r, cause);
            }

            fn cause(context: *const anyopaque) ?anyerror {
                const r: *const Reader = @ptrCast(@alignCast(context)); // safe: `ends` passes a Reader
                return closure(r.inner.err orelse return null);
            }
        };

        pub const Writer = struct {
            inner: if (is_windows) std.Io.File.Writer else std.Io.net.Stream.Writer,

            /// The writer's end: its interface, and why its last write
            /// failed, `Closed` where the other side has gone.
            pub fn ends(w: *Writer) aegis.io.WriteEnd {
                return .init(&w.inner.interface, w, cause);
            }

            fn cause(context: *const anyopaque) ?anyerror {
                const w: *const Writer = @ptrCast(@alignCast(context)); // safe: `ends` passes a Writer
                return closure(w.inner.err orelse return null);
            }
        };

        /// A failure's cause, `Closed` for every way the system says the
        /// other side has gone: a reset (`ECONNRESET`), a socket whose
        /// reading side shut (`EPIPE`), a broken pipe on Windows.
        fn closure(cause: anyerror) anyerror {
            return switch (cause) {
                error.ConnectionResetByPeer, error.SocketUnconnected, error.BrokenPipe => Closed,
                else => cause,
            };
        }
    };
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
    if (!is_windows and !socket_flag) aegis.assert.invariant(close_on_exec.opening_is_two_calls, "close_on_exec.opening_is_two_calls");
}

fn openPosix() Channel.OpenError!Channel {
    var ends: [2]posix.fd_t = undefined;
    if (socket_flag) {
        try opened(system.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &ends));
    } else {
        try close_on_exec.ForkGap.hold(pairMarked, .{&ends});
    }
    return .{ .parent = held.own(ends[0]), .child = held.own(ends[1]) };
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

fn fromValuePosix(value: []const u8) Channel.InheritedError!held.OwnedFile {
    const fd = std.fmt.parseInt(posix.fd_t, value, 10) catch return error.NotAChannel;
    if (fd < 0) return error.NotAChannel;
    // A stream socket is what `open` makes; anything else at that number --
    // nothing, a file, a pipe -- is not the channel the variable promises.
    var kind: i32 = undefined;
    var len: posix.socklen_t = @sizeOf(i32);
    switch (posix.errno(system.getsockopt(fd, posix.SOL.SOCKET, posix.SO.TYPE, std.mem.asBytes(&kind), &len))) {
        .SUCCESS => {},
        .BADF, .NOTSOCK => return error.NotAChannel,
        else => |err| return posix.unexpectedErrno(err),
    }
    if (kind != posix.SOCK.STREAM) return error.NotAChannel;
    try markPrivate(fd);
    return held.own(fd);
}

//======================================================================
// Windows
//======================================================================

fn openWindows() Channel.OpenError!Channel {
    // Both ends overlapped, as each side of a channel reads while it may write.
    const ends = try win32.pipe.create(.{
        .server = .{ .overlapped = true },
        .client = .{ .overlapped = true },
        .inbound = true,
        .outbound = true,
    });
    return .{
        .parent = .init(.{ .handle = ends[0], .flags = .{ .nonblocking = true } }),
        .child = .init(.{ .handle = ends[1], .flags = .{ .nonblocking = true } }),
    };
}

fn fromValueWindows(value: []const u8) Channel.InheritedError!held.OwnedFile {
    const number = std.fmt.parseInt(usize, value, 10) catch return error.NotAChannel;
    if (number == 0) return error.NotAChannel;
    const handle: windows.HANDLE = @ptrFromInt(number);
    if (win32.GetFileType(handle) != win32.file_type_pipe) return error.NotAChannel;

    // How the handle was opened decides how a read on it is made: a parent
    // that made the end synchronous gets a synchronous file.
    var mode: windows.FILE.MODE = undefined;
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    // NtQueryInformationFile writes the status block and the mode where it answers SUCCESS
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
    return .init(.{ .handle = handle, .flags = .{ .nonblocking = mode.IO == .ASYNCHRONOUS } });
}
