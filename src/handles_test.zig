const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const is_windows = builtin.os.tag == .windows;
const State = @import("child_state.zig");
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
    var watchdog: @import("test_support.zig").Watchdog = .init(@src());
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
