const std = @import("std");
const Deadline = @import("conduit.tty").Deadline;

/// A clock the test sets, in nanoseconds.
const Clock = struct {
    var nanoseconds: i96 = 0;

    fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
        return .{ .nanoseconds = nanoseconds };
    }

    fn io(vtable: *std.Io.VTable) std.Io {
        vtable.* = std.testing.io.vtable.*;
        vtable.now = now;
        return .{ .vtable = vtable, .userdata = std.testing.io.userdata };
    }
};

test "a deadline retains its last fraction of a millisecond until it expires" {
    var vtable: std.Io.VTable = undefined;
    const io = Clock.io(&vtable);
    Clock.nanoseconds = 0;
    const deadline: Deadline = .in(io, 1);
    Clock.nanoseconds = std.time.ns_per_ms - 1;
    try std.testing.expectEqual(@as(u32, 1), deadline.remainingMs(io));
    Clock.nanoseconds = std.time.ns_per_ms;
    try std.testing.expectEqual(@as(u32, 0), deadline.remainingMs(io));
}

test "a deadline reads the clock and expires" {
    var vtable: std.Io.VTable = undefined;
    const io = Clock.io(&vtable);
    Clock.nanoseconds = 100 * std.time.ns_per_ms;
    const deadline: Deadline = .in(io, 10);
    try std.testing.expectEqual(@as(u32, 10), deadline.remainingMs(io));
    Clock.nanoseconds = 111 * std.time.ns_per_ms;
    try std.testing.expectEqual(@as(u32, 0), deadline.remainingMs(io));
}

test "a timeout's deadline rounds its last fraction up, as a duration or an instant" {
    var vtable: std.Io.VTable = undefined;
    const io = Clock.io(&vtable);
    Clock.nanoseconds = 0;
    try std.testing.expectEqual(@as(?Deadline, null), Deadline.fromTimeout(io, .none));

    const half: std.Io.Clock.Duration = .{ .raw = .fromNanoseconds(std.time.ns_per_ms / 2), .clock = .awake };
    const from_duration = Deadline.fromTimeout(io, .{ .duration = half }).?;
    try std.testing.expectEqual(@as(u32, 1), from_duration.remainingMs(io));

    const at: std.Io.Clock.Timestamp = .{ .raw = .{ .nanoseconds = 3 * std.time.ns_per_ms / 2 }, .clock = .awake };
    const from_instant = Deadline.fromTimeout(io, .{ .deadline = at }).?;
    try std.testing.expectEqual(@as(u32, 2), from_instant.remainingMs(io));
    try std.testing.expectEqual(@as(u32, 2), from_instant.windowsMs(io));

    Clock.nanoseconds = 3 * std.time.ns_per_ms / 2;
    try std.testing.expectEqual(@as(u32, 0), from_instant.windowsMs(io));
}

test "a Windows wait never asks for INFINITE" {
    var vtable: std.Io.VTable = undefined;
    const io = Clock.io(&vtable);
    Clock.nanoseconds = 0;
    const longest: Deadline = .in(io, std.math.maxInt(u32));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), longest.remainingMs(io));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32) - 1), longest.windowsMs(io));
}
