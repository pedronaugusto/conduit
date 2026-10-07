//! Input delivery and lifetime, through the public API and native pipes.
const std = @import("std");
const builtin = @import("builtin");
const conduit = @import("conduit.zig");
const InputWriter = conduit.InputWriter;
const Child = conduit.Child;
const testing = std.testing;
const test_options = @import("conduit_test_options");
const io = testing.io;
const gpa = testing.allocator;
const shakedown = @import("shakedown");
const budget_ms = 5000;
const budget: std.Io.Duration = .fromMilliseconds(budget_ms);
const within_budget: std.Io.Timeout = .{ .duration = .{ .raw = budget, .clock = .awake } };

fn spawn(mode: []const u8) !Child {
    return Child.spawn(gpa, io, .{
        .argv = &.{ test_options.input_fixture, mode },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
    });
}

fn reap(child: *Child) void {
    // ziglint-ignore: Z026 cleanup; release below asserts the child is reaped
    _ = child.killWait(io, .zero) catch {};
    child.deinit(io);
}

fn output(child: *Child, expected: []const u8) !void {
    var result = try child.output(gpa, io, .{ .timeout = within_budget });
    defer result.deinit();
    try testing.expect(Child.succeeded(result.term()));
    try testing.expectEqualStrings(expected, result.stdout());
}

/// The writer's first write held on a clock that only the test moves: the
/// test waits for it to start with `entered` and lets it go with `release`.
/// Everything else, task creation and cancellation included, reaches the
/// real `Io`, and a cancel lands in the held write.
const WriteGate = struct {
    clock: shakedown.Clock,
    faults: *shakedown.FaultIo,

    const hold: std.Io.Duration = .fromSeconds(1);

    /// `gate` must not move once this returns.
    fn init(gate: *WriteGate) !void {
        gate.clock = .init(io, .{});
        gate.faults = try .init(gpa, gate.clock.io(), .{ .plan = &.{.{
            .at = .{ .nth = .{ .call = .file_write_streaming, .n = 1 } },
            .fault = .{ .delay = hold },
        }} });
    }

    fn deinit(gate: *WriteGate) void {
        gate.faults.deinit();
        gate.* = undefined;
    }

    fn gated(gate: *WriteGate) std.Io {
        return gate.faults.io();
    }

    fn entered(gate: *WriteGate) !void {
        try gate.clock.awaitArmed(1, within_budget);
    }

    fn release(gate: *WriteGate) void {
        gate.clock.advance(hold);
    }
};

test "InputWriter delivers copied bytes in queue order" {
    var child = try spawn("echo");
    defer reap(&child);
    var gate: WriteGate = undefined;
    try gate.init();
    defer gate.deinit();
    const gated_io = gate.gated();
    var writer = try child.inputWriter(gpa, gated_io, .{ .max_backlog = 1024 });
    defer writer.deinit(gated_io);
    try testing.expect(child.stdinFile() == null);
    var bytes = "first".*;
    try writer.queue(gated_io, &bytes);
    try gate.entered();
    @memset(&bytes, 'x');
    try writer.queue(gated_io, "second");
    try writer.queue(gated_io, "third");
    try writer.close(gated_io);
    gate.release();
    try output(&child, "firstsecondthird");
    try writer.wait(gated_io);
}

test "InputWriter bounds queued bytes together with bytes being written" {
    var child = try spawn("echo");
    defer reap(&child);
    var gate: WriteGate = undefined;
    try gate.init();
    defer gate.deinit();
    const gated_io = gate.gated();
    var writer = try child.inputWriter(gpa, gated_io, .{ .max_backlog = 10 });
    defer writer.deinit(gated_io);
    try writer.queue(gated_io, "123456");
    try gate.entered();
    try writer.queue(gated_io, "7890");
    try testing.expectError(error.BacklogFull, writer.queue(gated_io, "x"));
    try writer.queue(gated_io, "");
    try writer.close(gated_io);
    gate.release();
    try output(&child, "1234567890");
    try writer.wait(gated_io);
}

test "InputWriter closes input after every byte queued before its close" {
    var child = try spawn("end");
    defer reap(&child);
    var gate: WriteGate = undefined;
    try gate.init();
    defer gate.deinit();
    const gated_io = gate.gated();
    var writer = try child.inputWriter(gpa, gated_io, .{ .max_backlog = 10 });
    defer writer.deinit(gated_io);
    try writer.queue(gated_io, "before");
    try gate.entered();
    try writer.queue(gated_io, "end");
    try writer.close(gated_io);
    try writer.close(gated_io);
    try testing.expectError(error.InputClosed, writer.queue(gated_io, "after"));
    gate.release();
    try output(&child, "beforeendEOF");
    try writer.wait(gated_io);
}

test "InputWriter refuses a backlog without waiting for a child that stops reading" {
    var child = try spawn("stall");
    defer reap(&child);
    // Told when the write starts, which then blocks on the full pipe.
    const Started = struct {
        fn set(base: std.Io, context: *anyopaque) void {
            const started: *std.Io.Event = @ptrCast(@alignCast(context)); // safe: the plan hands this test's Event as the context
            started.set(base);
        }
    };
    var started: std.Io.Event = .unset;
    const observed = try shakedown.FaultIo.init(gpa, io, .{ .plan = &.{.{
        .at = .{ .nth = .{ .call = .file_write_streaming, .n = 1 } },
        .fault = .{ .call = .{ .ctx = &started, .f = Started.set } },
    }} });
    defer observed.deinit();
    const observed_io = observed.io();
    const bytes = try gpa.alloc(u8, 2 * 1024 * 1024);
    defer gpa.free(bytes);
    @memset(bytes, 'x');
    var writer = try child.inputWriter(gpa, observed_io, .{ .max_backlog = bytes.len });
    defer writer.deinit(observed_io);
    try writer.queue(observed_io, bytes);
    try started.waitTimeout(io, within_budget);
    try testing.expectError(error.BacklogFull, writer.queue(observed_io, "x"));
    writer.cancel(observed_io);
    try testing.expectError(error.Canceled, writer.wait(observed_io));
    try testing.expectError(error.Canceled, writer.queue(observed_io, "x"));
}

test "InputWriter keeps a write failure for later writers and waiters" {
    var saved: std.posix.Sigaction = undefined;
    if (builtin.target.os.tag != .windows) std.posix.sigaction(.PIPE, &.{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 }, &saved);
    defer if (builtin.target.os.tag != .windows) std.posix.sigaction(.PIPE, &saved, null);
    var child = try spawn("exit");
    defer reap(&child);
    var writer = try child.inputWriter(gpa, io, .{ .max_backlog = 1024 });
    defer writer.deinit(io);
    try testing.expect((try child.waitTimeout(io, within_budget)) != null);
    try writer.queue(io, "gone");
    try testing.expectError(error.BrokenPipe, writer.wait(io));
    try testing.expect(!writer.isOpen(io));
    try testing.expectError(error.BrokenPipe, writer.queue(io, "later"));
    try testing.expectError(error.BrokenPipe, writer.close(io));
    writer.cancel(io);
    try testing.expectError(error.BrokenPipe, writer.wait(io));
}

test "InputWriter cancellation closes an idle pipe and deinit joins an active write" {
    var child = try spawn("end");
    defer reap(&child);
    var writer = try child.inputWriter(gpa, io, .{ .max_backlog = 10 });
    defer writer.deinit(io);
    writer.cancel(io);
    writer.cancel(io);
    try testing.expectError(error.Canceled, writer.wait(io));
    try testing.expectError(error.Canceled, writer.close(io));
    try output(&child, "EOF");

    var blocked = try spawn("end");
    defer reap(&blocked);
    var gate: WriteGate = undefined;
    try gate.init();
    defer gate.deinit();
    const gated_io = gate.gated();
    var active = try blocked.inputWriter(gpa, gated_io, .{ .max_backlog = 10 });
    active.queue(gated_io, "held") catch |err| {
        active.deinit(gated_io);
        return err;
    };
    gate.entered() catch |err| {
        active.deinit(gated_io);
        return err;
    };
    active.deinit(gated_io);
    try output(&blocked, "EOF");
}

test "InputWriter cancellation of a waiter leaves delivery running" {
    var child = try spawn("echo");
    defer reap(&child);
    var writer = try child.inputWriter(gpa, io, .{ .max_backlog = 10 });
    defer writer.deinit(io);
    const Waiter = struct {
        fn wait(w: *InputWriter, entered: *std.Io.Event) InputWriter.WriteError!void {
            entered.set(io);
            try w.wait(io);
        }
    };
    var entered: std.Io.Event = .unset;
    var waiting = try io.concurrent(Waiter.wait, .{ &writer, &entered });
    defer _ = waiting.cancel(io) catch {};
    try entered.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(budget_ms), .clock = .awake } });
    try testing.expectError(error.Canceled, waiting.cancel(io));
    try writer.queue(io, "alive");
    try writer.close(io);
    try output(&child, "alive");
    try writer.wait(io);
}

test "InputWriter serializes concurrent producers without splitting their bytes" {
    var child = try spawn("echo");
    defer reap(&child);
    var writer = try child.inputWriter(gpa, io, .{ .max_backlog = 1024 });
    defer writer.deinit(io);
    const Producer = struct {
        fn queue(w: *InputWriter, id: u8) void {
            for (0..128) |index| w.queue(io, &.{ id, @intCast(index) }) catch @panic("producer refused");
        }
    };
    var producers: std.Io.Group = .init;
    defer producers.cancel(io);
    for (0..4) |id| try producers.concurrent(io, Producer.queue, .{ &writer, @as(u8, @intCast(id)) });
    try producers.await(io);
    try writer.close(io);
    var result = try child.output(gpa, io, .{ .timeout = within_budget });
    defer result.deinit();
    try testing.expect(Child.succeeded(result.term()));
    try testing.expectEqual(1024, result.stdout().len);
    var counts: [4]usize = @splat(0);
    var offset: usize = 0;
    while (offset < result.stdout().len) : (offset += 2) {
        const id = result.stdout()[offset];
        try testing.expect(id < counts.len);
        try testing.expectEqual(counts[id], result.stdout()[offset + 1]);
        counts[id] += 1;
    }
    for (counts) |count| try testing.expectEqual(128, count);
    try writer.wait(io);
}

test "InputWriter allocation refusal leaves the queue and the bound intact" {
    var child = try spawn("echo");
    defer reap(&child);
    // State, node, then payload: fail the payload, after a node was allocated.
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 2 });
    var writer = try child.inputWriter(failing.allocator(), io, .{ .max_backlog = 4 });
    defer writer.deinit(io);
    try testing.expectError(error.OutOfMemory, writer.queue(io, "lost"));
    failing.fail_index = std.math.maxInt(usize);
    try writer.queue(io, "kept");
    try writer.close(io);
    try output(&child, "kept");
    try writer.wait(io);
}

test "InputWriter failed startup leaves the pipe with the child" {
    var child = try spawn("echo");
    defer reap(&child);
    const file = child.stdinFile().?;
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, child.inputWriter(failing.allocator(), io, .{ .max_backlog = 10 }));
    try testing.expectEqual(file.handle, child.stdinFile().?.handle);
    const refused = try shakedown.FaultIo.init(gpa, io, .{ .plan = &.{.{
        .at = .{ .nth = .{ .call = .groupConcurrent, .n = 1 } },
        .fault = .{ .fail = error.ConcurrencyUnavailable },
    }} });
    defer refused.deinit();
    try testing.expectError(error.ConcurrencyUnavailable, child.inputWriter(gpa, refused.io(), .{ .max_backlog = 10 }));
    try testing.expectEqual(file.handle, child.stdinFile().?.handle);
    try file.writeStreamingAll(io, "still open");
    child.closeStdin(io);
    try output(&child, "still open");
    try testing.expectError(error.NoStdinPipe, child.inputWriter(gpa, io, .{ .max_backlog = 10 }));
}

test "InputWriter a zero bound accepts only empty input" {
    var child = try spawn("end");
    defer reap(&child);
    var writer = try child.inputWriter(gpa, io, .{ .max_backlog = 0 });
    defer writer.deinit(io);
    try writer.queue(io, "");
    try testing.expectError(error.BacklogFull, writer.queue(io, "x"));
    try writer.close(io);
    try output(&child, "EOF");
    try writer.wait(io);
    writer.cancel(io);
    try writer.wait(io);
}

test "InputWriter checks cancellation when a write makes no progress" {
    // A write that makes no progress, then a look for a cancel that finds
    // one; any write after it would fail.
    const stalled = try shakedown.FaultIo.init(gpa, io, .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .file_write_streaming, .n = 1 } }, .fault = .{ .short = 0 } },
        .{ .at = .{ .nth = .{ .call = .file_write_streaming, .n = 2 } }, .fault = .{ .fail = error.InputOutput }, .times = 0 },
        .{ .at = .{ .nth = .{ .call = .checkCancel, .n = 1 } }, .fault = .cancel, .times = 0 },
    } });
    defer stalled.deinit();
    const stalled_io = stalled.io();
    var child = try spawn("echo");
    defer reap(&child);
    var writer = try child.inputWriter(gpa, stalled_io, .{ .max_backlog = 10 });
    defer writer.deinit(stalled_io);
    try writer.queue(stalled_io, "held");
    try testing.expectError(error.Canceled, writer.wait(io));
    try testing.expectError(error.Canceled, writer.queue(io, "later"));
    // The cancel was found by the look after the write that made no
    // progress, and no write came after it.
    const fired = stalled.fired();
    try testing.expectEqual(@as(u32, 0), fired[0].entry);
    try testing.expectEqual(@as(u32, 2), fired[1].entry);
    try testing.expect(fired[0].step < fired[1].step);
    try testing.expectEqual(@as(u64, 1), stalled.count(.file_write_streaming));
}

test "InputWriter isOpen observes acceptance even with a full backlog" {
    var child = try spawn("end");
    defer reap(&child);
    var gate: WriteGate = undefined;
    try gate.init();
    defer gate.deinit();
    const gated_io = gate.gated();
    var writer = try child.inputWriter(gpa, gated_io, .{ .max_backlog = 4 });
    defer writer.deinit(gated_io);
    try testing.expect(writer.isOpen(gated_io));
    try writer.queue(gated_io, "held");
    try gate.entered();
    try testing.expect(writer.isOpen(gated_io));
    try testing.expectError(error.BacklogFull, writer.queue(gated_io, "x"));
    try writer.close(gated_io);
    try testing.expect(!writer.isOpen(gated_io));
    gate.release();
    try writer.wait(gated_io);
    try testing.expect(!writer.isOpen(gated_io));
    try output(&child, "heldEOF");
}

test "InputWriter isOpen observes cancellation and retained failures" {
    var child = try spawn("end");
    defer reap(&child);
    var writer = try child.inputWriter(gpa, io, .{ .max_backlog = 0 });
    defer writer.deinit(io);
    try testing.expect(writer.isOpen(io));
    writer.cancel(io);
    try testing.expect(!writer.isOpen(io));
    try testing.expectError(error.Canceled, writer.queue(io, ""));
}
