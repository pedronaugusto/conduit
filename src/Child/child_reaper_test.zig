const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const windows = std.os.windows;
const c = std.c;
const Allocator = std.mem.Allocator;
const Pty = @import("../Pty.zig").Pty;
const is_windows = builtin.os.tag == .windows;
const Child = @import("Child.zig").Child;
const State = @import("child_state.zig");
const win32 = if (is_windows) @import("../win32.zig") else struct {};
const access = @import("Child.zig").test_access;
const Observer = struct {
    reaper: *@import("../Reaper.zig").Reaper,
    retired: bool = false,

    fn observe(context: *anyopaque, child: *Child) void {
        const probe: *Observer = @ptrCast(@alignCast(context)); // safe: the test registers its live Observer for this callback.

        child.closeStdin(std.testing.io);
        // Give the Reaper the chance to finish the reap while delivery is
        // paused. With a held identity it must leave the status and handles
        // alone until delivery resumes.
        _ = probe.reaper.waitTimeout(std.testing.io, 20) catch {};
        probe.retired = State.get(child).reaped.load(.acquire) or if (is_windows) retired: {
            var code: win32.DWORD = undefined;
            break :retired win32.GetExitCodeProcess(State.get(child).id, &code) == .FALSE;
        } else c.kill(State.get(child).id, @enumFromInt(0)) != 0 and c.errno(@as(c_int, -1)) == .SRCH;
    }
};
test "a Reaper cannot retire the identity while kill is delivering a signal" {
    const testing = std.testing;
    const io = testing.io;
    var watchdog: @import("../testing/test_support.zig").Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    for (0..64) |iteration| {
        var stage: []const u8 = "spawning";
        errdefer |err| std.debug.print("identity fixture: iteration {d}, {s}: {s}\n", .{ iteration, stage, @errorName(err) });
        var child = try Child.spawn(io, testing.allocator, .{
            .argv = if (is_windows) &.{ "cmd.exe", "/c", "set /p line=& exit 0" } else &.{ "/bin/sh", "-c", "read x" },
            .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
            .detach = iteration % 2 == 0,
        });
        defer child.release(io) catch unreachable;
        defer _ = child.killWait(io, 0) catch {};
        var reaper: @import("../Reaper.zig").Reaper = .init(&child, .{});
        stage = "starting Reaper";
        try reaper.start(io);
        defer reaper.deinit(io) catch unreachable;

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
        const term = (try reaper.waitTimeout(io, 5000)) orelse return error.TestChildDidNotExit;
        stage = "comparing the published answer";
        try testing.expectEqual(term, try child.wait(io));
        stage = "ignoring a retired kill";
        try child.kill(.kill);
    }
}
