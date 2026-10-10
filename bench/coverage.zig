//! The rest of the public API: one row per operation, each checking what it
//! measured. The tables are read by `conduit_bench.zig`, which says what a
//! batched and a sampled row are.
const std = @import("std");
const builtin = @import("builtin");
const conduit = @import("conduit");
const fixture = @import("fixture.zig");
const Context = fixture.Context;
const single = @import("rows.zig").single;
const c = std.c;

/// How long one wait for the child may take before the run is wrong.
const budget: std.Io.Timeout = conduit.Deadline.within(.fromSeconds(5));

pub const batched = .{
    .{ .name = "exchange", .unit = "exchange", .run = exchange },
    .{ .name = "collect", .unit = "collect", .run = collect },
    .{ .name = "input_writer", .unit = "input_writer", .run = inputWriter },
    .{ .name = "try_wait", .unit = "call", .initial = 1000, .setup = sleeperSetup, .run = tryWait, .teardown = release },
    .{ .name = "reaper_wait", .unit = "wait", .run = reaperWait },
    .{ .name = "expect/until", .unit = "call", .setup = expectSetup, .run = expectUntil, .teardown = expectTeardown },
    .{ .name = "expect/until_any", .unit = "call", .setup = expectSetup, .run = expectUntilAny, .teardown = expectTeardown },
    .{ .name = "expect/bytes", .unit = "call", .setup = expectSetup, .run = expectBytes, .teardown = expectTeardown },
    .{ .name = "shell_spawn", .unit = "shell", .run = shellSpawn },
    .{ .name = "pty_open", .unit = "pty", .run = ptyOpen },
    .{ .name = "tty_ops/raw_restore", .unit = "call", .initial = 1000, .setup = ttySetup, .run = rawRestore, .teardown = ttyTeardown },
    .{ .name = "tty_ops/win_size", .unit = "call", .initial = 1000, .setup = ttySetup, .run = winSize, .teardown = ttyTeardown },
    .{ .name = "tty_ops/set_win_size", .unit = "call", .initial = 1000, .setup = ttySetup, .run = setWinSize, .teardown = ttyTeardown },
    .{ .name = "tty_ops/pty_size", .unit = "call", .initial = 1000, .setup = ttySetup, .run = ptySize, .teardown = ttyTeardown },
    .{ .name = "tty_ops/pty_resize", .unit = "call", .initial = 1000, .setup = ttySetup, .run = ptyResize, .teardown = ttyTeardown },
    .{ .name = "tty_ops/is_tty", .unit = "call", .initial = 1000, .setup = ttySetup, .run = isTty, .teardown = ttyTeardown },
    .{ .name = "tty_ops/tty_name", .unit = "call", .initial = 1000, .setup = ttySetup, .run = ttyName, .teardown = ttyTeardown },
    .{ .name = "tty_ops/foreground_group", .unit = "call", .initial = 1000, .setup = ttySetup, .run = foregroundGroup, .teardown = ttyTeardown },
    .{ .name = "find_program/hit", .unit = "lookup", .initial = 100, .setup = findSetup, .run = findHit, .teardown = findTeardown },
    .{ .name = "find_program/miss", .unit = "lookup", .initial = 100, .run = findMiss },
    .{ .name = "environ/inherit", .unit = "map", .initial = 100, .setup = environSetup, .run = environInherit },
    .{ .name = "environ/only", .unit = "map", .initial = 100, .run = environOnly },
    .{ .name = "process_identity/exists", .unit = "call", .initial = 1000, .setup = identitySetup, .run = identityExists, .teardown = release },
    .{ .name = "process_identity/start_time", .unit = "call", .initial = 1000, .setup = identitySetup, .run = identityStartTime, .teardown = release },
    .{ .name = "process_identity/capture", .unit = "call", .initial = 1000, .setup = identitySetup, .run = identityCapture, .teardown = release },
    .{ .name = "signal", .unit = "round_trip", .setup = signalSetup, .run = signal, .teardown = release },
    .{ .name = "extra_fds", .unit = "spawn", .run = extraFds },
};

pub const sampled = .{
    .{ .name = "read_available", .unit = "drain", .setup = readAvailableSetup, .run = readAvailable, .teardown = readAvailableTeardown },
    .{ .name = "proxy", .unit = "proxy", .setup = proxySetup, .run = proxy, .teardown = proxyTeardown },
} ++ if (builtin.target.os.tag == .linux) .{
    .{ .name = "wait_tree", .unit = "query", .setup = waitTreeSetup, .run = waitTree, .teardown = release },
} else .{};

fn release(x: *Context) !void {
    x.release();
}

/// A child that sleeps for the whole row.
fn sleeperSetup(x: *Context) !void {
    try x.spawn(.{ .argv = &.{ x.sleep, "30" }, .stdio = .ignore });
}

// ---------------------------------------------------------------- exchange

/// `cat` given the input and its output collected, spawn to reap.
fn exchange(x: *Context, units: u64) !void {
    const io = x.io();
    for (0..units) |_| {
        var child = try conduit.Child.spawn(x.gpa(), io, .{
            .argv = &.{x.cat},
            .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
        });
        defer child.deinit(io);
        var out = try child.exchange(x.gpa(), io, x.input, .{ .max_bytes = .fromRaw(x.input.len + 1) });
        defer out.deinit();
        if (!conduit.succeeded(out.term()) or out.stdoutTruncated() or !std.mem.eql(u8, out.stdout(), x.input)) return error.BadOutput;
    }
}

// ----------------------------------------------------------------- collect

/// `cat FILE` run to the end and its output collected, spawn to reap.
fn collect(x: *Context, units: u64) !void {
    const io = x.io();
    for (0..units) |_| {
        var child = try conduit.Child.spawn(x.gpa(), io, .{
            .argv = &.{ x.cat, x.path },
            .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
        });
        defer child.deinit(io);
        var out = try child.output(x.gpa(), io, .{ .max_bytes = .fromRaw(x.input.len + 1) });
        defer out.deinit();
        if (!conduit.succeeded(out.term()) or !std.mem.eql(u8, out.stdout(), x.input)) return error.BadOutput;
    }
}

// ------------------------------------------------------------ input writer

const chunk = 64;

/// The input queued 64 bytes at a time, then ended, while `cat`'s output is
/// collected: spawn to reap and delivery confirmed.
fn inputWriter(x: *Context, units: u64) !void {
    const io = x.io();
    for (0..units) |_| {
        var child = try conduit.Child.spawn(x.gpa(), io, .{
            .argv = &.{x.cat},
            .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
        });
        defer child.deinit(io);
        // glint-ignore: Z026 -- the row's own error is the one returned; a child that cannot be ended here is released next and has nowhere else to report
        errdefer _ = child.killWait(io, .zero) catch {};
        var writer = try child.inputWriter(x.gpa(), io, .{ .max_backlog = .fromRaw(x.input.len) });
        defer writer.deinit(io);
        var at: usize = 0;
        while (at < x.input.len) {
            const end = @min(x.input.len, at + chunk);
            try writer.queue(io, x.input[at..end]);
            at = end;
        }
        try writer.close(io);
        var out = try child.output(x.gpa(), io, .{ .max_bytes = .fromRaw(x.input.len + 1) });
        defer out.deinit();
        try writer.wait(io);
        if (!conduit.succeeded(out.term()) or !std.mem.eql(u8, out.stdout(), x.input)) return error.BadOutput;
    }
}

// ---------------------------------------------------------- read available

/// What an ended `echo` left in its taken pipe, before the clock.
fn readAvailableSetup(x: *Context) !void {
    if (x.input.len != 1024) return error.BadInput;
    const io = x.io();
    try x.spawn(.{
        .argv = &.{ x.echo, x.input },
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
    });
    errdefer x.release();
    x.pipe = x.child.takeStdout() orelse return error.NoPipe;
    errdefer x.pipe.close(io);
    if (!conduit.succeeded(try x.wait())) return error.ChildFailed;
    x.drained = 0;
}

/// The pipe read until nothing is left: only the reads are timed.
fn readAvailable(x: *Context, units: u64) !void {
    try single(units);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const got = try conduit.readAvailable(x.io(), x.pipe, &buffer);
        if (got == 0) break;
        x.drained += got;
    }
}

fn readAvailableTeardown(x: *Context) !void {
    x.pipe.close(x.io());
    x.release();
    if (x.drained != x.input.len + 1) return error.BadOutput;
}

// ---------------------------------------------------------------- try wait

fn tryWait(x: *Context, units: u64) !void {
    for (0..units) |_| if (try x.child.tryWait(x.io()) != null) return error.ChildEnded;
}

// ------------------------------------------------------------- reaper wait

/// `true` spawned and its wait put on a task of its own, joined.
fn reaperWait(x: *Context, units: u64) !void {
    const io = x.io();
    for (0..units) |_| {
        var child = try conduit.Child.spawn(x.gpa(), io, .{ .argv = &.{x.true_}, .stdio = .ignore });
        defer child.deinit(io);
        var reaper: conduit.Reaper = .init(&child, .{});
        try reaper.start(io);
        const term = reaper.wait(io) catch |err| {
            reaper.deinit(io);
            return err;
        };
        reaper.deinit(io);
        if (!conduit.succeeded(term)) return error.ChildFailed;
    }
}

// ------------------------------------------------------------------ expect

const expect_message = "expect round trip 0123456789\n";

/// `cat` on a terminal, and a conversation with it.
fn expectSetup(x: *Context) !void {
    const io = x.io();
    x.pty = try conduit.Pty.open(x.gpa(), x.io(), .{ .rows = 24, .cols = 80 });
    errdefer x.pty.close(io);
    _ = try conduit.rawMode(x.pty.readHandle().?);
    try x.spawn(.{ .argv = &.{x.cat}, .stdio = .{ .pty = &x.pty }, .detach = true });
    errdefer x.release();
    x.pty.closeSlave(io);
    x.conversation = .init(x.pty.master(), &x.conversation_buffer);
    try x.conversation.start(io);
    errdefer x.conversation.deinit(io);
    // One round trip, so `cat` is running and the rows time a warm one.
    try x.conversation.send(io, expect_message);
    _ = try x.conversation.until(io, expect_message, budget);
}

fn expectTeardown(x: *Context) !void {
    x.conversation.deinit(x.io());
    x.release();
    x.pty.close(x.io());
}

fn expectUntil(x: *Context, units: u64) !void {
    const io = x.io();
    for (0..units) |_| {
        try x.conversation.send(io, expect_message);
        const found = try x.conversation.until(io, expect_message, budget);
        if (found.before.len != 0) return error.BadOutput;
    }
}

fn expectUntilAny(x: *Context, units: u64) !void {
    const io = x.io();
    const patterns: []const []const u8 = &.{ "never-a\n", "never-b\n", "never-c\n", expect_message };
    for (0..units) |_| {
        try x.conversation.send(io, expect_message);
        const found = try x.conversation.untilAny(io, patterns, budget);
        if (found.index != 3 or found.before.len != 0) return error.BadOutput;
    }
}

fn expectBytes(x: *Context, units: u64) !void {
    const io = x.io();
    for (0..units) |_| {
        try x.conversation.send(io, expect_message);
        if (!std.mem.eql(u8, try x.conversation.bytes(io, expect_message.len, budget), expect_message)) return error.BadOutput;
    }
}

// ------------------------------------------------------------------- proxy

/// The pipes and the terminal, made before the clock.
fn proxySetup(x: *Context) !void {
    const p = &x.proxy;
    p.* = .{};
    if (c.pipe(&p.input) != 0) return error.Pipe;
    errdefer for (p.input) |fd| {
        _ = c.close(fd);
    };
    if (c.pipe(&p.output) != 0) return error.Pipe;
    errdefer for (p.output) |fd| {
        _ = c.close(fd);
    };
    p.output_open = true;
    p.drain = .{ .fd = p.output[0] };
    p.pty = try conduit.Pty.open(x.gpa(), x.io(), .{ .rows = 24, .cols = 80 });
}

/// `cat FILE` on a terminal in its default mode, the pair's bytes moved by
/// `Proxy.run` to a pipe another thread drains, with an input pipe that never
/// speaks: the drain thread started, to every byte out and the child reaped.
/// What came out is checked after.
fn proxy(x: *Context, units: u64) !void {
    try single(units);
    const io = x.io();
    const p = &x.proxy;
    var input_buffer: [32 * 1024]u8 = undefined;
    var output_buffer: [32 * 1024]u8 = undefined;
    p.reader = try std.Thread.spawn(.{}, Context.Drain.run, .{&p.drain});
    p.child = try conduit.Child.spawn(x.gpa(), io, .{ .argv = &.{ x.cat, x.path }, .stdio = .{ .pty = &p.pty }, .detach = true });
    p.pty.closeSlave(io);
    try conduit.Proxy.run(io, .{
        .master = p.pty.master(),
        .input = .{ .handle = p.input[0], .flags = .{ .nonblocking = false } },
        .output = .{ .handle = p.output[1], .flags = .{ .nonblocking = false } },
        .input_buffer = &input_buffer,
        .output_buffer = &output_buffer,
    });
    _ = c.close(p.output[1]);
    p.output_open = false;
    p.reader.?.join();
    p.reader = null;
    p.term = try p.child.?.wait(io);
    p.reaped = true;
}

fn proxyTeardown(x: *Context) !void {
    const io = x.io();
    const p = &x.proxy;
    if (p.output_open) _ = c.close(p.output[1]);
    if (p.reader) |reader| reader.join();
    if (p.child) |*child| {
        // glint-ignore: Z026 -- a teardown has no error to return and the measurement was taken before it; the child is released next
        if (!p.reaped) _ = child.killWait(io, .zero) catch {};
        child.deinit(io);
    }
    p.pty.close(io);
    _ = c.close(p.output[0]);
    for (p.input) |fd| {
        _ = c.close(fd);
    }
    const term = p.term orelse return error.BadOutput;
    if (!conduit.succeeded(term) or p.drain.failed or p.drain.total - p.drain.returns != x.input.len or
        p.drain.returns < std.mem.count(u8, x.input, "\n")) return error.BadOutput;
}

// ------------------------------------------------------------- shell spawn

const shell_says = "ready\r\n";

/// `sh -c 'echo ready'` as a terminal emulator starts a shell: a new pair,
/// `TERM` set, a controlling terminal. Spawn to its line read and reap.
fn shellSpawn(x: *Context, units: u64) !void {
    const io = x.io();
    for (0..units) |_| {
        var shell = try conduit.spawnShell(x.gpa(), io, .{ .program = x.sh, .args = &.{ "-c", "echo ready" } });
        defer shell.deinit(io);
        const child = shell.child();
        // glint-ignore: Z026 -- the row's own error is the one returned; a child that cannot be ended here is released next and has nowhere else to report
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
        if (!conduit.succeeded(term) or !std.mem.eql(u8, &said, shell_says)) return error.BadOutput;
    }
}

// ---------------------------------------------------------------- pty open

fn ptyOpen(x: *Context, units: u64) !void {
    for (0..units) |_| {
        var pty = try conduit.Pty.open(x.gpa(), x.io(), .{ .rows = 24, .cols = 80 });
        pty.close(x.io());
    }
}

// ----------------------------------------------------------------- tty ops

const size: conduit.Size = .{ .rows = 24, .cols = 80 };

/// A terminal with `sleep` in its foreground, found there before the clock.
fn ttySetup(x: *Context) !void {
    const io = x.io();
    x.pty = try conduit.Pty.open(x.gpa(), x.io(), .{ .rows = 24, .cols = 80 });
    errdefer x.pty.close(io);
    try x.spawn(.{ .argv = &.{ x.sleep, "30" }, .stdio = .{ .pty = &x.pty }, .detach = true });
    errdefer x.release();
    x.master = x.pty.readHandle().?;
    x.slave = x.pty.slaveHandle().?;
    x.pid = x.child.processId().?;
    for (0..1000) |_| {
        if ((conduit.foregroundGroup(x.master) catch 0) == x.pid) break;
        try io.sleep(.fromMilliseconds(1), .awake);
    } else return error.NoForegroundGroup;
}

fn ttyTeardown(x: *Context) !void {
    x.release();
    x.pty.close(x.io());
}

fn rawRestore(x: *Context, units: u64) !void {
    for (0..units) |_| try conduit.restore(x.master, try conduit.rawMode(x.master));
}

fn winSize(x: *Context, units: u64) !void {
    for (0..units) |_| if ((try conduit.winSize(x.master)).rows != 24) return error.BadSize;
}

fn setWinSize(x: *Context, units: u64) !void {
    for (0..units) |_| try conduit.setWinSize(x.master, size);
}

fn ptySize(x: *Context, units: u64) !void {
    for (0..units) |_| if ((try x.pty.size(x.io())).cols != 80) return error.BadSize;
}

fn ptyResize(x: *Context, units: u64) !void {
    for (0..units) |_| try x.pty.resize(x.io(), size);
}

fn isTty(x: *Context, units: u64) !void {
    for (0..units) |_| if (!conduit.isTty(x.master)) return error.NotATerminal;
}

fn ttyName(x: *Context, units: u64) !void {
    var name_buffer: [256]u8 = undefined;
    for (0..units) |_| if (!std.mem.startsWith(u8, try conduit.ttyName(x.slave, &name_buffer), "/dev/")) return error.BadName;
}

fn foregroundGroup(x: *Context, units: u64) !void {
    for (0..units) |_| if (try conduit.foregroundGroup(x.master) != x.pid) return error.BadGroup;
}

// ------------------------------------------------------------ find program

const missing_program = "conduit-bench-no-such-program";

/// The path the lookup finds once, for every later one to agree with.
fn findSetup(x: *Context) !void {
    x.found = (try conduit.findProgram(x.gpa(), x.io(), x.init.environ_map, x.cat)) orelse return error.NotFound;
}

fn findTeardown(x: *Context) !void {
    x.gpa().free(x.found);
    x.found = &.{};
}

fn findHit(x: *Context, units: u64) !void {
    for (0..units) |_| {
        const path = (try conduit.findProgram(x.gpa(), x.io(), x.init.environ_map, x.cat)) orelse return error.NotFound;
        defer x.gpa().free(path);
        if (!std.mem.eql(u8, path, x.found)) return error.Unstable;
    }
}

fn findMiss(x: *Context, units: u64) !void {
    for (0..units) |_| if (try conduit.findProgram(x.gpa(), x.io(), x.init.environ_map, missing_program)) |path| {
        x.gpa().free(path);
        return error.Found;
    };
}

// ----------------------------------------------------------------- environ

const environ_changes: []const conduit.environ.Override = &.{
    .{ .name = "TERM", .value = "xterm-256color" },
    .{ .name = "CONDUIT_BENCH_UNSET", .value = null },
};
const environ_only: []const conduit.environ.Override = &.{
    .{ .name = "PATH", .value = "/usr/bin:/bin" },
    .{ .name = "HOME", .value = "/nonexistent" },
    .{ .name = "TERM", .value = "xterm-256color" },
};

/// How many variables the inheriting map has, for every later one to agree
/// with.
fn environSetup(x: *Context) !void {
    var probe = try conduit.environ.inherit(x.gpa(), environ_changes);
    x.inherited = probe.count();
    probe.deinit();
}

fn environInherit(x: *Context, units: u64) !void {
    for (0..units) |_| {
        var map = try conduit.environ.inherit(x.gpa(), environ_changes);
        defer map.deinit();
        if (map.count() != x.inherited) return error.Unstable;
    }
}

fn environOnly(x: *Context, units: u64) !void {
    for (0..units) |_| {
        var map = try conduit.environ.only(x.gpa(), environ_only);
        defer map.deinit();
        if (map.count() != 3) return error.Unstable;
    }
}

// -------------------------------------------------------- process identity

/// A child that sleeps, and when it started.
fn identitySetup(x: *Context) !void {
    try sleeperSetup(x);
    errdefer x.release();
    x.pid = x.child.processId().?;
    x.started = (try conduit.startTime(x.pid)) orelse return error.NoStartTime;
}

fn identityExists(x: *Context, units: u64) !void {
    for (0..units) |_| if (!(conduit.processExists(x.pid) orelse false)) return error.Gone;
}

fn identityStartTime(x: *Context, units: u64) !void {
    for (0..units) |_| if ((try conduit.startTime(x.pid)) != x.started) return error.Unstable;
}

fn identityCapture(x: *Context, units: u64) !void {
    for (0..units) |_| {
        var captured = (try conduit.captureStarted(x.pid, x.started)) orelse return error.NotCaptured;
        captured.deinit();
    }
}

// ------------------------------------------------------------------ signal

/// Signals `conduit-bench signal_child`, this program run again, or the
/// program `BENCH_SIGNAL_CHILD` names, which speaks the same way: it says `x`
/// for each `SIGUSR1`, taken with `sigwait` so that none is lost between two
/// answers, and its one descendant ignores the signal and says `r` once both
/// are set.
fn signalSetup(x: *Context) !void {
    const io = x.io();
    const signal_child = x.init.environ_map.get("BENCH_SIGNAL_CHILD") orelse
        x.signal_path[0..try std.process.executablePath(io, &x.signal_path)];
    try x.spawn(.{
        .argv = &.{ signal_child, "signal_child" },
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
        .detach = true,
    });
    errdefer x.release();
    x.signal_out = x.child.stdoutFile().?.handle;
    try readExact(x.signal_out, "r\n");
}

fn signal(x: *Context, units: u64) !void {
    for (0..units) |_| {
        try x.child.kill(x.io(), .user1);
        try readExact(x.signal_out, "x\n");
    }
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
const extra_fds_script = "echo x >&3";

/// A pipe made, `sh` started with its write end at descriptor 3, what it wrote
/// there read to the end, and the child reaped.
fn extraFds(x: *Context, units: u64) !void {
    const io = x.io();
    for (0..units) |_| {
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
        if (!std.mem.eql(u8, buffer[0..got], "x\n")) return error.BadOutput;
    }
}

// --------------------------------------------------------------- wait tree

/// Whether `waitTree` can be asked here: only a Linux child's cgroup has the
/// operation, and only where this process may make one. Windows has the job
/// object instead.
pub fn waitTreeAvailable(x: *Context) !bool {
    if (comptime builtin.target.os.tag != .linux) return false;
    try x.spawn(.{ .argv = &.{x.true_}, .stdio = .ignore });
    defer x.release();
    if (!conduit.succeeded(try x.wait())) return error.ChildFailed;
    _ = x.child.waitTree(x.io(), conduit.Deadline.within(.fromSeconds(1))) catch |err| switch (err) {
        error.Unsupported => return false,
        else => return err,
    };
    return true;
}

/// A Linux child that has ended: the answer is there at once, and what is
/// timed is asking for it.
fn waitTreeSetup(x: *Context) !void {
    try x.spawn(.{ .argv = &.{x.true_}, .stdio = .ignore });
    errdefer x.release();
    if (!conduit.succeeded(try x.wait())) return error.ChildFailed;
}

fn waitTree(x: *Context, units: u64) !void {
    try single(units);
    if (!try x.child.waitTree(x.io(), conduit.Deadline.within(.fromSeconds(1)))) return error.TreeRemained;
}
