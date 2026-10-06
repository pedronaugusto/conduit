//! One clock-based deadline for every bounded wait in conduit, and for a
//! caller whose wait ends in a system call that counts whole milliseconds.
const std = @import("std");

pub const Deadline = struct {
    at: std.Io.Clock.Timestamp,

    pub fn in(io: std.Io, milliseconds: u32) Deadline {
        return .{ .at = .fromNow(io, .{
            .raw = .fromMilliseconds(milliseconds),
            .clock = .awake,
        }) };
    }

    /// The deadline a timeout names, read against the clock now; `null` for
    /// `.none`, which has none.
    pub fn fromTimeout(io: std.Io, timeout: std.Io.Timeout) ?Deadline {
        return .{ .at = timeout.toTimestamp(io) orelse return null };
    }

    pub fn remainingMs(deadline: Deadline, io: std.Io) u32 {
        const left = deadline.at.durationFromNow(io).raw.nanoseconds;
        if (left <= 0) return 0;
        // Kernel waits take whole milliseconds. A positive fraction still
        // belongs to the budget; rounding it down would declare expiry early.
        const milliseconds = @divTrunc(left - 1, std.time.ns_per_ms) + 1;
        return std.math.lossyCast(u32, milliseconds);
    }

    /// `remainingMs` for a Windows wait, where the largest count is
    /// `INFINITE` and would never end: one short of it at most.
    pub fn windowsMs(deadline: Deadline, io: std.Io) u32 {
        return @min(deadline.remainingMs(io), std.math.maxInt(u32) - 1);
    }
};
