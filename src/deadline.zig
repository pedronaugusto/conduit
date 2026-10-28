//! One clock-based deadline for every bounded wait in conduit, and for a
//! caller whose wait ends in a system call that counts whole milliseconds.
const std = @import("std");
const aegis = @import("aegis");

/// A span conduit is given: a kill's grace, a drain's, a tree's. aegis's
/// duration in nanoseconds, never negative, read and written in its text form
/// (`200ms`, `1s`) and logged with `{f}`. A timeout stays std's `Io.Timeout`,
/// a span or a deadline, as std's own waits take it.
pub const Duration = aegis.units.Duration(.nanosecond, u64);

/// A moment on the awake clock, and a signed span between two: the clock's
/// own terms, as std's timestamps carry them.
const Awake = aegis.units.Instant(.awake, .nanosecond, i96);
const Span = aegis.units.Duration(.nanosecond, i96);

pub const Deadline = struct {
    /// The moment the wait ends, on the awake clock.
    at: std.Io.Clock.Timestamp,

    /// A deadline that never comes: what `std.Io.Timeout.none` names.
    pub const never: Deadline = .{ .at = .{ .raw = .{ .nanoseconds = std.math.maxInt(i96) }, .clock = .awake } };

    /// `span` from now, on the awake clock. A span too long to add to the
    /// clock is `never`; a negative one has already passed.
    pub fn in(io: std.Io, span: std.Io.Duration) Deadline {
        const now = Awake.fromTimestamp(std.Io.Clock.Timestamp.now(io, .awake).raw, .exact);
        return .{ .at = .{ .raw = now.saturatingAdd(Span.fromIoDuration(span, .exact)).toTimestamp(), .clock = .awake } };
    }

    /// `span` from now, on the awake clock.
    pub fn after(io: std.Io, span: Duration) Deadline {
        return .in(io, span.toIoDuration());
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

    /// Sleeps until the deadline by the awake clock. A system's sleep can end
    /// before it (Windows rounds a wait to its clock tick, which the awake
    /// clock does not), so it sleeps again while time is left.
    pub fn sleep(deadline: Deadline, io: std.Io) std.Io.Cancelable!void {
        while (true) {
            const left = deadline.remaining(io);
            if (left.nanoseconds == 0) return;
            try std.Io.sleep(io, left, .awake);
        }
    }

    /// What is left of the wait as a span conduit is given; zero once it has
    /// passed, and the longest span for a deadline past that.
    pub fn spanLeft(deadline: Deadline, io: std.Io) Duration {
        return Duration.fromIoDuration(deadline.remaining(io), .down) catch .fromRaw(std.math.maxInt(u64));
    }

    /// What is left, in the whole milliseconds a system wait takes.
    pub fn remainingMs(deadline: Deadline, io: std.Io) u32 {
        const left = Span.fromIoDuration(deadline.at.durationFromNow(io).raw, .exact);
        if (left.compare(.fromRaw(0)) != .gt) return 0;
        // Kernel waits take whole milliseconds. A positive fraction still
        // belongs to the budget; rounding it down would declare expiry early.
        // A wait too long for a count of u32 milliseconds is the longest one.
        const milliseconds = left.convert(.millisecond, u32, .up) catch return std.math.maxInt(u32);
        return milliseconds.raw();
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
