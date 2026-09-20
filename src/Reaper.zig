//! Waits for a child on a background task so the owner can ask whether it has
//! ended without blocking on the answer.
//!
//! A `wait` is the only way to learn how a process ended, and it blocks. Where
//! a program is doing something else in the meantime — drawing a frame,
//! serving a request, waiting on a socket — the wait belongs on a task of its
//! own, and the result has to reach the other task safely. That is all this is:
//! one `std.Io.Group` task running `Child.wait`, and one atomic the result is
//! published through.
//!
//! Lifetime rules, all of them:
//!
//! * The `Child` must outlive the `Reaper`, and must not be destroyed while
//!   the `Reaper` is running.
//! * A `Reaper` must not be copied or moved once `start` has been called: the
//!   running task holds a pointer to it.
//! * `deinit` must be called before the `Reaper` goes out of scope, including
//!   on the path where the child never exits. It requests cancelation of the
//!   task and waits for it to finish.
//! * After `exit` returns a non-null term, the child has been reaped.
//!   `Child.wait` and `Child.tryWait` keep returning the same term, and
//!   `Child.kill` does nothing. A wait failure is returned instead and is
//!   likewise final.
//!
//! The owner may go on calling `Child.kill`, `Child.killWait`, `Child.wait`
//! and `Child.tryWait` while this runs, which is the sequence the whole thing
//! exists for: ask `exit`, get `null`, and decide the child has had long
//! enough. Only one of them is inside the operating system's wait at a time,
//! and the one that is publishes the term to the rest — so `tryWait` answers
//! `null` while this holds the wait, and `killWait` returns the term this
//! task reaped rather than asking for a second one. `Child.term` documents
//! the handshake.

const Reaper = @This();

const std = @import("std");
const Child = @import("Child.zig");

const Term = Child.Term;

/// The child being waited for. Borrowed.
child: *Child,
/// The task running the wait.
group: std.Io.Group,
/// `running`, a term encoded by `encode`, or an error encoded by
/// `encodeError`. Written once by the task and read by anyone.
state: std.atomic.Value(u64),

/// A `Reaper` that is not waiting for anything yet. Call `start` to put the
/// wait in flight.
pub fn init(child: *Child) Reaper {
    return .{
        .child = child,
        .group = .init,
        .state = .init(running),
    };
}

pub const StartError = std.Io.ConcurrentError;

/// Puts the wait in flight.
///
/// The task must be able to run alongside the caller, so an `std.Io`
/// implementation with no concurrency to offer fails here rather than
/// deadlocking later. Calling this twice on one `Reaper` starts a second wait,
/// which is a bug: the second one finds no child.
pub fn start(reaper: *Reaper, io: std.Io) StartError!void {
    return reaper.group.concurrent(io, run, .{ reaper, io });
}

pub const ExitError = Child.WaitError;

/// How the child ended, or `null` while the wait is still running.
///
/// Never blocks. A `null` is a snapshot and may be stale by the time the caller
/// acts on it; a term or error is final.
pub fn exit(reaper: *const Reaper) ExitError!?Term {
    const state = reaper.state.load(.acquire);
    if (state == running) return null;
    return @as(?Term, try decode(state));
}

/// Stops waiting and releases the task.
///
/// If the child has already ended this returns as soon as the task notices. If
/// it has not, cancelation is requested, and how promptly the blocked wait
/// gives up is up to the `std.Io` implementation — so a program that wants to
/// leave should make the child leave first, with `Child.killWait`.
///
/// Idempotent.
pub fn deinit(reaper: *Reaper, io: std.Io) void {
    reaper.group.cancel(io);
}

fn run(reaper: *Reaper, io: std.Io) void {
    const term = reaper.child.wait(io) catch |err| {
        reaper.state.store(encodeError(err), .release);
        return;
    };
    reaper.state.store(encode(term), .release);
}

/// No term can encode to this: the tag byte is out of range.
const running: u64 = std.math.maxInt(u64);

fn encode(term: Term) u64 {
    const tag: u64, const payload: u32 = switch (term) {
        .exited => |code| .{ 0, code },
        .signal => |signal| .{ 1, @intCast(@intFromEnum(signal)) },
        .stopped => |signal| .{ 2, @intCast(@intFromEnum(signal)) },
        .unknown => |value| .{ 3, value },
    };
    return (tag << 32) | payload;
}

fn encodeError(err: ExitError) u64 {
    return (@as(u64, 4) << 32) | @intFromError(err);
}

fn decode(state: u64) ExitError!Term {
    const payload: u32 = @truncate(state);
    return switch (state >> 32) {
        0 => .{ .exited = @intCast(payload) },
        1 => .{ .signal = @enumFromInt(payload) },
        2 => .{ .stopped = @enumFromInt(payload) },
        3 => .{ .unknown = payload },
        4 => @as(ExitError, @errorCast(@errorFromInt(@as(u16, @truncate(payload))))),
        else => unreachable,
    };
}

test "every term survives the round trip through the atomic" {
    const cases = [_]Term{
        .{ .exited = 0 },
        .{ .exited = 255 },
        .{ .signal = .TERM },
        .{ .stopped = .INT },
        .{ .unknown = 0xdeadbeef },
    };
    for (cases) |term| {
        try std.testing.expectEqual(term, try decode(encode(term)));
        try std.testing.expect(encode(term) != running);
    }
}

test "every wait error survives the round trip through the atomic" {
    const cases = [_]ExitError{
        error.AccessDenied,
        error.Canceled,
        error.Unexpected,
    };
    for (cases) |err| {
        try std.testing.expectError(err, decode(encodeError(err)));
        try std.testing.expect(encodeError(err) != running);
    }
}
