//! One clock-based deadline for every bounded wait in conduit, and for a
//! caller whose wait ends in a system call that counts whole milliseconds.
const std = @import("std");

pub const Deadline = struct {
    /// The moment the wait ends, on the awake clock.
    at: std.Io.Clock.Timestamp,

    /// A deadline that never comes: what `std.Io.Timeout.none` names.
    pub const never: Deadline = .{ .at = .{ .raw = .{ .nanoseconds = std.math.maxInt(i96) }, .clock = .awake } };

    /// `span` from now, on the awake clock. A span too long to add to the
    /// clock is `never`; a negative one has already passed.
    pub fn in(io: std.Io, span: std.Io.Duration) Deadline {
        const now = std.Io.Clock.Timestamp.now(io, .awake);
        return .{ .at = .{ .raw = .{ .nanoseconds = now.raw.nanoseconds +| span.nanoseconds }, .clock = .awake } };
    }

    /// The deadline a timeout names, read against the clock now; `null` for
    /// `.none`, which has none. A deadline on another clock is moved to the
    /// awake clock, so any two deadlines compare.
    pub fn fromTimeout(io: std.Io, timeout: std.Io.Timeout) ?Deadline {
        return switch (timeout) {
            .none => null,
            .duration => |span| .in(io, span.raw),
            .deadline => |at| .{ .at = at.toClock(io, .awake) },
        };
    }

    /// The deadline a timeout names; `never` for `.none`.
    pub fn of(io: std.Io, timeout: std.Io.Timeout) Deadline {
        return fromTimeout(io, timeout) orelse never;
    }

    /// Whichever of two deadlines comes first.
    pub fn min(a: Deadline, b: Deadline) Deadline {
        return if (b.at.raw.nanoseconds < a.at.raw.nanoseconds) b else a;
    }

    /// What is left of the wait; zero once it has passed.
    pub fn remaining(deadline: Deadline, io: std.Io) std.Io.Duration {
        const left = deadline.at.durationFromNow(io).raw;
        return if (left.nanoseconds <= 0) .zero else left;
    }

    /// What is left, in the whole milliseconds a system wait takes.
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

    /// This deadline as a `std.Io.Timeout`: `.none` for `never`, which no
    /// clock reaches.
    pub fn toTimeout(deadline: Deadline) std.Io.Timeout {
        return if (deadline.at.raw.nanoseconds == never.at.raw.nanoseconds) .none else .{ .deadline = deadline.at };
    }

    /// A timeout of `span` on the awake clock, the one conduit's own waits
    /// count on.
    pub fn within(span: std.Io.Duration) std.Io.Timeout {
        return .{ .duration = .{ .raw = span, .clock = .awake } };
    }
};
