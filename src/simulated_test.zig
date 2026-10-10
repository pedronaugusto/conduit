//! conduit inside a shakedown `Sim`, through `conduit.testing`: children
//! that are programs registered on the simulation, on pipes and on a
//! simulated terminal, signalled, waited for on its clock and reaped by a
//! `Reaper`, each run repeating from its seed.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const Io = std.Io;
const shakedown = @import("shakedown");
const seam = @import("conduit.testing");
const conduit = @import("conduit.zig");
const Child = conduit.Child;
const Pty = conduit.Pty;
const Reaper = conduit.Reaper;
const Sim = shakedown.Sim;

const is_windows = builtin.target.os.tag == .windows;

/// Reads its input to the end and writes it back upper-cased, then a line
/// to stderr; exits with 3.
fn shout(init: std.process.Init) !u8 {
    var buffer: [128]u8 = undefined;
    var r = Io.File.stdin().reader(init.io, &buffer);
    const all = try r.interface.allocRemaining(init.gpa, .unlimited);
    defer init.gpa.free(all);
    for (all) |*c| c.* = std.ascii.toUpper(c.*);
    try Io.File.stdout().writeStreamingAll(init.io, all);
    try Io.File.stderr().writeStreamingAll(init.io, "done\n");
    return 3;
}

/// Says whether it is on a terminal and how wide that is, then echoes the
/// line it reads.
fn prompt(init: std.process.Init) !void {
    const out = Io.File.stdout();
    try out.writeStreamingAll(init.io, if (try out.isTty(init.io)) "tty> " else "pipe> ");
    var buffer: [64]u8 = undefined;
    var r = Io.File.stdin().reader(init.io, &buffer);
    const line = try r.interface.takeDelimiterInclusive('\n');
    var said: [80]u8 = undefined;
    try out.writeStreamingAll(init.io, try std.mem.print(&said, "you said {s}", .{line}));
}

/// Never ends on its own.
fn forever(init: std.process.Init) !void {
    while (true) try init.io.sleep(.fromSeconds(1), .awake);
}

fn simulation(seed: u64) !*Sim {
    const sim = try Sim.init(testing.allocator, .{ .seed = seed, .watchdog = null });
    errdefer sim.deinit();
    try sim.programs().register("shout", shout, .{});
    try sim.programs().register("prompt", prompt, .{});
    try sim.programs().register("forever", forever, .{});
    return sim;
}

/// Runs `f(io)` on a fresh simulation's root with conduit's route, and
/// returns the run's trace hash.
fn runIn(seed: u64, comptime f: fn (Io) anyerror!void) !u64 {
    const sim = try simulation(seed);
    defer sim.deinit();
    const s = try seam.Seam.create(testing.allocator, sim.io());
    defer s.destroy();
    const Root = struct {
        fn run(io: Io) !void {
            try f(io);
        }
    };
    const outcome = sim.run(Root.run, .{s.io()});
    if (outcome != .finished) {
        std.debug.print("simulation ended {any}\n", .{outcome});
        return error.TestUnexpectedResult;
    }
    return sim.trace().hash();
}

const Cases = struct {
    fn pipes(io: Io) !void {
        var child = try Child.spawn(testing.allocator, io, .{ .argv = &.{"shout"}, .stdio = .{ .pipes = .{} } });
        defer child.deinit(io);
        try child.stdinFile().?.writeStreamingAll(io, "quiet words");
        child.closeStdin(io);
        var out = try child.output(testing.allocator, io, .{});
        defer out.deinit();
        try testing.expectEqualStrings("QUIET WORDS", out.stdout());
        try testing.expectEqualStrings("done\n", out.stderr());
        try testing.expectEqual(@as(?u32, 3), Child.exitCode(out.term()));
    }

    fn terminal(io: Io) !void {
        var pty = try Pty.open(testing.allocator, io, .{ .rows = 24, .cols = 80 });
        defer pty.close(io);
        var child = try Child.spawn(testing.allocator, io, .{ .argv = &.{"prompt"}, .stdio = .{ .pty = &pty } });
        defer child.deinit(io);
        pty.closeSlave(io);
        try pty.resize(io, .{ .rows = 50, .cols = 132 });
        try testing.expectEqual(@as(u16, 132), (try pty.size(io)).cols);
        try pty.master().write.writeStreamingAll(io, "hello\n");
        var buffer: [64]u8 = undefined;
        var r = pty.master().read.reader(io, &buffer);
        const all = try r.interface.allocRemaining(testing.allocator, .unlimited);
        defer testing.allocator.free(all);
        try testing.expectEqualStrings("tty> you said hello\n", all);
        try testing.expect(Child.succeeded(try child.wait(io)));
    }

    fn signals(io: Io) !void {
        var child = try Child.spawn(testing.allocator, io, .{ .argv = &.{"forever"}, .stdio = .ignore });
        defer child.deinit(io);
        try testing.expectEqual(@as(?conduit.Term, null), try child.tryWait(io));
        // A deadline on the simulation's clock: a minute passes at once.
        const before = Io.Timestamp.now(io, .awake);
        try testing.expectEqual(@as(?conduit.Term, null), try child.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } }));
        try testing.expect(Io.Timestamp.now(io, .awake).nanoseconds - before.nanoseconds >= std.time.ns_per_min);
        // A signal the program does not catch ends it; one ignored by
        // default does nothing.
        if (!is_windows) try child.kill(io, .window_change);
        try testing.expectEqual(@as(?conduit.Term, null), try child.tryWait(io));
        const term = try child.killWait(io, .fromSeconds(5));
        if (is_windows) {
            try testing.expectEqual(@as(?u32, 0xC000013A), Child.exitCode(term));
        } else {
            try testing.expectEqualStrings("TERM", Child.signalName(term).?);
        }
        // Reaped once: every later answer is the same.
        try testing.expectEqual(term, try child.wait(io));
        try child.kill(io, .kill);
    }

    fn reaper(io: Io) !void {
        var child = try Child.spawn(testing.allocator, io, .{ .argv = &.{"forever"}, .stdio = .ignore });
        defer child.deinit(io);
        var r: Reaper = .init(&child, .{});
        defer r.deinit(io);
        try r.start(io);
        try testing.expectEqual(@as(?conduit.Term, null), try r.exit());
        try testing.expectEqual(@as(?conduit.Term, null), try r.waitTimeout(io, .{ .duration = .{ .raw = .fromSeconds(1), .clock = .awake } }));
        r.kill(io, .zero);
        const term = try r.wait(io);
        if (!is_windows) try testing.expectEqualStrings("KILL", Child.signalName(term).?);
        try testing.expectEqual(term, try child.wait(io));
    }

    fn unsupported(io: Io) !void {
        const limits = [_]Child.ResourceLimit{.{ .resource = if (is_windows) undefined else .NOFILE, .limit = if (is_windows) undefined else .{ .cur = 64, .max = 64 } }};
        if (!is_windows) try testing.expectError(error.Unsupported, Child.spawn(testing.allocator, io, .{ .argv = &.{"forever"}, .resource_limits = &limits }));
        try testing.expectError(error.FileNotFound, Child.spawn(testing.allocator, io, .{ .argv = &.{"no-such-program"} }));
        // A real pair cannot carry a simulated child.
        var pty = try Pty.open(testing.allocator, testing.io, .{});
        defer pty.close(testing.io);
        try testing.expectError(error.Unsupported, Child.spawn(testing.allocator, io, .{ .argv = &.{"prompt"}, .stdio = .{ .pty = &pty } }));
    }
};

test "simulated: a child on pipes, its output collected and its exit code reported" {
    _ = try runIn(1, Cases.pipes);
}

test "simulated: a child on a terminal sees one, and the master reads it to the end" {
    _ = try runIn(2, Cases.terminal);
}

test "simulated: a deadline on the simulation's clock, a signal ignored, a kill after a grace" {
    _ = try runIn(3, Cases.signals);
}

test "simulated: a Reaper waits, is asked, kills and reaps" {
    _ = try runIn(4, Cases.reaper);
}

test "simulated: what a simulation cannot be is refused" {
    _ = try runIn(5, Cases.unsupported);
}

test "simulated: one seed, one run" {
    for (0..8) |seed| {
        try testing.expectEqual(try runIn(seed, Cases.terminal), try runIn(seed, Cases.terminal));
        try testing.expectEqual(try runIn(seed, Cases.signals), try runIn(seed, Cases.signals));
    }
}

test "a seam is only made over a simulation" {
    try testing.expectError(error.NotASimulation, seam.Seam.create(testing.allocator, testing.io));
}
