//! Waits for a child on a background task, so the owner can ask whether it has
//! ended, wait for it to end, and have it stopped, none of them blocking on
//! anything but what it asked for.
//!
//! A `wait` is the only way to learn how a process ended, and it blocks. Where
//! a program is doing something else in the meantime — drawing a frame,
//! serving a request, waiting on a socket — the wait belongs on a task of its
//! own, and the result has to reach the other task safely. That is what this
//! is: one `std.Io.Group` task waiting for the child, one atomic the result is
//! published through, and one event that is set when it has been, so that
//! `wait` and `waitTimeout` wait on the answer rather than asking for it again
//! and again.
//!
//! Two things more, both of them about ending:
//!
//! * `stop` asks the child and what it started to end, and makes them if they
//!   have not by the end of a grace. It returns at once: the insisting is done
//!   on this `Reaper`'s own task, so a caller holding a lock can stop a child
//!   without waiting for it.
//! * `Options.end_tree` ends what the child leaves running when it ends by
//!   itself. See there for what that reaches on each system.
//!
//! Lifetime rules, all of them:
//!
//! * The `Child` must outlive the `Reaper`, and must not be destroyed while
//!   the `Reaper` is running.
//! * A `Reaper` must not be copied or moved once `start` has been called: the
//!   running task holds a pointer to it.
//! * `deinit` must be called before the `Reaper` goes out of scope, including
//!   on the path where the child never exits. It ends the task and waits for
//!   it to finish — and with it any insisting `stop` had still to do, so a
//!   program that wants a stopped child gone waits for it before `deinit`.
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

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;
const Child = @import("Child.zig");

const is_windows = builtin.os.tag == .windows;
const win32 = if (is_windows) @import("win32.zig") else struct {};
const handles = @import("handles.zig");
const tree = if (is_windows) struct {} else @import("tree.zig");
const wait_for = if (is_windows) struct {} else @import("wait.zig");

const Term = Child.Term;

/// The child being waited for. Borrowed.
child: *Child,
options: Options,
/// The task running the wait, and the one `stop` insists on.
group: std.Io.Group,
/// `running`, a term encoded by `encode`, or an error encoded by
/// `encodeError`. Written once by the task and read by anyone.
state: std.atomic.Value(u64),
/// Set once `state` holds the answer, whatever it is.
answered: std.Io.Event,
/// Whether `stop` has been asked, so that a second request does not insist
/// a second time.
stopping: std.atomic.Value(bool),
/// POSIX: a pipe whose reading end the task waits on beside the child, and
/// which `deinit` writes to. The wait on the child is not a cancelation point
/// and has no deadline, so this is what ends it early. `null` until `start`,
/// and where a pipe could not be had.
wake: if (is_windows) void else ?[2]posix.fd_t,

pub const Options = struct {
    /// End what the child leaves running when it ends, and reap the child only
    /// once that is done.
    ///
    /// **POSIX**, for a child spawned with `detach`: once the child has
    /// ended, and before it is reaped, what is left in its process group is
    /// asked to end with `SIGTERM`, given `tree_grace_ms` to do so, and sent
    /// `SIGKILL` if it has not. The child, ended but not reaped, still holds
    /// the group's id, so the signal cannot reach a group that has since been
    /// given the same number. A descendant that left the group before the
    /// child ended is related to nothing any more and is not reached, which is
    /// the limit `Child.kill` states too; Linux and Darwin are asked whether
    /// the group is empty, and elsewhere what is left is sent `SIGKILL` at
    /// once. A child that was not detached has no group of its own, and
    /// nothing is signalled for it. The wait needs a handle on the child's
    /// end (`waitTimeout` says which), and without one the child is reaped
    /// as it would have been and nothing is signalled.
    ///
    /// **Windows**: the job the child was put in is ended as soon as the
    /// child is reaped. There is no request there a process outside the
    /// child's console group can catch, so there is no grace to give.
    ///
    /// The term published is the child's own, however long its tree took.
    end_tree: bool = false,
    /// With `end_tree`, how long what the child left gets between being asked
    /// to end and being made to.
    tree_grace_ms: u32 = 1000,
};

/// A `Reaper` that is not waiting for anything yet. Call `start` to put the
/// wait in flight.
pub fn init(child: *Child, options: Options) Reaper {
    return .{
        .child = child,
        .options = options,
        .group = .init,
        .state = .init(running),
        .answered = .unset,
        .stopping = .init(false),
        .wake = if (is_windows) {} else null,
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
    // Without a pipe the wait falls back to the standard library's, which is
    // a cancelation point of its own: the wake is how a better wait is ended,
    // not a condition of waiting at all.
    if (!is_windows) reaper.wake = handles.pipe() catch null;
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

/// How the child ended, once it has: blocks until the task has the answer.
///
/// This waits on the answer rather than on the child, so any number of tasks
/// may call it at once, and none of them asks the operating system anything.
/// It is a cancelation point. A `Reaper` that was never started never
/// answers.
pub fn wait(reaper: *Reaper, io: std.Io) ExitError!Term {
    try reaper.answered.wait(io);
    return (try reaper.exit()).?;
}

pub const WaitTimeoutError = ExitError;

/// `wait`, for at most `timeout_ms`: `null` if the child has not ended by
/// then.
pub fn waitTimeout(reaper: *Reaper, io: std.Io, timeout_ms: u32) WaitTimeoutError!?Term {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{
        .raw = .fromMilliseconds(timeout_ms),
        .clock = .awake,
    });
    while (true) {
        reaper.answered.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
            // A wakeup before the deadline is spurious; one after it is the
            // answer that there is none yet.
            error.Timeout => if (deadline.durationFromNow(io).raw.nanoseconds > 0) continue else return reaper.exit(),
            error.Canceled => return error.Canceled,
        };
        return reaper.exit();
    }
}

/// Asks the child to end, and makes it if it has not within `grace_ms`.
///
/// `.terminate` now and `.kill` once the grace has passed, each of them
/// `Child.kill`'s and reaching what `Child.kill` reaches. A `grace_ms` of zero
/// is `.kill` now. It never blocks: the grace is waited out on this
/// `Reaper`'s task, and ends early the moment the child does.
///
/// Only the first request with a grace counts. A second one would either
/// wait longer than the first, which it cannot, or less, which is a request
/// with a grace of zero — and that one is always sent. A signal that cannot
/// be delivered is not reported: the child has ended, or is ending, and the
/// term says how.
pub fn stop(reaper: *Reaper, io: std.Io, grace_ms: u32) void {
    if (grace_ms == 0) {
        reaper.child.kill(.kill) catch {};
        return;
    }
    if (reaper.stopping.swap(true, .acq_rel)) return;
    reaper.child.kill(.terminate) catch {};
    reaper.group.concurrent(io, insist, .{ reaper, io, grace_ms }) catch {
        // No task to wait out the grace on: insisting now is the one answer
        // that still ends the child.
        reaper.child.kill(.kill) catch {};
    };
}

fn insist(reaper: *Reaper, io: std.Io, grace_ms: u32) void {
    const term = reaper.waitTimeout(io, grace_ms) catch |err| switch (err) {
        // `deinit`: the owner is done with this child.
        error.Canceled => return,
        // An answer, if an unhappy one: the child is no longer waited for.
        else => return,
    };
    if (term == null) reaper.child.kill(.kill) catch {};
}

/// Stops waiting and releases the task.
///
/// If the child has already ended this returns as soon as the task notices. If
/// it has not, the task is told to go — and any insisting `stop` had yet to
/// do goes with it — so a program that wants the child gone should see it
/// gone first, with `stop` and `wait`.
///
/// Idempotent.
pub fn deinit(reaper: *Reaper, io: std.Io) void {
    if (!is_windows) if (reaper.wake) |ends| {
        _ = c.write(ends[1], "x", 1);
    };
    reaper.group.cancel(io);
    if (!is_windows) if (reaper.wake) |ends| {
        _ = c.close(ends[0]);
        _ = c.close(ends[1]);
        reaper.wake = null;
    };
}

fn run(reaper: *Reaper, io: std.Io) void {
    const result = reaper.reap(io);
    reaper.state.store(if (result) |term| encode(term) else |err| encodeError(err), .release);
    reaper.answered.set(io);
}

fn reap(reaper: *Reaper, io: std.Io) ExitError!Term {
    if (is_windows) {
        const term = try reaper.child.wait(io);
        if (reaper.options.end_tree) if (reaper.child.job) |job| {
            _ = win32.TerminateJobObject(job, 1);
        };
        return term;
    }
    const wake = reaper.wake orelse return reaper.child.wait(io);
    // Held from here to the reap, as any wait in flight holds it: so the child
    // ended is still the child's, unreaped, while its group is ended below.
    const held = reaper.child.holdReap() orelse return reaper.child.wait(io);
    defer held.release();
    const watch = wait_for.Watch.open(reaper.child.id) orelse return held.wait(io);
    defer watch.close();
    while (true) switch (watch.endedOrWoken(wake[0], null)) {
        .ended => break,
        .woken => return error.Canceled,
        // a signal, not the end: ask again
        .timed_out => {},
    };
    // Ended, and not yet reaped: the group's id is still the child's, and
    // what is left in the group can be addressed by it.
    if (reaper.options.end_tree) if (reaper.child.pgid) |pgid| {
        if (!reaper.endGroup(pgid, wake[0])) return error.Canceled;
    };
    return held.wait(io);
}

/// What the child left in its group: asked, given the grace, then made.
/// False when the wake came first.
fn endGroup(reaper: *Reaper, pgid: posix.pid_t, wake: posix.fd_t) bool {
    const leader = reaper.child.id;
    // A group holding nothing but the child is the usual case, and is the
    // one that sends nothing.
    switch (tree.members(pgid, leader)) {
        .none => return true,
        .others => {
            _ = c.kill(-pgid, .TERM);
            var waited_ms: u32 = 0;
            var slice_ms: u32 = 1;
            while (waited_ms < reaper.options.tree_grace_ms) {
                if (!pause(wake, slice_ms)) return false;
                waited_ms += slice_ms;
                slice_ms = @min(slice_ms * 2, tree_slice_ms);
                if (tree.members(pgid, leader) == .none) return true;
            }
        },
        .unknown => {},
    }
    // `kill(-pgid)` is not atomic against a `fork` inside the group, so it is
    // sent again while the group still answers, as `Child.kill` does.
    var pass: u8 = 0;
    while (pass < kill_passes) : (pass += 1) {
        _ = c.kill(-pgid, .KILL);
        if (tree.members(pgid, leader) == .none) break;
    }
    return true;
}

/// The longest the group is left between two looks while its grace runs.
/// Only a group with something left in it is looked at at all.
const tree_slice_ms: u32 = 20;
/// As `Child.kill`'s own count of passes for `.kill`.
const kill_passes: u8 = 3;

/// Sleeps `ms` unless the wake comes first. False when it did.
fn pause(wake: posix.fd_t, ms: u32) bool {
    var fds = [_]c.pollfd{.{ .fd = wake, .events = c.POLL.IN, .revents = 0 }};
    return c.poll(&fds, 1, @intCast(ms)) <= 0 or fds[0].revents == 0;
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
