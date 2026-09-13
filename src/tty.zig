//! Terminal attributes, window size and identity of an open file descriptor.
//!
//! Every function here takes a raw `std.posix.fd_t` rather than a
//! `std.Io.File`, because a terminal ioctl is not one of the operations
//! `std.Io` abstracts: it is issued synchronously on the descriptor and never
//! blocks. The descriptor may be either end of a `Pty`, or the process's own
//! standard input when that is attached to a terminal.
//!
//! None of these functions take ownership of the descriptor.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;

/// The dimensions of a terminal.
///
/// `rows` and `cols` are character cells and are what programs read through
/// `TIOCGWINSZ`. The pixel fields are advisory: most terminals report zero for
/// them, and a program that needs a pixel size should treat zero as "unknown"
/// rather than as a real measurement.
pub const Size = struct {
    rows: u16,
    cols: u16,
    x_pixel: u16 = 0,
    y_pixel: u16 = 0,

    fn fromWinsize(ws: posix.winsize) Size {
        return .{
            .rows = ws.row,
            .cols = ws.col,
            .x_pixel = ws.xpixel,
            .y_pixel = ws.ypixel,
        };
    }

    fn toWinsize(size: Size) posix.winsize {
        return .{
            .row = size.rows,
            .col = size.cols,
            .xpixel = size.x_pixel,
            .ypixel = size.y_pixel,
        };
    }
};

/// The terminal attributes captured by `rawMode`, to be handed back to
/// `restore`.
///
/// This is an opaque snapshot: its one field is the platform `termios` and
/// callers should not interpret it. Keeping it in a named type leaves room to
/// carry more state on platforms that need it.
pub const Saved = struct {
    termios: posix.termios,
};

pub const RawModeError = error{
    /// The descriptor is not a terminal.
    NotATerminal,
    /// The process is in an orphaned process group and cannot change the
    /// attributes of its controlling terminal.
    ProcessOrphaned,
} || std.posix.UnexpectedError;

/// Puts the terminal into raw mode and returns the attributes it had before,
/// which `restore` puts back.
///
/// Raw mode means: no canonical line buffering, no echo, no signal generation
/// from INTR/QUIT/SUSP, no input or output post-processing, eight-bit
/// characters, and a read that returns as soon as one byte is available. It is
/// what a full-screen program wants from the terminal it draws on.
///
/// The change applies to the terminal, not to the descriptor, so it outlives
/// the process unless `restore` is called. Callers should pair the two with
/// `defer`.
pub fn rawMode(fd: posix.fd_t) RawModeError!Saved {
    const saved = try posix.tcgetattr(fd);

    var raw = saved;
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cflag.PARENB = false;
    raw.cflag.CSIZE = .CS8;
    // A read of the terminal returns as soon as one byte is there, and never
    // waits on a timer.
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    try posix.tcsetattr(fd, .FLUSH, raw);
    return .{ .termios = saved };
}

pub const RestoreError = RawModeError;

/// Puts back the attributes `rawMode` captured.
///
/// Pending input is discarded, so a key pressed while the terminal was raw is
/// not delivered to the program that follows.
pub fn restore(fd: posix.fd_t, saved: Saved) RestoreError!void {
    return posix.tcsetattr(fd, .FLUSH, saved.termios);
}

pub const WinSizeError = error{
    /// The descriptor is not a terminal, or is a terminal with no size.
    NotATerminal,
} || std.posix.UnexpectedError;

/// Reads the terminal's window size.
pub fn winSize(fd: posix.fd_t) WinSizeError!Size {
    var ws: posix.winsize = undefined;
    switch (posix.errno(c.ioctl(fd, T.GWINSZ, @intFromPtr(&ws)))) {
        .SUCCESS => return .fromWinsize(ws),
        .NOTTY, .INVAL => return error.NotATerminal,
        .BADF => unreachable, // Invalid descriptor.
        .FAULT => unreachable, // `ws` is on this stack.
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub const SetWinSizeError = WinSizeError;

/// Sets the terminal's window size.
///
/// On a pseudo-terminal this may be issued on either end and is seen by both.
/// The kernel sends `SIGWINCH` to the terminal's foreground process group when
/// the size changes, which is how a program running on the far end learns to
/// redraw; that signal only reaches a child that has the terminal as its
/// controlling terminal (see `Child.SpawnOptions.detach`).
pub fn setWinSize(fd: posix.fd_t, size: Size) SetWinSizeError!void {
    const ws = size.toWinsize();
    switch (posix.errno(c.ioctl(fd, T.SWINSZ, @intFromPtr(&ws)))) {
        .SUCCESS => return,
        .NOTTY, .INVAL => return error.NotATerminal,
        .BADF => unreachable, // Invalid descriptor.
        .FAULT => unreachable, // `ws` is on this stack.
        else => |err| return posix.unexpectedErrno(err),
    }
}

/// Whether the descriptor refers to a terminal.
///
/// This asks about the descriptor only. A descriptor can be a terminal without
/// being the process's controlling terminal, which is exactly the situation of
/// a child spawned on a pseudo-terminal without `detach`.
pub fn isTty(fd: posix.fd_t) bool {
    return c.isatty(fd) != 0;
}

pub const TtyNameError = error{
    /// The descriptor is not a terminal.
    NotATerminal,
    /// `buffer` is too short for the name and its terminating byte.
    NameTooLong,
} || std.posix.UnexpectedError;

/// Writes the pathname of the terminal into `buffer` and returns the part of
/// it that was used.
///
/// The result is a `/dev` path such as `/dev/pts/3` or `/dev/ttys004`. A
/// buffer of `std.fs.max_path_bytes` is always enough.
pub fn ttyName(fd: posix.fd_t, buffer: []u8) TtyNameError![]const u8 {
    if (buffer.len == 0) return error.NameTooLong;
    switch (@as(posix.E, @enumFromInt(ttyname_r(fd, buffer.ptr, buffer.len)))) {
        .SUCCESS => return std.mem.sliceTo(buffer, 0),
        .NOTTY, .BADF, .INVAL => return error.NotATerminal,
        .RANGE => return error.NameTooLong,
        else => |err| return posix.unexpectedErrno(err),
    }
}

/// `ttyname_r` returns the error number directly rather than through `errno`,
/// and is not declared in `std.c`.
extern "c" fn ttyname_r(fd: posix.fd_t, buf: [*]u8, buflen: usize) c_int;

/// The ioctl request numbers this package issues.
///
/// `std.c.T` carries them for most systems, but the Darwin table in the
/// standard library stops at `TIOCGWINSZ`, so the Darwin branch spells all
/// three out from `<sys/ttycom.h>`. They are `c_int` because that is what
/// `ioctl` takes, and the constants have the high bit set.
pub const T = switch (builtin.os.tag) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => struct {
        pub const GWINSZ: c_int = @bitCast(@as(u32, 0x40087468));
        pub const SWINSZ: c_int = @bitCast(@as(u32, 0x80087467));
        pub const SCTTY: c_int = @bitCast(@as(u32, 0x20007461));
    },
    else => struct {
        pub const GWINSZ: c_int = @bitCast(@as(u32, c.T.IOCGWINSZ));
        pub const SWINSZ: c_int = @bitCast(@as(u32, c.T.IOCSWINSZ));
        pub const SCTTY: c_int = @bitCast(@as(u32, c.T.IOCSCTTY));
    },
};
