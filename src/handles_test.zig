const std = @import("std");
const Deadline = @import("conduit.tty").Deadline;
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const is_windows = builtin.target.os.tag == .windows;
const file = @import("handles.zig").file;
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
        _ = child.killWait(io, .zero) catch {};
        child.deinit(io);
    }
    try testing.expect((try child.waitTimeout(io, Deadline.within(.fromMilliseconds(5000)))) != null);
    try testing.expectError(error.BrokenPipe, writeStreamingAll(io, child.stdinFile().?, "closed"));

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
    const ends: [2]std.Io.File = if (is_windows) ends: {
        const win32 = @import("win32.zig");
        var read_end: std.os.windows.HANDLE = undefined;
        var write_end: std.os.windows.HANDLE = undefined;
        if (win32.CreatePipe(&read_end, &write_end, null, 0) == .FALSE) return error.PipeFailed;
        break :ends .{ file(read_end), file(write_end) };
    } else ends: {
        const fds = try pipe(.{});
        break :ends .{ file(fds[0]), file(fds[1]) };
    };
    defer ends[0].close(io);
    var writer_open = true;
    defer if (writer_open) ends[1].close(io);

    var buffer: [64]u8 = undefined;
    // Empty, with its writer open: nothing, at once.
    try testing.expectEqual(@as(usize, 0), try readAvailable(io, ends[0], &buffer));
    // What was written, and then nothing, while the writer is still open,
    // as when something a child started still holds it.
    try writeStreamingAll(io, ends[1], "said before ending\n");
    var got: usize = 0;
    while (true) {
        const n = try readAvailable(io, ends[0], buffer[got..]);
        if (n == 0) break;
        got += n;
    }
    try testing.expectEqualStrings("said before ending\n", buffer[0..got]);
    // The rest after the writer is gone, then the end, as nothing.
    try writeStreamingAll(io, ends[1], "last");
    ends[1].close(io);
    writer_open = false;
    got = 0;
    while (true) {
        const n = try readAvailable(io, ends[0], buffer[got..]);
        if (n == 0) break;
        got += n;
    }
    try testing.expectEqualStrings("last", buffer[0..got]);
    try testing.expectEqual(@as(usize, 0), try readAvailable(io, ends[0], &buffer));
    try testing.expectError(error.EmptyBuffer, readAvailable(io, ends[0], buffer[0..0]));
}
