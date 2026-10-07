//! The three one-line things the rest of this package does to a handle.
//!
//! Each of them was written out in two or three files, which is two or three
//! places for one idea to drift. They are here instead, named once.

const builtin = @import("builtin");
const std = @import("std");
/// This file, so a signature can name its error sets as callers do.
const handles = @This();
const posix = std.posix;
const c = std.c;

const is_windows = builtin.target.os.tag == .windows;

/// A raw handle as a `std.Io.File`.
///
/// The file shares the handle rather than duplicating it: closing the file
/// closes the handle, and whoever owns the handle owns the file.
pub fn file(handle: std.Io.File.Handle) std.Io.File {
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

/// Marks a descriptor close-on-exec, so an unrelated child started while this
/// process holds it is not handed it. POSIX only.
///
/// Best effort: a descriptor that could not be marked is still a working
/// descriptor, and there is nothing a caller could usefully do about it.
///
/// Where the call that made the descriptor can carry the flag itself, it
/// should — `pipe2`, `O_CLOEXEC`, `F_DUPFD_CLOEXEC` — because the gap between
/// an open and a second call is a gap another thread can `fork` through. This
/// is for the descriptors whose opening call takes no such flag.
pub fn setCloseOnExec(fd: posix.fd_t) void {
    if (is_windows) @compileError("handles.setCloseOnExec is POSIX-only");
    setCloseOnExecPosix(fd);
}

fn setCloseOnExecPosix(fd: posix.fd_t) void {
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
}

/// Whether a read error means the stream has finished rather than failed.
///
/// A pipe whose every writer is gone reports the end of the stream. A
/// pseudo-terminal master whose child is gone reports the end on Darwin and an
/// I/O error on Linux, where reading a master that has been hung up is an
/// error rather than an empty read. They are the same fact, and every reader
/// in this package -- `Child.output`, `Expect`, `Proxy`, `Pty` -- treats them
/// as one.
pub fn finished(err: anyerror) bool {
    return err == error.EndOfStream or err == error.InputOutput;
}

pub const ReadStreamingError = std.Io.File.ReadStreamingError || error{
    /// No read can make progress because every destination slice is empty.
    EmptyBuffer,
};

/// A streaming read that follows Zig's distinction between a transient zero
/// and `error.EndOfStream`.
///
/// All readers in this package want progress or a named end. Retrying here
/// keeps one permitted zero from truncating output, ending an `Expect`, or
/// stopping a proxy. An all-empty destination is rejected separately so a
/// backend that correctly returns zero for it cannot make this loop spin.
pub fn readStreaming(
    io: std.Io,
    f: std.Io.File,
    buffers: []const []u8,
) handles.ReadStreamingError!usize {
    var has_room = false;
    for (buffers) |buffer| has_room = has_room or buffer.len != 0;
    if (!has_room) return error.EmptyBuffer;

    while (true) {
        const n = try f.readStreaming(io, buffers);
        if (n != 0) return n;
        try std.Io.checkCancel(io);
    }
}

pub const ReadAvailableError = std.Io.File.ReadStreamingError || error{
    /// No read can make progress because the destination is empty.
    EmptyBuffer,
};

/// Reads what a pipe holds now into `buffer`, without waiting for more: 0
/// once nothing is left to read at this moment, whether or not anything
/// still holds the pipe's other end, and at the end of the stream.
///
/// This is how the rest of what a child wrote is read once it has ended.
/// Its writes are all in the pipe by then, so reading until this returns 0
/// takes every one of them, and none of what comes after: a read that waits
/// for the end of the stream would wait for whatever the child started that
/// inherited the other end, an ssh ControlMaster or a credential daemon,
/// for as long as that runs. `f` is a pipe this process reads, as `Child`
/// hands out; on Windows one opened for synchronous reads, as `Child`'s are.
pub fn readAvailable(io: std.Io, f: std.Io.File, buffer: []u8) handles.ReadAvailableError!usize {
    if (buffer.len == 0) return error.EmptyBuffer;
    const ready = if (is_windows) windowsPipeAvailable(f) else posixReadable(f.handle);
    if (ready == 0) return 0;
    const n = f.readStreaming(io, &.{buffer[0..@min(buffer.len, ready)]}) catch |err| switch (err) {
        error.EndOfStream => return 0,
        else => |e| return e,
    };
    return n;
}

/// Bytes a read of `fd` returns now without waiting: `maxInt` when it is
/// readable, with bytes or at its end, and 0 when a read would wait.
fn posixReadable(fd: posix.fd_t) usize {
    var fds = [1]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    // A failed poll reads nothing rather than risk a read that waits.
    const ready = posix.poll(&fds, 0) catch return 0;
    if (ready == 0) return 0;
    return std.math.maxInt(usize);
}

/// How many bytes the Windows pipe `f` holds, or `maxInt` when its writers
/// are gone, which a read then reports as the end.
fn windowsPipeAvailable(f: std.Io.File) usize {
    if (!is_windows) unreachable;
    // A query on an asynchronous handle can pend and retain the stack's
    // status block. Only the synchronous handles conduit creates are asked.
    if (f.flags.nonblocking) return 0;
    const windows = std.os.windows;
    var status: windows.IO_STATUS_BLOCK = undefined;
    var info: windows.FILE.PIPE.LOCAL_INFORMATION = undefined;
    return switch (windows.ntdll.NtQueryInformationFile(
        f.handle,
        &status,
        &info,
        @sizeOf(@TypeOf(info)),
        .PipeLocal,
    )) {
        .SUCCESS => if (info.ReadDataAvailable != 0)
            info.ReadDataAvailable
        else if (info.NamedPipeState == .CLOSING or info.NamedPipeState == .DISCONNECTED)
            std.math.maxInt(usize)
        else
            0,
        .PIPE_CLOSING, .PIPE_BROKEN, .PIPE_DISCONNECTED => std.math.maxInt(usize),
        else => 0,
    };
}

/// Writes the whole slice, retaining short writes and checking cancellation
/// when a backend reports zero progress. File.writeStreamingAll retries that
/// zero without a cancellation point, so a task could otherwise spin past a
/// request to stop. The same rule belongs to every writer in this package.
pub fn writeStreamingAll(io: std.Io, f: std.Io.File, bytes: []const u8) std.Io.File.Writer.Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = try f.writeStreaming(io, &.{}, &.{bytes[offset..]}, 1);
        if (n == 0) try std.Io.checkCancel(io);
        offset += n;
    }
}

/// Tests only: the fault plans of the tests below.
const shakedown = @import("shakedown");

test "readStreaming retries a permitted zero-byte result" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var written = try tmp.dir.createFile(io, "bytes", .{});
    try written.writeStreamingAll(io, "after zero");
    written.close(io);
    var f = try tmp.dir.openFile(io, "bytes", .{});
    defer f.close(io);

    // The first read makes no progress, without reading.
    const zero = try shakedown.FaultIo.init(std.testing.allocator, io, .{ .plan = &.{.{
        .at = .{ .nth = .{ .call = .file_read_streaming, .n = 1 } },
        .fault = .{ .short = 0 },
    }} });
    defer zero.deinit();

    var buffer: [32]u8 = undefined;
    const n = try readStreaming(zero.io(), f, &.{&buffer});
    try std.testing.expectEqual(@as(usize, 1), zero.fired().len);
    try std.testing.expectEqualStrings("after zero", buffer[0..n]);
}

test "writeStreamingAll retains short writes after zero progress" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try tmp.dir.createFile(io, "bytes", .{ .read = true });
    defer f.close(io);
    // No progress, then two bytes a write.
    const short = try shakedown.FaultIo.init(std.testing.allocator, io, .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .file_write_streaming, .n = 1 } }, .fault = .{ .short = 0 } },
        .{ .at = .{ .nth = .{ .call = .file_write_streaming, .n = 2 } }, .fault = .{ .short = 2 }, .times = 0 },
    } });
    defer short.deinit();
    try writeStreamingAll(short.io(), f, "abcdef");
    try std.testing.expectEqual(@as(u64, 4), short.count(.file_write_streaming));
    var bytes: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 6), try f.readPositionalAll(io, &bytes, 0));
    try std.testing.expectEqualStrings("abcdef", &bytes);
}
