const std = @import("std");
const conduit = @import("conduit");
const coverage = @import("coverage.zig");
const smoke = @import("bench_options").smoke;
const c = std.c;

var true_program: []const u8 = "true";
var echo_program: []const u8 = "echo";
var cat_program: []const u8 = "cat";
var sleep_program: []const u8 = "sleep";
var shell_program: []const u8 = "sh";

pub fn main(init: std.process.Init) !void {
    true_program = init.environ_map.get("BENCH_TRUE") orelse "true";
    echo_program = init.environ_map.get("BENCH_ECHO") orelse "echo";
    cat_program = init.environ_map.get("BENCH_CAT") orelse "cat";
    sleep_program = init.environ_map.get("BENCH_SLEEP") orelse "sleep";
    shell_program = init.environ_map.get("BENCH_SH") orelse "sh";
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len == 2 and std.mem.eql(u8, args[1], "signal_child")) signalChild();
    // conduit-bench <input> [workload] [count]: every workload by default,
    // `default_count` times each.
    if (args.len < 2 or args.len > 4) return error.Usage;
    const path = args[1];
    const workload = if (args.len > 2) args[2] else "all";
    const n = if (args.len > 3) try std.fmt.parseInt(usize, args[3], 10) else default_count;
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, path, init.gpa, .unlimited);
    defer init.gpa.free(input);

    if (std.mem.eql(u8, workload, "all")) {
        for (own_workloads ++ coverage.names) |each| try runOne(init, each, n, input, path);
        return;
    }
    return runOne(init, workload, n, input, path);
}

/// How many times a workload runs when the command line does not say.
const default_count = 100;

/// The workloads this file runs itself; `coverage.names` are the rest. `all`
/// runs both lists, in order.
const own_workloads = [_][]const u8{
    "spawn_wait",
    "spawn_collect",
    "pty_spawn",
    "pty_spawn_child_kill",
    "pty_throughput",
    "wait_timeout",
    "tree_kill",
    "leaf_kill",
    "end_recorded",
};

fn runOne(init: std.process.Init, workload: []const u8, n: usize, input: []const u8, path: []const u8) !void {
    if (std.mem.eql(u8, workload, "spawn_wait")) return spawnWait(init, n);
    if (std.mem.eql(u8, workload, "spawn_collect")) return spawnCollect(init, n, input);
    if (std.mem.eql(u8, workload, "pty_spawn")) return ptySpawn(init, n, input, .tree);
    if (std.mem.eql(u8, workload, "pty_spawn_child_kill")) return ptySpawn(init, n, input, .child);
    if (std.mem.eql(u8, workload, "pty_throughput")) return ptyThroughput(init, input);
    if (std.mem.eql(u8, workload, "wait_timeout")) return waitTimeout(init, n);
    if (std.mem.eql(u8, workload, "tree_kill")) return treeKill(init, n);
    if (std.mem.eql(u8, workload, "leaf_kill")) return leafKill(init, n);
    if (std.mem.eql(u8, workload, "end_recorded")) return endRecorded(init, n);
    if (try coverage.run(.{
        .init = init,
        .n = n,
        .input = input,
        .path = path,
        .cat = cat_program,
        .echo = echo_program,
        .sleep = sleep_program,
        .sh = shell_program,
        .true_ = true_program,
    }, workload)) return;
    return error.UnknownWorkload;
}

fn now(io: std.Io) std.Io.Timestamp {
    return benchmarkNow(io);
}

fn elapsedNs(start: std.Io.Timestamp, io: std.Io) f64 {
    return @floatFromInt(start.durationTo(now(io)).toNanoseconds());
}

fn report(init: std.process.Init, workload: []const u8, metric: []const u8, value: f64, unit: []const u8) !void {
    return reportAs(init, "conduit", workload, metric, value, unit);
}

fn reportAs(init: std.process.Init, side: []const u8, workload: []const u8, metric: []const u8, value: f64, unit: []const u8) !void {
    var buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
    try out.interface.print("{s}\t{s}\t{s}\t{d:.6}\t{s}\n", .{ side, workload, metric, value, unit });
    try out.interface.flush();
}

fn spawnWait(init: std.process.Init, n: usize) !void {
    for (0..if (smoke) @as(usize, 0) else @min(n, 10)) |_| try oneSpawnWait(init);
    const start = now(init.io);
    for (0..n) |_| try oneSpawnWait(init);
    try report(init, "SPAWN+WAIT", "latency", elapsedNs(start, init.io) / @as(f64, @floatFromInt(n)) / 1000.0, "us");
}

fn oneSpawnWait(init: std.process.Init) !void {
    var child = try conduit.Child.spawn(init.gpa, init.io, .{ .argv = &.{true_program}, .stdio = .ignore });
    defer child.deinit(init.io);
    if (!conduit.succeeded(try child.wait(init.io))) return error.ChildFailed;
}

fn spawnCollect(init: std.process.Init, n: usize, arg: []const u8) !void {
    if (arg.len != 1024 or std.mem.findScalar(u8, arg, 0) != null) return error.BadInput;
    for (0..if (smoke) @as(usize, 0) else @min(n, 5)) |_| try oneCollect(init, arg);
    const start = now(init.io);
    for (0..n) |_| try oneCollect(init, arg);
    try report(init, "SPAWN+COLLECT", "latency", elapsedNs(start, init.io) / @as(f64, @floatFromInt(n)) / 1000.0, "us");
}

fn oneCollect(init: std.process.Init, arg: []const u8) !void {
    const argv = &.{ echo_program, arg };
    var child = try conduit.Child.spawn(init.gpa, init.io, .{
        .argv = argv,
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.deinit(init.io);
    var result = try child.output(init.gpa, init.io, .{ .max_bytes = 2048 });
    defer result.deinit();
    if (!conduit.succeeded(result.term()) or result.stdout().len != 1025 or result.stdout()[1024] != '\n') return error.BadOutput;
}

/// How the round trip ends the child. `.tree` is `killWait`, the call a
/// program uses, and what the row measures. `.child` is a diagnostic only:
/// one `kill` to the child's pid and a wait, the plainest way to end it, so the
/// cost of the descendant walk `killWait` pays can be read off beside it.
const PtyEnd = enum { tree, child };

fn ptySpawn(init: std.process.Init, n: usize, input: []const u8, end: PtyEnd) !void {
    if (input.len != 1024 or input[input.len - 1] != '\n') return error.BadInput;
    for (0..if (smoke) @as(usize, 0) else @min(n, 3)) |_| _ = try onePtyRoundTrip(init, input, end);
    const start = now(init.io);
    for (0..n) |_| _ = try onePtyRoundTrip(init, input, end);
    const side = switch (end) {
        .tree => "conduit",
        .child => "conduit-childkill",
    };
    try reportAs(init, side, "PTY SPAWN", "latency", elapsedNs(start, init.io) / @as(f64, @floatFromInt(n)) / 1000.0, "us");
}

fn onePtyRoundTrip(init: std.process.Init, input: []const u8, end: PtyEnd) !u64 {
    var pty = try conduit.Pty.open(init.gpa, .{ .rows = 24, .cols = 80 });
    defer pty.close(init.io);
    _ = try conduit.rawMode(pty.readHandle().?);
    var child = try conduit.Child.spawn(init.gpa, init.io, .{
        .argv = &.{cat_program},
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(init.io);
    errdefer _ = child.killWait(init.io, .zero) catch {};
    pty.closeSlave(init.io);
    try pty.writeFile().writeStreamingAll(init.io, input);
    const checksum = try drainExact(init.io, pty.readFile(), expectedPtyBytes(input));
    switch (end) {
        .tree => _ = try child.killWait(init.io, .zero),
        .child => {
            if (c.kill(child.processId().?, .KILL) != 0) return error.KillFailed;
            _ = try child.wait(init.io);
        },
    }
    return checksum;
}

fn expectedPtyBytes(input: []const u8) usize {
    return input.len;
}

fn drainExact(io: std.Io, file: std.Io.File, wanted: usize) !u64 {
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

const WriteCtx = struct {
    io: std.Io,
    file: std.Io.File,
    bytes: []const u8,
    failed: std.atomic.Value(bool) = .init(false),
};

fn writeAll(ctx: *WriteCtx) void {
    ctx.file.writeStreamingAll(ctx.io, ctx.bytes) catch ctx.failed.store(true, .release);
}

fn ptyThroughput(init: std.process.Init, input: []const u8) !void {
    if (input.len == 0 or input[input.len - 1] != '\n') return error.BadInput;
    var pty = try conduit.Pty.open(init.gpa, .{ .rows = 24, .cols = 80 });
    defer pty.close(init.io);
    _ = try conduit.rawMode(pty.readHandle().?);
    var child = try conduit.Child.spawn(init.gpa, init.io, .{
        .argv = &.{cat_program},
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(init.io);
    errdefer _ = child.killWait(init.io, .zero) catch {};
    pty.closeSlave(init.io);

    var ctx: WriteCtx = .{ .io = init.io, .file = pty.writeFile(), .bytes = input };
    var group: std.Io.Group = .init;
    defer group.cancel(init.io);
    const start = now(init.io);
    try group.concurrent(init.io, writeAll, .{&ctx});
    const checksum = try drainExact(init.io, pty.readFile(), expectedPtyBytes(input));
    group.cancel(init.io);
    const ns = elapsedNs(start, init.io);
    if (ctx.failed.load(.acquire) or checksum == 0) return error.TransferFailed;
    _ = try child.killWait(init.io, .zero);
    try report(init, "PTY THROUGHPUT", "throughput", @as(f64, @floatFromInt(input.len)) / ns * 1000.0, "MB/s");
}

fn waitTimeout(init: std.process.Init, n: usize) !void {
    for (0..if (smoke) @as(usize, 0) else @min(n, 3)) |_| _ = try oneWaitTimeout(init);
    var total_ns: f64 = 0;
    for (0..n) |_| total_ns += try oneWaitTimeout(init);
    const overshoot_us = @max(0.0, total_ns / @as(f64, @floatFromInt(n)) / 1000.0 - 10_000.0);
    try report(init, "WAIT-TIMEOUT", "overshoot", overshoot_us, "us");
}

fn oneWaitTimeout(init: std.process.Init) !f64 {
    var child = try conduit.Child.spawn(init.gpa, init.io, .{ .argv = &.{ sleep_program, "0.01" }, .stdio = .ignore });
    defer child.deinit(init.io);
    errdefer _ = child.killWait(init.io, .zero) catch {};
    const start = now(init.io);
    const term = (try child.waitTimeout(init.io, conduit.Deadline.within(.fromSeconds(1)))) orelse return error.UnexpectedTimeout;
    if (!conduit.succeeded(term)) return error.ChildFailed;
    return elapsedNs(start, init.io);
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

fn treeKill(init: std.process.Init, n: usize) !void {
    for (0..if (smoke) @as(usize, 0) else @min(n, 2)) |_| _ = try oneTreeKill(init);
    var total_ns: f64 = 0;
    for (0..n) |_| total_ns += try oneTreeKill(init);
    try report(init, "TREE KILL", "latency", total_ns / @as(f64, @floatFromInt(n)) / 1_000_000.0, "ms");
}

fn oneTreeKill(init: std.process.Init) !f64 {
    var child = try conduit.Child.spawn(init.gpa, init.io, .{ .argv = &.{ shell_program, "-c", "sleep 30 & sleep 30 & wait" }, .stdio = .ignore, .detach = true });
    defer child.deinit(init.io);
    errdefer _ = child.killWait(init.io, .zero) catch {};
    var storage: [8]std.posix.pid_t = undefined;
    const descendants = try waitForTwoChildren(init.io, child.processId().?, &storage);
    const start = now(init.io);
    try child.kill(.kill);
    _ = try child.wait(init.io);
    const ns = elapsedNs(start, init.io);
    try confirmGone(init.io, descendants);
    return ns;
}

/// `endRecorded` on the same fixed tree, as a later run of a program ends
/// what an earlier one recorded: the pid and its start time, no group, no
/// grace. The call and the reap of the root are timed; every descendant is
/// then confirmed gone.
fn endRecorded(init: std.process.Init, n: usize) !void {
    for (0..if (smoke) @as(usize, 0) else @min(n, 2)) |_| _ = try oneEndRecorded(init);
    var total_ns: f64 = 0;
    for (0..n) |_| total_ns += try oneEndRecorded(init);
    try report(init, "END RECORDED", "latency", total_ns / @as(f64, @floatFromInt(n)) / 1_000_000.0, "ms");
}

fn oneEndRecorded(init: std.process.Init) !f64 {
    var child = try conduit.Child.spawn(init.gpa, init.io, .{ .argv = &.{ shell_program, "-c", "sleep 30 & sleep 30 & wait" }, .stdio = .ignore, .detach = true });
    defer child.deinit(init.io);
    errdefer _ = child.killWait(init.io, .zero) catch {};
    var storage: [8]std.posix.pid_t = undefined;
    const descendants = try waitForTwoChildren(init.io, child.processId().?, &storage);
    const root = child.processId().?;
    const started = (try conduit.startTime(root)) orelse return error.NoStartTime;
    const start = now(init.io);
    if (!try conduit.killRecorded(init.io, .{ .pid = root, .start = started, .grace = .zero })) return error.NothingEnded;
    _ = try child.wait(init.io);
    const ns = elapsedNs(start, init.io);
    try confirmGone(init.io, descendants);
    return ns;
}

/// Diagnostic: `Child.kill(.kill)` of a detached child that never forks
/// (`sleep`), started and given a millisecond to run before the timed
/// region. Two lines: the call alone (`kill`) and the call and the reap
/// (`latency`), the second being mostly the kernel tearing the process down.
fn leafKill(init: std.process.Init, n: usize) !void {
    var sums: [2]f64 = .{ 0, 0 };
    for (0..if (smoke) @as(usize, 0) else @min(n, 2)) |_| _ = try oneLeafKill(init);
    for (0..n) |_| {
        const got = try oneLeafKill(init);
        sums[0] += got[0];
        sums[1] += got[1];
    }
    const count: f64 = @floatFromInt(n);
    try report(init, "LEAF KILL", "kill", sums[0] / count / 1000.0, "us");
    try report(init, "LEAF KILL", "latency", sums[1] / count / 1000.0, "us");
}

fn oneLeafKill(init: std.process.Init) ![2]f64 {
    var child = try conduit.Child.spawn(init.gpa, init.io, .{ .argv = &.{ sleep_program, "30" }, .stdio = .ignore, .detach = true });
    defer child.deinit(init.io);
    errdefer _ = child.killWait(init.io, .zero) catch {};
    try std.Io.sleep(init.io, .fromMilliseconds(1), .awake);
    const start = now(init.io);
    try child.kill(.kill);
    const signalled = elapsedNs(start, init.io);
    _ = try child.wait(init.io);
    return .{ signalled, elapsedNs(start, init.io) };
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
fn benchmarkNow(io: std.Io) std.Io.Timestamp {
    if (@import("bench_options").smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
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
