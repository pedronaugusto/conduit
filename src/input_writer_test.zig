//! Input delivery and lifetime, through the public API and native pipes.
const std = @import("std");
const builtin = @import("builtin");
const conduit = @import("conduit.zig");
const InputWriter = conduit.InputWriter;
const Child = conduit.Child;
const Watchdog = @import("testing/support.zig").Watchdog;
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

fn reap(child: *Child) void {
    // ziglint-ignore: Z026 cleanup; release below asserts the child is reaped
    _ = child.killWait(io, 0) catch {};
    child.release(io) catch unreachable;
}

fn output(child: *Child, expected: []const u8) !void {
    var result = try child.output(gpa, io, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);
    try testing.expect(Child.succeeded(result.term()));
    try testing.expectEqualStrings(expected, result.stdout());
}

// Tests run serially. The copied vtable keeps the original userdata, so every
// other operation, including task creation and cancellation, uses the real Io.
const WriteGate = struct {
    var active: *WriteGate = undefined;
    file: std.Io.File,
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    block: bool = true,

    fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        if (operation == .file_write_streaming and operation.file_write_streaming.file.handle == active.file.handle) {
            active.entered.set(io);
            if (active.block) try active.release.wait(io);
        }
        return io.vtable.operate(userdata, operation);
    }

    fn backend(gate: *WriteGate, vtable: *std.Io.VTable) std.Io {
        active = gate;
        vtable.* = io.vtable.*;
        vtable.operate = operate;
        return .{ .userdata = io.userdata, .vtable = vtable };
    }
};

test "InputWriter delivers copied bytes in queue order" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try spawn("echo");
    defer reap(&child);
    var gate: WriteGate = .{ .file = child.stdinFile().? };
    var vtable: std.Io.VTable = undefined;
    const gated_io = gate.backend(&vtable);
    var writer = try child.inputWriter(gpa, gated_io, .{ .max_backlog = 1024 });
    defer writer.deinit(gated_io);
    try testing.expect(child.stdinFile() == null);
    var bytes = "first".*;
    try writer.queue(gated_io, &bytes);
    try gate.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(budget_ms), .clock = .awake } });
    @memset(&bytes, 'x');
    try writer.queue(gated_io, "second");
    try writer.queue(gated_io, "third");
    try writer.end(gated_io);
    gate.release.set(io);
    try output(&child, "firstsecondthird");
    try writer.wait(gated_io);
}

test "InputWriter bounds queued bytes together with bytes being written" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try spawn("echo");
    defer reap(&child);
    var gate: WriteGate = .{ .file = child.stdinFile().? };
    var vtable: std.Io.VTable = undefined;
    const gated_io = gate.backend(&vtable);
    var writer = try child.inputWriter(gpa, gated_io, .{ .max_backlog = 10 });
    defer writer.deinit(gated_io);
    try writer.queue(gated_io, "123456");
    try gate.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(budget_ms), .clock = .awake } });
    try writer.queue(gated_io, "7890");
    try testing.expectError(error.BacklogFull, writer.queue(gated_io, "x"));
    try writer.queue(gated_io, "");
    try writer.end(gated_io);
    gate.release.set(io);
    try output(&child, "1234567890");
    try writer.wait(gated_io);
}

test "InputWriter closes input after every byte queued before its end" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try spawn("end");
    defer reap(&child);
    var gate: WriteGate = .{ .file = child.stdinFile().? };
    var vtable: std.Io.VTable = undefined;
    const gated_io = gate.backend(&vtable);
    var writer = try child.inputWriter(gpa, gated_io, .{ .max_backlog = 10 });
    defer writer.deinit(gated_io);
    try writer.queue(gated_io, "before");
    try gate.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(budget_ms), .clock = .awake } });
    try writer.queue(gated_io, "end");
    try writer.end(gated_io);
    try writer.end(gated_io);
    try testing.expectError(error.InputClosed, writer.queue(gated_io, "after"));
    gate.release.set(io);
    try output(&child, "beforeendEOF");
    try writer.wait(gated_io);
}

test "InputWriter refuses a backlog without waiting for a child that stops reading" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try spawn("stall");
    defer reap(&child);
    var gate: WriteGate = .{ .file = child.stdinFile().?, .block = false };
    var vtable: std.Io.VTable = undefined;
    const observed_io = gate.backend(&vtable);
    const bytes = try gpa.alloc(u8, 2 * 1024 * 1024);
    defer gpa.free(bytes);
    @memset(bytes, 'x');
    var writer = try child.inputWriter(gpa, observed_io, .{ .max_backlog = bytes.len });
    defer writer.deinit(observed_io);
    try writer.queue(observed_io, bytes);
    try gate.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(budget_ms), .clock = .awake } });
    try testing.expectError(error.BacklogFull, writer.queue(observed_io, "x"));
    writer.cancel(observed_io);
    try testing.expectError(error.Canceled, writer.wait(observed_io));
    try testing.expectError(error.Canceled, writer.queue(observed_io, "x"));
}

test "InputWriter keeps a write failure for later writers and waiters" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var saved: std.posix.Sigaction = undefined;
    if (builtin.os.tag != .windows) std.posix.sigaction(.PIPE, &.{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.posix.sigemptyset(), .flags = 0 }, &saved);
    defer if (builtin.os.tag != .windows) std.posix.sigaction(.PIPE, &saved, null);
    var child = try spawn("exit");
    defer reap(&child);
    var writer = try child.inputWriter(gpa, io, .{ .max_backlog = 1024 });
    defer writer.deinit(io);
    try testing.expect((try child.waitTimeout(io, budget_ms)) != null);
    try writer.queue(io, "gone");
    try testing.expectError(error.BrokenPipe, writer.wait(io));
    try testing.expect(!writer.isOpen(io));
    try testing.expectError(error.BrokenPipe, writer.queue(io, "later"));
    try testing.expectError(error.BrokenPipe, writer.end(io));
    writer.cancel(io);
    try testing.expectError(error.BrokenPipe, writer.wait(io));
}

test "InputWriter cancellation closes an idle pipe and deinit joins an active write" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try spawn("end");
    defer reap(&child);
    var writer = try child.inputWriter(gpa, io, .{ .max_backlog = 10 });
    defer writer.deinit(io);
    writer.cancel(io);
    writer.cancel(io);
    try testing.expectError(error.Canceled, writer.wait(io));
    try testing.expectError(error.Canceled, writer.end(io));
    try output(&child, "EOF");

    var blocked = try spawn("end");
    defer reap(&blocked);
    var gate: WriteGate = .{ .file = blocked.stdinFile().? };
    var vtable: std.Io.VTable = undefined;
    const gated_io = gate.backend(&vtable);
    var active = try blocked.inputWriter(gpa, gated_io, .{ .max_backlog = 10 });
    defer active.deinit(gated_io);
    try active.queue(gated_io, "held");
    try gate.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(budget_ms), .clock = .awake } });
    active.deinit(gated_io);
    try output(&blocked, "EOF");
}

test "InputWriter cancellation of a waiter leaves delivery running" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
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
    try writer.end(io);
    try output(&child, "alive");
    try writer.wait(io);
}

test "InputWriter serializes concurrent producers without splitting their bytes" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
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
    try writer.end(io);
    var result = try child.output(gpa, io, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);
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
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try spawn("echo");
    defer reap(&child);
    // State, node, then payload: fail the payload, after a node was allocated.
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 2 });
    var writer = try child.inputWriter(failing.allocator(), io, .{ .max_backlog = 4 });
    defer writer.deinit(io);
    try testing.expectError(error.OutOfMemory, writer.queue(io, "lost"));
    failing.fail_index = std.math.maxInt(usize);
    try writer.queue(io, "kept");
    try writer.end(io);
    try output(&child, "kept");
    try writer.wait(io);
}

test "InputWriter failed startup leaves the pipe with the child" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try spawn("echo");
    defer reap(&child);
    const file = child.stdinFile().?;
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, child.inputWriter(failing.allocator(), io, .{ .max_backlog = 10 }));
    try testing.expectEqual(file.handle, child.stdinFile().?.handle);
    const Refuse = struct {
        fn start(_: ?*anyopaque, _: *std.Io.Group, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
            return error.ConcurrencyUnavailable;
        }
    };
    var vtable = io.vtable.*;
    vtable.groupConcurrent = Refuse.start;
    const refused_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try testing.expectError(error.ConcurrencyUnavailable, child.inputWriter(gpa, refused_io, .{ .max_backlog = 10 }));
    try testing.expectEqual(file.handle, child.stdinFile().?.handle);
    try file.writeStreamingAll(io, "still open");
    child.closeStdin(io);
    try output(&child, "still open");
    try testing.expectError(error.NoStdinPipe, child.inputWriter(gpa, io, .{ .max_backlog = 10 }));
}

test "InputWriter a zero bound accepts only empty input" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try spawn("end");
    defer reap(&child);
    var writer = try child.inputWriter(gpa, io, .{ .max_backlog = 0 });
    defer writer.deinit(io);
    try writer.queue(io, "");
    try testing.expectError(error.BacklogFull, writer.queue(io, "x"));
    try writer.end(io);
    try output(&child, "EOF");
    try writer.wait(io);
    writer.cancel(io);
    try writer.wait(io);
}

test "InputWriter checks cancellation when a write makes no progress" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const NoProgress = struct {
        var zero: std.atomic.Value(bool) = .init(false);

        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_write_streaming) {
                if (zero.swap(true, .acq_rel)) return .{ .file_write_streaming = error.InputOutput };
                return .{ .file_write_streaming = 0 };
            }
            return io.vtable.operate(userdata, operation);
        }

        fn checkCancel(userdata: ?*anyopaque) std.Io.Cancelable!void {
            if (zero.load(.acquire)) return error.Canceled;
            return io.vtable.checkCancel(userdata);
        }
    };
    NoProgress.zero.store(false, .release);
    var vtable = io.vtable.*;
    vtable.operate = NoProgress.operate;
    vtable.checkCancel = NoProgress.checkCancel;
    const stalled_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    var child = try spawn("echo");
    defer reap(&child);
    var writer = try child.inputWriter(gpa, stalled_io, .{ .max_backlog = 10 });
    defer writer.deinit(stalled_io);
    try writer.queue(stalled_io, "held");
    try testing.expectError(error.Canceled, writer.wait(io));
    try testing.expectError(error.Canceled, writer.queue(io, "later"));
}

test "InputWriter isOpen observes acceptance even with a full backlog" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try spawn("end");
    defer reap(&child);
    var gate: WriteGate = .{ .file = child.stdinFile().? };
    var vtable: std.Io.VTable = undefined;
    const gated_io = gate.backend(&vtable);
    var writer = try child.inputWriter(gpa, gated_io, .{ .max_backlog = 4 });
    defer writer.deinit(gated_io);
    try testing.expect(writer.isOpen(gated_io));
    try writer.queue(gated_io, "held");
    try gate.entered.waitTimeout(io, .{ .duration = .{ .raw = .fromMilliseconds(budget_ms), .clock = .awake } });
    try testing.expect(writer.isOpen(gated_io));
    try testing.expectError(error.BacklogFull, writer.queue(gated_io, "x"));
    try writer.end(gated_io);
    try testing.expect(!writer.isOpen(gated_io));
    gate.release.set(io);
    try writer.wait(gated_io);
    try testing.expect(!writer.isOpen(gated_io));
    try output(&child, "heldEOF");
}

test "InputWriter isOpen observes cancellation and retained failures" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try spawn("end");
    defer reap(&child);
    var writer = try child.inputWriter(gpa, io, .{ .max_backlog = 0 });
    defer writer.deinit(io);
    try testing.expect(writer.isOpen(io));
    writer.cancel(io);
    try testing.expect(!writer.isOpen(io));
    try testing.expectError(error.Canceled, writer.queue(io, ""));
}

test "InputWriter exposes no writable ownership slots" {
    try testing.expect(@typeInfo(InputWriter) == .@"enum");
}
