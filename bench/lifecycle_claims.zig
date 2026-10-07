//! The lifecycle claims: ratios and bounds the package promises, each row
//! a measurement, its limit and whether it passed. Speed claims belong on a
//! quiet machine, outside the unit suite.
const std = @import("std");
const builtin = @import("builtin");
const conduit = @import("conduit");
var smoke = false;
/// How long one wait here may take before the run is wrong.
const budget: std.Io.Timeout = conduit.Deadline.within(.fromSeconds(5));

pub fn main(init: std.process.Init) !void {
    if (builtin.target.os.tag == .windows) return error.PosixHarness;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    smoke = args.len == 2 and std.mem.eql(u8, args[1], "--smoke");
    if (args.len != 1 and !smoke and (args.len != 2 or !std.mem.eql(u8, args[1], "--quiet-machine"))) {
        var buffer: [128]u8 = undefined;
        var err = std.Io.File.stderr().writerStreaming(init.io, &buffer);
        try err.interface.writeAll("lifecycle-claims --quiet-machine (exclusive idle machine only)\n");
        try err.interface.flush();
        return error.QuietMachineRequired;
    }
    try waitRatio(init);
    try spawnRatio(init);
    try stopClaims(init, false);
    try stopClaims(init, true);
    try reaperJoin(init);
    try readerJoin(init);
}

fn now(io: std.Io) std.Io.Timestamp {
    if (smoke) return .{ .nanoseconds = 1 };
    return .now(io, .awake);
}

fn us(start: std.Io.Timestamp, io: std.Io) i64 {
    return start.durationTo(now(io)).toMicroseconds();
}

fn report(init: std.process.Init, claim: []const u8, actual: i64, limit: i64) !void {
    var buffer: [256]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try out.interface.print("{s}\t{d}\t{d}\t{s}\n", .{ claim, actual, limit, if (actual <= limit) "pass" else "over" });
    try out.interface.flush();
}

fn oneWait(init: std.process.Init, deadlined: bool) !i64 {
    const start = now(init.io);
    var child = try conduit.Child.spawn(init.gpa, init.io, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdio = .ignore,
    });
    defer child.deinit(init.io);
    errdefer _ = child.killWait(init.io, .zero) catch {};
    const term = if (deadlined)
        (try child.waitTimeout(init.io, budget)) orelse return error.ChildDidNotExit
    else
        try child.wait(init.io);
    if (!conduit.succeeded(term)) return error.ChildFailed;
    return us(start, init.io);
}

fn waitRatio(init: std.process.Init) !void {
    const rounds: usize = if (smoke) 1 else 6;
    const per_round: usize = if (smoke) 1 else 8;
    var blocking: i64 = std.math.maxInt(i64);
    var deadlined: i64 = std.math.maxInt(i64);
    if (!smoke) {
        _ = try oneWait(init, false);
        _ = try oneWait(init, true);
    }
    for (0..rounds) |round| {
        var a: i64 = 0;
        var b: i64 = 0;
        for (0..per_round) |_| {
            if (round % 2 == 0) {
                a += try oneWait(init, false);
                b += try oneWait(init, true);
            } else {
                b += try oneWait(init, true);
                a += try oneWait(init, false);
            }
        }
        blocking = @min(blocking, a);
        deadlined = @min(deadlined, b);
    }
    try report(init, "deadline/blocking, millionths (limit 3:2)", @divTrunc(deadlined * 1_000_000, @max(blocking, 1)), 1_500_000);
}

fn oneSpawn(init: std.process.Init, cwd: ?[]const u8) !i64 {
    const start = now(init.io);
    var child = try conduit.Child.spawn(init.gpa, init.io, .{
        .argv = &.{"/usr/bin/true"},
        .cwd = cwd,
        .stdio = .ignore,
    });
    defer child.deinit(init.io);
    errdefer _ = child.killWait(init.io, .zero) catch {};
    // A cgroup adds a join to the forked side, or forks both where the C
    // library cannot start a child in one: either way the two would not
    // differ by the fork alone. Refuse rather than label that a comparison.
    if (builtin.target.os.tag == .linux) {
        var buffer: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
        if ((try child.containment(&buffer)).cgroup != null) return error.CgroupForcesFork;
    }
    if (!conduit.succeeded(try child.wait(init.io))) return error.ChildFailed;
    return us(start, init.io);
}

fn spawnRatio(init: std.process.Init) !void {
    const rounds: usize = if (smoke) 1 else 200;
    if (!smoke) {
        _ = try oneSpawn(init, null);
        _ = try oneSpawn(init, "/");
    }
    for (0..if (smoke) @as(usize, 1) else 5) |_| {
        var fast: i64 = 0;
        var forked: i64 = 0;
        for (0..rounds) |_| {
            fast += try oneSpawn(init, null);
            forked += try oneSpawn(init, "/");
        }
        try report(init, "file-actions/fork, millionths (limit 9:10)", @divTrunc(fast * 1_000_000, @max(forked, 1)), 900_000);
    }
}

fn stopClaims(init: std.process.Init, stubborn: bool) !void {
    var child = try conduit.Child.spawn(init.gpa, init.io, .{
        .argv = &.{ "/bin/sh", "-c", if (stubborn) "trap '' TERM; echo ready; read x" else "echo ready; read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
        .detach = true,
    });
    defer child.deinit(init.io);
    defer _ = child.killWait(init.io, .zero) catch {};
    var buffer: [64]u8 = undefined;
    var reader = child.stdoutFile().?.reader(init.io, &buffer);
    if (!std.mem.eql(u8, (try reader.interface.takeDelimiter('\n')).?, "ready")) return error.NotReady;
    var reaper: conduit.Reaper = .init(&child, .{});
    try reaper.start(init.io);
    defer reaper.deinit(init.io);
    const grace: u32 = if (stubborn) 300 else 60_000;
    const start = now(init.io);
    reaper.kill(init.io, .fromMilliseconds(grace));
    const call_us = us(start, init.io);
    const term = (try reaper.waitTimeout(init.io, budget)) orelse return error.ChildDidNotExit;
    const total_us = us(start, init.io);
    if (term != .signal or term.signal != (if (stubborn) std.posix.SIG.KILL else std.posix.SIG.TERM)) return error.WrongSignal;
    if (stubborn) {
        try report(init, "stop call, us (before 300 ms grace)", call_us, 300_000 - 1);
        try report(init, "forced stop, us (300 ms grace + 2 s)", total_us, 2_300_000 - 1);
    } else try report(init, "honoured stop, us (before 5 s)", total_us, 5_000_000 - 1);
}

fn reaperJoin(init: std.process.Init) !void {
    var child = try conduit.Child.spawn(init.gpa, init.io, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.deinit(init.io);
    defer _ = child.killWait(init.io, .zero) catch {};
    var reaper: conduit.Reaper = .init(&child, .{ .end_tree = true });
    try reaper.start(init.io);
    defer reaper.deinit(init.io);
    try init.io.sleep(.fromMilliseconds(20), .awake);
    const start = now(init.io);
    try reaper.stop(init.io);
    try report(init, "Reaper join with live child, us (before 5 s)", us(start, init.io), 5_000_000 - 1);
}

fn readerJoin(init: std.process.Init) !void {
    var pty = try conduit.Pty.open(init.gpa, .{ .rows = 24, .cols = 80 });
    defer pty.close(init.io);
    var child = try conduit.Child.spawn(init.gpa, init.io, .{
        .argv = &.{ "/bin/sh", "-c", "echo ready; read x" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(init.io);
    defer _ = child.killWait(init.io, .zero) catch {};
    pty.closeSlave(init.io);
    var buffer: [1024]u8 = undefined;
    var expect: conduit.Expect = .init(child.terminalMaster().?, &buffer);
    try expect.start(init.io);
    defer expect.deinit(init.io);
    _ = try expect.until(init.io, "ready", budget);
    const start = now(init.io);
    expect.stop(init.io);
    try report(init, "Expect join with open terminal, us (before 5 s)", us(start, init.io), 5_000_000 - 1);
}
