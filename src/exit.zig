//! A child process ending, learned without reaping it.
//!
//! Reaping is the right to say how a child ended, and `Child` holds it. Before
//! that, two things are wanted that take none of it: to wait until the child has
//! ended (`wait`), and to ask whether it has (`ask`). Neither leaves the child
//! anything but unreaped, so its pid, and the id of a group it leads, stay its
//! own until `waitpid`: what a caller needs who is about to end what the child
//! left in its group.
//!
//! Waiting is reactor's: a handle the system makes ready the moment the child
//! ends, a `pidfd` on Linux, a kqueue registration on Darwin and the BSDs, the
//! process handle on Windows. On a reactor runtime that wait is an operation of
//! the task's own loop and holds no thread; on any other `Io` it holds the
//! calling thread and looks for a cancel between short waits. Either way it is a
//! cancelation point.
//!
//! **A watch does not reap.** It says the child has ended; `waitpid` is still
//! what turns that into a status, and `Child` is what holds the right to call
//! it. The watch is opened when the child is spawned, while it is unreaped and
//! cannot be a different process, held by the `Child` and closed with it.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;
const reactor = @import("reactor");
const Deadline = @import("conduit.tty").Deadline;

const is_windows = builtin.target.os.tag == .windows;

/// How a wait for a child to end ended.
pub const Wait = enum {
    /// The child has ended and is not reaped.
    ended,
    /// The wake was signalled first.
    woken,
    /// The time ran out first.
    timeout,
    /// This system cannot say when a child ends, or could not be asked: the way
    /// left is to try the reap.
    unavailable,
};

/// Opens the watch on the child `pid`, which nobody has reaped, to be held for
/// as long as the child is. `null` where none could be had: a process with no
/// descriptor to spare, which `wait` then asks about instead.
///
/// It is opened when the child is spawned, and on Darwin before the child can
/// run: a kqueue refuses a watch on a process that has ended with `ESRCH`, and
/// for a moment more than that, the system still says the child has not ended
/// when asked. A watch that was there first is told of the end however soon it
/// comes.
pub fn open(io: std.Io, pid: posix.pid_t) ?reactor.Process {
    return reactor.Process.open(io, pid) catch null;
}

/// Waits until the child `id` has ended, or `timeout` passes, or `wake` is
/// signalled, which the wait reports first when both have come. `id` is a child
/// of this process that nobody has reaped, and stays unreaped. `watch` is the
/// one `open` made for it, or `null`.
pub fn wait(
    io: std.Io,
    id: std.process.Child.Id,
    watch: ?*const reactor.Process,
    wake: ?*reactor.Wake,
    timeout: std.Io.Timeout,
) std.Io.Cancelable!Wait {
    if (is_windows) return finished(reactor.wait(io, .{ .object = id }, timeout));
    const process = watch orelse return asking(io, id, timeout);
    const woken = wake orelse return finished(reactor.wait(io, .{ .process = process }, timeout));
    const index = reactor.waitAny(io, &.{ .{ .wake = woken }, .{ .process = process } }, timeout) catch |err| return switch (err) {
        error.Timeout => .timeout,
        error.Canceled => error.Canceled,
        error.Unsupported, error.Unexpected => .unavailable,
    };
    return if (index == 0) .woken else .ended;
}

fn finished(result: reactor.WaitError!void) std.Io.Cancelable!Wait {
    result catch |err| return switch (err) {
        error.Timeout => .timeout,
        error.Canceled => error.Canceled,
        // A handle that cannot be waited on: the reap is what says so.
        error.Unsupported, error.Unexpected => .unavailable,
    };
    return .ended;
}

/// The wait when no watch could be opened: ask whether the child has ended on an
/// interval that grows to a few milliseconds, so a child that ends promptly is
/// noticed promptly and one that does not is not asked about a thousand times a
/// second.
fn asking(io: std.Io, id: posix.pid_t, timeout: std.Io.Timeout) std.Io.Cancelable!Wait {
    const deadline: Deadline = .of(io, timeout);
    var interval_ms: u32 = 1;
    while (true) {
        switch (ask(id)) {
            .ended => return .ended,
            .unknown => return .unavailable,
            .running => {},
        }
        const left = deadline.remainingMs(io);
        if (left == 0) return .timeout;
        try std.Io.sleep(io, .fromMilliseconds(@min(interval_ms, left)), .awake);
        interval_ms = @min(interval_ms * 2, 4);
    }
}

/// What `ask` can say.
pub const Ended = enum {
    /// It has ended and is still there to be reaped.
    ended,
    /// It is running.
    running,
    /// This system cannot be asked, or would not answer.
    unknown,
};

/// Asks whether `pid`, a child of this process that nobody has reaped, has
/// ended: `waitid` with `WNOWAIT`, so the child stays unreaped. Never blocks.
///
/// On Darwin a child that ended before a kqueue could watch it is refused by
/// that kqueue with `ESRCH`; this is how a caller that holds the reap tells that
/// case apart from a child that is running.
pub fn ask(pid: posix.pid_t) Ended {
    const flags = waitid_flags orelse return .unknown;
    while (true) {
        var info = std.mem.zeroes(c.siginfo_t);
        if (waitid(p_pid, @intCast(pid), &info, flags) == 0) {
            // With `WNOHANG` and nothing to report, the fields stay zero.
            return if (infoPid(&info) == 0) .running else .ended;
        }
        switch (posix.errno(@as(c_int, -1))) {
            .INTR => continue,
            else => return .unknown,
        }
    }
}

/// P_PID and id_t are ABI choices, independent of the wait option bits.
/// FreeBSD and DragonFly use Solaris's selector and a 64-bit id_t; NetBSD
/// keeps P_PID=1, and OpenBSD puts it after P_ALL and P_PGID.
const p_pid: c_uint = switch (builtin.target.os.tag) {
    .freebsd, .dragonfly, .illumos => 0,
    .openbsd => 2,
    else => 1,
};
const WaitId = switch (builtin.target.os.tag) {
    .freebsd, .dragonfly => i64,
    .illumos => i32,
    else => c_uint,
};

/// `WEXITED | WNOHANG | WNOWAIT`, spelled per system, where it is known to
/// be right; `null` elsewhere.
const waitid_flags: ?c_int = switch (builtin.target.os.tag) {
    .linux => 0x4 | 0x1 | 0x1000000,
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => 0x4 | 0x1 | 0x20,
    // sys/sys/wait.h in the BSD sources; sys/wait.h in illumos. The
    // standard library names these bits except on Darwin and OpenBSD.
    .freebsd, .netbsd, .dragonfly, .illumos => c.W.EXITED | c.W.NOHANG | c.W.NOWAIT,
    .openbsd => 0x4 | 0x1 | 0x10,
    else => null,
};

extern "c" fn waitid(idtype: c_uint, id: WaitId, info: *c.siginfo_t, options: c_int) c_int;

fn infoPid(info: *const c.siginfo_t) posix.pid_t {
    return switch (builtin.target.os.tag) {
        .linux => info.fields.common.first.piduid.pid,
        .netbsd => info.info.reason.child.pid,
        .illumos => info.reason.proc.pid,
        .openbsd => info.data.proc.pid,
        else => info.pid,
    };
}
