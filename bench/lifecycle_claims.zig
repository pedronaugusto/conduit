//! The lifecycle claims: ratios and bounds the package promises, each a
//! verdict on shakedown rows. The rows go to standard output as JSON lines,
//! the verdicts to standard error as the claim, the measurement, its limit and
//! whether it passed. Speed claims belong on a quiet machine, outside the unit
//! suite.
//!
//!     lifecycle-claims --quiet-machine [--row <name prefix>]
//!     lifecycle-claims --smoke
//!
//! A ratio is taken between two rows measured in turn, a round of one then a
//! round of the other, the order swapped each round, so that a machine that
//! drifts drifts under both; its figure is the best sample of each. A bound is
//! on the slowest sample.
const std = @import("std");
const builtin = @import("builtin");
const conduit = @import("conduit");
const rowset = @import("rows.zig");
const bench = @import("shakedown").bench;
const single = rowset.single;

/// How long one wait here may take before the run is wrong.
const budget: std.Io.Timeout = conduit.Deadline.within(.fromSeconds(5));

const Context = struct {
    init: std.process.Init,
    child: conduit.Child = undefined,
    reaped: bool = false,
    reaper: conduit.Reaper = undefined,
    pty: conduit.Pty = undefined,
    conversation: conduit.Expect = undefined,
    conversation_buffer: [1024]u8 = undefined,
    term: ?conduit.Term = null,
    /// The signal that ought to have ended the child.
    signal: @TypeOf(std.posix.SIG.KILL) = undefined,

    fn io(x: *const Context) std.Io {
        return x.init.io;
    }

    fn gpa(x: *const Context) std.mem.Allocator {
        return x.init.gpa;
    }

    fn spawn(x: *Context, options: conduit.Child.SpawnOptions) !void {
        x.child = try conduit.Child.spawn(x.gpa(), x.io(), options);
        x.reaped = false;
    }

    fn release(x: *Context) void {
        // glint-ignore: Z026 -- a teardown has no error to return and the measurement was taken before it; the child is released next
        if (!x.reaped) _ = x.child.killWait(x.io(), .zero) catch {};
        x.child.deinit(x.io());
        x.reaped = true;
    }
};

/// Rows of two kinds. A paired row is whole operations, batched. A bound's row
/// is one operation, started before the clock: the runner must not grow its
/// batch, so a sample too short to read is an error.
const paired = .{
    .{ .name = "wait/blocking", .unit = "spawn", .run = waitBlocking },
    .{ .name = "wait/deadlined", .unit = "spawn", .run = waitDeadlined },
    .{ .name = "spawn/file_actions", .unit = "spawn", .setup = requireFork, .run = spawnFast },
    .{ .name = "spawn/fork", .unit = "spawn", .setup = requireFork, .run = spawnForked },
};
const bounded = .{
    .{ .name = "stop/honoured", .unit = "stop", .setup = honouredSetup, .run = stopHonoured, .teardown = stopTeardown },
    .{ .name = "stop/call", .unit = "call", .setup = stubbornSetup, .run = stopCall, .teardown = stopTeardown },
    .{ .name = "stop/forced", .unit = "stop", .setup = stubbornSetup, .run = stopForced, .teardown = stopTeardown },
    .{ .name = "reaper/join", .unit = "join", .setup = joinSetup, .run = reaperJoin, .teardown = joinTeardown },
    .{ .name = "expect/join", .unit = "join", .setup = readerSetup, .run = readerJoin, .teardown = readerTeardown },
};
const WorkloadError = rowset.ErrorOf(paired ++ bounded);
comptime {
    std.debug.assert(WorkloadError != anyerror);
}
const Row = bench.Row(Context, WorkloadError);
const paired_rows = rowset.of(Context, WorkloadError, paired);
const bounded_rows = rowset.of(Context, WorkloadError, bounded);

const usage = "lifecycle-claims --quiet-machine [--row <name prefix>] (exclusive idle machine only), or --smoke\n";

pub fn main(init: std.process.Init) !void {
    if (builtin.target.os.tag == .windows) return error.PosixHarness;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var smoke = false;
    var quiet = false;
    var prefix: []const u8 = "";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--smoke")) {
            smoke = true;
        } else if (std.mem.eql(u8, args[i], "--quiet-machine")) {
            quiet = true;
        } else if (i + 1 < args.len and std.mem.eql(u8, args[i], "--row")) {
            i += 1;
            prefix = args[i];
        } else {
            try std.Io.File.stderr().writeStreamingAll(init.io, usage);
            return error.Usage;
        }
    }
    if (!smoke and !quiet) {
        try std.Io.File.stderr().writeStreamingAll(init.io, usage);
        return error.QuietMachineRequired;
    }
    var selected = false;
    for (paired_rows ++ bounded_rows) |row| selected = selected or std.mem.startsWith(u8, row.name, prefix);
    if (!selected) return error.UnknownRow;

    var context: Context = .{ .init = init };
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const out = &stdout.interface;
    const metadata: bench.Metadata = .{ .commit = @import("preflight_bench_options").commit };
    if (smoke) {
        try bench.run(WorkloadError, init.gpa, init.io, out, &context, &paired_rows, metadata, .{ .smoke = true, .prefix = prefix });
        try bench.run(WorkloadError, init.gpa, init.io, out, &context, &bounded_rows, metadata, .{ .smoke = true, .prefix = prefix });
        try out.flush();
        return;
    }

    const turn: bench.Options = .{ .samples = 32, .prefix = "" };
    // One operation per sample: a batch never grows, and a sample under ten
    // clock ticks is an error.
    const one: bench.Options = .{ .samples = 7, .minimum = .zero, .resolution_multiple = 10 };
    var claims: Claims = .{ .init = init, .context = &context, .out = out, .metadata = metadata, .prefix = prefix };

    if (claims.wanted("wait/")) {
        const got = try claims.measure(paired_rows[0..2], 6, turn);
        defer claims.free(got);
        try claims.ratio("deadline/blocking, millionths (limit 3:2)", got[1], got[0], 1_500_000);
    }
    if (claims.wanted("spawn/")) {
        const got = try claims.measure(paired_rows[2..4], 5, turn);
        defer claims.free(got);
        try claims.ratio("file-actions/fork, millionths (limit 9:10)", got[0], got[1], 900_000);
    }
    if (claims.wanted("stop/")) {
        const got = try claims.measure(bounded_rows[0..3], 1, one);
        defer claims.free(got);
        try claims.bound("honoured stop, us (before 5 s)", got[0], 5_000_000 - 1);
        try claims.bound("stop call, us (before 300 ms grace)", got[1], 300_000 - 1);
        try claims.bound("forced stop, us (300 ms grace + 2 s)", got[2], 2_300_000 - 1);
    }
    if (claims.wanted("reaper/")) {
        const got = try claims.measure(bounded_rows[3..4], 1, one);
        defer claims.free(got);
        try claims.bound("Reaper join with live child, us (before 5 s)", got[0], 5_000_000 - 1);
    }
    if (claims.wanted("expect/")) {
        const got = try claims.measure(bounded_rows[4..5], 1, one);
        defer claims.free(got);
        try claims.bound("Expect join with open terminal, us (before 5 s)", got[0], 5_000_000 - 1);
    }
    try out.flush();
}

/// Measures rows and says what each claim made of them.
const Claims = struct {
    init: std.process.Init,
    context: *Context,
    out: *std.Io.Writer,
    metadata: bench.Metadata,
    prefix: []const u8,

    const Measured = struct { result: bench.Result, samples: []f64 };

    /// Whether a row of this group is selected.
    fn wanted(claims: Claims, group: []const u8) bool {
        return std.mem.startsWith(u8, group, claims.prefix) or std.mem.startsWith(u8, claims.prefix, group);
    }

    fn free(claims: Claims, got: []Measured) void {
        for (got) |each| claims.init.gpa.free(each.samples);
        claims.init.gpa.free(got);
    }

    /// `rows` for `rounds` rounds, each round a run of each row in turn, the
    /// order swapped on every other round. Each row's samples, kept in the
    /// order they were taken, are one row on standard output.
    fn measure(claims: Claims, rows: []const Row, rounds: usize, options: bench.Options) ![]Measured {
        const gpa = claims.init.gpa;
        var taken = try gpa.alloc(std.ArrayList(f64), rows.len);
        defer {
            for (taken) |*list| list.deinit(gpa);
            gpa.free(taken);
        }
        for (taken) |*list| list.* = .empty;
        const batches = try gpa.alloc(u64, rows.len);
        defer gpa.free(batches);
        @memset(batches, std.math.maxInt(u64));
        var resolution: u64 = 0;
        for (0..rounds) |round| {
            for (0..rows.len) |step| {
                const k = if (round % 2 == 0) step else rows.len - 1 - step;
                var scratch: std.Io.Writer.Allocating = .init(gpa);
                defer scratch.deinit();
                try bench.run(WorkloadError, gpa, claims.init.io, &scratch.writer, claims.context, rows[k..][0..1], claims.metadata, options);
                var run = try bench.parse(gpa, scratch.written());
                defer run.deinit();
                const one = run.rows.items[0].value;
                try taken[k].appendSlice(gpa, one.samples);
                batches[k] = @min(batches[k], one.batch);
                resolution = one.clock_resolution_ns;
            }
        }
        const got = try gpa.alloc(Measured, rows.len);
        errdefer gpa.free(got);
        var made: usize = 0;
        errdefer for (got[0..made]) |each| gpa.free(each.samples);
        for (rows, got, 0..) |row, *each, k| {
            const samples = try taken[k].toOwnedSlice(gpa);
            errdefer gpa.free(samples);
            const stats = try bench.statistics(gpa, samples);
            each.* = .{ .samples = samples, .result = .{
                .row = row.name,
                .unit = row.unit,
                .samples = samples,
                .best = stats.best,
                .median = stats.median,
                .p99 = stats.p99,
                .ops_per_second = 1e9 / stats.median,
                .commit = claims.metadata.commit,
                .zig = claims.metadata.zig,
                .cpu = claims.metadata.cpu,
                .os = claims.metadata.os,
                .batch = batches[k],
                .clock_resolution_ns = resolution,
            } };
            made += 1;
            try bench.write(claims.out, each.result);
        }
        try claims.out.flush();
        return got;
    }

    /// The best of `top` over the best of `bottom`, in millionths, against a limit.
    fn ratio(claims: Claims, claim: []const u8, top: Measured, bottom: Measured, limit: i64) !void {
        const actual: i64 = @intFromFloat(top.result.best * 1_000_000 / bottom.result.best);
        try claims.say(claim, actual, limit);
    }

    /// The slowest sample, in microseconds, against a limit.
    fn bound(claims: Claims, claim: []const u8, got: Measured, limit: i64) !void {
        const slowest: f64 = std.mem.max(f64, got.samples);
        try claims.say(claim, @intFromFloat(slowest / 1000), limit);
    }

    fn say(claims: Claims, claim: []const u8, actual: i64, limit: i64) !void {
        var buffer: [256]u8 = undefined;
        var err = std.Io.File.stderr().writerStreaming(claims.init.io, &buffer);
        try err.interface.print("{s}\t{d}\t{d}\t{s}\n", .{ claim, actual, limit, if (actual <= limit) "pass" else "over" });
        try err.interface.flush();
    }
};

// ----------------------------------------------------------- wait and spawn

fn waitBlocking(x: *Context, units: u64) !void {
    try wait(x, units, false);
}

fn waitDeadlined(x: *Context, units: u64) !void {
    try wait(x, units, true);
}

fn wait(x: *Context, units: u64, deadlined: bool) !void {
    const io = x.io();
    for (0..units) |_| {
        var child = try conduit.Child.spawn(x.gpa(), io, .{
            .argv = &.{ "/bin/sh", "-c", "exit 0" },
            .stdio = .ignore,
        });
        defer child.deinit(io);
        // glint-ignore: Z026 -- the row's own error is the one returned; a child that cannot be ended here is released next and has nowhere else to report
        errdefer _ = child.killWait(io, .zero) catch {};
        const term = if (deadlined)
            (try child.waitTimeout(io, budget)) orelse return error.ChildDidNotExit
        else
            try child.wait(io);
        if (!conduit.succeeded(term)) return error.ChildFailed;
    }
}

/// A cgroup adds a join to the forked side, or forks both where the C library
/// cannot start a child in one: either way the two would not differ by the
/// fork alone. Refuse rather than label that a comparison.
fn requireFork(x: *Context) !void {
    if (builtin.target.os.tag != .linux) return;
    var child = try conduit.Child.spawn(x.gpa(), x.io(), .{ .argv = &.{"/usr/bin/true"}, .stdio = .ignore });
    defer child.deinit(x.io());
    // glint-ignore: Z026 -- the row's own error is the one returned; a child that cannot be ended here is released next and has nowhere else to report
    errdefer _ = child.killWait(x.io(), .zero) catch {};
    var buffer: [std.Io.Dir.max_path_bytes + 64]u8 = undefined;
    if ((try child.containment(&buffer)).cgroup != null) return error.CgroupForcesFork;
    _ = try child.wait(x.io());
}

fn spawnFast(x: *Context, units: u64) !void {
    try spawnWait(x, units, null);
}

fn spawnForked(x: *Context, units: u64) !void {
    try spawnWait(x, units, "/");
}

fn spawnWait(x: *Context, units: u64, cwd: ?[]const u8) !void {
    const io = x.io();
    for (0..units) |_| {
        var child = try conduit.Child.spawn(x.gpa(), io, .{
            .argv = &.{"/usr/bin/true"},
            .cwd = cwd,
            .stdio = .ignore,
        });
        defer child.deinit(io);
        // glint-ignore: Z026 -- the row's own error is the one returned; a child that cannot be ended here is released next and has nowhere else to report
        errdefer _ = child.killWait(io, .zero) catch {};
        if (!conduit.succeeded(try child.wait(io))) return error.ChildFailed;
    }
}

// --------------------------------------------------------------------- stop

/// A shell that has said it is ready, and a reaper on it.
fn stopSetup(x: *Context, stubborn: bool) !void {
    const io = x.io();
    try x.spawn(.{
        .argv = &.{ "/bin/sh", "-c", if (stubborn) "trap '' TERM; echo ready; read x" else "echo ready; read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
        .detach = true,
    });
    errdefer x.release();
    var buffer: [64]u8 = undefined;
    var reader = x.child.stdoutFile().?.reader(io, &buffer);
    if (!std.mem.eql(u8, (try reader.interface.takeDelimiter('\n')).?, "ready")) return error.NotReady;
    x.reaper = .init(&x.child, .{});
    try x.reaper.start(io);
    x.term = null;
    x.signal = if (stubborn) std.posix.SIG.KILL else std.posix.SIG.TERM;
}

fn honouredSetup(x: *Context) !void {
    try stopSetup(x, false);
}

fn stubbornSetup(x: *Context) !void {
    try stopSetup(x, true);
}

/// The stop of a child that honours `TERM`, to its end.
fn stopHonoured(x: *Context, units: u64) !void {
    try single(units);
    x.reaper.kill(x.io(), .fromMilliseconds(60_000));
    x.term = (try x.reaper.waitTimeout(x.io(), budget)) orelse return error.ChildDidNotExit;
}

/// The call that stops a child that ignores `TERM`, which returns before the
/// grace is up.
fn stopCall(x: *Context, units: u64) !void {
    try single(units);
    x.reaper.kill(x.io(), .fromMilliseconds(300));
}

/// The stop of a child that ignores `TERM`, to its end: the grace, then `KILL`.
fn stopForced(x: *Context, units: u64) !void {
    try single(units);
    x.reaper.kill(x.io(), .fromMilliseconds(300));
    x.term = (try x.reaper.waitTimeout(x.io(), budget)) orelse return error.ChildDidNotExit;
}

/// What the stop left: the call alone is waited for here, and the child ended
/// by the signal the stop meant.
fn stopTeardown(x: *Context) !void {
    defer x.release();
    defer x.reaper.deinit(x.io());
    const term = x.term orelse (try x.reaper.waitTimeout(x.io(), budget)) orelse return error.ChildDidNotExit;
    x.reaped = true;
    if (term != .signal or term.signal != x.signal) return error.WrongSignal;
}

// -------------------------------------------------------------------- joins

/// A shell that waits on its input, and a reaper on it that ends the tree,
/// given twenty milliseconds to be running.
fn joinSetup(x: *Context) !void {
    const io = x.io();
    try x.spawn(.{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    errdefer x.release();
    x.reaper = .init(&x.child, .{ .end_tree = true });
    try x.reaper.start(io);
    errdefer x.reaper.deinit(io);
    try io.sleep(.fromMilliseconds(20), .awake);
}

/// `Reaper.stop` with the child alive.
fn reaperJoin(x: *Context, units: u64) !void {
    try single(units);
    try x.reaper.stop(x.io());
}

fn joinTeardown(x: *Context) !void {
    x.reaper.deinit(x.io());
    x.release();
}

/// A terminal with a shell on it that has said it is ready, and an `Expect`
/// reading it.
fn readerSetup(x: *Context) !void {
    const io = x.io();
    x.pty = try conduit.Pty.open(x.gpa(), .{ .rows = 24, .cols = 80 });
    errdefer x.pty.close(io);
    try x.spawn(.{
        .argv = &.{ "/bin/sh", "-c", "echo ready; read x" },
        .stdio = .{ .pty = &x.pty },
        .detach = true,
    });
    errdefer x.release();
    x.pty.closeSlave(io);
    x.conversation = .init(x.child.terminalMaster().?, &x.conversation_buffer);
    try x.conversation.start(io);
    errdefer x.conversation.deinit(io);
    _ = try x.conversation.until(io, "ready", budget);
}

/// `Expect.stop` with the terminal open.
fn readerJoin(x: *Context, units: u64) !void {
    try single(units);
    x.conversation.stop(x.io());
}

fn readerTeardown(x: *Context) !void {
    x.conversation.deinit(x.io());
    x.release();
    x.pty.close(x.io());
}
