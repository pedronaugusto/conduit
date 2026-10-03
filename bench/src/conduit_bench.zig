const std = @import("std");
const conduit = @import("conduit");
const api = @import("api.zig");
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
    if (args.len != 4) return error.Usage;
    const n = try std.fmt.parseInt(usize, args[2], 10);
    const input = try std.Io.Dir.cwd().readFileAlloc(init.io, args[3], init.gpa, .unlimited);
    defer init.gpa.free(input);

    if (std.mem.eql(u8, args[1], "spawn_wait")) return spawnWait(init, n);
    if (std.mem.eql(u8, args[1], "spawn_collect")) return spawnCollect(init, n, input);
    if (std.mem.eql(u8, args[1], "pty_spawn")) return ptySpawn(init, n, input, .tree);
    if (std.mem.eql(u8, args[1], "pty_spawn_child_kill")) return ptySpawn(init, n, input, .child);
    if (std.mem.eql(u8, args[1], "pty_throughput")) return ptyThroughput(init, input);
    if (std.mem.eql(u8, args[1], "wait_timeout")) return waitTimeout(init, n);
    if (std.mem.eql(u8, args[1], "tree_kill")) return treeKill(init, n);
    if (std.mem.eql(u8, args[1], "leaf_kill")) return leafKill(init, n);
    if (std.mem.eql(u8, args[1], "end_recorded")) return endRecorded(init, n);
    if (try coverage.run(.{
        .init = init,
        .n = n,
        .input = input,
        .path = args[3],
        .cat = cat_program,
        .echo = echo_program,
        .sleep = sleep_program,
        .sh = shell_program,
        .true_ = true_program,
    }, args[1])) return;
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
    var child = try conduit.Child.spawn(init.io, init.gpa, .{ .argv = &.{true_program}, .stdio = .ignore });
    defer child.deinit(init.io);
    if (!conduit.succeeded(try child.wait(init.io))) return error.ChildFailed;
}

fn spawnCollect(init: std.process.Init, n: usize, arg: []const u8) !void {
    if (arg.len != 1024 or std.mem.indexOfScalar(u8, arg, 0) != null) return error.BadInput;
    for (0..if (smoke) @as(usize, 0) else @min(n, 5)) |_| try oneCollect(init, arg);
    const start = now(init.io);
    for (0..n) |_| try oneCollect(init, arg);
    try report(init, "SPAWN+COLLECT", "latency", elapsedNs(start, init.io) / @as(f64, @floatFromInt(n)) / 1000.0, "us");
}

fn oneCollect(init: std.process.Init, arg: []const u8) !void {
    const argv = &.{ echo_program, arg };
    var child = try conduit.Child.spawn(init.io, init.gpa, .{
        .argv = argv,
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.deinit(init.io);
    var result = try child.output(init.io, init.gpa, .{ .max_bytes = 2048 });
    defer result.deinit(init.gpa);
    if (!conduit.succeeded(api.outputTerm(&result)) or api.outputBytes(&result).len != 1025 or api.outputBytes(&result)[1024] != '\n') return error.BadOutput;
}

/// How the round trip ends the child. `.tree` is `killWait`, the call a
/// program uses, and what the row measures. `.child` is a diagnostic only:
/// one `kill` to the child's pid and a wait, what every rival does, so the
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
    var pty = try api.openPty(init.gpa);
    defer pty.close(init.io);
    _ = try conduit.rawMode(api.readHandle(pty));
    var child = try conduit.Child.spawn(init.io, init.gpa, .{
        .argv = &.{cat_program},
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(init.io);
    errdefer _ = child.killWait(init.io, 0) catch {};
    pty.closeSlave(init.io);
    try pty.writeFile().writeStreamingAll(init.io, input);
    const checksum = try drainExact(init.io, pty.readFile(), expectedPtyBytes(input));
    switch (end) {
        .tree => _ = try child.killWait(init.io, 0),
        .child => {
            if (c.kill(api.pid(&child), .KILL) != 0) return error.KillFailed;
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
    var pty = try api.openPty(init.gpa);
    defer pty.close(init.io);
    _ = try conduit.rawMode(api.readHandle(pty));
    var child = try conduit.Child.spawn(init.io, init.gpa, .{
        .argv = &.{cat_program},
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(init.io);
    errdefer _ = child.killWait(init.io, 0) catch {};
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
    _ = try child.killWait(init.io, 0);
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
    var child = try conduit.Child.spawn(init.io, init.gpa, .{ .argv = &.{ sleep_program, "0.01" }, .stdio = .ignore });
    defer child.deinit(init.io);
    errdefer _ = child.killWait(init.io, 0) catch {};
    const start = now(init.io);
    const term = (try child.waitTimeout(init.io, 1000)) orelse return error.UnexpectedTimeout;
    if (!conduit.succeeded(term)) return error.ChildFailed;
    return elapsedNs(start, init.io);
}

extern "c" fn proc_listchildpids(ppid: std.posix.pid_t, buffer: ?*anyopaque, buffersize: c_int) c_int;

fn childrenOf(pid: std.posix.pid_t, out: []std.posix.pid_t) usize {
    if (@import("builtin").os.tag == .linux) return childrenOfLinux(pid, out);
    const rc = proc_listchildpids(pid, out.ptr, @intCast(out.len * @sizeOf(std.posix.pid_t)));
    return if (rc > 0) @min(@as(usize, @intCast(rc)), out.len) else 0;
}

/// The shell is one thread, so its children are its main thread's.
fn childrenOfLinux(pid: std.posix.pid_t, out: []std.posix.pid_t) usize {
    var path: [64]u8 = undefined;
    const name = std.fmt.bufPrintZ(&path, "/proc/{d}/task/{d}/children", .{ pid, pid }) catch return 0;
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
        for (pids) |pid| if (c.kill(pid, @enumFromInt(0)) == 0) {
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
    var child = try conduit.Child.spawn(init.io, init.gpa, .{ .argv = &.{ shell_program, "-c", "sleep 30 & sleep 30 & wait" }, .stdio = .ignore, .detach = true });
    defer child.deinit(init.io);
    errdefer _ = child.killWait(init.io, 0) catch {};
    var storage: [8]std.posix.pid_t = undefined;
    const descendants = try waitForTwoChildren(init.io, api.pid(&child), &storage);
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
    var child = try conduit.Child.spawn(init.io, init.gpa, .{ .argv = &.{ shell_program, "-c", "sleep 30 & sleep 30 & wait" }, .stdio = .ignore, .detach = true });
    defer child.deinit(init.io);
    errdefer _ = child.killWait(init.io, 0) catch {};
    var storage: [8]std.posix.pid_t = undefined;
    const descendants = try waitForTwoChildren(init.io, api.pid(&child), &storage);
    const root = api.pid(&child);
    const started = (try conduit.startTime(root)) orelse return error.NoStartTime;
    const start = now(init.io);
    if (!try conduit.endRecorded(init.io, .{ .pid = root, .start = started, .grace_ms = 0 })) return error.NothingEnded;
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
    var child = try conduit.Child.spawn(init.io, init.gpa, .{ .argv = &.{ sleep_program, "30" }, .stdio = .ignore, .detach = true });
    defer child.deinit(init.io);
    errdefer _ = child.killWait(init.io, 0) catch {};
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
