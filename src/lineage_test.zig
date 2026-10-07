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
    testing_hook.fail_enumeration.store(true, .release);
    defer testing_hook.fail_enumeration.store(false, .release);
    var child = try Child.spawn(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .descendants = .contain,
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.deinit(std.testing.io);
    const pid = child.processId().?;
    try std.testing.expectError(error.Unexpected, child.waitTimeout(std.testing.io, Deadline.within(.fromMilliseconds(5000))));
    var status: c_int = 0;
    try std.testing.expectEqual(@as(c_int, -1), c.waitpid(pid, &status, posix.W.NOHANG));
    try std.testing.expectEqual(posix.E.CHILD, posix.errno(-1));
}
