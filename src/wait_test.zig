const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const is_windows = builtin.os.tag == .windows;
const access = @import("wait.zig").test_access;
const Deadline = @import("wait.zig").Deadline;
const slice_ms = @import("wait.zig").slice_ms;
const Watch = @import("wait.zig").Watch;
const Outcome = @import("wait.zig").Outcome;
const Ended = @import("wait.zig").Ended;
const endedUnreaped = @import("wait.zig").endedUnreaped;
const Watchdog = @import("testing/support.zig").Watchdog;
const p_pid = access.p_pid;
const WaitId = access.WaitId;
const waitid_flags = access.waitid_flags;
const infoPid = access.infoPid;
const openPidfd = access.openPidfd;
const endedPidfd = access.endedPidfd;
const endedOrWokenPidfd = access.endedOrWokenPidfd;
const openKqueue = access.openKqueue;
const endedKqueue = access.endedKqueue;
const endedOrWokenKqueue = access.endedOrWokenKqueue;
test "a watch on a child ends when the child does" {
    const testing = std.testing;
    const Child = @import("child.zig").Child;
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var child = try Child.spawn(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdio = .ignore,
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};

    // Every system this package is tested on has one; a system that has not is
    // one where the caller asks again instead, and there is nothing here to
    // assert about it.
    const watch = Watch.open(child.state.id) orelse return error.SkipZigTest;
    defer watch.close();

    try testing.expect(watch.ended(5000));
}

test "a watch with a wake ends on the wake, then on the child" {
    const testing = std.testing;
    const Child = @import("child.zig").Child;
    const handles = @import("handles.zig");
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var child = try Child.spawn(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};

    const watch = Watch.open(child.state.id) orelse return error.SkipZigTest;
    defer watch.close();
    const wake = try handles.pipe();
    defer _ = c.close(wake[0]);
    defer _ = c.close(wake[1]);

    try testing.expectEqual(Outcome.timed_out, watch.endedOrWoken(wake[0], 20));
    _ = c.write(wake[1], "w", 1);
    try testing.expectEqual(Outcome.woken, watch.endedOrWoken(wake[0], 5000));
    var byte: [1]u8 = undefined;
    _ = c.read(wake[0], &byte, 1);

    child.closeStdin(testing.io);
    // With no deadline: the wait lasts exactly as long as the child does.
    var outcome = watch.endedOrWoken(wake[0], null);
    while (outcome == .timed_out) outcome = watch.endedOrWoken(wake[0], null);
    try testing.expectEqual(Outcome.ended, outcome);
}

test "a watch on a child that is still running says so" {
    const testing = std.testing;
    const Child = @import("child.zig").Child;
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var child = try Child.spawn(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .stdio = .ignore,
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};

    const watch = Watch.open(child.state.id) orelse return error.SkipZigTest;
    defer watch.close();

    try testing.expect(!watch.ended(20));
}

test "exit observation keeps the child's identity until its owner reaps it" {
    const testing = std.testing;
    const io = testing.io;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const Child = @import("child.zig").Child;
    var child = try Child.spawn(testing.allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", "read x; exit 0" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
        .descendants = .contain,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    const root = child.processId().?;
    // The owned wait identity is the private supervisor on Linux. The root
    // belongs to that supervisor; waitid in this process cannot observe it.
    const pid = child.state.id;
    try testing.expectEqual(Ended.running, endedUnreaped(pid));
    child.closeStdin(io);
    const deadline: Deadline = .in(io, 5000);
    while (endedUnreaped(pid) == .running and deadline.remainingMs(io) > 0)
        try io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectEqual(Ended.ended, endedUnreaped(pid));
    // Observation left the wait identity unreaped and the root label intact.
    try testing.expectEqual(root, child.processId().?);
    try testing.expectEqual(@as(c_int, 0), c.kill(pid, @enumFromInt(0)));
    try testing.expect(Child.succeeded((try child.waitTimeout(io, 5000)).?));
}
