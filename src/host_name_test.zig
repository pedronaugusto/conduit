const std = @import("std");
const builtin = @import("builtin");
const host_name = @import("host_name.zig");

test "the host name is the system's, a name and nothing after it" {
    var buf: [host_name.max_len]u8 = undefined;
    const name = try host_name.hostName(&buf);
    // A system may have no name: FreeBSD's is empty until one is set, where
    // Linux's default is "(none)". Windows always names the machine.
    if (comptime builtin.target.os.tag == .windows) try std.testing.expect(name.len > 0);
    try std.testing.expect(std.mem.findScalar(u8, name, 0) == null);
    if (comptime builtin.target.os.tag != .windows) {
        var expected: [std.posix.HOST_NAME_MAX]u8 = undefined;
        try std.testing.expectEqualStrings(try std.posix.gethostname(&expected), name);
    }
}
