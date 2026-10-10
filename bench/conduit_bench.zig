//! conduit's own measurements of its own calls, as shakedown rows: one JSON
//! line per row on standard output, every sample in nanoseconds per unit.
//!
//!     conduit-bench [--smoke] [--row <name prefix>] [--samples <n>] [--input <file>]
//!
//! `--input` is a file of whole lines for the size rows; with none, a 1 KiB
//! line is made in the working directory. The other rows are in `coverage.zig`
//! and the shared fixture in `fixture.zig`.
const std = @import("std");
const conduit = @import("conduit");
const bench = @import("shakedown").bench;
const coverage = @import("coverage.zig");
const fixture = @import("fixture.zig");
const rowset = @import("rows.zig");
const Context = fixture.Context;
const single = rowset.single;
const c = std.c;

/// A row that does `units` whole operations, spawn to reap.
const batched = .{
    .{ .name = "spawn_wait", .unit = "spawn", .run = spawnWait },
    .{ .name = "spawn_collect", .unit = "spawn", .setup = requireKiB, .run = spawnCollect },
    .{ .name = "pty_spawn", .unit = "round_trip", .setup = requireLine, .run = ptySpawnTree },
    .{ .name = "pty_spawn_child_kill", .unit = "round_trip", .setup = requireLine, .run = ptySpawnChild },
};

/// A row whose sample is one operation, the child it needs started before the
/// clock and ended after it.
const sampled = .{
    .{ .name = "pty_throughput", .unit = "transfer", .setup = throughputSetup, .run = throughput, .teardown = throughputTeardown },
    .{ .name = "wait_timeout", .unit = "wait", .setup = waitTimeoutSetup, .run = waitTimeout, .teardown = release },
    .{ .name = "tree_kill", .unit = "kill", .setup = treeSetup, .run = treeKill, .teardown = treeTeardown },
    .{ .name = "end_recorded", .unit = "kill", .setup = recordedSetup, .run = endRecorded, .teardown = treeTeardown },
    .{ .name = "leaf_kill/kill", .unit = "kill", .setup = leafSetup, .run = leafKill, .teardown = leafTeardown },
    .{ .name = "leaf_kill/latency", .unit = "kill", .setup = leafSetup, .run = leafKillWait, .teardown = release },
};

const all_rows = batched ++ coverage.batched ++ sampled ++ coverage.sampled;
const WorkloadError = rowset.ErrorOf(all_rows);
comptime {
    std.debug.assert(WorkloadError != anyerror);
}
const batched_rows = rowset.of(Context, WorkloadError, batched ++ coverage.batched);
const sampled_rows = rowset.of(Context, WorkloadError, sampled ++ coverage.sampled);

const usage = "usage: conduit-bench [--smoke] [--row <name prefix>] [--samples <n>] [--input <file>]\n";

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "signal_child")) signalChild();
    var smoke = false;
    var prefix: []const u8 = "";
    var samples: usize = 31;
    var input_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (std.mem.eql(u8, flag, "--smoke")) {
            smoke = true;
        } else if (i + 1 < args.len and std.mem.eql(u8, flag, "--row")) {
            i += 1;
            prefix = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, flag, "--samples")) {
            i += 1;
            samples = try std.fmt.parseInt(usize, args[i], 10);
        } else if (i + 1 < args.len and std.mem.eql(u8, flag, "--input")) {
            i += 1;
            input_path = args[i];
        } else {
            try std.Io.File.stderr().writeStreamingAll(init.io, usage);
            return error.Usage;
        }
    }
    if (input_path == null) {
        const line: [1023]u8 = @splat('x');
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "line.txt", .data = &line ++ "\n" });
    }
    const path = try std.Io.Dir.cwd().realPathFileAlloc(init.io, input_path orelse "line.txt", init.gpa);
    defer init.gpa.free(path);
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .unlimited);
    defer init.gpa.free(input);

    var context: Context = .{
        .init = init,
        .input = input,
        .path = path,
        .cat = init.environ_map.get("BENCH_CAT") orelse "cat",
        .echo = init.environ_map.get("BENCH_ECHO") orelse "echo",
        .sleep = init.environ_map.get("BENCH_SLEEP") orelse "sleep",
        .sh = init.environ_map.get("BENCH_SH") orelse "sh",
        .true_ = init.environ_map.get("BENCH_TRUE") orelse "true",
    };

    // `wait_tree` is a row only where a cgroup can be made.
    var available: [sampled_rows.len]bench.Row(Context, WorkloadError) = undefined;
    var count: usize = 0;
    const waits = try coverage.waitTreeAvailable(&context);
    for (sampled_rows) |row| {
        if (!waits and std.mem.eql(u8, row.name, "wait_tree")) continue;
        available[count] = row;
        count += 1;
    }
    var selected = false;
    for (batched_rows) |row| selected = selected or std.mem.startsWith(u8, row.name, prefix);
    for (available[0..count]) |row| selected = selected or std.mem.startsWith(u8, row.name, prefix);
    if (!selected) return error.UnknownRow;

    const metadata: bench.Metadata = .{ .commit = @import("preflight_bench_options").commit };
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try bench.run(WorkloadError, init.gpa, init.io, &stdout.interface, &context, &batched_rows, metadata, .{ .smoke = smoke, .prefix = prefix, .samples = samples });
    // A sample here is one operation, so a batch must never grow: a sample
    // shorter than ten clock ticks is an error, not a longer batch. The
    // shortest, one kill signal or one read, are a few microseconds against
    // a tick of tens of nanoseconds.
    try bench.run(WorkloadError, init.gpa, init.io, &stdout.interface, &context, available[0..count], metadata, .{ .smoke = smoke, .prefix = prefix, .samples = samples, .minimum = .zero, .resolution_multiple = 10 });
    try stdout.interface.flush();
}

// --------------------------------------------------------------- spawn wait

fn spawnWait(x: *Context, units: u64) !void {
    for (0..units) |_| {
        var child = try conduit.Child.spawn(x.gpa(), x.io(), .{ .argv = &.{x.true_}, .stdio = .ignore });
        defer child.deinit(x.io());
        if (!conduit.succeeded(try child.wait(x.io()))) return error.ChildFailed;
    }
}

// ------------------------------------------------------------ spawn collect

fn requireKiB(x: *Context) !void {
    if (x.input.len != 1024 or std.mem.findScalar(u8, x.input, 0) != null) return error.BadInput;
}

fn spawnCollect(x: *Context, units: u64) !void {
    for (0..units) |_| {
        const argv = &.{ x.echo, x.input };
        var child = try conduit.Child.spawn(x.gpa(), x.io(), .{
            .argv = argv,
            .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
        });
        defer child.deinit(x.io());
        var result = try child.output(x.gpa(), x.io(), .{ .max_bytes = .fromRaw(2048) });
        defer result.deinit();
        if (!conduit.succeeded(result.term()) or result.stdout().len != 1025 or result.stdout()[1024] != '\n') return error.BadOutput;
    }
}

// ---------------------------------------------------------------- pty spawn

fn requireLine(x: *Context) !void {
    if (x.input.len != 1024 or x.input[x.input.len - 1] != '\n') return error.BadInput;
}

/// How the round trip ends the child. `.tree` is `killWait`, the call a
/// program uses, and what the row measures. `.child` is a diagnostic only:
/// one `kill` to the child's pid and a wait, the plainest way to end it, so the
/// cost of the descendant walk `killWait` pays can be read off beside it.
const PtyEnd = enum { tree, child };

fn ptySpawnTree(x: *Context, units: u64) !void {
    for (0..units) |_| _ = try ptyRoundTrip(x, .tree);
}

fn ptySpawnChild(x: *Context, units: u64) !void {
    for (0..units) |_| _ = try ptyRoundTrip(x, .child);
}

fn ptyRoundTrip(x: *Context, end: PtyEnd) !u64 {
    const io = x.io();
    var pty = try conduit.Pty.open(x.gpa(), x.io(), .{ .rows = 24, .cols = 80 });
    defer pty.close(io);
    _ = try conduit.rawMode(pty.readHandle().?);
    var child = try conduit.Child.spawn(x.gpa(), io, .{
        .argv = &.{x.cat},
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(io);
    // glint-ignore: Z026 -- the row's own error is the one returned; a child that cannot be ended here is released next and has nowhere else to report
    errdefer _ = child.killWait(io, .zero) catch {};
    pty.closeSlave(io);
    try pty.writeFile().writeStreamingAll(io, x.input);
    const checksum = try drainExact(io, pty.readFile(), x.input.len);
    switch (end) {
        .tree => _ = try child.killWait(io, .zero),
        .child => {
            if (c.kill(child.processId().?, .KILL) != 0) return error.KillFailed;
            _ = try child.wait(io);
        },
    }
    return checksum;
}

pub fn drainExact(io: std.Io, file: std.Io.File, wanted: usize) !u64 {
    var buf: [64 * 1024]u8 = undefined;
    var total: usize = 0;
    var checksum: u64 = 0;
    while (total < wanted) {
        const n = try file.readStreaming(io, &.{buf[0..@min(buf.len, wanted - total)]});
        if (n == 0) return error.EarlyEof;
        for (buf[0..n]) |byte| checksum +%= byte;
        total += n;
    }
    return checksum;
}

// ----------------------------------------------------------- pty throughput

const WriteCtx = struct {
    io: std.Io,
    file: std.Io.File,
    bytes: []const u8,
    failed: std.atomic.Value(bool) = .init(false),
};

fn writeAll(ctx: *WriteCtx) void {
    ctx.file.writeStreamingAll(ctx.io, ctx.bytes) catch ctx.failed.store(true, .release);
}

/// The terminal and the `cat` on it, made before the clock and ended after.
fn throughputSetup(x: *Context) !void {
    if (x.input.len == 0 or x.input[x.input.len - 1] != '\n') return error.BadInput;
    const io = x.io();
    x.pty = try conduit.Pty.open(x.gpa(), x.io(), .{ .rows = 24, .cols = 80 });
    errdefer x.pty.close(io);
    _ = try conduit.rawMode(x.pty.readHandle().?);
    try x.spawn(.{ .argv = &.{x.cat}, .stdio = .{ .pty = &x.pty }, .detach = true });
    errdefer x.release();
    x.pty.closeSlave(io);
}

/// The whole input written to `cat` on its terminal and every byte read back,
/// from the writer's start to its end. The child is a fresh one, as it is for
/// a program that uses it once: its start is in the first bytes' wait. The row
/// is the transfer; its throughput is the input's size over the sample.
fn throughput(x: *Context, units: u64) !void {
    try single(units);
    const io = x.io();
    var ctx: WriteCtx = .{ .io = io, .file = x.pty.writeFile(), .bytes = x.input };
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    try group.concurrent(io, writeAll, .{&ctx});
    const checksum = try drainExact(io, x.pty.readFile(), x.input.len);
    group.cancel(io);
    if (ctx.failed.load(.acquire) or checksum == 0) return error.TransferFailed;
}

fn throughputTeardown(x: *Context) !void {
    x.release();
    x.pty.close(x.io());
}

// ------------------------------------------------------------- wait timeout

fn waitTimeoutSetup(x: *Context) !void {
    try x.spawn(.{ .argv = &.{ x.sleep, "0.01" }, .stdio = .ignore });
}

/// `waitTimeout` on a child that ends in ten milliseconds. The sample is the
/// call, which returns at the child's end: the row's overshoot is the median
/// less those ten milliseconds.
fn waitTimeout(x: *Context, units: u64) !void {
    try single(units);
    const term = (try x.child.waitTimeout(x.io(), conduit.Deadline.within(.fromSeconds(1)))) orelse return error.UnexpectedTimeout;
    x.reaped = true;
    if (!conduit.succeeded(term)) return error.ChildFailed;
}

fn release(x: *Context) !void {
    x.release();
}

extern "c" fn proc_listchildpids(ppid: std.posix.pid_t, buffer: ?*anyopaque, buffersize: c_int) c_int;

fn childrenOf(pid: std.posix.pid_t, out: []std.posix.pid_t) usize {
    if (comptime @import("builtin").target.os.tag == .linux) return childrenOfLinux(pid, out);
    if (comptime !@import("builtin").target.os.tag.isDarwin()) return 0;
    const rc = proc_listchildpids(pid, out.ptr, @intCast(out.len * @sizeOf(std.posix.pid_t)));
    return if (rc > 0) @min(@as(usize, @intCast(rc)), out.len) else 0;
}

/// The shell is one thread, so its children are its main thread's.
fn childrenOfLinux(pid: std.posix.pid_t, out: []std.posix.pid_t) usize {
    var path: [64]u8 = undefined;
    const name = std.mem.printSentinel(&path, "/proc/{d}/task/{d}/children", .{ pid, pid }, 0) catch return 0;
    const fd = c.open(name, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    var text: [256]u8 = undefined;
    const n = c.read(fd, &text, text.len);
    if (n <= 0) return 0;
    var count: usize = 0;
    var it = std.mem.tokenizeScalar(u8, text[0..@intCast(n)], ' ');
    while (it.next()) |word| {
        if (count == out.len) break;
        out[count] = std.fmt.parseInt(std.posix.pid_t, word, 10) catch continue;
        count += 1;
    }
    return count;
}

fn waitForTwoChildren(io: std.Io, pid: std.posix.pid_t, out: *[8]std.posix.pid_t) ![]std.posix.pid_t {
    for (0..1000) |_| {
        const count = childrenOf(pid, out);
        if (count >= 2) return out[0..count];
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return error.TreeDidNotStart;
}

fn confirmGone(io: std.Io, pids: []const std.posix.pid_t) !void {
    for (0..1000) |_| {
        var any = false;
        for (pids) |pid| if (c.kill(pid, @fromBackingInt(@intCast(0))) == 0) {
            any = true;
        };
        if (!any) return;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    return error.DescendantSurvived;
}

// ----------------------------------------------------------------- tree kill

/// A shell with two children of its own, started and found before the clock.
fn treeSetup(x: *Context) !void {
    try x.spawn(.{ .argv = &.{ x.sh, "-c", "sleep 30 & sleep 30 & wait" }, .stdio = .ignore, .detach = true });
    errdefer x.release();
    const found = try waitForTwoChildren(x.io(), x.child.processId().?, &x.descendants);
    x.descendant_count = found.len;
}

/// The kill and the reap of the root.
fn treeKill(x: *Context, units: u64) !void {
    try single(units);
    try x.child.kill(x.io(), .kill);
    _ = try x.wait();
}

/// Every descendant is then confirmed gone.
fn treeTeardown(x: *Context) !void {
    x.release();
    try confirmGone(x.io(), x.descendants[0..x.descendant_count]);
}

/// `endRecorded` on the same fixed tree, as a later run of a program ends
/// what an earlier one recorded: the pid and its start time, no group, no
/// grace. The call and the reap of the root are timed.
fn recordedSetup(x: *Context) !void {
    try treeSetup(x);
    errdefer x.release();
    x.pid = x.child.processId().?;
    x.started = (try conduit.startTime(x.pid)) orelse return error.NoStartTime;
}

fn endRecorded(x: *Context, units: u64) !void {
    try single(units);
    if (!try conduit.killRecorded(x.io(), .{ .pid = x.pid, .start = x.started, .grace = .zero })) return error.NothingEnded;
    _ = try x.wait();
}

// ----------------------------------------------------------------- leaf kill

/// `Child.kill(.kill)` of a detached child that never forks (`sleep`),
/// started and given a millisecond to run before the clock. Two rows: the call
/// alone (`kill`) and the call and the reap (`latency`), the second being
/// mostly the kernel tearing the process down.
fn leafSetup(x: *Context) !void {
    try x.spawn(.{ .argv = &.{ x.sleep, "30" }, .stdio = .ignore, .detach = true });
    errdefer x.release();
    try x.io().sleep(.fromMilliseconds(1), .awake);
}

fn leafKill(x: *Context, units: u64) !void {
    try single(units);
    try x.child.kill(x.io(), .kill);
}

fn leafKillWait(x: *Context, units: u64) !void {
    try single(units);
    try x.child.kill(x.io(), .kill);
    _ = try x.wait();
}

/// The reap the `kill` row leaves out.
fn leafTeardown(x: *Context) !void {
    defer x.release();
    _ = try x.wait();
}

extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

/// The child the signal workload signals, when this program is run as
/// `conduit-bench signal_child`: it says `x` for each `SIGUSR1`, taken with
/// `sigwait` so that none arriving between two answers is lost, and its one
/// descendant ignores the signal and says `r` once both are set.
fn signalChild() noreturn {
    var set: c.sigset_t = undefined;
    _ = c.sigemptyset(&set);
    _ = c.sigaddset(&set, .USR1);
    if (c.sigprocmask(c.SIG.BLOCK, &set, null) != 0) c._exit(1);
    const descendant = c.fork();
    if (descendant < 0) c._exit(1);
    if (descendant == 0) {
        var ignore: c.Sigaction = .{ .handler = .{ .handler = c.SIG.IGN }, .mask = std.mem.zeroes(c.sigset_t), .flags = 0 };
        _ = c.sigaction(.USR1, &ignore, null);
        _ = c.sigprocmask(c.SIG.UNBLOCK, &set, null);
        if (c.write(1, "r\n", 2) != 2) c._exit(1);
        const argv = [_:null]?[*:0]const u8{ "sleep", "1000" };
        _ = execvp("sleep", &argv);
        c._exit(127);
    }
    while (true) {
        var sig: c_int = 0;
        if (c.sigwait(&set, &sig) == 0 and c.write(1, "x\n", 2) != 2) c._exit(1);
    }
}
