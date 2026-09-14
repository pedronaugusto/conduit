//! Moves bytes between a pseudo-terminal master and a pair of files, and keeps
//! the child's terminal the same size as the program's own, until the terminal
//! end closes.
//!
//! This is the loop at the centre of every program that puts another program on
//! a pseudo-terminal: everything read from `input` is written to the master as
//! if it had been typed, and everything the child writes to its terminal is
//! read from the master and written to `output`. Two directions, so two tasks;
//! the caller's task runs the one from the child, which is the one that ends.
//!
//! # What happens to Ctrl-C
//!
//! Nothing, here — and that is the design, not an omission.
//!
//! A program that proxies a terminal puts its own terminal into raw mode
//! first, with `conduit.rawMode`. Raw mode is precisely the state in which the
//! terminal stops turning control characters into signals: Ctrl-C arrives at a
//! read as the byte `0x03` and Ctrl-Z as `0x1a`, the same as any other byte.
//! This loop forwards them, the child's terminal — which is *not* in raw mode
//! — turns them back into `SIGINT` and `SIGTSTP` for the child, and the
//! program in the middle is never interrupted by a key meant for the child.
//! On Windows the same thing happens for the same reason:
//! `ENABLE_PROCESSED_INPUT` is off, so Ctrl-C is a byte rather than a control
//! event, and the pseudoconsole turns it back into one for the client.
//!
//! So: call `conduit.rawMode` on your standard input, `defer conduit.restore`, and
//! Ctrl-C reaches the child and only the child. Without raw mode the signal
//! goes to your process instead, and no amount of byte-pumping can change
//! that.
//!
//! # What happens to a resize
//!
//! `Options.resize` asks this loop to keep the pair the same size as a
//! terminal of the caller's — normally the program's own standard input. The
//! size is read on a task of its own and copied onto the pair whenever it
//! changes, starting with the size it has when `run` begins.
//!
//! It is read rather than waited for, because **this package installs no
//! signal handler, ever**. A `SIGWINCH` handler is process-wide state, and a
//! library that installed one would be taking something from the program that
//! owns it. A program that already has a handler — or that reads Windows
//! console resize records — can hand over `Options.Resize.ticket` and bump it
//! from there, and the forwarder will pick the change up on its next tick
//! instead of waiting out the interval. Either way the cost is one ioctl or
//! one `GetConsoleScreenBufferInfo` every `interval_ms`, and `Pty.resize` is
//! safe to call while the master is being read and written.

const builtin = @import("builtin");
const std = @import("std");

const Pty = @import("Pty.zig");
const tty = @import("tty.zig");

const is_windows = builtin.os.tag == .windows;

/// The files to move bytes between, and the buffers to move them in.
///
/// None of the files are owned: `run` closes nothing. The buffers must not
/// alias, and must outlive the call. A few kilobytes each is plenty; a buffer
/// smaller than a terminal's line is merely slower, not wrong.
pub const Options = struct {
    /// The master end of the pair the child is running on. `Pty.master` or
    /// `Child.pty` is where this comes from.
    master: Pty.Master,
    /// Where the child's input comes from, usually the program's own standard
    /// input in raw mode.
    input: std.Io.File,
    /// Where the child's output goes, usually the program's own standard
    /// output.
    output: std.Io.File,
    /// Carries `input` to the master.
    input_buffer: []u8,
    /// Carries the master to `output`.
    output_buffer: []u8,
    /// Keep the pair the same size as a terminal of the caller's. `null` does
    /// not forward the window size at all, and the pair keeps the geometry it
    /// was opened with.
    resize: ?Resize = null,
};

/// How to keep the child's terminal the same size as the program's own.
pub const Resize = struct {
    /// The pair to resize. The same pair `Options.master` came from.
    pty: *Pty,
    /// The terminal whose size is copied. On POSIX any descriptor that is a
    /// terminal, usually the program's standard input. On Windows it must be
    /// a console *screen buffer* handle — the standard output — because that
    /// is what has a size.
    source: std.Io.File.Handle,
    /// A counter the program bumps when it learns of a resize some other way:
    /// from its own `SIGWINCH` handler on POSIX, or from a console window
    /// event on Windows. Any change to the value makes the forwarder look at
    /// the size on its next tick rather than at the end of `interval_ms`.
    ///
    /// `null` polls, which is correct and costs one call per interval.
    ticket: ?*const std.atomic.Value(u32) = null,
    /// How often the size is re-read when nothing has bumped `ticket`.
    interval_ms: u32 = 50,
    /// How often `ticket` is looked at. Only meaningful when there is one.
    tick_ms: u32 = 5,
};

pub const RunError = error{
    /// The `std.Io` implementation cannot run the other directions alongside
    /// the first.
    ConcurrencyUnavailable,
    /// `output` could not be written.
    WriteFailed,
    /// The master could not be read, for a reason other than the child
    /// leaving.
    ReadFailed,
} || std.Io.Cancelable;

/// Pumps both directions, and forwards the window size, until the child's end
/// of the terminal closes.
///
/// Returns when reading the master reports end of file — which on some systems
/// is reported as an I/O error instead, and is treated the same — or when
/// writing `output` fails. The other tasks are cancelled on the way out, so a
/// read of the program's own standard input that will never complete does not
/// hold the call open.
///
/// A child that has exited does not by itself end this: bytes it wrote are
/// still in the terminal, and on POSIX the master reports end of file only
/// once the slave end is closed everywhere. `Pty.closeSlave` in the parent,
/// right after `Child.spawn`, is what makes that happen; on Windows the
/// pseudoconsole ends the stream when the client does.
///
/// A window size that could not be read or set is not an error: a terminal
/// that has gone away is the child's problem and the program's, not this
/// loop's, and it will be reported to them by the read or write that follows.
pub fn run(io: std.Io, options: Options) RunError!void {
    var input_error: ?RunError = null;
    var group: std.Io.Group = .init;
    try group.concurrent(io, inputTask, .{ io, options, &input_error });
    if (options.resize) |resize| {
        group.concurrent(io, forwardSize, .{ io, resize }) catch |err| {
            group.cancel(io);
            return err;
        };
    }

    const result = pump(io, options.master.read, options.output, options.output_buffer);

    // Unconditional, and before the result is examined: the group owns
    // resources either way, and the direction carrying `input` is blocked on a
    // read that may never complete.
    group.cancel(io);

    try result;
    if (input_error) |err| return err;
}

/// The direction carrying `input`, as a task.
///
/// `std.Io.Group` tasks may fail only with `error.Canceled`, so anything else
/// is left in `out_error` for `run` to return once the group has joined.
fn inputTask(io: std.Io, options: Options, out_error: *?RunError) std.Io.Cancelable!void {
    pump(io, options.input, options.master.write, options.input_buffer) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => out_error.* = err,
    };
}

/// One direction. Ends at the first sign that `from` has no more to give.
fn pump(io: std.Io, from: std.Io.File, to: std.Io.File, buffer: []u8) RunError!void {
    while (true) {
        const n = from.readStreaming(io, &.{buffer}) catch |err| switch (err) {
            // The far end of a pseudo-terminal is gone. Linux reports this as
            // an I/O error rather than as end of file, and both mean the same
            // thing here.
            error.EndOfStream, error.InputOutput => return,
            error.Canceled => return error.Canceled,
            else => return error.ReadFailed,
        };
        if (n == 0) return;
        to.writeStreamingAll(io, buffer[0..n]) catch |err| switch (err) {
            error.BrokenPipe => return,
            error.Canceled => return error.Canceled,
            else => return error.WriteFailed,
        };
    }
}

/// Copies `source`'s geometry onto the pair whenever it changes.
///
/// The first copy happens immediately, so a child started on a 24×80 pair
/// begins life at whatever size the program is actually at.
fn forwardSize(io: std.Io, resize: Resize) std.Io.Cancelable!void {
    var last: ?tty.Size = null;
    var seen_ticket: u32 = if (resize.ticket) |ticket| ticket.load(.acquire) else 0;

    while (true) {
        if (tty.winSize(resize.source)) |now| {
            if (last == null or !std.meta.eql(last.?, now)) {
                resize.pty.resize(now) catch {};
                last = now;
            }
        } else |_| {
            // A source that is not a terminal, or is gone. Nothing to forward,
            // and nothing a caller of `run` could do about it.
        }

        const ticket = resize.ticket orelse {
            try std.Io.sleep(io, .fromMilliseconds(resize.interval_ms), .awake);
            continue;
        };

        // With a ticket the wait is broken into slices, so a program that
        // already knows a resize happened does not have to wait out the
        // interval to have it forwarded.
        var waited_ms: u32 = 0;
        while (waited_ms < resize.interval_ms) {
            const now = ticket.load(.acquire);
            if (now != seen_ticket) {
                seen_ticket = now;
                break;
            }
            const step = @max(1, @min(resize.tick_ms, resize.interval_ms - waited_ms));
            try std.Io.sleep(io, .fromMilliseconds(step), .awake);
            waited_ms += step;
        }
    }
}

//======================================================================
// Tests.
//======================================================================

const testing = std.testing;
const Child = @import("Child.zig");
const Watchdog = @import("test_support.zig").Watchdog;

/// `run` under a `std.Io.Group`, which accepts only `error.Canceled`.
fn runQuietly(io: std.Io, options: Options) std.Io.Cancelable!void {
    run(io, options) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };
}

/// Reads from `file` until `want` has arrived or the budget runs out.
///
/// Polled rather than read straight, so a pump that never delivers fails the
/// test it is in instead of stopping the run.
fn expectWithin(io: std.Io, file: std.Io.File, seen: []u8, want: []const u8) !void {
    var filled: usize = 0;
    while (filled < want.len) {
        var fds = [_]std.posix.pollfd{.{
            .fd = file.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, 5000) == 0) return error.TestPumpDeliveredNothing;
        filled += try file.readStreaming(io, &.{seen[filled..]});
    }
    try testing.expectEqualStrings(want, seen[0..filled]);
}

test "bytes written to one terminal reach the program on the other, and back" {
    // POSIX only: the test stands up a second pseudo-terminal to play the part
    // of the user's own, which a pseudoconsole cannot do -- there is nothing on
    // Windows that both is a console and can be read from.
    if (is_windows) return error.SkipZigTest;

    const io = testing.io;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const gpa = testing.allocator;

    // The terminal the "user" is at. Raw, so nothing it is sent is echoed
    // back and confused with the child's output.
    var user = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer user.close(io);
    _ = try tty.rawMode(user.slave.?);

    // The terminal the child runs on, also raw: `cat` is doing the echoing
    // here, and the terminal doing it too would double every line.
    var terminal = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer terminal.close(io);
    _ = try tty.rawMode(terminal.slave.?);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "cat" },
        .stdio = .{ .pty = &terminal },
        .detach = true,
    });
    defer child.deinit(io);
    terminal.closeSlave(io);

    var input_buffer: [256]u8 = undefined;
    var output_buffer: [256]u8 = undefined;
    var group: std.Io.Group = .init;
    try group.concurrent(io, runQuietly, .{ io, Options{
        .master = terminal.master(),
        .input = user.slaveFile(),
        .output = user.slaveFile(),
        .input_buffer = &input_buffer,
        .output_buffer = &output_buffer,
    } });
    defer group.cancel(io);

    try user.writeFile().writeStreamingAll(io, "round trip\n");

    var seen: [64]u8 = undefined;
    try expectWithin(io, user.readFile(), &seen, "round trip\n");

    // Ending the child closes the last descriptor for its terminal, which is
    // what makes `run` return.
    _ = try child.killWait(io, 500);
}

test "a Ctrl-C typed at the proxy's input becomes SIGINT for the child" {
    if (is_windows) return error.SkipZigTest;

    const io = testing.io;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const gpa = testing.allocator;

    // The user's terminal, raw: that is what turns Ctrl-C into a byte instead
    // of a signal for this process, which is the whole claim being tested.
    var user = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer user.close(io);
    _ = try tty.rawMode(user.slave.?);

    var terminal = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer terminal.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 100" },
        .stdio = .{ .pty = &terminal },
        .detach = true,
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};
    terminal.closeSlave(io);

    var input_buffer: [256]u8 = undefined;
    var output_buffer: [256]u8 = undefined;
    var group: std.Io.Group = .init;
    try group.concurrent(io, runQuietly, .{ io, Options{
        .master = terminal.master(),
        .input = user.slaveFile(),
        .output = user.slaveFile(),
        .input_buffer = &input_buffer,
        .output_buffer = &output_buffer,
    } });
    defer group.cancel(io);

    // Not written to the child's terminal: written to the *user's*, which the
    // proxy is reading, exactly as if it had been typed.
    try user.writeFile().writeStreamingAll(io, "\x03");

    var waited_ms: u32 = 0;
    const term = while (waited_ms < 5000) : (waited_ms += 2) {
        if (try child.tryWait()) |term| break term;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    } else return error.TestChildWasNotInterrupted;
    try testing.expectEqual(Child.Term{ .signal = .INT }, term);
}

test "the window size is forwarded onto the pair" {
    if (is_windows) return error.SkipZigTest;

    const io = testing.io;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    // Two pairs again: one stands in for the program's own terminal, whose
    // size the forwarder reads, and one is the child's.
    var user = try Pty.open(.{ .rows = 11, .cols = 37 });
    defer user.close(io);

    var terminal = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer terminal.close(io);

    var input_buffer: [64]u8 = undefined;
    var output_buffer: [64]u8 = undefined;
    var ticket: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    try group.concurrent(io, runQuietly, .{ io, Options{
        .master = terminal.master(),
        .input = user.slaveFile(),
        .output = user.slaveFile(),
        .input_buffer = &input_buffer,
        .output_buffer = &output_buffer,
        .resize = .{
            .pty = &terminal,
            .source = user.slave.?,
            .ticket = &ticket,
            .interval_ms = 1000,
            .tick_ms = 1,
        },
    } });
    defer group.cancel(io);

    // The size the program is already at is copied straight away.
    try expectSizeWithin(io, &terminal, .{ .rows = 11, .cols = 37 });

    // And a change is picked up on the ticket rather than at the end of the
    // one-second interval, which is what the ticket is for.
    try user.resize(.{ .rows = 50, .cols = 160 });
    _ = ticket.fetchAdd(1, .release);
    try expectSizeWithin(io, &terminal, .{ .rows = 50, .cols = 160 });
}

fn expectSizeWithin(io: std.Io, pty: *Pty, want: tty.Size) !void {
    var waited_ms: u32 = 0;
    while (waited_ms < 5000) : (waited_ms += 2) {
        const now = try pty.size();
        if (now.rows == want.rows and now.cols == want.cols) return;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    return error.TestSizeWasNotForwarded;
}
