const std = @import("std");
const reap = @import("testing/support.zig").reap;
const builtin = @import("builtin");
const c = std.c;
const exit = @import("exit.zig");
const reactor = @import("reactor");
const shakedown = @import("shakedown");
const Child = @import("child.zig").Child;
const Deadline = @import("conduit.tty").Deadline;

test "a wait for a child ends when the child does, and leaves it unreaped" {
    const testing = std.testing;
    const io = testing.io;
    var child = try Child.spawn(testing.allocator, io, .{
        .argv = if (builtin.target.os.tag == .windows) &.{ "cmd.exe", "/c", "exit 3" } else &.{ "/bin/sh", "-c", "exit 3" },
        .stdio = .ignore,
    });
    defer child.deinit(io);
    defer reap(&child, io);

    try testing.expectEqual(exit.Wait.ended, try exit.wait(io, child.state.id, watchOf(&child), null, Deadline.within(.fromMilliseconds(5000))));
    // Ended, and still there to reap: the status is the owner's to collect.
    try testing.expectEqual(Child.Term{ .exited = 3 }, try child.wait(io));
}

test "a wait for a child that is still running times out, and the next wait is still the child's" {
    const testing = std.testing;
    const io = testing.io;
    var child = try Child.spawn(testing.allocator, io, .{
        .argv = if (builtin.target.os.tag == .windows) &.{ "cmd.exe", "/c", "set /p line=" } else &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.deinit(io);
    defer reap(&child, io);

    try testing.expectEqual(exit.Wait.timeout, try exit.wait(io, child.state.id, watchOf(&child), null, Deadline.within(.fromMilliseconds(20))));
    child.closeStdin(io);
    // With no deadline: the wait lasts exactly as long as the child does.
    try testing.expectEqual(exit.Wait.ended, try exit.wait(io, child.state.id, watchOf(&child), null, .none));
}

fn watchOf(child: *const Child) ?*const reactor.Process {
    if (builtin.target.os.tag == .windows) return null;
    return if (child.state.exit_watch) |*watch| watch else null;
}

test "a child killed a moment before it is waited for is noticed without asking again" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    // A watch opened after the kill finds the child gone to a kqueue and yet,
    // for a moment, not ended to `waitid`, and then has only asking to go on;
    // the one opened with the child is told. Any sleep is an asking.
    const counted = try shakedown.FaultIo.init(testing.allocator, io, .{});
    defer counted.deinit();
    for (0..200) |_| {
        var child = try Child.spawn(testing.allocator, io, .{
            .argv = &.{ "/bin/sleep", "30" },
            .stdio = .ignore,
            .detach = true,
        });
        defer child.deinit(io);
        defer reap(&child, io);
        try child.kill(io, .kill);
        try testing.expectEqual(exit.Wait.ended, try exit.wait(counted.io(), child.state.id, watchOf(&child), null, Deadline.within(.fromMilliseconds(5000))));
    }
    try testing.expectEqual(@as(u64, 0), counted.count(.sleep));
}

test "a wake ends a wait for a child at once, and the child is still waited for after it" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var child = try Child.spawn(testing.allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.deinit(io);
    defer reap(&child, io);
    var wake = try reactor.Wake.init(io);
    defer wake.deinit(io);

    try testing.expectEqual(exit.Wait.timeout, try exit.wait(io, child.state.id, watchOf(&child), &wake, Deadline.within(.fromMilliseconds(20))));
    wake.signal();
    // No deadline: only the wake ends this.
    try testing.expectEqual(exit.Wait.woken, try exit.wait(io, child.state.id, watchOf(&child), &wake, .none));
    child.closeStdin(io);
    try testing.expectEqual(exit.Wait.ended, try exit.wait(io, child.state.id, watchOf(&child), &wake, Deadline.within(.fromMilliseconds(5000))));
    // Both ready: the wake is the answer, and the end is still there after it.
    wake.signal();
    try testing.expectEqual(exit.Wait.woken, try exit.wait(io, child.state.id, watchOf(&child), &wake, .none));
    try testing.expectEqual(exit.Wait.ended, try exit.wait(io, child.state.id, watchOf(&child), &wake, .none));
}

fn waitForever(io: std.Io, id: std.process.Child.Id, watch: ?*const reactor.Process) std.Io.Cancelable!exit.Wait {
    return exit.wait(io, id, watch, null, .none);
}

test "a cancel ends a wait for a child that will not end, which is not the child's end" {
    const testing = std.testing;
    const io = testing.io;
    var child = try Child.spawn(testing.allocator, io, .{
        .argv = if (builtin.target.os.tag == .windows) &.{ "cmd.exe", "/c", "set /p line=" } else &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.deinit(io);
    defer reap(&child, io);

    var waiting = io.concurrent(waitForever, .{ io, child.state.id, watchOf(&child) }) catch return error.SkipZigTest;
    try io.sleep(.fromMilliseconds(20), .awake);
    try testing.expectError(error.Canceled, waiting.cancel(io));
    // Nothing was reaped: the child is running and its owner still waits.
    try testing.expectEqual(@as(?Child.Term, null), try child.tryWait(io));
}

test "asking whether a child has ended leaves it unreaped" {
    if (builtin.target.os.tag == .windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var child = try Child.spawn(testing.allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", "read x; exit 0" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
        .descendants = .contain,
    });
    defer child.deinit(io);
    defer reap(&child, io);
    const root = child.processId().?;
    // The owned wait identity is the private supervisor on Linux. The root
    // belongs to that supervisor; waitid in this process cannot observe it.
    const pid = child.state.id;
    try testing.expectEqual(exit.Ended.running, exit.ask(pid));
    child.closeStdin(io);
    const deadline: Deadline = .in(io, .fromMilliseconds(5000));
    while (exit.ask(pid) == .running and deadline.remainingMs(io) > 0)
        try io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectEqual(exit.Ended.ended, exit.ask(pid));
    // Asking left the wait identity unreaped and the root label intact.
    try testing.expectEqual(root, child.processId().?);
    try testing.expectEqual(@as(c_int, 0), c.kill(pid, @fromBackingInt(@intCast(0))));
    try testing.expect(Child.succeeded((try child.waitTimeout(io, Deadline.within(.fromMilliseconds(5000)))).?));
}
