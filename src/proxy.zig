//! Moves bytes between a pseudo-terminal master and a pair of files, and keeps
//! the child's terminal the same size as the program's own, until the terminal
//! end closes.
//!
//! This is the loop at the centre of every program that puts another program on
//! a pseudo-terminal: everything read from `input` is written to the master as
//! if it had been typed, and everything the child writes to its terminal is
//! read from the master and written to `output`. The call ends when the
//! child's output does, or when either direction fails.
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
//! one `GetConsoleScreenBufferInfo` every `interval`, and `Pty.resize` is
//! safe to call while the master is being read and written.

const std = @import("std");

const Pty = @import("pty.zig").Pty;
const handles = @import("handles.zig");
const tty = @import("conduit.tty");

const Deadline = @import("conduit.tty").Deadline;

/// The files to move bytes between, and the buffers to move them in.
///
/// None of the files are owned: `run` closes nothing. The buffers must not
/// alias, and must outlive the call. A few kilobytes each is plenty; a buffer
/// smaller than a terminal's line is merely slower, not wrong.
pub const Options = struct {
    /// The master end of the pair the child is running on. `Pty.master` or
    /// `Child.terminalMaster()` is where this comes from.
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
    /// the size on its next tick rather than at the end of `interval`.
    ///
    /// `null` polls, which is correct and costs one call per interval.
    ticket: ?*const std.atomic.Value(u32) = null,
    /// How often the size is re-read when nothing has bumped `ticket`.
    /// Less than a millisecond uses one, so an idle forwarder still yields.
    interval: std.Io.Duration = .fromMilliseconds(50),
    /// How often `ticket` is looked at. Only meaningful when there is one.
    /// Less than a millisecond uses one.
    tick: std.Io.Duration = .fromMilliseconds(5),
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
    /// One of the two transfer buffers is empty, so its direction cannot make
    /// progress.
    BufferTooSmall,
    /// The task running `run` was cancelled.
    Canceled,
};

/// Pumps both directions, and forwards the window size, until the child's end
/// of the terminal closes.
///
/// Returns when the output direction ends: when reading the master reports
/// end of file — which on some systems is reported as an I/O error instead
/// and is treated the same — or when either pump fails. `input` reaching its
/// own end of file stops the input pump and nothing else; the child's output
/// is still carried until its terminal closes. Nothing is written to the
/// master in its place: a child that should see the end of its input is sent
/// the terminal's end-of-file character by the caller. The other tasks are
/// cancelled on the way out, so a read from a silent terminal cannot hide an
/// input-side error, and a read of the program's own standard input that will
/// never complete does not hold the call open.
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
    if (options.input_buffer.len == 0 or options.output_buffer.len == 0) {
        return error.BufferTooSmall;
    }
    var completion: Completion = .{};
    var group: std.Io.Group = .init;
    errdefer group.cancel(io);
    try group.concurrent(io, pumpTask, .{
        io,
        options.input,
        options.master.write,
        options.input_buffer,
        Direction.input,
        &completion,
    });
    try group.concurrent(io, pumpTask, .{
        io,
        options.master.read,
        options.output,
        options.output_buffer,
        Direction.output,
        &completion,
    });
    if (options.resize) |resize| {
        try group.concurrent(io, forwardSize, .{ io, resize });
    }

    try completion.arrived.wait(io);
    group.cancel(io);

    switch (completion.winner.load(.acquire)) {
        .none => unreachable,
        .input => if (completion.input_error) |err| return err,
        .output => if (completion.output_error) |err| return err,
    }
}

const Direction = enum(u8) { none, input, output };

const Completion = struct {
    winner: std.atomic.Value(Direction) = .init(.none),
    arrived: std.Io.Event = .unset,
    input_error: ?RunError = null,
    output_error: ?RunError = null,
};

/// One direction as a task. The output direction finishing, or either one
/// failing, publishes its result and wakes `run`; input that reaches its end
/// only ends its own task. The group boundary itself carries cancellation
/// only.
fn pumpTask(
    io: std.Io,
    from: std.Io.File,
    to: std.Io.File,
    buffer: []u8,
    direction: Direction,
    completion: *Completion,
) std.Io.Cancelable!void {
    const pump_error: ?RunError = result: {
        pump(io, from, to, buffer) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => break :result err,
        };
        break :result null;
    };
    switch (direction) {
        .none => unreachable,
        // Input that has simply run out ends this direction and nothing else:
        // the child may still have everything it is going to write to say.
        .input => if (pump_error == null) return else {
            completion.input_error = pump_error;
        },
        .output => completion.output_error = pump_error,
    }
    if (completion.winner.cmpxchgStrong(.none, direction, .release, .monotonic) == null) {
        completion.arrived.set(io);
    }
}

/// One direction. Ends at the first sign that `from` has no more to give.
fn pump(io: std.Io, from: std.Io.File, to: std.Io.File, buffer: []u8) RunError!void {
    while (true) {
        const n = handles.readStreaming(io, from, &.{buffer}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => if (handles.finished(err)) return else return error.ReadFailed,
        };
        handles.writeStreamingAll(io, to, buffer[0..n]) catch |err| switch (err) {
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
                // glint-ignore: Z026 -- a pair that refuses a size keeps its old one, and this task has no caller to tell
                resize.pty.resize(now) catch {};
                last = now;
            }
        } else |_| {
            // A source that is not a terminal, or is gone. Nothing to forward,
            // and nothing a caller of `run` could do about it.
        }

        try waitResize(io, resize, &seen_ticket);
    }
}

/// A span of at least one millisecond, so an idle forwarder still yields.
fn atLeastOneMs(span: std.Io.Duration) std.Io.Duration {
    const one: std.Io.Duration = .fromMilliseconds(1);
    return if (span.nanoseconds < one.nanoseconds) one else span;
}

/// One cancelable interval, even when tickets change continuously. The
/// deadline owns the budget; a delayed tick never spends it a second time.
fn waitResize(io: std.Io, resize: Resize, seen_ticket: *u32) std.Io.Cancelable!void {
    try std.Io.checkCancel(io);
    const interval = atLeastOneMs(resize.interval);
    const ticket = resize.ticket orelse return std.Io.sleep(io, interval, .awake);
    const deadline: Deadline = .in(io, interval);
    while (true) {
        const now = ticket.load(.acquire);
        if (now != seen_ticket.*) {
            seen_ticket.* = now;
            return;
        }
        const left = deadline.remaining(io);
        if (left.nanoseconds == 0) return;
        const tick = atLeastOneMs(resize.tick);
        try std.Io.sleep(io, if (tick.nanoseconds < left.nanoseconds) tick else left, .awake);
    }
}

//======================================================================
// Tests.
//======================================================================

const testing = std.testing;
/// Tests only: the clocks and fault plans of the tests below.
const shakedown = @import("shakedown");

test "empty transfer buffers are rejected before either direction starts" {
    const io = testing.io;
    var one: [1]u8 = undefined;
    try testing.expectError(error.BufferTooSmall, run(io, .{
        .master = undefined,
        .input = undefined,
        .output = undefined,
        .input_buffer = &.{},
        .output_buffer = &one,
    }));
    try testing.expectError(error.BufferTooSmall, run(io, .{
        .master = undefined,
        .input = undefined,
        .output = undefined,
        .input_buffer = &one,
        .output_buffer = &.{},
    }));
}

test "Proxy resize waits remain cancelable with a zero interval or a changing ticket" {
    // A clock that never moves, so the wait always has time left; its first
    // sleep is canceled, and so is its second look for a cancel.
    var clock: shakedown.Clock = .init(testing.io, .{});
    const counted = try shakedown.FaultIo.init(testing.allocator, clock.io(), .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .sleep, .n = 1 } }, .fault = .cancel },
        .{ .at = .{ .nth = .{ .call = .checkCancel, .n = 2 } }, .fault = .cancel },
    } });
    defer counted.deinit();
    const controlled_io = counted.io();
    var ticket: std.atomic.Value(u32) = .init(0);
    var seen: u32 = 0;
    var pair: Pty = undefined; // The wait borrows but never accesses the pair.
    const resize: Resize = .{ .pty = &pair, .source = undefined, .ticket = &ticket, .interval = .zero };
    try testing.expectError(error.Canceled, waitResize(controlled_io, resize, &seen));
    try testing.expectEqual(@as(u64, 1), counted.count(.sleep));
    ticket.store(1, .release);
    try testing.expectError(error.Canceled, waitResize(controlled_io, resize, &seen));
    try testing.expectEqual(@as(u64, 2), counted.count(.checkCancel));
}

test "Proxy resize intervals count delayed sleeps once" {
    // A five-millisecond tick resumes twenty-five milliseconds late.
    var clock: shakedown.Clock = .init(testing.io, .{ .advance = .{ .auto = .{ .late = .fromMilliseconds(25) } } });
    const counted = try shakedown.FaultIo.init(testing.allocator, clock.io(), .{});
    defer counted.deinit();
    const start = clock.read(.awake);
    var ticket: std.atomic.Value(u32) = .init(0);
    var seen: u32 = 0;
    var pair: Pty = undefined;
    try waitResize(counted.io(), .{ .pty = &pair, .source = undefined, .ticket = &ticket, .interval = .fromMilliseconds(50), .tick = .fromMilliseconds(5) }, &seen);
    try testing.expectEqual(@as(u64, 2), counted.count(.sleep));
    try testing.expectEqual(std.Io.Duration.fromMilliseconds(60), start.durationTo(clock.read(.awake)));
}
