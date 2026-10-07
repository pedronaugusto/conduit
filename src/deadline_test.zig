const std = @import("std");
const Deadline = @import("conduit.tty").Deadline;
const Clock = @import("shakedown").Clock;

test "a deadline retains its last fraction of a millisecond until it expires" {
    var clock: Clock = .init(std.testing.io, .{});
    const io = clock.io();
    const deadline: Deadline = .in(io, .fromMilliseconds(1));
    clock.advance(.fromNanoseconds(std.time.ns_per_ms - 1));
    try std.testing.expectEqual(@as(u32, 1), deadline.remainingMs(io));
    clock.advance(.fromNanoseconds(1));
    try std.testing.expectEqual(@as(u32, 0), deadline.remainingMs(io));
}

test "a deadline reads the clock and expires" {
    var clock: Clock = .init(std.testing.io, .{});
    const io = clock.io();
    const deadline: Deadline = .in(io, .fromMilliseconds(10));
    try std.testing.expectEqual(@as(u32, 10), deadline.remainingMs(io));
    clock.advance(.fromMilliseconds(11));
    try std.testing.expectEqual(@as(u32, 0), deadline.remainingMs(io));
}

test "a timeout's deadline rounds its last fraction up, as a duration or an instant" {
    var clock: Clock = .init(std.testing.io, .{});
    const io = clock.io();
    try std.testing.expectEqual(@as(?Deadline, null), Deadline.fromTimeout(io, .none));

    const half: std.Io.Clock.Duration = .{ .raw = .fromNanoseconds(std.time.ns_per_ms / 2), .clock = .awake };
    const from_duration = Deadline.fromTimeout(io, .{ .duration = half }).?;
    try std.testing.expectEqual(@as(u32, 1), from_duration.remainingMs(io));

    const later = clock.read(.awake).addDuration(.fromNanoseconds(3 * std.time.ns_per_ms / 2));
    const from_instant = Deadline.fromTimeout(io, .{ .deadline = .{ .raw = later, .clock = .awake } }).?;
    try std.testing.expectEqual(@as(u32, 2), from_instant.remainingMs(io));
    try std.testing.expectEqual(@as(u32, 2), from_instant.windowsMs(io));

    clock.advance(.fromNanoseconds(3 * std.time.ns_per_ms / 2));
    try std.testing.expectEqual(@as(u32, 0), from_instant.windowsMs(io));
}

test "a Windows wait never asks for INFINITE" {
    var clock: Clock = .init(std.testing.io, .{});
    const io = clock.io();
    const longest: Deadline = .in(io, .fromMilliseconds(std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), longest.remainingMs(io));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32) - 1), longest.windowsMs(io));
}

test "no timeout is a deadline that never comes, and the earlier of two wins" {
    var clock: Clock = .init(std.testing.io, .{});
    const io = clock.io();
    try std.testing.expectEqual(Deadline.never, Deadline.of(io, .none));
    try std.testing.expectEqual(std.Io.Timeout.none, Deadline.never.toTimeout());
    try std.testing.expectEqual(Deadline.never, Deadline.in(io, .max));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32) - 1), Deadline.never.windowsMs(io));
    try std.testing.expectEqual(@as(u32, 0), Deadline.of(io, Deadline.within(.zero)).remainingMs(io));
    const second = Deadline.of(io, Deadline.within(.fromSeconds(1)));
    try std.testing.expectEqual(@as(u32, 1000), second.remainingMs(io));
    try std.testing.expectEqual(std.Io.Duration.fromSeconds(1), second.remaining(io));
    const soon: Deadline = .in(io, .fromMilliseconds(10));
    try std.testing.expectEqual(soon, Deadline.never.min(soon));
    try std.testing.expectEqual(soon, soon.min(second));
    clock.advance(.fromSeconds(2));
    try std.testing.expectEqual(std.Io.Duration.zero, second.remaining(io));
}
