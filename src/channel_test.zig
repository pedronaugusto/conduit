const builtin = @import("builtin");
const std = @import("std");
const tty = @import("conduit.tty");
const posix = std.posix;

const is_windows = builtin.target.os.tag == .windows;

test "both ends of a channel carry bytes both ways" {
    const io = std.testing.io;
    const channel = try tty.Channel.open();
    defer channel.parent.close(io);
    defer channel.child.close(io);

    try channel.parent.writeStreamingAll(io, "to the child");
    var buffer: [64]u8 = undefined;
    var got: usize = 0;
    while (got < "to the child".len) got += try channel.child.readStreaming(io, &.{buffer[got..]});
    try std.testing.expectEqualStrings("to the child", buffer[0..got]);

    try channel.child.writeStreamingAll(io, "and back");
    got = 0;
    while (got < "and back".len) got += try channel.parent.readStreaming(io, &.{buffer[got..]});
    try std.testing.expectEqualStrings("and back", buffer[0..got]);
}

test "the parent's end sees the end once the child's is closed" {
    const io = std.testing.io;
    const channel = try tty.Channel.open();
    defer channel.parent.close(io);
    channel.child.close(io);
    var buffer: [8]u8 = undefined;
    try std.testing.expectError(error.EndOfStream, channel.parent.readStreaming(io, &.{&buffer}));
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

    const channel = try tty.Channel.open();
    defer channel.parent.close(io);
    defer channel.child.close(io);
    var text: [tty.Channel.value_max]u8 = undefined;
    try environ.put("CONDUIT_CHANNEL", tty.Channel.valueOf(&text, channel.child.handle));
    const found = (try tty.Channel.inherited(&environ, "CONDUIT_CHANNEL")).?;
    try std.testing.expectEqual(channel.child.handle, found.handle);
    try std.testing.expectEqual(channel.child.flags.nonblocking, found.flags.nonblocking);
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
