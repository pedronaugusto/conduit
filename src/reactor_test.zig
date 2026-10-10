//! What conduit's waits do on a reactor runtime, where they are operations of
//! the task's own loop, and not on the calling thread: the same promises as on
//! `std.Io.Threaded`, which the rest of the suite keeps, and the cancelation the
//! slices between short waits used to bound.
const builtin = @import("builtin");
const std = @import("std");
const reap = @import("testing/support.zig").reap;
const reactor = @import("reactor");
const conduit = @import("conduit.zig");
const Deadline = @import("conduit.tty").Deadline;

const is_windows = builtin.target.os.tag == .windows;
const Child = conduit.Child;
const Reaper = conduit.Reaper;
const Term = conduit.Term;

const script = if (is_windows) struct {
    const ignore_request = [_][]const u8{ "cmd.exe", "/c", "ping -n 30 127.0.0.1 > nul" };
    const read_then_exit_5 = [_][]const u8{ "cmd.exe", "/c", "set /p line=& exit 5" };
    const sleep_forever = [_][]const u8{ "cmd.exe", "/c", "ping -n 30 127.0.0.1 > nul" };
    const emit_both = [_][]const u8{ "cmd.exe", "/c", "echo out& echo err 1>&2" };
} else struct {
    const ignore_request = [_][]const u8{ "/bin/sh", "-c", "trap '' TERM; sleep 100 & wait" };
    const read_then_exit_5 = [_][]const u8{ "/bin/sh", "-c", "read line; exit 5" };
    const sleep_forever = [_][]const u8{ "/bin/sh", "-c", "sleep 30" };
    const emit_both = [_][]const u8{
        "/bin/sh",                                                "-c",
        // More than a pipe holds on each stream, so neither can be left for after the other.
        "head -c 300000 /dev/zero; head -c 200000 /dev/zero >&2",
    };
};

/// A runtime whose body of a test runs as a task its waits park. On POSIX it has
/// no thread beside the home thread, which is the case a wait that held a thread
/// would deadlock. On Windows a pipe is read by a call that blocks, and the
/// workers are what keep a blocked read from holding the loop. It is large, and
/// is kept off the stack of the test that holds it.
const Host = struct {
    runtime: reactor.Runtime = undefined,

    fn start() !*Host {
        const host = try std.heap.page_allocator.create(Host);
        errdefer std.heap.page_allocator.destroy(host);
        host.* = .{};
        host.runtime.init(std.heap.page_allocator, .{ .workers = if (is_windows) 2 else 0, .offload = .none }) catch |err| switch (err) {
            // No evented backend on this system.
            error.BackendUnavailable => return error.SkipZigTest,
            else => |e| return e,
        };
        errdefer host.runtime.deinit();
        try host.runtime.start();
        return host;
    }

    fn deinit(host: *Host) void {
        host.runtime.deinit();
        std.heap.page_allocator.destroy(host);
    }

    fn io(host: *Host) std.Io {
        return host.runtime.io();
    }

    /// Runs `body` as a task on the runtime and returns what it returns.
    fn run(host: *Host, comptime body: anytype) !void {
        const runtime_io = host.io();
        var task = try runtime_io.concurrent(body, .{runtime_io});
        return task.await(runtime_io);
    }
};

/// The number of times a reactor extension took the path for an `Io` that is
/// not a runtime, so a test can say its waits did not.
fn expectNative(before: u64) !void {
    try std.testing.expectEqual(before, reactor.fallbacks());
}

fn spawnReading(io: std.Io) !Child {
    return Child.spawn(std.testing.allocator, io, .{
        .argv = &script.read_then_exit_5,
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
}

fn waits(io: std.Io) !void {
    var child = try spawnReading(io);
    defer child.deinit(io);
    defer reap(&child, io);

    const before = reactor.fallbacks();
    // Running, and the time runs out first.
    try std.testing.expectEqual(@as(?Term, null), try child.waitTimeout(io, Deadline.within(.fromMilliseconds(30))));
    child.closeStdin(io);
    try std.testing.expectEqual(Term{ .exited = 5 }, (try child.waitTimeout(io, Deadline.within(.fromMilliseconds(10_000)))).?);
    try std.testing.expectEqual(Term{ .exited = 5 }, try child.wait(io));
    try expectNative(before);
}

test "a child is waited for on a runtime, with and without a deadline" {
    const host = try Host.start();
    defer host.deinit();
    try host.run(waits);
}

fn killed(io: std.Io) !void {
    var child = try Child.spawn(std.testing.allocator, io, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = true,
    });
    defer child.deinit(io);
    const before = reactor.fallbacks();
    _ = try child.killWait(io, .fromMilliseconds(100));
    try std.testing.expect(try child.tryWait(io) != null);
    try expectNative(before);
}

test "killWait ends a child that does not read on a runtime" {
    const host = try Host.start();
    defer host.deinit();
    try host.run(killed);
}

fn waitForever(io: std.Io, child: *Child) conduit.Child.WaitError!Term {
    return child.wait(io);
}

fn cancelled(io: std.Io) !void {
    var child = try spawnReading(io);
    defer child.deinit(io);
    defer reap(&child, io);

    var waiting = try io.concurrent(waitForever, .{ io, &child });
    // Let it park on the child's end.
    try io.sleep(.fromMilliseconds(30), .awake);
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    try std.testing.expectError(error.Canceled, waiting.cancel(io));
    // The cancel is a wake of the parked task, not the end of a slice.
    const took = start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw;
    try std.testing.expect(took.toMilliseconds() < 500);
    // Nothing was reaped: the child is running and its owner waits again.
    try std.testing.expectEqual(@as(?Term, null), try child.tryWait(io));
    child.closeStdin(io);
    try std.testing.expectEqual(Term{ .exited = 5 }, try child.wait(io));
}

test "a cancel ends a wait for a child on a runtime and reaps nothing" {
    const host = try Host.start();
    defer host.deinit();
    try host.run(cancelled);
}

fn collected(io: std.Io) !void {
    var child = try Child.spawn(std.testing.allocator, io, .{
        .argv = &script.emit_both,
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .pipe } },
    });
    defer child.deinit(io);
    defer reap(&child, io);
    const before = reactor.fallbacks();
    var output = try child.output(std.testing.allocator, io, .{ .timeout = Deadline.within(.fromSeconds(30)) });
    defer output.deinit();
    try std.testing.expect(!output.timedOut());
    try std.testing.expect(conduit.succeeded(output.term()));
    if (!is_windows) {
        try std.testing.expectEqual(@as(usize, 300_000), output.stdout().len);
        try std.testing.expectEqual(@as(usize, 200_000), output.stderr().len);
    } else {
        try std.testing.expect(output.stdout().len != 0 and output.stderr().len != 0);
    }
    try expectNative(before);
}

test "both streams of a child are collected on a runtime" {
    const host = try Host.start();
    defer host.deinit();
    try host.run(collected);
}

fn timedOut(io: std.Io) !void {
    var child = try Child.spawn(std.testing.allocator, io, .{
        .argv = &script.sleep_forever,
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .pipe } },
        .detach = true,
    });
    defer child.deinit(io);
    defer reap(&child, io);
    const before = reactor.fallbacks();
    var output = try child.output(std.testing.allocator, io, .{
        .timeout = Deadline.within(.fromMilliseconds(100)),
        .grace = .fromMilliseconds(50),
    });
    defer output.deinit();
    try std.testing.expect(output.timedOut());
    try expectNative(before);
}

test "output ends a child that outlasts its timeout on a runtime" {
    const host = try Host.start();
    defer host.deinit();
    try host.run(timedOut);
}

fn reaped(io: std.Io) !void {
    var child = try spawnReading(io);
    defer child.deinit(io);
    defer reap(&child, io);
    var reaper: Reaper = .init(&child, .{});
    try reaper.start(io);
    defer reaper.deinit(io);

    const before = reactor.fallbacks();
    try std.testing.expectEqual(@as(?Term, null), try reaper.waitTimeout(io, Deadline.within(.fromMilliseconds(30))));
    child.closeStdin(io);
    try std.testing.expectEqual(Term{ .exited = 5 }, (try reaper.waitTimeout(io, Deadline.within(.fromMilliseconds(10_000)))).?);
    try std.testing.expectEqual(Term{ .exited = 5 }, try child.wait(io));
    try expectNative(before);
}

test "a Reaper waits for a child on a runtime" {
    const host = try Host.start();
    defer host.deinit();
    try host.run(reaped);
}

fn stopped(io: std.Io) !void {
    var child = try spawnReading(io);
    defer child.deinit(io);
    defer reap(&child, io);
    var reaper: Reaper = .init(&child, .{});
    try reaper.start(io);
    // The task is parked on the child's end; stopping ends it without a thread
    // to wake, and the child is still the owner's to reap.
    try io.sleep(.fromMilliseconds(30), .awake);
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    try reaper.stop(io);
    reaper.deinit(io);
    try std.testing.expect(start.durationTo(std.Io.Clock.Timestamp.now(io, .awake)).raw.toMilliseconds() < 500);
    try std.testing.expectEqual(@as(?Term, null), try child.tryWait(io));
}

test "stopping a Reaper on a runtime ends its wait and leaves the child" {
    const host = try Host.start();
    defer host.deinit();
    try host.run(stopped);
}

fn forced(io: std.Io) !void {
    // The shell ignores the request, and the `sleep` it starts is the tree the
    // force has to reach.
    var child = try Child.spawn(std.testing.allocator, io, .{
        .argv = &script.ignore_request,
        .stdio = .ignore,
        .detach = true,
    });
    defer child.deinit(io);
    defer reap(&child, io);
    var reaper: Reaper = .init(&child, .{});
    try reaper.start(io);
    defer reaper.deinit(io);

    const before = reactor.fallbacks();
    // Asked, not waited for: the grace is waited out on the Reaper's own task,
    // which parks on the runtime's one thread beside the task that waits here.
    reaper.kill(io, .fromMilliseconds(100));
    const term = (try reaper.waitTimeout(io, Deadline.within(.fromMilliseconds(10_000)))) orelse return error.TestChildDidNotExit;
    try std.testing.expect(term == .signal or is_windows);
    try expectNative(before);
}

test "a Reaper ends a child that ignores the request once its grace has run out, on a runtime" {
    const host = try Host.start();
    defer host.deinit();
    try host.run(forced);
}

fn captured(io: std.Io) !void {
    var child = try Child.spawn(std.testing.allocator, io, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = true,
    });
    defer child.deinit(io);
    defer reap(&child, io);
    const pid = child.processId().?;
    var held = (try conduit.captureStarted(pid, (try conduit.startTime(pid)) orelse return error.SkipZigTest)) orelse return error.SkipZigTest;
    defer held.deinit();

    const before = reactor.fallbacks();
    try std.testing.expect(!try held.wait(io, Deadline.within(.fromMilliseconds(30))));
    try std.testing.expect(held.signal(.KILL));
    try std.testing.expect(try held.wait(io, Deadline.within(.fromMilliseconds(10_000))));
    try expectNative(before);
}

test "a held process is waited for on a runtime" {
    if (is_windows) return error.SkipZigTest;
    const host = try Host.start();
    defer host.deinit();
    try host.run(captured);
}

fn jobEmptied(io: std.Io) !void {
    var child = try spawnReading(io);
    defer child.deinit(io);
    defer reap(&child, io);
    const before = reactor.fallbacks();
    // The job holds the child, so it is not empty.
    try std.testing.expect(!try child.waitTree(io, Deadline.within(.fromMilliseconds(50))));
    child.closeStdin(io);
    _ = try child.wait(io);
    try std.testing.expect(try child.waitTree(io, Deadline.within(.fromMilliseconds(10_000))));
    // Said once, said again.
    try std.testing.expect(try child.waitTree(io, Deadline.within(.zero)));
    try expectNative(before);
}

test "a job's emptying is heard on a runtime" {
    if (!is_windows) return error.SkipZigTest;
    const host = try Host.start();
    defer host.deinit();
    try host.run(jobEmptied);
}
