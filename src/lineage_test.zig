const std = @import("std");
const Deadline = @import("conduit.tty").Deadline;
const posix = std.posix;
const c = std.c;
const testing = std.testing;
const testing_hook = @import("lineage.zig").testing_hook;
const supported = @import("lineage.zig").supported;
const Child = @import("child.zig").Child;
test "a contained wait reports lost observation after reaping its held root" {
    if (!supported) return error.SkipZigTest;
    testing_hook.enumeration.store(.fail, .release);
    defer testing_hook.enumeration.store(.normal, .release);
    var child = try Child.spawn(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .descendants = .contain,
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.deinit(testing.io);
    const pid = child.processId().?;
    try testing.expectError(error.Unexpected, child.waitTimeout(testing.io, Deadline.within(.fromMilliseconds(5000))));
    var status: c_int = 0;
    try testing.expectEqual(@as(c_int, -1), c.waitpid(pid, &status, posix.W.NOHANG));
    try testing.expectEqual(posix.E.CHILD, posix.errno(-1));
}
