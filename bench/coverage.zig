//! The rest of the public API: one workload per operation, each checking what
//! it measured. An operation this system does not have is reported
//! `unavailable` instead of a number.
const std = @import("std");
const conduit = @import("conduit");
const smoke = @import("bench_options").smoke;
/// How long one wait for the child may take before the run is wrong.
const budget: std.Io.Timeout = conduit.Deadline.within(.fromSeconds(5));
const c = std.c;

pub const Ctx = struct {
    init: std.process.Init,
    n: usize,
    input: []const u8,
    path: []const u8,
    cat: []const u8,
    echo: []const u8,
    sleep: []const u8,
    sh: []const u8,
    true_: []const u8,

    fn io(x: Ctx) std.Io {
        return x.init.io;
    }
    fn gpa(x: Ctx) std.mem.Allocator {
        return x.init.gpa;
    }
};

/// The workloads here, by name and function.
const table = .{
    .{ "exchange", exchange },
    .{ "collect", collect },
    .{ "input_writer", inputWriter },
    .{ "read_available", readAvailable },
    .{ "try_wait", tryWait },
    .{ "reaper_wait", reaperWait },
    .{ "expect", expect },
    .{ "proxy", proxy },
    .{ "shell_spawn", shellSpawn },
    .{ "pty_open", ptyOpen },
    .{ "tty_ops", ttyOps },
    .{ "find_program", findProgram },
    .{ "environ", environ },
    .{ "process_identity", processIdentity },
    .{ "signal", signal },
    .{ "extra_fds", extraFds },
    .{ "wait_tree", waitTree },
};

/// The name of every workload here, in order.
pub const names = names: {
    var out: [table.len][]const u8 = undefined;
    for (&out, 0..) |*name, i| name.* = table[i][0];
    break :names out;
};

/// Runs `workload` if it is one of these. False when it is not.
pub fn run(x: Ctx, workload: []const u8) !bool {
    inline for (table) |entry| {
        if (std.mem.eql(u8, workload, entry[0])) {
            try entry[1](x);
            return true;
        }
    }
    return false;
}

// Smoke exercises correctness without sampling a benchmark clock.
var smoke_ticks = std.atomic.Value(i64).init(0);
fn now(io: std.Io) std.Io.Timestamp {
    if (smoke) return .{ .nanoseconds = smoke_ticks.fetchAdd(1, .monotonic) };
    return std.Io.Clock.awake.now(io);
}

fn since(start: std.Io.Timestamp, io: std.Io) f64 {
    return @floatFromInt(start.durationTo(now(io)).toNanoseconds());
}

fn print(x: Ctx, comptime format: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(x.io(), &buf);
    try out.interface.print(format, args);
    try out.interface.flush();
}

fn report(x: Ctx, workload: []const u8, metric: []const u8, value: f64, unit: []const u8) !void {
    try print(x, "conduit\t{s}\t{s}\t{d:.6}\t{s}\n", .{ workload, metric, value, unit });
}

/// A row for a value every run must agree on, whatever it measured.
fn agree(x: Ctx, workload: []const u8, metric: []const u8, value: usize, unit: []const u8) !void {
    try print(x, "conduit\t{s}\t{s}\t{d}\t{s}\n", .{ workload, metric, value, unit });
}

fn unavailable(x: Ctx, workload: []const u8, metrics: []const []const u8, unit: []const u8) !void {
    for (metrics) |metric| try print(x, "conduit\t{s}\t{s}\tunavailable\t{s}\n", .{ workload, metric, unit });
}

/// Per-operation latency and the bytes it moved per second.
fn sizeRows(x: Ctx, workload: []const u8, total_ns: f64, bytes: usize) !void {
    const count: f64 = @floatFromInt(x.n);
    try report(x, workload, "latency", total_ns / count / 1000.0, "us");
    try report(x, workload, "throughput", @as(f64, @floatFromInt(bytes)) * count / total_ns * 1000.0, "MB/s");
    try agree(x, workload, "bytes_out", bytes, "bytes");
}

fn warmups(x: Ctx, limit: usize) usize {
    return if (smoke) 0 else @min(x.n, limit);
}

// ---------------------------------------------------------------- exchange

fn exchange(x: Ctx) !void {
    return exchangeAll(x);
}

fn exchangeAll(x: Ctx) !void {
    for (0..warmups(x, 3)) |_| _ = try oneExchange(x);
    var total: f64 = 0;
    for (0..x.n) |_| total += try oneExchange(x);
    try sizeRows(x, "EXCHANGE", total, x.input.len);
}

/// `cat` given the input and its output collected, spawn to reap.
fn oneExchange(x: Ctx) !f64 {
    const io = x.io();
    const start = now(io);
    var child = try conduit.Child.spawn(x.gpa(), io, .{
        .argv = &.{x.cat},
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.deinit(io);
    var out = try child.exchange(x.gpa(), io, x.input, .{ .max_bytes = x.input.len + 1 });
    const ns = since(start, io);
    defer out.deinit();
    if (!conduit.succeeded(out.term()) or out.stdoutTruncated() or !std.mem.eql(u8, out.stdout(), x.input)) return error.BadOutput;
    return ns;
}

// ----------------------------------------------------------------- collect

fn collect(x: Ctx) !void {
    for (0..warmups(x, 3)) |_| _ = try oneCollect(x);
    var total: f64 = 0;
    for (0..x.n) |_| total += try oneCollect(x);
    try sizeRows(x, "COLLECT", total, x.input.len);
}

/// `cat FILE` run to the end and its output collected, spawn to reap.
fn oneCollect(x: Ctx) !f64 {
    const io = x.io();
    const start = now(io);
    var child = try conduit.Child.spawn(x.gpa(), io, .{
        .argv = &.{ x.cat, x.path },
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.deinit(io);
    var out = try child.output(x.gpa(), io, .{ .max_bytes = x.input.len + 1 });
    const ns = since(start, io);
    defer out.deinit();
    if (!conduit.succeeded(out.term()) or !std.mem.eql(u8, out.stdout(), x.input)) return error.BadOutput;
    return ns;
}

// ------------------------------------------------------------ input writer

pub const chunk = 64;

fn inputWriter(x: Ctx) !void {
    return inputWriterAll(x);
}

fn inputWriterAll(x: Ctx) !void {
    for (0..warmups(x, 2)) |_| _ = try oneInputWriter(x);
    var total: f64 = 0;
    for (0..x.n) |_| total += try oneInputWriter(x);
    try sizeRows(x, "INPUT WRITER", total, x.input.len);
}

/// The input queued 64 bytes at a time, then ended, while `cat`'s output is
/// collected: spawn to reap and delivery confirmed.
fn oneInputWriter(x: Ctx) !f64 {
    const io = x.io();
    const start = now(io);
    var child = try conduit.Child.spawn(x.gpa(), io, .{
        .argv = &.{x.cat},
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, .zero) catch {};
    var writer = try child.inputWriter(x.gpa(), io, .{ .max_backlog = x.input.len });
    defer writer.deinit(io);
    var at: usize = 0;
    while (at < x.input.len) {
        const end = @min(x.input.len, at + chunk);
        try writer.queue(io, x.input[at..end]);
        at = end;
    }
    try writer.close(io);
    var out = try child.output(x.gpa(), io, .{ .max_bytes = x.input.len + 1 });
    defer out.deinit();
    try writer.wait(io);
    const ns = since(start, io);
    if (!conduit.succeeded(out.term()) or !std.mem.eql(u8, out.stdout(), x.input)) return error.BadOutput;
    return ns;
}

// ---------------------------------------------------------- read available

fn readAvailable(x: Ctx) !void {
    return readAvailableAll(x);
}

fn readAvailableAll(x: Ctx) !void {
    if (x.input.len != 1024) return error.BadInput;
    for (0..warmups(x, 5)) |_| _ = try oneReadAvailable(x);
    var total: f64 = 0;
    for (0..x.n) |_| total += try oneReadAvailable(x);
    try report(x, "READ AVAILABLE", "latency", total / @as(f64, @floatFromInt(x.n)) / 1000.0, "us");
    try agree(x, "READ AVAILABLE", "bytes_out", x.input.len + 1, "bytes");
}

/// What an ended `echo` left in its taken pipe, read until nothing is left:
/// only the reads are timed.
fn oneReadAvailable(x: Ctx) !f64 {
    const io = x.io();
    var child = try conduit.Child.spawn(x.gpa(), io, .{
        .argv = &.{ x.echo, x.input },
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.deinit(io);
    const file = child.takeStdout() orelse return error.NoPipe;
    defer file.close(io);
    if (!conduit.succeeded(try child.wait(io))) return error.ChildFailed;
    var buffer: [4096]u8 = undefined;
    var total: usize = 0;
    const start = now(io);
    while (true) {
        const got = try conduit.readAvailable(io, file, &buffer);
        if (got == 0) break;
        total += got;
    }
    const ns = since(start, io);
    if (total != x.input.len + 1) return error.BadOutput;
    return ns;
}

// ---------------------------------------------------------------- try wait

fn tryWait(x: Ctx) !void {
    const io = x.io();
    var child = try conduit.Child.spawn(x.gpa(), io, .{ .argv = &.{ x.sleep, "30" }, .stdio = .ignore });
    defer child.deinit(io);
    defer _ = child.killWait(io, .zero) catch {};
    for (0..warmups(x, 1000)) |_| if (try child.tryWait(x.io()) != null) return error.ChildEnded;
    const start = now(io);
    for (0..x.n) |_| if (try child.tryWait(x.io()) != null) return error.ChildEnded;
    try report(x, "TRY WAIT", "call", since(start, io) / @as(f64, @floatFromInt(x.n)), "ns");
}

// ------------------------------------------------------------- reaper wait

fn reaperWait(x: Ctx) !void {
    for (0..warmups(x, 10)) |_| _ = try oneReaperWait(x);
    var total: f64 = 0;
    for (0..x.n) |_| total += try oneReaperWait(x);
    try report(x, "REAPER WAIT", "latency", total / @as(f64, @floatFromInt(x.n)) / 1000.0, "us");
}

/// `true` spawned and its wait put on a task of its own, joined.
fn oneReaperWait(x: Ctx) !f64 {
    const io = x.io();
    const start = now(io);
    var child = try conduit.Child.spawn(x.gpa(), io, .{ .argv = &.{x.true_}, .stdio = .ignore });
    defer child.deinit(io);
    var reaper: conduit.Reaper = .init(&child, .{});
    try reaper.start(io);
    const term = reaper.wait(io) catch |err| {
        reaper.deinit(io);
        return err;
    };
    reaper.deinit(io);
    const ns = since(start, io);
    if (!conduit.succeeded(term)) return error.ChildFailed;
    return ns;
}

// ------------------------------------------------------------------ expect

pub const expect_message = "expect round trip 0123456789\n";

fn expect(x: Ctx) !void {
    const io = x.io();
    var pty = try conduit.Pty.open(x.gpa(), .{ .rows = 24, .cols = 80 });
    defer pty.close(io);
    _ = try conduit.rawMode(pty.readHandle().?);
    var child = try conduit.Child.spawn(x.gpa(), io, .{ .argv = &.{x.cat}, .stdio = .{ .pty = &pty }, .detach = true });
    defer child.deinit(io);
    defer _ = child.killWait(io, .zero) catch {};
    pty.closeSlave(io);
    var buffer: [4096]u8 = undefined;
    var conversation: conduit.Expect = .init(pty.master(), &buffer);
    try conversation.start(io);
    defer conversation.deinit(io);
    const message = expect_message;
    const patterns: []const []const u8 = &.{ "never-a\n", "never-b\n", "never-c\n", message };
    const count: f64 = @floatFromInt(x.n);

    for (0..warmups(x, 20)) |_| {
        try conversation.send(io, message);
        _ = try conversation.until(io, message, budget);
    }
    var start = now(io);
    for (0..x.n) |_| {
        try conversation.send(io, message);
        const found = try conversation.until(io, message, budget);
        if (found.before.len != 0) return error.BadOutput;
    }
    try report(x, "EXPECT", "until", since(start, io) / count / 1000.0, "us");

    start = now(io);
    for (0..x.n) |_| {
        try conversation.send(io, message);
        const found = try conversation.untilAny(io, patterns, budget);
        if (found.index != 3 or found.before.len != 0) return error.BadOutput;
    }
    try report(x, "EXPECT", "until_any", since(start, io) / count / 1000.0, "us");

    start = now(io);
    for (0..x.n) |_| {
        try conversation.send(io, message);
        if (!std.mem.eql(u8, try conversation.bytes(io, message.len, budget), message)) return error.BadOutput;
    }
    try report(x, "EXPECT", "bytes", since(start, io) / count / 1000.0, "us");
}

// ------------------------------------------------------------------- proxy

/// A terminal in its default (cooked) mode writes each newline as CR LF, and
/// on macOS now and then one CR more, so the drain counts what is not a CR:
/// the file's own bytes, which must arrive exactly.
const Drain = struct {
    fd: c.fd_t,
    total: usize = 0,
    returns: usize = 0,
    failed: bool = false,

    fn run(drain: *Drain) void {
        var buffer: [64 * 1024]u8 = undefined;
        while (true) {
            const got = c.read(drain.fd, &buffer, buffer.len);
            if (got == 0) return;
            if (got < 0) {
                if (std.c.errno(got) == .INTR) continue;
                drain.failed = true;
                return;
            }
            const bytes = buffer[0..@intCast(got)];
            drain.total += bytes.len;
            drain.returns += std.mem.count(u8, bytes, "\r");
        }
    }
};

fn proxy(x: Ctx) !void {
    for (0..warmups(x, 1)) |_| _ = try oneProxy(x);
    var total: f64 = 0;
    for (0..x.n) |_| total += try oneProxy(x);
    try sizeRows(x, "PROXY", total, x.input.len);
}

/// `cat FILE` on a terminal in its default mode, the pair's bytes moved by
/// `Proxy.run` to a pipe another thread drains, with an input pipe that
/// never speaks: spawn to every byte out and the child reaped.
fn oneProxy(x: Ctx) !f64 {
    const io = x.io();
    var input: [2]c.fd_t = undefined;
    var output: [2]c.fd_t = undefined;
    if (c.pipe(&input) != 0) return error.Pipe;
    defer for (input) |fd| {
        _ = c.close(fd);
    };
    if (c.pipe(&output) != 0) return error.Pipe;
    defer _ = c.close(output[0]);
    var output_open = true;
    defer if (output_open) {
        _ = c.close(output[1]);
    };
    var drain: Drain = .{ .fd = output[0] };
    var pty = try conduit.Pty.open(x.gpa(), .{ .rows = 24, .cols = 80 });
    defer pty.close(io);
    var input_buffer: [32 * 1024]u8 = undefined;
    var output_buffer: [32 * 1024]u8 = undefined;

    const start = now(io);
    const reader = try std.Thread.spawn(.{}, Drain.run, .{&drain});
    errdefer {
        if (output_open) _ = c.close(output[1]);
        output_open = false;
        reader.join();
    }
    var child = try conduit.Child.spawn(x.gpa(), io, .{ .argv = &.{ x.cat, x.path }, .stdio = .{ .pty = &pty }, .detach = true });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, .zero) catch {};
    pty.closeSlave(io);
    try conduit.Proxy.run(io, .{
        .master = pty.master(),
        .input = .{ .handle = input[0], .flags = .{ .nonblocking = false } },
        .output = .{ .handle = output[1], .flags = .{ .nonblocking = false } },
        .input_buffer = &input_buffer,
        .output_buffer = &output_buffer,
    });
    _ = c.close(output[1]);
    output_open = false;
    reader.join();
    const term = try child.wait(io);
    const ns = since(start, io);
    if (!conduit.succeeded(term) or drain.failed or drain.total - drain.returns != x.input.len or
        drain.returns < std.mem.count(u8, x.input, "\n")) return error.BadOutput;
    return ns;
}

// ------------------------------------------------------------- shell spawn

pub const shell_says = "ready\r\n";

fn shellSpawn(x: Ctx) !void {
    for (0..warmups(x, 5)) |_| _ = try oneShell(x);
    var total: f64 = 0;
    for (0..x.n) |_| total += try oneShell(x);
    try report(x, "SHELL SPAWN", "latency", total / @as(f64, @floatFromInt(x.n)) / 1000.0, "us");
}

/// `sh -c 'echo ready'` as a terminal emulator starts a shell: a new pair,
/// `TERM` set, a controlling terminal. Spawn to its line read and reap.
fn oneShell(x: Ctx) !f64 {
    const io = x.io();
    const start = now(io);
    var shell = try conduit.spawnShell(x.gpa(), io, .{ .program = x.sh, .args = &.{ "-c", "echo ready" } });
    defer shell.deinit(io);
    const child = shell.child();
    errdefer _ = child.killWait(io, .zero) catch {};
    var said: [shell_says.len]u8 = undefined;
    var got: usize = 0;
    const master = shell.pty().readFile();
    while (got < said.len) {
        const n = try master.readStreaming(io, &.{said[got..]});
        if (n == 0) return error.EarlyEof;
        got += n;
    }
    const term = try child.wait(io);
    const ns = since(start, io);
    if (!conduit.succeeded(term) or !std.mem.eql(u8, &said, shell_says)) return error.BadOutput;
    return ns;
}

// ---------------------------------------------------------------- pty open

fn ptyOpen(x: Ctx) !void {
    const io = x.io();
    for (0..warmups(x, 20)) |_| {
        var pty = try conduit.Pty.open(x.gpa(), .{ .rows = 24, .cols = 80 });
        pty.close(io);
    }
    const start = now(io);
    for (0..x.n) |_| {
        var pty = try conduit.Pty.open(x.gpa(), .{ .rows = 24, .cols = 80 });
        pty.close(io);
    }
    try report(x, "PTY OPEN", "latency", since(start, io) / @as(f64, @floatFromInt(x.n)) / 1000.0, "us");
}

// ----------------------------------------------------------------- tty ops

fn ttyOps(x: Ctx) !void {
    const io = x.io();
    var pty = try conduit.Pty.open(x.gpa(), .{ .rows = 24, .cols = 80 });
    defer pty.close(io);
    var child = try conduit.Child.spawn(x.gpa(), io, .{ .argv = &.{ x.sleep, "30" }, .stdio = .{ .pty = &pty }, .detach = true });
    defer child.deinit(io);
    defer _ = child.killWait(io, .zero) catch {};
    const master = pty.readHandle().?;
    const slave = pty.slaveHandle().?;
    const pid = child.processId().?;
    for (0..1000) |_| {
        if ((conduit.foregroundGroup(master) catch 0) == pid) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    } else return error.NoForegroundGroup;

    const size: conduit.Size = .{ .rows = 24, .cols = 80 };
    var name_buffer: [256]u8 = undefined;
    const count: f64 = @floatFromInt(x.n);
    const rounds = if (smoke) 1 else 2;
    for (0..rounds) |round| {
        const timed = round + 1 == rounds;
        var start = now(io);
        for (0..x.n) |_| try conduit.restore(master, try conduit.rawMode(master));
        if (timed) try report(x, "TTY OPS", "raw_restore", since(start, io) / count, "ns");
        start = now(io);
        for (0..x.n) |_| if ((try conduit.winSize(master)).rows != 24) return error.BadSize;
        if (timed) try report(x, "TTY OPS", "win_size", since(start, io) / count, "ns");
        start = now(io);
        for (0..x.n) |_| try conduit.setWinSize(master, size);
        if (timed) try report(x, "TTY OPS", "set_win_size", since(start, io) / count, "ns");
        start = now(io);
        for (0..x.n) |_| if ((try pty.size()).cols != 80) return error.BadSize;
        if (timed) try report(x, "TTY OPS", "pty_size", since(start, io) / count, "ns");
        start = now(io);
        for (0..x.n) |_| try pty.resize(size);
        if (timed) try report(x, "TTY OPS", "pty_resize", since(start, io) / count, "ns");
        start = now(io);
        for (0..x.n) |_| if (!conduit.isTty(master)) return error.NotATerminal;
        if (timed) try report(x, "TTY OPS", "is_tty", since(start, io) / count, "ns");
        start = now(io);
        for (0..x.n) |_| if (!std.mem.startsWith(u8, try conduit.ttyName(slave, &name_buffer), "/dev/")) return error.BadName;
        if (timed) try report(x, "TTY OPS", "tty_name", since(start, io) / count, "ns");
        start = now(io);
        for (0..x.n) |_| if (try conduit.foregroundGroup(master) != pid) return error.BadGroup;
        if (timed) try report(x, "TTY OPS", "foreground_group", since(start, io) / count, "ns");
    }
}

// ------------------------------------------------------------ find program

pub const missing_program = "conduit-bench-no-such-program";

fn findProgram(x: Ctx) !void {
    const io = x.io();
    const env = x.init.environ_map;
    const found = (try conduit.findProgram(x.gpa(), io, env, x.cat)) orelse return error.NotFound;
    defer x.gpa().free(found);
    const rounds = if (smoke) 1 else 2;
    const count: f64 = @floatFromInt(x.n);
    for (0..rounds) |round| {
        const timed = round + 1 == rounds;
        var start = now(io);
        for (0..x.n) |_| {
            const path = (try conduit.findProgram(x.gpa(), io, env, x.cat)) orelse return error.NotFound;
            defer x.gpa().free(path);
            if (!std.mem.eql(u8, path, found)) return error.Unstable;
        }
        if (timed) try report(x, "FIND PROGRAM", "hit", since(start, io) / count / 1000.0, "us");
        start = now(io);
        for (0..x.n) |_| if (try conduit.findProgram(x.gpa(), io, env, missing_program)) |path| {
            x.gpa().free(path);
            return error.Found;
        };
        if (timed) try report(x, "FIND PROGRAM", "miss", since(start, io) / count / 1000.0, "us");
    }
    try print(x, "conduit\tFIND PROGRAM\tfound:{s}\t{d}\tbytes\n", .{ found, found.len });
}

// ----------------------------------------------------------------- environ

fn environ(x: Ctx) !void {
    const io = x.io();
    const changes: []const conduit.environ.Override = &.{
        .{ .name = "TERM", .value = "xterm-256color" },
        .{ .name = "CONDUIT_BENCH_UNSET", .value = null },
    };
    const only: []const conduit.environ.Override = &.{
        .{ .name = "PATH", .value = "/usr/bin:/bin" },
        .{ .name = "HOME", .value = "/nonexistent" },
        .{ .name = "TERM", .value = "xterm-256color" },
    };
    var probe = try conduit.environ.inherit(x.gpa(), changes);
    const inherited = probe.count();
    probe.deinit();
    const rounds = if (smoke) 1 else 2;
    const count: f64 = @floatFromInt(x.n);
    for (0..rounds) |round| {
        const timed = round + 1 == rounds;
        var start = now(io);
        for (0..x.n) |_| {
            var map = try conduit.environ.inherit(x.gpa(), changes);
            defer map.deinit();
            if (map.count() != inherited) return error.Unstable;
        }
        if (timed) try report(x, "ENVIRON", "inherit", since(start, io) / count / 1000.0, "us");
        start = now(io);
        for (0..x.n) |_| {
            var map = try conduit.environ.only(x.gpa(), only);
            defer map.deinit();
            if (map.count() != 3) return error.Unstable;
        }
        if (timed) try report(x, "ENVIRON", "only", since(start, io) / count / 1000.0, "us");
    }
    try agree(x, "ENVIRON", "inherited_vars", inherited, "count");
}

// -------------------------------------------------------- process identity

fn processIdentity(x: Ctx) !void {
    const io = x.io();
    var child = try conduit.Child.spawn(x.gpa(), io, .{ .argv = &.{ x.sleep, "30" }, .stdio = .ignore });
    defer child.deinit(io);
    defer _ = child.killWait(io, .zero) catch {};
    const pid = child.processId().?;
    const started = (try conduit.startTime(pid)) orelse return error.NoStartTime;
    const rounds = if (smoke) 1 else 2;
    const count: f64 = @floatFromInt(x.n);
    for (0..rounds) |round| {
        const timed = round + 1 == rounds;
        var start = now(io);
        for (0..x.n) |_| if (!(conduit.processExists(pid) orelse false)) return error.Gone;
        if (timed) try report(x, "PROCESS IDENTITY", "exists", since(start, io) / count, "ns");
        start = now(io);
        for (0..x.n) |_| if ((try conduit.startTime(pid)) != started) return error.Unstable;
        if (timed) try report(x, "PROCESS IDENTITY", "start_time", since(start, io) / count, "ns");
        start = now(io);
        for (0..x.n) |_| {
            var captured = (try conduit.captureStarted(pid, started)) orelse return error.NotCaptured;
            captured.deinit();
        }
        if (timed) try report(x, "PROCESS IDENTITY", "capture", since(start, io) / count, "ns");
    }
}

// ------------------------------------------------------------------ signal

/// Signals `conduit-bench signal_child`, this program run again, or the
/// program `BENCH_SIGNAL_CHILD` names, which speaks the same way: it says
/// `x` for each `SIGUSR1`, taken with `sigwait` so that none is lost between
/// two answers, and its one descendant ignores the signal and says `r` once
/// both are set.
fn signal(x: Ctx) !void {
    const io = x.io();
    var own_path: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const signal_child = x.init.environ_map.get("BENCH_SIGNAL_CHILD") orelse
        own_path[0..try std.process.executablePath(io, &own_path)];
    var child = try conduit.Child.spawn(x.gpa(), io, .{
        .argv = &.{ signal_child, "signal_child" },
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
        .detach = true,
    });
    defer child.deinit(io);
    defer _ = child.killWait(io, .zero) catch {};
    const out = child.stdoutFile().?.handle;
    try readExact(out, "r\n");
    for (0..warmups(x, 20)) |_| {
        try child.kill(.user1);
        try readExact(out, "x\n");
    }
    const start = now(io);
    for (0..x.n) |_| {
        try child.kill(.user1);
        try readExact(out, "x\n");
    }
    try report(x, "SIGNAL", "round_trip", since(start, io) / @as(f64, @floatFromInt(x.n)) / 1000.0, "us");
    try agree(x, "SIGNAL", "acks", x.n, "count");
}

/// Reads exactly `expected` from `fd`, or fails.
fn readExact(fd: std.posix.fd_t, expected: []const u8) !void {
    var buffer: [16]u8 = undefined;
    var got: usize = 0;
    while (got < expected.len) {
        const n = c.read(fd, buffer[got..expected.len].ptr, expected.len - got);
        if (n <= 0) return error.ShortRead;
        got += @intCast(n);
    }
    if (!std.mem.eql(u8, buffer[0..got], expected)) return error.BadOutput;
}

// --------------------------------------------------------------- extra fds

/// What the child runs with its pipe at descriptor 3.
pub const extra_fds_script = "echo x >&3";

fn extraFds(x: Ctx) !void {
    if (comptime !@hasField(conduit.Child.SpawnOptions, "extra_fds"))
        return unavailable(x, "EXTRA FDS", &.{"latency"}, "us");
    for (0..warmups(x, 5)) |_| _ = try oneExtraFds(x);
    var total: f64 = 0;
    for (0..x.n) |_| total += try oneExtraFds(x);
    try report(x, "EXTRA FDS", "latency", total / @as(f64, @floatFromInt(x.n)) / 1000.0, "us");
    try agree(x, "EXTRA FDS", "bytes_out", 2, "bytes");
}

/// A pipe made, `sh` started with its write end at descriptor 3, what it
/// wrote there read to the end, and the child reaped.
fn oneExtraFds(x: Ctx) !f64 {
    const io = x.io();
    const start = now(io);
    var ends: [2]c_int = undefined;
    if (c.pipe(&ends) != 0) return error.Pipe;
    defer _ = c.close(ends[0]);
    for (ends) |fd| _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
    var child = try conduit.Child.spawn(x.gpa(), io, .{
        .argv = &.{ x.sh, "-c", extra_fds_script },
        .stdio = .ignore,
        .extra_fds = &.{.{ .handle = ends[1], .flags = .{ .nonblocking = false } }},
    });
    defer child.deinit(io);
    _ = c.close(ends[1]);
    var buffer: [8]u8 = undefined;
    var got: usize = 0;
    while (true) {
        const n = c.read(ends[0], buffer[got..].ptr, buffer.len - got);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break;
        got += @intCast(n);
    }
    if (!conduit.succeeded(try child.wait(io))) return error.ChildFailed;
    const ns = since(start, io);
    if (!std.mem.eql(u8, buffer[0..got], "x\n")) return error.BadOutput;
    return ns;
}

// --------------------------------------------------------------- wait tree

/// `waitTree` on a Linux child's cgroup once the child has ended: the
/// answer is there at once, and what is timed is asking for it. Windows has
/// the job object instead, and nothing else here has the operation.
fn waitTree(x: Ctx) !void {
    if (comptime @import("builtin").target.os.tag != .linux)
        return unavailable(x, "WAIT TREE", &.{"latency"}, "us");
    const io = x.io();
    var total: f64 = 0;
    for (0..warmups(x, 5) + x.n) |i| {
        var child = try conduit.Child.spawn(x.gpa(), io, .{ .argv = &.{x.true_}, .stdio = .ignore });
        defer child.deinit(io);
        if (!conduit.succeeded(try child.wait(io))) return error.ChildFailed;
        const start = now(io);
        const empty = child.waitTree(io, conduit.Deadline.within(.fromSeconds(1))) catch |err| switch (err) {
            // No cgroup this process may make: nothing to time here.
            error.Unsupported => return unavailable(x, "WAIT TREE", &.{"latency"}, "us"),
            else => return err,
        };
        const ns = since(start, io);
        if (!empty) return error.TreeRemained;
        if (i >= warmups(x, 5)) total += ns;
    }
    try report(x, "WAIT TREE", "latency", total / @as(f64, @floatFromInt(x.n)) / 1000.0, "us");
}
