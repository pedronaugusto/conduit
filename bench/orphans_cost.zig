//! Spawn+wait of /usr/bin/true with Orphans off and on, interleaved; and the
//! cost of one look (Orphans.count) with N live children. Linux only:
//! elsewhere it says so and ends.
const std = @import("std");
const conduit = @import("conduit");
var true_program: []const u8 = "true";
var sleep_program: []const u8 = "sleep";

fn spawnWait(io: std.Io, gpa: std.mem.Allocator, n: usize) !f64 {
    const start = benchmarkNow(io);
    for (0..n) |_| {
        var child = try conduit.Child.spawn(gpa, io, .{ .argv = &.{true_program}, .stdio = .ignore });
        defer child.deinit(io);
        _ = try child.wait(io);
    }
    const ns = start.durationTo(benchmarkNow(io)).nanoseconds;
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(n)) / 1000.0;
}

pub fn main(init: std.process.Init) !void {
    if (!conduit.Orphans.supported) {
        try say(init.io, "Orphans tracking unavailable: requires Linux\n", .{});
        return;
    }
    true_program = init.environ_map.get("BENCH_TRUE") orelse "true";
    sleep_program = init.environ_map.get("BENCH_SLEEP") orelse "sleep";
    const io = init.io;
    const gpa = std.heap.c_allocator;
    const smoke = @import("bench_options").smoke;
    const n = if (smoke) 1 else 2000;
    if (!smoke) _ = try spawnWait(io, gpa, 200);
    var best_off: f64 = 1e9;
    var best_on: f64 = 1e9;
    for (0..(if (smoke) @as(usize, 1) else 7)) |_| {
        best_off = @min(best_off, try spawnWait(io, gpa, n));
        var orphans: conduit.Orphans = .init(gpa);
        try orphans.start();
        best_on = @min(best_on, try spawnWait(io, gpa, n));
        try orphans.stop(io);
        orphans.deinit();
    }
    try say(io, "spawn+wait off {d:.1} us, on {d:.1} us\n", .{ best_off, best_on });

    // One look with 0, 10, 100 live children of conduit's own.
    const live_counts: []const usize = if (smoke) &.{ 0, 1 } else &.{ 0, 10, 100 };
    for (live_counts) |live| {
        var children: [100]conduit.Child = undefined;
        var orphans: conduit.Orphans = .init(gpa);
        try orphans.start();
        for (children[0..live]) |*ch| ch.* = try conduit.Child.spawn(gpa, io, .{ .argv = &.{ sleep_program, "100" }, .stdio = .ignore });
        var best: f64 = 1e9;
        for (0..(if (smoke) @as(usize, 1) else 7)) |_| {
            const start = benchmarkNow(io);
            for (0..(if (smoke) @as(usize, 1) else 200)) |_| _ = try orphans.count(io);
            const ns = start.durationTo(benchmarkNow(io)).nanoseconds;
            best = @min(best, @as(f64, @floatFromInt(ns)) / (if (smoke) @as(f64, 1) else 200) / 1000.0);
        }
        for (children[0..live]) |*ch| {
            _ = ch.killWait(io, .zero) catch {};
            ch.deinit(io);
        }
        try orphans.stop(io);
        orphans.deinit();
        try say(io, "look with {d} own children: {d:.1} us\n", .{ live, best });
    }
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
fn benchmarkNow(io: std.Io) std.Io.Timestamp {
    if (@import("bench_options").smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}

/// One line of the report, on standard output.
fn say(io: std.Io, comptime format: []const u8, args: anytype) !void {
    var buffer: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(io, &buffer);
    try out.interface.print(format, args);
    try out.interface.flush();
}
