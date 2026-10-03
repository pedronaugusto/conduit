//! A child that opens its own terminal and says whether poll can wait on it.
const std = @import("std");
const tty = @import("conduit.tty");

pub fn main(init: std.process.Init) !void {
    const out = std.Io.File.stdout();
    const own = tty.openControlling(init.io) catch {
        try out.writeStreamingAll(init.io, "terminal none.");
        return;
    };
    defer own.close(init.io);
    var fds = [_]std.posix.pollfd{.{ .fd = own.input.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&fds, 0);
    const said = if (fds[0].revents & std.posix.POLL.NVAL != 0) "terminal refused." else "terminal pollable.";
    try out.writeStreamingAll(init.io, said);
}
