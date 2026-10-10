const builtin = @import("builtin");
const std = @import("std");
const reap = @import("../testing/support.zig").reap;
const Deadline = @import("conduit.tty").Deadline;
const posix = std.posix;
const windows = std.os.windows;
const c = std.c;
const Allocator = std.mem.Allocator;
const is_windows = builtin.target.os.tag == .windows;
const Child = @import("../child.zig").Child;
const win32 = @import("../win32.zig");
const access = @import("../child.zig").test_access;
const Reaper = @import("../reaper.zig").Reaper;
const Observer = struct {
    reaper: *Reaper,
    retired: bool = false,

    fn observe(context: *anyopaque, child: *Child) void {
        const probe: *Observer = @ptrCast(@alignCast(context)); // safe: the test registers its live Observer for this callback.

        child.closeStdin(std.testing.io);
        // Give the Reaper the chance to finish the reap while delivery is
        // paused. With a held identity it must leave the status and handles
        // alone until delivery resumes.
        // glint-ignore: Z026 -- only a pause for the Reaper; the assertion is what it did meanwhile, read below
        _ = probe.reaper.waitTimeout(std.testing.io, Deadline.within(.fromMilliseconds(20))) catch {};
        probe.retired = child.state.reaped.load(.acquire) or if (is_windows) retired: {
            var code: windows.DWORD = undefined;
            break :retired win32.GetExitCodeProcess(child.state.id, &code) == .FALSE;
        } else c.kill(child.state.id, @fromBackingInt(@intCast(0))) != 0 and c.errno(@as(c_int, -1)) == .SRCH;
    }
};
test "a Reaper cannot retire the identity while kill is delivering a signal" {
    const testing = std.testing;
    const io = testing.io;

    for (0..64) |iteration| {
        var stage: []const u8 = "spawning";
        errdefer std.debug.print("identity fixture: iteration {d}, {s}\n", .{ iteration, stage });
        var child = try Child.spawn(testing.allocator, io, .{
            .argv = if (is_windows) &.{ "cmd.exe", "/c", "set /p line=& exit 0" } else &.{ "/bin/sh", "-c", "read x" },
            .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
            .detach = iteration % 2 == 0,
        });
        defer child.deinit(io);
        defer reap(&child, io);
        var reaper: Reaper = .init(&child, .{});
        stage = "starting Reaper";
        try reaper.start(io);
        defer reaper.deinit(io);

        var probe: Observer = .{ .reaper = &reaper };
        var hook: access.SignalProbe = .{ .context = &probe, .observe = Observer.observe };
        access.probe(&hook);
        defer access.probe(null);
        stage = "delivering the signal";
        try child.kill(if (iteration % 3 == 0) .kill else .terminate);
        access.probe(null);
        stage = "checking retirement during delivery";
        try testing.expect(!probe.retired);
        stage = "waiting for publication";
        const term = (try reaper.waitTimeout(io, Deadline.within(.fromMilliseconds(5000)))) orelse return error.TestChildDidNotExit;
        stage = "comparing the published answer";
        try testing.expectEqual(term, try child.wait(io));
        stage = "ignoring a retired kill";
        try child.kill(.kill);
    }
}

const HeldOutput = struct {
    child: *Child,
    result: ?(Child.OutputError!Child.Output) = null,

    fn run(held: *HeldOutput) std.Io.Cancelable!void {
        held.result = held.child.output(std.testing.allocator, std.testing.io, .{ .timeout = Deadline.within(.fromMilliseconds(10_000)) });
    }
};

test "output leaves the reap to the task that holds it" {
    if (is_windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;

    var child = try Child.spawn(testing.allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", "echo done" },
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
        .detach = true,
    });
    defer child.deinit(io);
    defer reap(&child, io);
    const held = child.holdReap().?;
    var released = false;
    defer if (!released) held.release();

    var output: HeldOutput = .{ .child = &child };
    defer if (output.result) |result| if (result) |collected| {
        var owned = collected;
        owned.deinit();
    } else |_| {};
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, HeldOutput.run, .{&output});

    // The child has long ended; output must still not have reaped it.
    try io.sleep(.fromMilliseconds(300), .awake);
    try testing.expect(!child.state.reaped.load(.acquire));
    try testing.expect(output.result == null);

    const term = try held.wait(io);
    held.release();
    released = true;
    try group.await(io);
    const result = try output.result.?;
    try testing.expectEqual(term, result.term());
    try testing.expectEqualStrings("done\n", result.stdout());
}
