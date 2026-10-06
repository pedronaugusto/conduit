const std = @import("std");
const conduit = @import("conduit");
const tty = @import("conduit.tty");

pub fn main() !void {
    std.debug.assert(conduit.succeeded(.{ .exited = 0 }));
    _ = tty;
    _ = &conduit.Child.spawn;
}
