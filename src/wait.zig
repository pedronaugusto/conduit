//! Waiting for a child to end, with a deadline on the waiting.
//!
//! A blocking wait has no deadline and a deadline needs one of two things: a
//! wait that takes one, or asking again and again until the time runs out.
//! This package used to ask again — one milliseconds, then two, then four —
//! which costs a millisecond and a half of latency on every child that ends
//! promptly, and leaves a window in which the child is gone and nobody knows
//! it yet.
//!
//! Both systems this package is tested on have a handle that becomes ready
//! when a process ends, and `Watch` is that handle: a `pidfd` on Linux, a
//! kqueue with an `EVFILT_PROC`/`NOTE_EXIT` registration on Darwin and the
//! BSDs. Where there is neither — an old kernel, a system with no such
//! mechanism — `Watch.open` says so and the caller asks again as before.
//!
//! **A watch does not reap.** It says the child has ended; `waitpid` is still
//! what turns that into a status, and `Child` is what holds the right to call
//! it. So a watch is opened for one wait and closed at the end of it, which
//! also means it is opened while the child is still unreaped and cannot
//! therefore be a different process by the time it is watched.
//!
//! POSIX only. On Windows a wait already takes a deadline.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;

/// A point in time to stop waiting at, and what is left until it.
///
/// One of these replaces the counters the waits here used to keep: a step that
/// returned early — a signal, a spurious wakeup — used to count as a whole
/// step, so a deadline was only ever approximately one.
pub const Deadline = struct {
    at: std.Io.Clock.Timestamp,

    pub fn in(io: std.Io, milliseconds: u32) Deadline {
        return .{ .at = .fromNow(io, .{
            .raw = .fromMilliseconds(milliseconds),
            .clock = .awake,
        }) };
    }

    /// How long there is left, and zero once the deadline has passed.
    pub fn remainingMs(deadline: Deadline, io: std.Io) u32 {
        const left = deadline.at.durationFromNow(io).raw.toMilliseconds();
        if (left <= 0) return 0;
        return std.math.lossyCast(u32, left);
    }
};

/// How long one wait on a `Watch` lasts before the caller is given a chance to
/// notice it has been cancelled.
///
/// A blocking wait on a handle is not a cancelation point, so the deadline is
/// spent in slices of this and cancelation is checked between them. Five
/// milliseconds is a shorter interval than the ladder this replaces ever
/// reached, so cancelation is noticed at least as promptly as it was, and a
/// child that ends inside a slice is noticed the moment it does — which is the
/// whole point.
pub const slice_ms: u32 = 5;

/// A handle that becomes ready when a process ends.
pub const Watch = struct {
    handle: posix.fd_t,

    /// Opens a watch on `pid`, or `null` where this system has nothing to
    /// open.
    ///
    /// `null` is not a failure: the caller falls back to asking again, which
    /// is what this package did everywhere before. An old Linux kernel with no
    /// `pidfd_open`, a system that is neither Linux nor a BSD, and a `pid`
    /// that has already been reaped all arrive here the same way.
    pub fn open(pid: posix.pid_t) ?Watch {
        return switch (builtin.os.tag) {
            .linux => openPidfd(pid),
            .driverkit,
            .ios,
            .maccatalyst,
            .macos,
            .tvos,
            .visionos,
            .watchos,
            .dragonfly,
            .freebsd,
            .netbsd,
            .openbsd,
            => openKqueue(pid),
            else => null,
        };
    }

    pub fn close(watch: Watch) void {
        _ = c.close(watch.handle);
    }

    /// Waits up to `milliseconds` for the process to end.
    ///
    /// True means it has, as far as the operating system will say without a
    /// `waitpid`; false means the time ran out. A wait that is interrupted
    /// returns false, and the caller's deadline is what decides whether to ask
    /// again.
    pub fn ended(watch: Watch, milliseconds: u32) bool {
        return switch (builtin.os.tag) {
            .linux => endedPidfd(watch, milliseconds),
            else => endedKqueue(watch, milliseconds),
        };
    }
};

//======================================================================
// Linux.
//======================================================================

/// `pidfd_open` is Linux 5.3. An older kernel answers `ENOSYS` and the caller
/// falls back.
fn openPidfd(pid: posix.pid_t) ?Watch {
    const rc = std.os.linux.pidfd_open(pid, 0);
    if (std.os.linux.errno(rc) != .SUCCESS) return null;
    return .{ .handle = @intCast(rc) };
}

/// A `pidfd` is readable when the process it names has ended. It is not
/// readable in any other sense: `poll` is the whole interface.
fn endedPidfd(watch: Watch, milliseconds: u32) bool {
    var fds = [_]c.pollfd{.{ .fd = watch.handle, .events = c.POLL.IN, .revents = 0 }};
    const ready = c.poll(&fds, 1, @intCast(@min(milliseconds, std.math.maxInt(i32))));
    if (ready <= 0) return false;
    return fds[0].revents != 0;
}

//======================================================================
// Darwin and the BSDs.
//======================================================================

/// A kqueue with one `EVFILT_PROC` registration on `pid`, asking for the one
/// note that matters: the process has exited.
///
/// The registration is made here rather than at the wait, so that a process
/// that ends between the two still leaves the event queued — which is what a
/// kqueue is for, and what a `poll` on a condition would miss.
fn openKqueue(pid: posix.pid_t) ?Watch {
    const queue = c.kqueue();
    if (queue < 0) return null;
    var change = [_]c.Kevent{.{
        .ident = @intCast(pid),
        .filter = c.EVFILT.PROC,
        .flags = c.EV.ADD | c.EV.ENABLE | c.EV.ONESHOT,
        .fflags = c.NOTE.EXIT,
        .data = 0,
        .udata = 0,
    }};
    var nothing: [0]c.Kevent = undefined;
    const zero: c.timespec = .{ .sec = 0, .nsec = 0 };
    if (c.kevent(queue, &change, 1, &nothing, 0, &zero) < 0) {
        _ = c.close(queue);
        return null;
    }
    return .{ .handle = queue };
}

fn endedKqueue(watch: Watch, milliseconds: u32) bool {
    var event: [1]c.Kevent = undefined;
    const timeout: c.timespec = .{
        .sec = @intCast(milliseconds / 1000),
        .nsec = @intCast((milliseconds % 1000) * std.time.ns_per_ms),
    };
    var nothing: [0]c.Kevent = undefined;
    const ready = c.kevent(watch.handle, &nothing, 0, &event, 1, &timeout);
    if (ready <= 0) return false;
    // `EV_ERROR` is how a registration on a process that has already gone
    // comes back. Either way there is nothing left to wait for.
    return true;
}

test "a watch on a child ends when the child does" {
    const testing = std.testing;
    const Child = @import("Child.zig");
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var child = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdio = .ignore,
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};

    // Every system this package is tested on has one; a system that has not is
    // one where the caller asks again instead, and there is nothing here to
    // assert about it.
    const watch = Watch.open(child.id) orelse return error.SkipZigTest;
    defer watch.close();

    try testing.expect(watch.ended(5000));
}

test "a watch on a child that is still running says so" {
    const testing = std.testing;
    const Child = @import("Child.zig");
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var child = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .stdio = .ignore,
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};

    const watch = Watch.open(child.id) orelse return error.SkipZigTest;
    defer watch.close();

    try testing.expect(!watch.ended(20));
}
