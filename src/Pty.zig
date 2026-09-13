//! A pseudo-terminal pair: a master descriptor a program reads and writes, and
//! a slave descriptor that behaves like a terminal to whatever is connected to
//! it.
//!
//! The pair is opened through the POSIX 98 interface (`posix_openpt`,
//! `grantpt`, `unlockpt`, `ptsname_r`), which is available on Linux, the BSDs
//! and Darwin. Both descriptors are owned by the `Pty` until `close`,
//! `closeSlave` or `closeMaster` is called; see the ownership note on
//! `Child.spawn` for which end a parent should keep.

const Pty = @This();

const std = @import("std");
const posix = std.posix;
const c = std.c;
const tty = @import("tty.zig");

const Size = tty.Size;

/// The controlling end. A program writes what it wants the child to see as
/// keyboard input, and reads what the child writes to its terminal.
///
/// `closed` once `close` or `closeMaster` has been called.
master: posix.fd_t,
/// The terminal end. This is what a child process gets as its standard input,
/// output and error.
///
/// `closed` once `close` or `closeSlave` has been called.
slave: posix.fd_t,

/// The value an end has once it is closed. Not a valid descriptor.
pub const closed: posix.fd_t = -1;

/// The initial terminal geometry of a new pair.
///
/// The defaults are the historical terminal size, which is what a program
/// assumes when nothing tells it otherwise. Pixel dimensions default to zero,
/// which terminals read as "not reported".
pub const OpenOptions = struct {
    rows: u16 = 24,
    cols: u16 = 80,
    x_pixel: u16 = 0,
    y_pixel: u16 = 0,
};

pub const OpenError = error{
    /// The per-process descriptor limit was reached.
    ProcessFdQuotaExceeded,
    /// The system-wide descriptor limit was reached.
    SystemFdQuotaExceeded,
    /// No pseudo-terminal is available.
    NoDevice,
    /// The slave device could not be opened with the current credentials.
    PermissionDenied,
} || std.posix.UnexpectedError;

/// Opens a new pseudo-terminal pair with the given geometry.
///
/// On success the caller owns both descriptors and must eventually call
/// `close`, or `closeSlave` and `closeMaster` separately. On failure no
/// descriptor is leaked.
pub fn open(options: OpenOptions) OpenError!Pty {
    const master = posix_openpt(.{ .ACCMODE = .RDWR, .NOCTTY = true });
    if (master < 0) switch (lastErrno()) {
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .AGAIN, .NOSPC, .NXIO => return error.NoDevice,
        .ACCES, .PERM => return error.PermissionDenied,
        else => |err| return posix.unexpectedErrno(err),
    };
    // Raw closes: `open` has no `std.Io` to hand, because nothing it does is
    // an operation `std.Io` abstracts.
    errdefer _ = c.close(master);

    // `grantpt` fixes the ownership and mode of the slave device and
    // `unlockpt` clears the lock that keeps it unopenable until then. Both are
    // required before the slave path may be opened, and both are no-ops on
    // systems that do not need them.
    if (grantpt(master) != 0) return openErrno();
    if (unlockpt(master) != 0) return openErrno();

    // `ptsname_r` does not agree with itself across libcs: glibc returns the
    // error number, musl and Darwin return -1. All three set `errno`, so that
    // is what is read, and the return value is only tested against zero.
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (ptsname_r(master, &name_buffer, name_buffer.len) != 0) return openErrno();
    const name: [*:0]const u8 = @ptrCast(&name_buffer);

    // NOCTTY: opening the slave here must not make it this process's
    // controlling terminal. The child asks for that explicitly, after `setsid`.
    const slave = c.open(name, .{ .ACCMODE = .RDWR, .NOCTTY = true });
    if (slave < 0) return openErrno();
    errdefer _ = c.close(slave);

    const pty: Pty = .{ .master = master, .slave = slave };
    // The descriptor is a pseudo-terminal master, opened two calls ago, so the
    // only failure this can report is one no caller could tell apart from the
    // open itself failing.
    tty.setWinSize(master, .{
        .rows = options.rows,
        .cols = options.cols,
        .x_pixel = options.x_pixel,
        .y_pixel = options.y_pixel,
    }) catch return error.Unexpected;
    return pty;
}

pub const ResizeError = tty.SetWinSizeError;

/// Changes the geometry of the pair.
///
/// Both ends see the new size, and the kernel sends `SIGWINCH` to the
/// terminal's foreground process group. A child that was spawned without a
/// controlling terminal has no foreground process group here and will not be
/// signalled, though it still reads the new size if it asks.
///
/// Safe to call from another task while the master is being read or written.
pub fn resize(pty: Pty, new_size: Size) ResizeError!void {
    return tty.setWinSize(pty.master, new_size);
}

pub const SizeError = tty.WinSizeError;

/// Reads the geometry of the pair.
pub fn size(pty: Pty) SizeError!Size {
    return tty.winSize(pty.master);
}

/// The master end as a `std.Io.File`, for reading and writing through
/// `std.Io`.
///
/// The file shares the descriptor rather than duplicating it: closing the
/// returned file closes this end of the pair, and so does `close`. Pick one.
pub fn masterFile(pty: Pty) std.Io.File {
    return .{ .handle = pty.master, .flags = .{ .nonblocking = false } };
}

/// The slave end as a `std.Io.File`.
///
/// The same sharing rule as `masterFile` applies. A parent that has spawned a
/// child on this pair rarely wants this file; it wants `closeSlave`.
pub fn slaveFile(pty: Pty) std.Io.File {
    return .{ .handle = pty.slave, .flags = .{ .nonblocking = false } };
}

/// Closes whichever ends are still open.
///
/// Idempotent, and correct after `closeSlave` or `closeMaster`: a closed end is
/// set to `closed` and is not closed twice.
pub fn close(pty: *Pty, io: std.Io) void {
    pty.closeSlave(io);
    pty.closeMaster(io);
}

/// Closes the slave end only.
///
/// A parent that has spawned a child on this pair should call this as soon as
/// the child exists. While any descriptor for the slave remains open in the
/// parent, a read of the master blocks instead of reporting end of file when
/// the child exits, because the terminal still has a reader.
pub fn closeSlave(pty: *Pty, io: std.Io) void {
    if (pty.slave == closed) return;
    pty.slaveFile().close(io);
    pty.slave = closed;
}

/// Closes the master end only.
///
/// The child sees end of file on its terminal, and a subsequent write from the
/// child raises `SIGHUP`.
pub fn closeMaster(pty: *Pty, io: std.Io) void {
    if (pty.master == closed) return;
    pty.masterFile().close(io);
    pty.master = closed;
}

/// The current `errno`, as one of `OpenError`. Everything `open` calls
/// reports failure the same way, so they all land here.
fn openErrno() OpenError {
    return switch (lastErrno()) {
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .AGAIN, .NOSPC, .NXIO => error.NoDevice,
        .ACCES, .PERM => error.PermissionDenied,
        else => |err| posix.unexpectedErrno(err),
    };
}

fn lastErrno() posix.E {
    return c.errno(@as(c_int, -1));
}

// These four are the POSIX 98 pseudo-terminal interface. None of them is
// declared in `std.c`, and `ptsname_r` returns the error number directly
// rather than through `errno`.
extern "c" fn posix_openpt(oflag: c.O) posix.fd_t;
extern "c" fn grantpt(fd: posix.fd_t) c_int;
extern "c" fn unlockpt(fd: posix.fd_t) c_int;
extern "c" fn ptsname_r(fd: posix.fd_t, buf: [*]u8, buflen: usize) c_int;

test "open gives two ends of one terminal at the requested size" {
    const io = std.testing.io;
    var pty = try Pty.open(.{ .rows = 30, .cols = 100 });
    defer pty.close(io);

    try std.testing.expect(tty.isTty(pty.master));
    try std.testing.expect(tty.isTty(pty.slave));

    const from_master = try pty.size();
    try std.testing.expectEqual(@as(u16, 30), from_master.rows);
    try std.testing.expectEqual(@as(u16, 100), from_master.cols);

    // The size belongs to the terminal, so the slave reports the same one.
    const from_slave = try tty.winSize(pty.slave);
    try std.testing.expectEqual(from_master, from_slave);
}

test "resize is visible from both ends" {
    const io = std.testing.io;
    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    try pty.resize(.{ .rows = 40, .cols = 132, .x_pixel = 1320, .y_pixel = 800 });

    const from_slave = try tty.winSize(pty.slave);
    try std.testing.expectEqual(Size{
        .rows = 40,
        .cols = 132,
        .x_pixel = 1320,
        .y_pixel = 800,
    }, from_slave);
}

test "the slave end has a name under /dev" {
    const io = std.testing.io;
    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const name = try tty.ttyName(pty.slave, &buffer);
    try std.testing.expect(std.mem.startsWith(u8, name, "/dev/"));
}

test "raw mode round-trips on the slave end" {
    const io = std.testing.io;
    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    const before = try posix.tcgetattr(pty.slave);
    try std.testing.expect(before.lflag.ECHO);

    const saved = try tty.rawMode(pty.slave);
    const during = try posix.tcgetattr(pty.slave);
    try std.testing.expect(!during.lflag.ECHO);
    try std.testing.expect(!during.lflag.ICANON);
    try std.testing.expect(!during.oflag.OPOST);

    try tty.restore(pty.slave, saved);
    const after = try posix.tcgetattr(pty.slave);
    try std.testing.expectEqual(before.lflag, after.lflag);
    try std.testing.expectEqual(before.iflag, after.iflag);
    try std.testing.expectEqual(before.oflag, after.oflag);
}
