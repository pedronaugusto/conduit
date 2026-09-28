//! One clock-based deadline for every bounded wait in conduit.
const std = @import("std");

pub const Deadline = struct {
    at: std.Io.Clock.Timestamp,

    pub fn in(io: std.Io, milliseconds: u32) Deadline {
        return .{ .at = .fromNow(io, .{
            .raw = .fromMilliseconds(milliseconds),
            .clock = .awake,
        }) };
    }

    pub fn remainingMs(deadline: Deadline, io: std.Io) u32 {
        const left = deadline.at.durationFromNow(io).raw.toMilliseconds();
        if (left <= 0) return 0;
        return std.math.lossyCast(u32, left);
    }
};

test "a deadline reads the clock and expires" {
    const io = std.testing.io;
    const deadline: Deadline = .in(io, 10);
    try std.testing.expect(deadline.remainingMs(io) <= 10);
    try io.sleep(.fromMilliseconds(11), .awake);
    try std.testing.expectEqual(@as(u32, 0), deadline.remainingMs(io));
}
