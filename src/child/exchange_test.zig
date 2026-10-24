//! `Child.exchange` and `Child.exchangeInto`: input in, output out, one
//! deadline, through native pipes.
const std = @import("std");
const Deadline = @import("conduit.tty").Deadline;
const conduit = @import("../conduit.zig");
const Child = conduit.Child;
const testing = std.testing;
const test_options = @import("conduit_test_options");
const io = testing.io;
const gpa = testing.allocator;
const budget_ms = 5000;
const budget: std.Io.Duration = .fromMilliseconds(budget_ms);
const within_budget: std.Io.Timeout = .{ .duration = .{ .raw = budget, .clock = .awake } };

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
    const input = try bulk();
    defer gpa.free(input);
    var child = try spawn("end");
    defer child.deinit(io);
    var result = try child.exchange(gpa, io, input, .{ .timeout = within_budget });
    defer result.deinit();
    try testing.expect(Child.succeeded(result.term()));
    try testing.expect(!result.timedOut());
    try testing.expect(!result.stdoutTruncated());
    try testing.expectEqual(input.len + 3, result.stdout().len);
    try testing.expectEqualSlices(u8, input, result.stdout()[0..input.len]);
    try testing.expectEqualStrings("EOF", result.stdout()[input.len..]);
}

test "exchange closes input at once when there is none, and takes an allocator nobody shares" {
    // An arena is not made to be used from two threads; the exchange's own
    // tasks use it one at a time.
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var child = try spawn("end");
    defer child.deinit(io);
    var result = try child.exchange(arena.allocator(), io, "", .{ .timeout = within_budget });
    defer result.deinit();
    try testing.expect(Child.succeeded(result.term()));
    try testing.expectEqualStrings("EOF", result.stdout());
}

test "exchange keeps no more than max_bytes and says the rest was dropped" {
    const input = try bulk();
    defer gpa.free(input);
    var child = try spawn("echo");
    defer child.deinit(io);
    var result = try child.exchange(gpa, io, input, .{ .timeout = within_budget, .max_bytes = .fromRaw(100) });
    defer result.deinit();
    try testing.expect(Child.succeeded(result.term()));
    try testing.expect(result.stdoutTruncated());
    try testing.expectEqualSlices(u8, input[0..100], result.stdout());
}

test "input a child never reads is not an error" {
    const input = try bulk();
    defer gpa.free(input);
    var child = try spawn("exit");
    defer child.deinit(io);
    var result = try child.exchange(gpa, io, input, .{ .timeout = within_budget });
    defer result.deinit();
    try testing.expect(Child.succeeded(result.term()));
    try testing.expect(!result.timedOut());
}

test "one deadline ends a child that neither reads its input nor ends" {
    const input = try bulk();
    defer gpa.free(input);
    var child = try spawn("stall");
    defer child.deinit(io);
    // The write blocks on a full pipe and the run never ends: the deadline
    // ends both, and the call returns.
    var result = try child.exchange(gpa, io, input, .{ .timeout = Deadline.within(.fromMilliseconds(100)) });
    defer result.deinit();
    try testing.expect(result.timedOut());
    try testing.expect(!Child.succeeded(result.term()));
    try testing.expect((try child.result()) != null);
}

test "exchange refuses input for a child with no stdin pipe and leaves it running" {
    var child = try spawn("end");
    defer child.deinit(io);
    const stdin = child.takeStdin().?;
    try testing.expectError(error.NoStdinPipe, child.exchange(gpa, io, "input", .{ .timeout = within_budget }));
    try testing.expectEqual(null, try child.tryWait(io));
    // The refused call left the child alone: it still reads what it is given.
    try stdin.writeStreamingAll(io, "still here ");
    stdin.close(io);
    var result = try child.output(gpa, io, .{ .timeout = within_budget });
    defer result.deinit();
    try testing.expect(Child.succeeded(result.term()));
    try testing.expectEqualStrings("still here EOF", result.stdout());
}

test "output takes an allocator nobody shares" {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var child = try spawn("end");
    defer child.deinit(io);
    child.closeStdin(io);
    var result = try child.output(arena.allocator(), io, .{ .timeout = within_budget });
    defer result.deinit();
    try testing.expect(Child.succeeded(result.term()));
    try testing.expectEqualStrings("EOF", result.stdout());
}

test "exchangeInto reads into a small writer's buffer, which drains as it fills and is flushed at the end" {
    const input = try bulk();
    defer gpa.free(input);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile(io, "out", .{});
    defer file.close(io);
    var buffer: [16]u8 = undefined;
    var out = file.writer(io, &buffer);
    var err = std.Io.Writer.Discarding.init(&.{});
    var child = try spawn("end");
    defer child.deinit(io);
    const ended = try child.exchangeInto(io, input, .{ .stdout = &out.interface, .stderr = &err.writer }, .{ .timeout = within_budget });
    try testing.expect(Child.succeeded(ended.term));
    try testing.expect(!ended.timed_out);
    try testing.expect(!ended.stdout_truncated);
    // Nothing is left in the writer's buffer: all of it reached the file.
    try testing.expectEqual(0, out.interface.end);
    const written = try tmp.dir.readFileAlloc(io, "out", gpa, .unlimited);
    defer gpa.free(written);
    try testing.expectEqual(input.len + 3, written.len);
    try testing.expectEqualSlices(u8, input, written[0..input.len]);
    try testing.expectEqualStrings("EOF", written[input.len..]);
}

test "exchangeInto writes to a writer with no buffer what it reads, up to max_bytes" {
    const input = try bulk();
    defer gpa.free(input);
    var out = std.Io.Writer.Discarding.init(&.{});
    var err = std.Io.Writer.Discarding.init(&.{});
    var child = try spawn("echo");
    defer child.deinit(io);
    const kept = input.len / 2 + 1;
    const ended = try child.exchangeInto(io, input, .{ .stdout = &out.writer, .stderr = &err.writer }, .{
        .timeout = within_budget,
        .max_bytes = .fromRaw(kept),
    });
    try testing.expect(Child.succeeded(ended.term));
    try testing.expect(ended.stdout_truncated);
    try testing.expectEqual(kept, out.fullCount());
}

test "a writer that fails is not written again, and is reported once the child has ended" {
    const input = try bulk();
    defer gpa.free(input);
    // Full after 100 bytes, and with nowhere to drain to.
    var held: [100]u8 = undefined;
    var out = std.Io.Writer.fixed(&held);
    var err = std.Io.Writer.Discarding.init(&.{});
    var child = try spawn("echo");
    defer child.deinit(io);
    // The child goes on writing past the writer's end: it is read to the
    // end regardless, so it never blocks on a full pipe and ends well before
    // the deadline.
    try testing.expectError(error.WriteFailed, child.exchangeInto(io, input, .{ .stdout = &out, .stderr = &err.writer }, .{
        .timeout = within_budget,
    }));
    const term = (try child.result()) orelse return error.TestChildNotReaped;
    try testing.expect(Child.succeeded(term));
    try testing.expectEqualSlices(u8, input[0..100], out.buffered());
}
