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
        const left = deadline.at.durationFromNow(io).raw.nanoseconds;
        if (left <= 0) return 0;
        // Kernel waits take whole milliseconds. A positive fraction still
        // belongs to the budget; rounding it down would declare expiry early.
        const milliseconds = @divTrunc(left - 1, std.time.ns_per_ms) + 1;
        return std.math.lossyCast(u32, milliseconds);
    }
};

test "a deadline retains its last fraction of a millisecond until it expires" {
    const Clock = struct {
        var nanoseconds: i96 = 0;

        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            return .{ .nanoseconds = nanoseconds };
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    const io: std.Io = .{ .vtable = &vtable, .userdata = std.testing.io.userdata };
    Clock.nanoseconds = 0;
    const deadline: Deadline = .in(io, 1);
    Clock.nanoseconds = std.time.ns_per_ms - 1;
    try std.testing.expectEqual(@as(u32, 1), deadline.remainingMs(io));
    Clock.nanoseconds = std.time.ns_per_ms;
    try std.testing.expectEqual(@as(u32, 0), deadline.remainingMs(io));
}

test "a deadline reads the clock and expires" {
    const Clock = struct {
        var milliseconds: u32 = 100;
        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            return .{ .nanoseconds = @as(i96, milliseconds) * std.time.ns_per_ms };
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    const io: std.Io = .{ .vtable = &vtable, .userdata = std.testing.io.userdata };
    Clock.milliseconds = 100;
    const deadline: Deadline = .in(io, 10);
    try std.testing.expectEqual(@as(u32, 10), deadline.remainingMs(io));
    Clock.milliseconds = 111;
    try std.testing.expectEqual(@as(u32, 0), deadline.remainingMs(io));
}
