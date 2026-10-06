//! `Child.exchange`: input in, output out, one deadline, through native pipes.
const std = @import("std");
const conduit = @import("../conduit.zig");
const Child = conduit.Child;
const Watchdog = @import("../testing/support.zig").Watchdog;
const testing = std.testing;
const test_options = @import("conduit_test_options");
const io = testing.io;
const gpa = testing.allocator;
const budget_ms = 5000;

fn spawn(mode: []const u8) !Child {
    return Child.spawn(gpa, io, .{
        .argv = &.{ test_options.input_fixture, mode },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
    });
}

/// More than any pipe holds, so a writer that waited for its reader to finish
/// before reading back, or the other way round, would never finish.
fn bulk() ![]u8 {
    const bytes = try gpa.alloc(u8, 1 << 20);
    for (bytes, 0..) |*byte, i| byte.* = @truncate(i *% 31);
    return bytes;
}

test "exchange writes input past a pipe's size while it reads as much back" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const input = try bulk();
    defer gpa.free(input);
    var child = try spawn("end");
    defer child.release(io) catch unreachable;
    var result = try child.exchange(gpa, io, input, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);
    try testing.expect(Child.succeeded(result.term()));
    try testing.expect(!result.timedOut());
    try testing.expect(!result.stdoutTruncated());
    try testing.expectEqual(input.len + 3, result.stdout().len);
    try testing.expectEqualSlices(u8, input, result.stdout()[0..input.len]);
    try testing.expectEqualStrings("EOF", result.stdout()[input.len..]);
}

test "exchange closes input at once when there is none, and takes an allocator nobody shares" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // An arena is not made to be used from two threads; the exchange's own
    // tasks use it one at a time.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var child = try spawn("end");
    defer child.release(io) catch unreachable;
    var result = try child.exchange(arena.allocator(), io, "", .{ .timeout_ms = budget_ms });
    defer result.deinit(arena.allocator());
    try testing.expect(Child.succeeded(result.term()));
    try testing.expectEqualStrings("EOF", result.stdout());
}

test "exchange keeps no more than max_bytes and says the rest was dropped" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const input = try bulk();
    defer gpa.free(input);
    var child = try spawn("echo");
    defer child.release(io) catch unreachable;
    var result = try child.exchange(gpa, io, input, .{ .timeout_ms = budget_ms, .max_bytes = 100 });
    defer result.deinit(gpa);
    try testing.expect(Child.succeeded(result.term()));
    try testing.expect(result.stdoutTruncated());
    try testing.expectEqualSlices(u8, input[0..100], result.stdout());
}

test "input a child never reads is not an error" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const input = try bulk();
    defer gpa.free(input);
    var child = try spawn("exit");
    defer child.release(io) catch unreachable;
    var result = try child.exchange(gpa, io, input, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);
    try testing.expect(Child.succeeded(result.term()));
    try testing.expect(!result.timedOut());
}

test "one deadline ends a child that neither reads its input nor ends" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const input = try bulk();
    defer gpa.free(input);
    var child = try spawn("stall");
    defer child.release(io) catch unreachable;
    // The write blocks on a full pipe and the run never ends: the deadline
    // ends both, and the call returns.
    var result = try child.exchange(gpa, io, input, .{ .timeout_ms = 100 });
    defer result.deinit(gpa);
    try testing.expect(result.timedOut());
    try testing.expect(!Child.succeeded(result.term()));
    try testing.expect((try child.result()) != null);
}

test "exchange refuses input for a child with no stdin pipe and leaves it running" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try spawn("end");
    defer child.release(io) catch unreachable;
    const stdin = child.takeStdin().?;
    try testing.expectError(error.NoStdinPipe, child.exchange(gpa, io, "input", .{ .timeout_ms = budget_ms }));
    try testing.expectEqual(null, try child.tryWait());
    // The refused call left the child alone: it still reads what it is given.
    try stdin.writeStreamingAll(io, "still here ");
    stdin.close(io);
    var result = try child.output(gpa, io, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);
    try testing.expect(Child.succeeded(result.term()));
    try testing.expectEqualStrings("still here EOF", result.stdout());
}

test "output takes an allocator nobody shares" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var child = try spawn("end");
    defer child.release(io) catch unreachable;
    child.closeStdin(io);
    var result = try child.output(arena.allocator(), io, .{ .timeout_ms = budget_ms });
    defer result.deinit(arena.allocator());
    try testing.expect(Child.succeeded(result.term()));
    try testing.expectEqualStrings("EOF", result.stdout());
}
