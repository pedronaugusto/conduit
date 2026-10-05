const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const is_windows = builtin.os.tag == .windows;
const testing = std.testing;
const access = @import("lineage.zig").test_access;
const tree = access.tree;
const testing_hook = @import("lineage.zig").testing_hook;
const supported = @import("lineage.zig").supported;
const Tracker = @import("lineage.zig").Tracker;
const Child = @import("child.zig").Child;
const Watchdog = @import("testing/support.zig").Watchdog;
const Darwin = access.Darwin;
test "a contained wait reports lost observation after reaping its held root" {
    if (!supported) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(std.testing.io);
    defer watchdog.deinit(std.testing.io);
    testing_hook.fail_enumeration.store(true, .release);
    defer testing_hook.fail_enumeration.store(false, .release);
    var child = try Child.spawn(std.testing.io, std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .descendants = .contain,
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.release(std.testing.io) catch unreachable;
    const pid = child.processId().?;
    try std.testing.expectError(error.Unexpected, child.waitTimeout(std.testing.io, 5000));
    var status: c_int = 0;
    try std.testing.expectEqual(@as(c_int, -1), c.waitpid(pid, &status, posix.W.NOHANG));
    try std.testing.expectEqual(posix.E.CHILD, posix.errno(-1));
}
