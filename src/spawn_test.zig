//! What this package claims about spawning, exercised against `/bin/sh`.
//!
//! Every test reaps its child, and every test that could leave one behind does
//! so in a `defer`. A test that leaks a process is worse than a test that
//! fails: it survives the run.

const std = @import("std");
const posix = std.posix;

const zpty = @import("zpty.zig");
const Child = zpty.Child;
const Pty = zpty.Pty;

const io = std.testing.io;
const gpa = std.testing.allocator;

/// `getpgid` is not declared in `std.c`, and two of these tests are about
/// exactly what it reports.
extern "c" fn getpgid(pid: posix.pid_t) posix.pid_t;

/// How long any one test will wait for a child to say or do something before
/// it gives up. Generous, because it is a failure budget and not a timing
/// assertion: nothing here should come near it.
const budget_ms = 5000;

/// Reads whatever is available, waiting at most `budget_ms` for the first
/// byte. Zero means end of stream.
///
/// Every read in this file goes through here. A test that blocks forever on a
/// child that never speaks is worse than a failing test: it stops the run
/// instead of reporting anything.
fn readWithin(file: std.Io.File, buffer: []u8) !usize {
    var fds = [_]posix.pollfd{.{
        .fd = file.handle,
        .events = posix.POLL.IN,
        .revents = 0,
    }};
    if (try posix.poll(&fds, budget_ms) == 0) return error.TestChildSaidNothing;
    return file.readStreaming(io, &.{buffer}) catch |err| switch (err) {
        // A pseudo-terminal master whose slave is gone reports this on Linux
        // where a pipe reports end of stream.
        error.EndOfStream, error.InputOutput => 0,
        else => err,
    };
}

/// Reads a file to the end into an owned slice, so a test can assert on what a
/// child wrote.
fn drain(file: std.Io.File) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buffer: [512]u8 = undefined;
    while (true) {
        const n = try readWithin(file, &buffer);
        if (n == 0) break;
        try out.appendSlice(gpa, buffer[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

/// Waits for the child to end, and kills it if it will not within
/// `budget_ms`.
///
/// This is what every test uses instead of `Child.wait`: a wait that cannot
/// outlast the test, so a child that misbehaves produces a failure rather than
/// a run that never finishes.
fn waitWithin(child: *Child) !Child.Term {
    var waited: u32 = 0;
    while (true) {
        if (try child.tryWait()) |term| return term;
        if (waited >= budget_ms) break;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
        waited += 2;
    }
    _ = child.killWait(io, 0) catch {};
    return error.TestChildDidNotExit;
}

/// Asserts that the next non-empty line the terminal produces is `want`.
///
/// `pending` carries the bytes read past the end of one line into the next
/// call. The carriage return a terminal puts before every newline is trimmed,
/// and empty lines -- the echo of a newline written to the master -- are
/// skipped.
fn expectLine(master: std.Io.File, pending: *std.ArrayList(u8), want: []const u8) !void {
    while (true) {
        if (std.mem.indexOfScalar(u8, pending.items, '\n')) |newline| {
            const line = std.mem.trimEnd(u8, pending.items[0..newline], "\r");
            if (line.len == 0) {
                try pending.replaceRange(gpa, 0, newline + 1, &.{});
                continue;
            }
            defer pending.replaceRange(gpa, 0, newline + 1, &.{}) catch {};
            return std.testing.expectEqualStrings(want, line);
        }
        var buffer: [256]u8 = undefined;
        const n = try readWithin(master, &buffer);
        if (n == 0) return error.TestChildSaidNothing;
        try pending.appendSlice(gpa, buffer[0..n]);
    }
}

test "a child on pipes: its output is captured and its exit code is seen" {
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'hello from the child'; exit 3" },
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    const output = try drain(child.stdout.?);
    defer gpa.free(output);
    try std.testing.expectEqualStrings("hello from the child", output);

    try std.testing.expectEqual(Child.Term{ .exited = 3 }, try waitWithin(&child));
}

test "a child on pipes can be written to" {
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "read line; printf '%s' \"$line\"" },
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    try child.stdin.?.writeStreamingAll(io, "a line\n");
    child.stdin.?.close(io);
    child.stdin = null;

    const output = try drain(child.stdout.?);
    defer gpa.free(output);
    try std.testing.expectEqualStrings("a line", output);
    try std.testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
}

test "a child on a pty sees a terminal" {
    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "test -t 0 && test -t 1 && test -t 2" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    try std.testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
}

test "a child on a pty reports the window size it was given, and the one it is resized to" {
    var pty = try Pty.open(.{ .rows = 30, .cols = 100 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        // Reports the size, waits for a byte, and reports it again: the second
        // report is taken after the resize below.
        .argv = &.{ "/bin/sh", "-c", "stty size; read ignored; stty size" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    const master = pty.masterFile();
    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);

    try expectLine(master, &pending, "30 100");

    try pty.resize(.{ .rows = 41, .cols = 121 });
    try master.writeStreamingAll(io, "\n");

    try expectLine(master, &pending, "41 121");

    try std.testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
}

test "Ctrl-C written to the master reaches a detached pty child as SIGINT" {
    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    // `exec` so the shell is replaced and the signal has one process to reach.
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 100" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    // The interrupt character of a terminal in its default mode. Turning it
    // into a signal is the line discipline's job, and it has a process group
    // to send it to only because the child claimed the pair as its controlling
    // terminal.
    try pty.masterFile().writeStreamingAll(io, "\x03");

    try std.testing.expectEqual(Child.Term{ .signal = .INT }, try waitWithin(&child));
}

test "the same Ctrl-C does not reach a child that has no controlling terminal" {
    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 100" },
        .stdio = .{ .pty = &pty },
        .detach = false,
    });
    defer child.deinit(io);
    pty.closeSlave(io);

    try pty.masterFile().writeStreamingAll(io, "\x03");

    // There is no foreground process group on this terminal, so the byte is
    // just a byte. The child is still there; `killWait` is what ends it.
    try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    try std.testing.expectEqual(@as(?Child.Term, null), try child.tryWait());
    try std.testing.expectEqual(Child.Term{ .signal = .TERM }, try child.killWait(io, 500));
}

test "killWait ends a child that would otherwise outlive the test, and says how" {
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 100" },
        .stdio = .ignore,
        .detach = true,
    });
    defer child.deinit(io);

    const term = try child.killWait(io, 200);
    try std.testing.expectEqual(Child.Term{ .signal = .TERM }, term);
    // Reaped once: `wait` answers from what `killWait` learned, and so cannot
    // block here.
    try std.testing.expectEqual(term, try child.wait(io));
}

test "killWait with no grace goes straight to SIGKILL" {
    var child = try Child.spawn(io, gpa, .{
        // Ignoring SIGTERM is exactly what the grace period is for; with no
        // grace there is nothing to ignore.
        .argv = &.{ "/bin/sh", "-c", "trap '' TERM; sleep 100" },
        .stdio = .ignore,
        .detach = true,
    });
    defer child.deinit(io);

    try std.testing.expectEqual(Child.Term{ .signal = .KILL }, try child.killWait(io, 0));
}

test "a detached child is in its own process group" {
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 100" },
        .stdio = .ignore,
        .detach = true,
    });
    defer child.deinit(io);
    defer _ = child.killWait(io, 0) catch {};

    try std.testing.expectEqual(child.pid, child.pgid.?);
    try std.testing.expectEqual(child.pid, getpgid(child.pid));

    // Which is the point of it: a signal to this process's group, the one a
    // terminal sends on Ctrl-C, does not reach the child.
    try std.testing.expect(getpgid(0) != child.pid);
}

test "an attached child shares the parent's process group" {
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 100" },
        .stdio = .ignore,
        .detach = false,
    });
    defer child.deinit(io);
    defer _ = child.killWait(io, 0) catch {};

    try std.testing.expectEqual(@as(?posix.pid_t, null), child.pgid);
    try std.testing.expectEqual(getpgid(0), getpgid(child.pid));
}

test "tryWait is null while the child runs and a term once it has ended" {
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "read line; exit 7" },
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    try std.testing.expectEqual(@as(?Child.Term, null), try child.tryWait());

    // Closing its standard input ends the `read`, and with it the shell.
    child.stdin.?.close(io);
    child.stdin = null;

    try std.testing.expectEqual(Child.Term{ .exited = 7 }, try waitWithin(&child));
    try std.testing.expectEqual(Child.Term{ .exited = 7 }, (try child.tryWait()).?);
}

test "Reaper.exit becomes non-null once the child has ended" {
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "read line; exit 5" },
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer child.deinit(io);

    var reaper: zpty.Reaper = .init(&child);
    try reaper.start(io);
    defer reaper.deinit(io);

    try std.testing.expectEqual(@as(?Child.Term, null), reaper.exit());

    child.stdin.?.close(io);
    child.stdin = null;

    // The wait is on another task, so the result arrives when it arrives --
    // but not later than the budget every other wait in this file obeys.
    var waited: u32 = 0;
    const term = while (waited < budget_ms) : (waited += 1) {
        if (reaper.exit()) |term| break term;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    } else return error.TestChildDidNotExit;
    try std.testing.expectEqual(Child.Term{ .exited = 5 }, term);
    // The reaper's task did the reaping, so this answers from the same term.
    try std.testing.expectEqual(term, try child.wait(io));
}

test "stderr_to sends the child's standard error to a file of the caller's" {
    var pipe_pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pipe_pty.close(io);

    // Any writable file will do; a pseudo-terminal is the one this package can
    // open without touching the filesystem.
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'to stderr' 1>&2" },
        .stdio = .{ .pipes = .{ .stdin = false } },
        .stderr_to = pipe_pty.slaveFile(),
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    // The stderr pipe was not created, because the file replaced it.
    try std.testing.expectEqual(@as(?std.Io.File, null), child.stderr);
    try std.testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));

    var buffer: [64]u8 = undefined;
    const n = try readWithin(pipe_pty.masterFile(), &buffer);
    try std.testing.expectEqualStrings("to stderr", buffer[0..n]);
}

test "the child's environment and working directory are the ones asked for" {
    var environ: std.process.Environ.Map = .init(gpa);
    defer environ.deinit();
    try environ.put("ZPTY_TEST_VALUE", "present");
    try environ.put("PATH", "/usr/bin:/bin");

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "sh", "-c", "printf '%s %s' \"$ZPTY_TEST_VALUE\" \"$PWD\"" },
        .cwd = "/tmp",
        .environ = &environ,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    const output = try drain(child.stdout.?);
    defer gpa.free(output);
    try std.testing.expect(std.mem.startsWith(u8, output, "present /"));
    try std.testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
}

test "a program that is not there is an error, not a child that exits 127" {
    try std.testing.expectError(error.FileNotFound, Child.spawn(io, gpa, .{
        .argv = &.{"zpty-no-such-program-anywhere"},
        .stdio = .ignore,
    }));
    try std.testing.expectError(error.FileNotFound, Child.spawn(io, gpa, .{
        .argv = &.{"/nonexistent/zpty-no-such-program"},
        .stdio = .ignore,
    }));
    try std.testing.expectError(error.BadWorkingDirectory, Child.spawn(io, gpa, .{
        .argv = &.{"/bin/sh"},
        .cwd = "/nonexistent/zpty-no-such-directory",
        .stdio = .ignore,
    }));
    try std.testing.expectError(error.InvalidArgv, Child.spawn(io, gpa, .{
        .argv = &.{},
        .stdio = .ignore,
    }));
}
