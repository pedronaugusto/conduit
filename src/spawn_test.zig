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

/// Reads a file to the end into an owned slice, so a test can assert on what a
/// child wrote.
fn drain(file: std.Io.File) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buffer: [512]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            // A pseudo-terminal master whose slave is gone reports this on
            // Linux where a pipe reports end of file.
            error.EndOfStream, error.InputOutput => break,
            else => return err,
        };
        if (n == 0) break;
        try out.appendSlice(gpa, buffer[0..n]);
    }
    return out.toOwnedSlice(gpa);
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

    try std.testing.expectEqual(Child.Term{ .exited = 3 }, try child.wait(io));
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
    try std.testing.expectEqual(Child.Term{ .exited = 0 }, try child.wait(io));
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

    try std.testing.expectEqual(Child.Term{ .exited = 0 }, try child.wait(io));
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

    var buffer: [256]u8 = undefined;
    var reader = master.readerStreaming(io, &buffer);
    try std.testing.expectEqualStrings("30 100", try line(&reader.interface));

    try pty.resize(.{ .rows = 41, .cols = 121 });
    try master.writeStreamingAll(io, "\n");

    // The terminal echoes the newline just written, so the next non-empty line
    // is the one the resize produced.
    try std.testing.expectEqualStrings("41 121", try line(&reader.interface));

    try std.testing.expectEqual(Child.Term{ .exited = 0 }, try child.wait(io));
}

/// The next non-empty line, without the carriage return a terminal puts before
/// every newline.
fn line(reader: *std.Io.Reader) ![]const u8 {
    while (true) {
        const raw = (try reader.takeDelimiter('\n')) orelse return error.EndOfStream;
        const trimmed = std.mem.trimEnd(u8, raw, "\r");
        if (trimmed.len != 0) return trimmed;
    }
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
    // into a signal is the line discipline's job, and it only has a process
    // group to send it to because the child claimed the pair as its
    // controlling terminal.
    try pty.masterFile().writeStreamingAll(io, "\x03");

    try std.testing.expectEqual(Child.Term{ .signal = .INT }, try child.wait(io));
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
    // Reaped once: the second call answers from what the first learned.
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

    try std.testing.expectEqual(Child.Term{ .exited = 7 }, try child.wait(io));
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

    // The wait is on another task, so the result arrives when it arrives.
    const term = while (true) {
        if (reaper.exit()) |term| break term;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    };
    try std.testing.expectEqual(Child.Term{ .exited = 5 }, term);
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
    try std.testing.expectEqual(Child.Term{ .exited = 0 }, try child.wait(io));

    var buffer: [64]u8 = undefined;
    const n = try pipe_pty.masterFile().readStreaming(io, &.{&buffer});
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
    try std.testing.expectEqual(Child.Term{ .exited = 0 }, try child.wait(io));
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
