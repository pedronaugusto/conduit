const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const is_windows = builtin.os.tag == .windows;
const State = @import("Child/state.zig");
const access = @import("handles.zig").test_access;
const file = @import("handles.zig").file;
const setCloseOnExec = @import("handles.zig").setCloseOnExec;
const setCloseOnExecPosix = access.setCloseOnExecPosix;
const finished = @import("handles.zig").finished;
const ReadStreamingError = @import("handles.zig").ReadStreamingError;
const readStreaming = @import("handles.zig").readStreaming;
const writeStreamingAll = @import("handles.zig").writeStreamingAll;
const windowsPipeClosed = access.windowsPipeClosed;
const opening_is_two_calls = @import("handles.zig").opening_is_two_calls;
const ForkGap = @import("handles.zig").ForkGap;
const PipeError = @import("handles.zig").PipeError;
const pipe = @import("handles.zig").pipe;
const pipePosix = access.pipePosix;
test "Windows a closed pipe is a broken write and a file keeps its unexpected error" {
    if (!is_windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var watchdog: @import("testing/support.zig").Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try @import("Child.zig").Child.spawn(io, testing.allocator, .{
        .argv = &.{ @import("conduit_test_options").input_fixture, "exit" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer {
        _ = child.killWait(io, 0) catch {};
        child.release(io) catch unreachable;
    }
    try testing.expect((try child.waitTimeout(io, 5000)) != null);
    try testing.expectError(error.BrokenPipe, writeStreamingAll(child.stdinFile().?, io, "closed"));

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "file", .{});
    defer f.close(io);
    const FailWrite = struct {
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            if (operation == .file_write_streaming) return .{ .file_write_streaming = error.Unexpected };
            return testing.io.vtable.operate(userdata, operation);
        }
    };
    var vtable = io.vtable.*;
    vtable.operate = FailWrite.operate;
    const failed_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try testing.expectError(error.Unexpected, writeStreamingAll(f, failed_io, "unchanged"));
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
        const fds = try pipe();
        break :ends .{ file(fds[0]), file(fds[1]) };
    };
    defer ends[0].close(io);
    var writer_open = true;
    defer if (writer_open) ends[1].close(io);

    var buffer: [64]u8 = undefined;
    // Empty, with its writer open: nothing, at once.
    try testing.expectEqual(@as(usize, 0), try readAvailable(ends[0], io, &buffer));
    // What was written, and then nothing, while the writer is still open,
    // as when something a child started still holds it.
    try writeStreamingAll(ends[1], io, "said before ending\n");
    var got: usize = 0;
    while (true) {
        const n = try readAvailable(ends[0], io, buffer[got..]);
        if (n == 0) break;
        got += n;
    }
    try testing.expectEqualStrings("said before ending\n", buffer[0..got]);
    // The rest after the writer is gone, then the end, as nothing.
    try writeStreamingAll(ends[1], io, "last");
    ends[1].close(io);
    writer_open = false;
    got = 0;
    while (true) {
        const n = try readAvailable(ends[0], io, buffer[got..]);
        if (n == 0) break;
        got += n;
    }
    try testing.expectEqualStrings("last", buffer[0..got]);
    try testing.expectEqual(@as(usize, 0), try readAvailable(ends[0], io, &buffer));
    try testing.expectError(error.EmptyBuffer, readAvailable(ends[0], io, buffer[0..0]));
}
