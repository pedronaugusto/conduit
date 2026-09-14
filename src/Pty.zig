//! A pseudo-terminal pair: a master end a program reads and writes, and a
//! terminal end that behaves like a terminal to whatever is connected to it.
//!
//! # One shape, two systems
//!
//! The master is *two handles*, because on Windows it genuinely is two. POSIX
//! gives one bidirectional descriptor for the master; ConPTY gives a
//! pseudoconsole object plus a pair of pipes, one carrying what the program
//! types in and one carrying what the child draws. So `read` and `write` are
//! separate fields on both platforms — the same handle twice on POSIX, the two
//! ends of two different pipes on Windows — and no caller has to know which it
//! is holding.
//!
//! The terminal end is `slave`: a file descriptor on POSIX, an `HPCON` on
//! Windows. It is not a stream on Windows, which is why `slaveFile` is POSIX
//! only.
//!
//! On POSIX the pair is opened through the POSIX 98 interface
//! (`posix_openpt`, `grantpt`, `unlockpt`, `ptsname_r`), which is available on
//! Linux, the BSDs and Darwin. On Windows it is `CreatePseudoConsole`, which
//! needs Windows 10 version 1809 or newer.
//!
//! Every end is owned by the `Pty` until `close`, `closeSlave` or
//! `closeMaster` is called; see the ownership note on `Child.spawn` for which
//! end a parent should keep, and `closeSlave` for the one place the two
//! systems ask for different timing.

const Pty = @This();

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;
const windows = std.os.windows;
const trace = @import("trace.zig");
const tty = @import("tty.zig");

const is_windows = builtin.os.tag == .windows;
const win32 = if (is_windows) @import("win32.zig") else struct {};

const Size = tty.Size;

/// A stream handle. `std.posix.fd_t` on POSIX, `HANDLE` on Windows.
pub const Handle = std.Io.File.Handle;

/// The terminal end of a pair.
///
/// POSIX: the slave file descriptor, which a child gets as its standard
/// input, output and error. Windows: the pseudoconsole, which a child is
/// attached to rather than handed.
pub const Slave = if (is_windows) win32.HPCON else posix.fd_t;

/// The end to read: everything the child wrote to its terminal.
///
/// POSIX: the master descriptor. Windows: the read end of the pseudoconsole's
/// output pipe. `null` once `close` or `closeMaster` has been called.
read: ?Handle,
/// The end to write: everything the child should see as typed at its terminal.
///
/// POSIX: the same descriptor as `read`. Windows: the write end of the
/// pseudoconsole's input pipe. `null` once `close` or `closeMaster` has been
/// called.
write: ?Handle,
/// The terminal end. `null` once `close` or `closeSlave` has been called.
slave: ?Slave,
/// Windows only: the geometry last given to `open` or `resize`.
///
/// A pseudoconsole cannot be asked its size, so `size` answers from here. On
/// POSIX there is an ioctl for it and this field does not exist, because a
/// remembered number there would be a copy that a child could make wrong.
remembered_size: if (is_windows) Size else void,

/// The master end as two `std.Io.File`s.
pub const Master = struct {
    /// What the child wrote to its terminal.
    read: std.Io.File,
    /// What the child will see as typed at its terminal.
    write: std.Io.File,
};

/// The initial terminal geometry of a new pair.
///
/// The defaults are the historical terminal size, which is what a program
/// assumes when nothing tells it otherwise. Pixel dimensions default to zero,
/// which terminals read as "not reported" and Windows ignores entirely.
pub const OpenOptions = struct {
    rows: u16 = 24,
    cols: u16 = 80,
    x_pixel: u16 = 0,
    y_pixel: u16 = 0,

    fn size(options: OpenOptions) Size {
        return .{
            .rows = options.rows,
            .cols = options.cols,
            .x_pixel = options.x_pixel,
            .y_pixel = options.y_pixel,
        };
    }
};

pub const OpenError = error{
    /// The per-process handle limit was reached.
    ProcessFdQuotaExceeded,
    /// The system-wide handle limit was reached.
    SystemFdQuotaExceeded,
    /// POSIX: no pseudo-terminal is available.
    NoDevice,
    /// POSIX: the slave device could not be opened with the current
    /// credentials.
    PermissionDenied,
    /// The system could not spare the memory for the pair. On Windows this is
    /// also what an operating system too old for `CreatePseudoConsole` to
    /// succeed reports, since the call itself is resolved at load time.
    SystemResources,
} || tty.UnexpectedError;

/// Opens a new pseudo-terminal pair with the given geometry.
///
/// On success the caller owns every end and must eventually call `close`, or
/// `closeSlave` and `closeMaster` separately. On failure nothing is leaked.
///
/// On POSIX both ends are close-on-exec, so a pair held open while some
/// unrelated child is spawned is not handed to it. `Child.spawn` puts the
/// slave on the child's standard streams with `dup2`, which clears the flag on
/// the copies, so the child it *is* for still gets its terminal.
pub fn open(options: OpenOptions) OpenError!Pty {
    if (is_windows) return openWindows(options);
    return openPosix(options);
}

pub const ResizeError = error{
    /// POSIX: the master is not a terminal, which cannot happen for a `Pty`
    /// this package opened.
    NotATerminal,
} || tty.UnexpectedError;

/// Changes the geometry of the pair.
///
/// On POSIX both ends see the new size and the kernel sends `SIGWINCH` to the
/// terminal's foreground process group. A child that was spawned without a
/// controlling terminal has no foreground process group here and will not be
/// signalled, though it still reads the new size if it asks.
///
/// On Windows the pseudoconsole is resized and the attached client learns
/// through the console API it already uses; there is no signal to miss. The
/// console host repaints its viewport into the output pipe as part of it, so
/// **a program that has stopped reading the master can block here**: a resize
/// is not a small write, and a pipe nobody drains fills up.
///
/// Safe to call from another task while the master is being read or written.
/// That is what makes window-size forwarding possible at all — see `Proxy`.
pub fn resize(pty: *Pty, new_size: Size) ResizeError!void {
    if (is_windows) {
        const slave = pty.slave orelse return error.Unexpected;
        if (win32.ResizePseudoConsole(slave, new_size.toCoord()) != win32.ok) {
            return error.Unexpected;
        }
        pty.remembered_size = new_size;
        return;
    }
    const read = pty.read orelse return error.Unexpected;
    return tty.setWinSize(read, new_size);
}

pub const SizeError = ResizeError;

/// Reads the geometry of the pair.
///
/// On POSIX this asks the kernel, so it reflects a resize done by anyone. On
/// Windows a pseudoconsole cannot be asked, so this answers with what `open`
/// or `resize` last set.
pub fn size(pty: Pty) SizeError!Size {
    if (is_windows) return pty.remembered_size;
    const read = pty.read orelse return error.Unexpected;
    return tty.winSize(read);
}

/// Both master ends as `std.Io.File`s.
///
/// The files share the handles rather than duplicating them: closing one
/// closes that end of the pair, and so does `close`. Pick one.
///
/// Asserts the master is still open.
pub fn master(pty: Pty) Master {
    return .{ .read = pty.readFile(), .write = pty.writeFile() };
}

/// The end to read, as a `std.Io.File`. Asserts it is still open.
pub fn readFile(pty: Pty) std.Io.File {
    return file(pty.read.?);
}

/// The end to write, as a `std.Io.File`. Asserts it is still open.
pub fn writeFile(pty: Pty) std.Io.File {
    return file(pty.write.?);
}

/// The terminal end as a `std.Io.File`. POSIX only, and asserts it is still
/// open.
///
/// The same sharing rule as `master` applies. A parent that has spawned a
/// child on this pair rarely wants this file; it wants `closeSlave`.
///
/// Referring to this declaration on Windows is a compile error: a
/// pseudoconsole is an object a process is attached to, not a stream anything
/// reads or writes.
pub const slaveFile = if (is_windows)
    @compileError("Pty.slaveFile is POSIX-only: a pseudoconsole is not a stream")
else
    slaveFilePosix;

fn slaveFilePosix(pty: Pty) std.Io.File {
    return file(pty.slave.?);
}

/// Closes whichever ends are still open.
///
/// Idempotent, and correct after `closeSlave` or `closeMaster`: a closed end
/// is `null` and is not closed twice.
///
/// The two systems want opposite orders, for opposite reasons. On POSIX the
/// terminal end goes first, which is what lets a reader of the master see the
/// stream finish. On Windows the master ends go first: `ClosePseudoConsole`
/// waits for the console host to flush what the client last wrote, and the
/// host writes it into a pipe whose other end this process is holding — so a
/// caller who has stopped reading would wait forever. Dropping that end first
/// makes the host's write fail rather than block, and it goes.
///
/// A program that wants the last of the output rather than the quickest exit
/// should read the master until it has what it wants and then call this.
pub fn close(pty: *Pty, io: std.Io) void {
    if (is_windows) {
        pty.closeMaster(io);
        pty.closeSlave(io);
        return;
    }
    pty.closeSlave(io);
    pty.closeMaster(io);
}

/// Closes the terminal end only.
///
/// **The two platforms want this at different moments, and it is the one place
/// in this package where that is true.**
///
/// On POSIX a parent that has spawned a child on this pair should call this as
/// soon as the child exists. While any descriptor for the slave remains open
/// in the parent, a read of the master blocks instead of reporting end of file
/// when the child exits, because the terminal still has a reader.
///
/// On Windows the pseudoconsole is not a descriptor the child inherited a copy
/// of — it is the console, and `ClosePseudoConsole` ends the client attached
/// to it. So this is called when the program is finished with the child, not
/// straight after spawning it.
///
/// **On Windows, reap the child first and keep reading the master.** The call
/// does not return until the client attached to the pseudoconsole has gone and
/// the console host has flushed what it last wrote, and the host flushes into
/// a pipe this process holds the reading end of. So a program that has stopped
/// reading waits for a write that cannot complete, and a program whose child
/// is still running waits for the child. `close` deals with the first by
/// dropping the master ends before this; the second is the caller's, and
/// `Child.killWait` is how it is done.
pub fn closeSlave(pty: *Pty, io: std.Io) void {
    const slave = pty.slave orelse return;
    pty.slave = null;
    if (is_windows) {
        trace.print("pty: ClosePseudoConsole(0x{x})", .{@intFromPtr(slave)});
        win32.ClosePseudoConsole(slave);
        trace.print("pty: ClosePseudoConsole returned", .{});
        return;
    }
    file(slave).close(io);
}

/// Closes both master ends.
///
/// **On POSIX this hangs the terminal up.** Dropping the last master descriptor
/// is the pseudo-terminal spelling of a modem dropping the line: the kernel
/// sends `SIGHUP` to the session leader of the terminal's session, which for a
/// child spawned with `detach` and `.pty` is the child itself. Its default
/// action ends the process, so a child that does not handle the signal is gone
/// shortly after this returns -- and a child that does handle it sees a read of
/// its terminal report end of file, and a write fail with `EIO`. A child
/// spawned without `detach` has no controlling terminal here and so is not
/// signalled; it only meets the closed stream.
///
/// On Windows the child's console loses the pipes behind it; the client learns
/// when it next reads or writes.
///
/// **This is also how a task that is reading the master is released.** That
/// read ends when the far end finishes or the handle goes away, and for a pair
/// whose console host is still running only the second happens — so a program
/// that keeps a reader on a task should close the master and then join it,
/// rather than the other way round.
pub fn closeMaster(pty: *Pty, io: std.Io) void {
    trace.print("pty: closing the master ends", .{});
    defer trace.print("pty: master ends closed", .{});
    // The same handle twice on POSIX, so it is closed once.
    const same = pty.read != null and pty.write != null and pty.read.? == pty.write.?;
    if (pty.read) |handle| {
        file(handle).close(io);
        pty.read = null;
    }
    if (pty.write) |handle| {
        if (!same) file(handle).close(io);
        pty.write = null;
    }
}

fn file(handle: Handle) std.Io.File {
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

//======================================================================
// POSIX.
//======================================================================

fn openPosix(options: OpenOptions) OpenError!Pty {
    const master_fd = posix_openpt(.{ .ACCMODE = .RDWR, .NOCTTY = true });
    if (master_fd < 0) return openErrno();
    // Raw closes: `open` has no `std.Io` to hand, because nothing it does is
    // an operation `std.Io` abstracts.
    errdefer _ = c.close(master_fd);

    // Close-on-exec, and not as an afterthought: a master this process is
    // holding while it spawns some unrelated child would otherwise be
    // inherited by that child, which would then be keeping the terminal open
    // -- so a read of the master never finishes even after the child that was
    // meant to have it exits. POSIX has no flag for `posix_openpt` to carry
    // (it takes `O_RDWR` and `O_NOCTTY` and nothing else is portable), so it
    // is a second call, and the window between the two is the one a concurrent
    // `fork` on another thread could slip through. The slave below has no such
    // window: `open` takes the flag.
    setCloseOnExec(master_fd);

    // `grantpt` fixes the ownership and mode of the slave device and
    // `unlockpt` clears the lock that keeps it unopenable until then. Both are
    // required before the slave path may be opened, and both are no-ops on
    // systems that do not need them.
    if (grantpt(master_fd) != 0) return openErrno();
    if (unlockpt(master_fd) != 0) return openErrno();

    // `ptsname_r` does not agree with itself across libcs: glibc returns the
    // error number, musl and Darwin return -1. All three set `errno`, so that
    // is what is read, and the return value is only tested against zero.
    var name_buffer: [std.fs.max_path_bytes]u8 = undefined;
    if (ptsname_r(master_fd, &name_buffer, name_buffer.len) != 0) return openErrno();
    const name: [*:0]const u8 = @ptrCast(&name_buffer);

    // NOCTTY: opening the slave here must not make it this process's
    // controlling terminal. The child asks for that explicitly, after `setsid`.
    const slave_fd = c.open(name, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true });
    if (slave_fd < 0) return openErrno();
    errdefer _ = c.close(slave_fd);

    // The descriptor is a pseudo-terminal master, opened two calls ago, so the
    // only failure this can report is one no caller could tell apart from the
    // open itself failing.
    tty.setWinSize(master_fd, options.size()) catch return error.Unexpected;

    return .{
        .read = master_fd,
        .write = master_fd,
        .slave = slave_fd,
        .remembered_size = {},
    };
}

/// Best effort: a descriptor that could not be marked close-on-exec is still
/// a working descriptor, and there is nothing a caller could usefully do about
/// it.
fn setCloseOnExec(fd: posix.fd_t) void {
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
}

/// The current `errno`, as one of `OpenError`. Everything `openPosix` calls
/// reports failure the same way, so they all land here.
fn openErrno() OpenError {
    return switch (c.errno(@as(c_int, -1))) {
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .AGAIN, .NOSPC, .NXIO => error.NoDevice,
        .ACCES, .PERM => error.PermissionDenied,
        .NOMEM => error.SystemResources,
        else => |err| posix.unexpectedErrno(err),
    };
}

// These four are the POSIX 98 pseudo-terminal interface. None of them is
// declared in `std.c`.
extern "c" fn posix_openpt(oflag: c.O) posix.fd_t;
extern "c" fn grantpt(fd: posix.fd_t) c_int;
extern "c" fn unlockpt(fd: posix.fd_t) c_int;
extern "c" fn ptsname_r(fd: posix.fd_t, buf: [*]u8, buflen: usize) c_int;

//======================================================================
// Windows.
//======================================================================

/// How much the console host may get ahead of a program reading the master.
///
/// A hint, not a limit: the system rounds it and a write larger than it still
/// succeeds in pieces. The default is a few kilobytes, which is less than one
/// repaint of a large window — and a console host blocked on a full pipe
/// blocks `ResizePseudoConsole` and `ClosePseudoConsole` with it. This is
/// enough for a repaint of a window far larger than anyone runs.
const pipe_bytes: win32.DWORD = 256 * 1024;

fn openWindows(options: OpenOptions) OpenError!Pty {
    // Two pipes. Each has an end for the console and an end for this program,
    // and neither end is inheritable -- `null` security attributes is what
    // says so -- which is the Windows counterpart of the close-on-exec the
    // POSIX side sets on both ends: a pair held open while some unrelated
    // child is started is not handed to it. The console duplicates what it is
    // given, and a child reaches the console through the attribute list rather
    // than through an inherited handle.
    var input_read: win32.HANDLE = undefined;
    var input_write: win32.HANDLE = undefined;
    if (win32.CreatePipe(&input_read, &input_write, null, pipe_bytes) == .FALSE) return lastError();
    errdefer windows.CloseHandle(input_write);
    errdefer windows.CloseHandle(input_read);

    var output_read: win32.HANDLE = undefined;
    var output_write: win32.HANDLE = undefined;
    if (win32.CreatePipe(&output_read, &output_write, null, pipe_bytes) == .FALSE) return lastError();
    errdefer windows.CloseHandle(output_write);
    errdefer windows.CloseHandle(output_read);

    const geometry = options.size();
    var console: win32.HPCON = undefined;
    switch (win32.CreatePseudoConsole(
        geometry.toCoord(),
        input_read,
        output_write,
        0,
        &console,
    )) {
        win32.ok => {},
        // `HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_MEMORY)`. Every other failure
        // here is a bug in this package's arguments rather than a condition a
        // caller can do anything about.
        @as(win32.HRESULT, @bitCast(@as(u32, 0x8007000E))) => return error.SystemResources,
        else => return error.Unexpected,
    }

    trace.print("pty: CreatePseudoConsole gave hpcon=0x{x}, {d}x{d}", .{
        @intFromPtr(console),
        geometry.rows,
        geometry.cols,
    });

    // The console duplicated both of its ends, so this program's copies of
    // them are now only a way to keep the pipes from ever reporting end of
    // file.
    windows.CloseHandle(input_read);
    windows.CloseHandle(output_write);

    return .{
        .read = output_read,
        .write = input_write,
        .slave = console,
        .remembered_size = geometry,
    };
}

fn lastError() OpenError {
    return switch (windows.GetLastError()) {
        .TOO_MANY_OPEN_FILES => error.ProcessFdQuotaExceeded,
        .NOT_ENOUGH_MEMORY, .OUTOFMEMORY => error.SystemResources,
        .ACCESS_DENIED => error.PermissionDenied,
        else => |err| windows.unexpectedError(err),
    };
}

//======================================================================
// Tests.
//======================================================================

const testing = std.testing;
const Watchdog = @import("test_support.zig").Watchdog;

/// Reads the master and throws it away, on a task of its own.
///
/// A pseudoconsole's host writes into a pipe this process holds the other end
/// of, and a resize is a repaint. With nobody reading, a large enough one
/// fills the pipe and the host stops there — taking `ResizePseudoConsole` and
/// `ClosePseudoConsole` with it. A program that resizes a pair it is not
/// reading is making a mistake; a test that does it hangs, so this is here.
const Drain = struct {
    group: std.Io.Group = .init,

    fn start(drain: *Drain, io: std.Io, f: std.Io.File) !void {
        try drain.group.concurrent(io, run, .{ io, f });
    }

    fn deinit(drain: *Drain, io: std.Io) void {
        drain.group.cancel(io);
    }

    fn run(io: std.Io, f: std.Io.File) std.Io.Cancelable!void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const n = f.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
            if (n == 0) return;
        }
    }
};

test "open gives a pair at the requested size, and resize changes it" {
    const io = testing.io;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    var pty = try Pty.open(.{ .rows = 30, .cols = 100 });
    // Registered before the close below, so it runs after it: the master is
    // still being read while the pair goes away.
    var drain: Drain = .{};
    defer drain.deinit(io);
    defer pty.close(io);
    try drain.start(io, pty.readFile());

    const opened = try pty.size();
    try testing.expectEqual(@as(u16, 30), opened.rows);
    try testing.expectEqual(@as(u16, 100), opened.cols);

    try pty.resize(.{ .rows = 41, .cols = 121 });
    const resized = try pty.size();
    try testing.expectEqual(@as(u16, 41), resized.rows);
    try testing.expectEqual(@as(u16, 121), resized.cols);
}

test "close is idempotent and correct after closing one end" {
    const io = testing.io;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    var pty = try Pty.open(.{});
    // The master ends go first here, which is what makes the terminal end safe
    // to close on Windows with nothing reading: see `close`.
    pty.closeMaster(io);
    pty.closeSlave(io);
    try testing.expectEqual(@as(?Slave, null), pty.slave);
    pty.close(io);
    try testing.expectEqual(@as(?Handle, null), pty.read);
    try testing.expectEqual(@as(?Handle, null), pty.write);
    pty.close(io);
}

test "both ends of a POSIX pair are the same terminal" {
    if (is_windows) return error.SkipZigTest;
    const io = testing.io;
    var pty = try Pty.open(.{ .rows = 30, .cols = 100 });
    defer pty.close(io);

    try testing.expect(tty.isTty(pty.read.?));
    try testing.expect(tty.isTty(pty.slave.?));
    // The size belongs to the terminal, so the slave reports the same one.
    try testing.expectEqual(try pty.size(), try tty.winSize(pty.slave.?));

    try pty.resize(.{ .rows = 40, .cols = 132, .x_pixel = 1320, .y_pixel = 800 });
    try testing.expectEqual(Size{
        .rows = 40,
        .cols = 132,
        .x_pixel = 1320,
        .y_pixel = 800,
    }, try tty.winSize(pty.slave.?));
}

test "the terminal end of a POSIX pair has a name under /dev" {
    if (is_windows) return error.SkipZigTest;
    const io = testing.io;
    var pty = try Pty.open(.{});
    defer pty.close(io);

    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const name = try tty.ttyName(pty.slave.?, &buffer);
    try testing.expect(std.mem.startsWith(u8, name, "/dev/"));
}

test "raw mode round-trips on the terminal end of a POSIX pair" {
    if (is_windows) return error.SkipZigTest;
    const io = testing.io;
    var pty = try Pty.open(.{});
    defer pty.close(io);

    const before = try posix.tcgetattr(pty.slave.?);
    try testing.expect(before.lflag.ECHO);

    const saved = try tty.rawMode(pty.slave.?);
    const during = try posix.tcgetattr(pty.slave.?);
    try testing.expect(!during.lflag.ECHO);
    try testing.expect(!during.lflag.ICANON);
    try testing.expect(!during.oflag.OPOST);

    try tty.restore(pty.slave.?, saved);
    const after = try posix.tcgetattr(pty.slave.?);
    try testing.expectEqual(before.lflag, after.lflag);
    try testing.expectEqual(before.iflag, after.iflag);
    try testing.expectEqual(before.oflag, after.oflag);
}

test "both ends of a POSIX pair are close-on-exec" {
    // The claim is about what an unrelated child does *not* inherit. A pair
    // held open while some other program is started must not reach it: a
    // grandchild holding the slave keeps the terminal open, and a read of the
    // master then never finishes even after the child it was opened for has
    // gone.
    if (is_windows) return error.SkipZigTest;
    const io = testing.io;
    var pty = try Pty.open(.{});
    defer pty.close(io);

    const FD_CLOEXEC: c_int = c.FD_CLOEXEC;
    try testing.expectEqual(FD_CLOEXEC, c.fcntl(pty.read.?, c.F.GETFD, @as(c_int, 0)) & FD_CLOEXEC);
    try testing.expectEqual(FD_CLOEXEC, c.fcntl(pty.slave.?, c.F.GETFD, @as(c_int, 0)) & FD_CLOEXEC);
}
