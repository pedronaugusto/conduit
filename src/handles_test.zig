const std = @import("std");
const reap = @import("testing/support.zig").reap;
const Deadline = @import("conduit.tty").Deadline;
const builtin = @import("builtin");
const is_windows = builtin.target.os.tag == .windows;
const held = @import("conduit.tty").held;
const writeStreamingAll = @import("handles.zig").writeStreamingAll;
const pipe = @import("conduit.tty").pipe;
const Child = @import("child.zig").Child;
const test_options = @import("conduit_test_options");
const FaultIo = @import("shakedown").FaultIo;
test "Windows a closed pipe is a broken write and a file keeps its unexpected error" {
    if (!is_windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var child = try Child.spawn(testing.allocator, io, .{
        .argv = &.{ test_options.input_fixture, "exit" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer {
        reap(&child, io);
        child.deinit(io);
    }
    try testing.expect((try child.waitTimeout(io, Deadline.within(.fromMilliseconds(5000)))) != null);
    try testing.expectError(error.BrokenPipe, writeStreamingAll(io, child.stdinFile().?.get(), "closed"));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "file", .{});
    defer f.close(io);
    const failed = try FaultIo.init(testing.allocator, io, .{ .plan = &.{.{
        .at = .{ .nth = .{ .call = .file_write_streaming, .n = 1 } },
        .fault = .{ .fail = error.Unexpected },
    }} });
    defer failed.deinit();
    try testing.expectError(error.Unexpected, writeStreamingAll(failed.io(), f, "unchanged"));
}

test "readAvailable reads what a pipe holds and returns rather than wait for the rest" {
    const testing = std.testing;
    const io = testing.io;
    const readAvailable = @import("handles.zig").readAvailable;
    var ends: [2]held.OwnedFile = if (is_windows) ends: {
        const win32 = @import("win32");
        var read_end: std.os.windows.HANDLE = undefined;
        var write_end: std.os.windows.HANDLE = undefined;
        if (win32.CreatePipe(&read_end, &write_end, null, 0) == .FALSE) return error.PipeFailed;
        break :ends .{ held.own(read_end), held.own(write_end) };
    } else ends: {
        const fds = try pipe(.{});
        break :ends .{ held.own(fds[0]), held.own(fds[1]) };
    };
    defer ends[0].deinit(io);
    var writer_open = true;
    defer if (writer_open) ends[1].deinit(io);

    var buffer: [64]u8 = undefined;
    // Empty, with its writer open: nothing, at once.
    try testing.expectEqual(@as(usize, 0), try readAvailable(io, ends[0].borrow().*, &buffer));
    // What was written, and then nothing, while the writer is still open,
    // as when something a child started still holds it.
    try writeStreamingAll(io, ends[1].borrow().*, "said before ending\n");
    var got: usize = 0;
    while (true) {
        const n = try readAvailable(io, ends[0].borrow().*, buffer[got..]);
        if (n == 0) break;
        got += n;
    }
    try testing.expectEqualStrings("said before ending\n", buffer[0..got]);
    // The rest after the writer is gone, then the end, as nothing.
    try writeStreamingAll(io, ends[1].borrow().*, "last");
    ends[1].deinit(io);
    writer_open = false;
    got = 0;
    while (true) {
        const n = try readAvailable(io, ends[0].borrow().*, buffer[got..]);
        if (n == 0) break;
        got += n;
    }
    try testing.expectEqualStrings("last", buffer[0..got]);
    try testing.expectEqual(@as(usize, 0), try readAvailable(io, ends[0].borrow().*, &buffer));
    try testing.expectError(error.EmptyBuffer, readAvailable(io, ends[0].borrow().*, buffer[0..0]));
}
