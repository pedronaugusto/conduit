const builtin = @import("builtin");
const std = @import("std");
const tty = @import("conduit.tty");
const posix = std.posix;

const is_windows = builtin.target.os.tag == .windows;

test "both ends of a channel carry bytes both ways" {
    const io = std.testing.io;
    var channel = try tty.Channel.open();
    defer channel.parent.deinit(io);
    defer channel.child.deinit(io);

    try channel.parent.borrow().writeStreamingAll(io, "to the child");
    var buffer: [64]u8 = undefined;
    var got: usize = 0;
    while (got < "to the child".len) got += try channel.child.borrow().readStreaming(io, &.{buffer[got..]});
    try std.testing.expectEqualStrings("to the child", buffer[0..got]);

    try channel.child.borrow().writeStreamingAll(io, "and back");
    got = 0;
    while (got < "and back".len) got += try channel.parent.borrow().readStreaming(io, &.{buffer[got..]});
    try std.testing.expectEqualStrings("and back", buffer[0..got]);
}

test "the parent's end sees the end once the child's is closed" {
    const io = std.testing.io;
    var channel = try tty.Channel.open();
    defer channel.parent.deinit(io);
    channel.child.deinit(io);
    var buffer: [8]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, channel.parent.borrow().readStreaming(io, &.{&buffer}));
}

test "an end reads and writes both ways, and its reader ends once the other side has closed" {
    const io = std.testing.io;
    const channel = try tty.Channel.open();
    var parent: tty.Channel.End = .of(channel.parent);
    defer parent.deinit(io);
    var child: tty.Channel.End = .of(channel.child);

    var out_buffer: [16]u8 = undefined;
    var to_child = parent.writer(io, &out_buffer);
    try to_child.ends().writer().writeAll("to the child");
    try to_child.ends().writer().flush();
    var in_buffer: [64]u8 = undefined;
    var from_parent = child.reader(io, &in_buffer);
    try std.testing.expectEqualStrings("to the child", try from_parent.ends().reader().take("to the child".len));

    var back_buffer: [16]u8 = undefined;
    var to_parent = child.writer(io, &back_buffer);
    try to_parent.ends().writer().writeAll("and back");
    try to_parent.ends().writer().flush();
    child.deinit(io);
    var from_child = parent.reader(io, &in_buffer);
    const reader = from_child.ends().reader();
    try std.testing.expectEqualStrings("and back", try reader.take("and back".len));
    // What was sent, then the end: the reader's own, or a read the close
    // cut short with the cause `Closed`.
    if (reader.takeByte()) |_| return error.TestUnexpectedByte else |err| switch (err) {
        error.EndOfStream => try std.testing.expectEqual(null, from_child.ends().failure()),
        error.ReadFailed => try std.testing.expectEqual(tty.Channel.End.Closed, from_child.ends().failure().?),
    }
}

test "a write to a channel whose other side closed with bytes unread fails with the cause Closed, however the system says it" {
    const io = std.testing.io;
    const channel = try tty.Channel.open();
    var parent: tty.Channel.End = .of(channel.parent);
    defer parent.deinit(io);
    var buffer: [4]u8 = undefined;
    var to_child = parent.writer(io, &buffer);
    const end = to_child.ends();
    // Bytes the other side never reads, then its close: on Linux the next
    // writes see ECONNRESET, elsewhere EPIPE or a broken pipe.
    try end.writer().writeAll("never read");
    try end.writer().flush();
    var child = channel.child;
    child.deinit(io);
    var closed = false;
    for (0..64) |_| {
        end.writer().writeAll("more") catch |err| switch (err) {
            error.WriteFailed => {
                try std.testing.expectEqual(tty.Channel.End.Closed, end.failure().?);
                try std.testing.expectEqual(error.WriteFailed, end.settle(err));
                closed = true;
                break;
            },
        };
        end.writer().flush() catch {
            try std.testing.expectEqual(tty.Channel.End.Closed, end.failure().?);
            closed = true;
            break;
        };
    }
    try std.testing.expect(closed);
}

test "a variable names a channel only by a number where one is open" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try std.testing.expectEqual(null, try tty.Channel.inherited(&environ, "CONDUIT_CHANNEL"));

    for ([_][]const u8{ "", "fd:3", "-1", "0x10", "three" }) |value| {
        try environ.put("CONDUIT_CHANNEL", value);
        try std.testing.expectError(error.NotAChannel, tty.Channel.inherited(&environ, "CONDUIT_CHANNEL"));
    }

    var channel = try tty.Channel.open();
    defer channel.parent.deinit(io);
    defer channel.child.deinit(io);
    var text: [tty.Channel.value_max]u8 = undefined;
    try environ.put("CONDUIT_CHANNEL", tty.Channel.valueOf(&text, channel.child.borrow().handle));
    // The child's own end, found again: `channel.child` closes it.
    var found = (try tty.Channel.inherited(&environ, "CONDUIT_CHANNEL")).?;
    try std.testing.expectEqual(channel.child.borrow().handle, found.borrow().handle);
    try std.testing.expectEqual(channel.child.borrow().flags.nonblocking, found.borrow().flags.nonblocking);
}

test "a descriptor that is no stream socket is no channel" {
    if (is_windows) return error.SkipZigTest;
    const ends = try tty.pipe(.{});
    defer for (ends) |fd| {
        _ = posix.system.close(fd);
    };
    var text: [tty.Channel.value_max]u8 = undefined;
    try std.testing.expectError(error.NotAChannel, tty.Channel.fromValue(tty.Channel.valueOf(&text, ends[0])));
}
