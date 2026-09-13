//! What this package claims about spawning, exercised against the system
//! shell.
//!
//! Every test reaps its child, and every test that could leave one behind does
//! so in a `defer`. A test that leaks a process is worse than a test that
//! fails: it survives the run.
//!
//! Nothing here blocks without a budget. Every read goes through `Sink`, which
//! reads on a task of its own and is cancelled when the test ends, and every
//! wait goes through `waitWithin` or through `Child.output`'s own timeout. A
//! test that hangs stops the whole run and reports nothing, which is the one
//! failure mode worth designing against.
//!
//! # One body, two systems
//!
//! The bodies below are the same on POSIX and on Windows wherever the claim
//! is. What differs is only the words that make a shell do a thing, and those
//! are all in `script`. Where a claim itself is POSIX-only — a controlling
//! terminal, a process group id, `SIGINT` — the test says so and skips.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;

const zpty = @import("zpty.zig");
const Child = zpty.Child;
const Pty = zpty.Pty;

const io = std.testing.io;
const gpa = std.testing.allocator;
const testing = std.testing;

const is_windows = builtin.os.tag == .windows;

/// How long any one test will wait for a child to say or do something before
/// it gives up. Generous, because it is a failure budget and not a timing
/// assertion: nothing here should come near it.
const budget_ms = 5000;

/// The shell each system has, and the scripts these tests need from it.
///
/// `cmd.exe` expands `%name%` when it parses a line, so a variable a line sets
/// and then reads needs delayed expansion (`/v:on` and `!name!`); that is the
/// only thing in here that is not obvious.
const script = if (is_windows) struct {
    const greeting = [_][]const u8{ "cmd.exe", "/c", "echo hello from the child& exit 3" };
    const echo_stdin = [_][]const u8{ "cmd.exe", "/v:on", "/c", "set /p line=& echo !line!" };
    const read_then_exit_7 = [_][]const u8{ "cmd.exe", "/c", "set /p line=& exit 7" };
    const read_then_exit_5 = [_][]const u8{ "cmd.exe", "/c", "set /p line=& exit 5" };
    const say_on_terminal = [_][]const u8{ "cmd.exe", "/c", "echo on the terminal" };
    const sleep_forever = [_][]const u8{ "ping.exe", "-n", "101", "127.0.0.1" };
    const report_environment = [_][]const u8{ "cmd.exe", "/c", "echo %ZPTY_TEST_VALUE% %CD%" };
    const working_directory = "C:\\Windows";
    const working_directory_mark = "Windows";
    const shell_arguments = [_][]const u8{ "/c", "echo hi" };
} else struct {
    const greeting = [_][]const u8{ "/bin/sh", "-c", "printf 'hello from the child'; exit 3" };
    const echo_stdin = [_][]const u8{ "/bin/sh", "-c", "read line; printf '%s' \"$line\"" };
    const read_then_exit_7 = [_][]const u8{ "/bin/sh", "-c", "read line; exit 7" };
    const read_then_exit_5 = [_][]const u8{ "/bin/sh", "-c", "read line; exit 5" };
    const say_on_terminal = [_][]const u8{ "/bin/sh", "-c", "printf 'on the terminal\\n'" };
    const sleep_forever = [_][]const u8{ "/bin/sh", "-c", "sleep 100" };
    const report_environment = [_][]const u8{ "sh", "-c", "printf '%s %s' \"$ZPTY_TEST_VALUE\" \"$PWD\"" };
    const working_directory = "/tmp";
    const working_directory_mark = "/tmp";
    const shell_arguments = [_][]const u8{ "-c", "printf 'hi'" };
};

//======================================================================
// Bounded reading.
//======================================================================

/// Everything a file has produced so far, read on a task of its own.
///
/// `std.posix.poll` is not available on Windows for these handles, and a plain
/// read would block past the end of the test, so this is how every test here
/// waits for bytes: start the task, ask `contains` until the budget runs out,
/// cancel on the way out.
const Sink = struct {
    mutex: std.Io.Mutex = .init,
    bytes: std.ArrayList(u8) = .empty,
    group: std.Io.Group = .init,

    fn start(sink: *Sink, file: std.Io.File) !void {
        try sink.group.concurrent(io, read, .{ sink, file });
    }

    fn deinit(sink: *Sink) void {
        sink.group.cancel(io);
        sink.bytes.deinit(gpa);
    }

    fn read(sink: *Sink, file: std.Io.File) std.Io.Cancelable!void {
        var buffer: [512]u8 = undefined;
        while (true) {
            const n = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                // A pseudo-terminal whose child is gone reports an I/O error
                // where a pipe reports end of stream.
                else => return,
            };
            if (n == 0) return;
            sink.mutex.lockUncancelable(io);
            defer sink.mutex.unlock(io);
            sink.bytes.appendSlice(gpa, buffer[0..n]) catch return;
        }
    }

    fn contains(sink: *Sink, needle: []const u8) bool {
        sink.mutex.lockUncancelable(io);
        defer sink.mutex.unlock(io);
        return std.mem.indexOf(u8, sink.bytes.items, needle) != null;
    }

    /// Waits for `needle` to arrive, and fails the test if it does not.
    fn expect(sink: *Sink, needle: []const u8) !void {
        var waited_ms: u32 = 0;
        while (waited_ms < budget_ms) : (waited_ms += 2) {
            if (sink.contains(needle)) return;
            try std.Io.sleep(io, .fromMilliseconds(2), .awake);
        }
        return error.TestChildSaidNothing;
    }
};

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

/// How a child that was killed reports it.
///
/// POSIX says which signal ended it. Windows has no such notion: a terminated
/// process reports the exit code it was terminated with, and this package uses
/// 1.
fn expectKilled(term: Child.Term, signal: posix.SIG) !void {
    if (is_windows) return testing.expectEqual(Child.Term{ .exited = 1 }, term);
    return testing.expectEqual(Child.Term{ .signal = signal }, term);
}

//======================================================================
// Pipes.
//======================================================================

test "a child on pipes: its output is collected and its exit code is seen" {
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.greeting,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, result.stdout, "hello from the child") != null);
    try testing.expect(!result.stdout_truncated);
    try testing.expect(!result.timed_out);
    try testing.expectEqual(Child.Term{ .exited = 3 }, result.term);
}

test "a child on pipes can be written to" {
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.echo_stdin,
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    try child.stdin.?.writeStreamingAll(io, "a line\n");
    child.stdin.?.close(io);
    child.stdin = null;

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, result.stdout, "a line") != null);
    try testing.expectEqual(Child.Term{ .exited = 0 }, result.term);
}

test "output stops at max_bytes and says it did" {
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.greeting,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .max_bytes = 5, .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expectEqualStrings("hello", result.stdout);
    try testing.expect(result.stdout_truncated);
    // Capped, not cut short: the child still ran to the end and its status is
    // the real one.
    try testing.expectEqual(Child.Term{ .exited = 3 }, result.term);
}

test "output gives up on a child that will not end, and ends it" {
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .{ .pipes = .{ .stdin = false } },
    });
    defer child.deinit(io);

    var result = try child.output(io, gpa, .{ .timeout_ms = 50, .grace_ms = 50 });
    defer result.deinit(gpa);

    try testing.expect(result.timed_out);
    // Reaped by `output`, so this cannot block.
    try testing.expect((try child.tryWait()) != null);
}

test "tryWait is null while the child runs and a term once it has ended" {
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.read_then_exit_7,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    try testing.expectEqual(@as(?Child.Term, null), try child.tryWait());

    // Closing its standard input ends the read, and with it the shell.
    child.stdin.?.close(io);
    child.stdin = null;

    try testing.expectEqual(Child.Term{ .exited = 7 }, try waitWithin(&child));
    try testing.expectEqual(Child.Term{ .exited = 7 }, (try child.tryWait()).?);
}

test "Reaper.exit becomes non-null once the child has ended" {
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.read_then_exit_5,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer child.deinit(io);

    var reaper: zpty.Reaper = .init(&child);
    try reaper.start(io);
    defer reaper.deinit(io);

    try testing.expectEqual(@as(?Child.Term, null), reaper.exit());

    child.stdin.?.close(io);
    child.stdin = null;

    // The wait is on another task, so the result arrives when it arrives --
    // but not later than the budget every other wait in this file obeys.
    var waited: u32 = 0;
    const term = while (waited < budget_ms) : (waited += 1) {
        if (reaper.exit()) |term| break term;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    } else return error.TestChildDidNotExit;
    try testing.expectEqual(Child.Term{ .exited = 5 }, term);
    // The reaper's task did the reaping, so this answers from the same term.
    try testing.expectEqual(term, try child.wait(io));
}

test "stdinWriter and stdoutReader find the child's streams wherever they are" {
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.echo_stdin,
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    var write_buffer: [64]u8 = undefined;
    var writer = child.stdinWriter(io, &write_buffer).?;
    try writer.interface.writeAll("a line\n");
    try writer.interface.flush();
    child.stdin.?.close(io);
    child.stdin = null;

    // The same file the reader would come from, so the two agree.
    try testing.expectEqual(child.stdout.?.handle, child.stdoutFile().?.handle);

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "a line") != null);
}

//======================================================================
// Killing, waiting, groups.
//======================================================================

test "killWait ends a child that would otherwise outlive the test, and says how" {
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = true,
    });
    defer child.deinit(io);

    const term = try child.killWait(io, 200);
    try expectKilled(term, .TERM);
    // Reaped once: `wait` answers from what `killWait` learned, and so cannot
    // block here.
    try testing.expectEqual(term, try child.wait(io));
}

test "a detached child has a process group of its own and an attached one does not" {
    var detached = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = true,
    });
    defer detached.deinit(io);
    defer _ = detached.killWait(io, 0) catch {};
    try testing.expect(detached.pgid != null);

    var attached = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = false,
    });
    defer attached.deinit(io);
    defer _ = attached.killWait(io, 0) catch {};
    try testing.expectEqual(@as(?Child.ProcessGroupId, null), attached.pgid);
}

test "a detached child's process group is the one the operating system reports" {
    // POSIX only: Windows has no `getpgid`, and the group a
    // `CREATE_NEW_PROCESS_GROUP` child is in is not something a parent can
    // read back.
    if (is_windows) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = true,
    });
    defer child.deinit(io);
    defer _ = child.killWait(io, 0) catch {};

    try testing.expectEqual(child.id, child.pgid.?);
    try testing.expectEqual(child.id, getpgid(child.id));
    // Which is the point of it: a signal to this process's group, the one a
    // terminal sends on Ctrl-C, does not reach the child.
    try testing.expect(getpgid(0) != child.id);
}

test "an attached child shares the parent's process group" {
    if (is_windows) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = false,
    });
    defer child.deinit(io);
    defer _ = child.killWait(io, 0) catch {};

    try testing.expectEqual(getpgid(0), getpgid(child.id));
}

test "killWait with no grace goes straight to the signal nothing survives" {
    // POSIX only: the claim is about a child that ignores the polite request,
    // and Windows has no polite request for a process to ignore.
    if (is_windows) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "trap '' TERM; sleep 100" },
        .stdio = .ignore,
        .detach = true,
    });
    defer child.deinit(io);

    try testing.expectEqual(Child.Term{ .signal = .KILL }, try child.killWait(io, 0));
}

//======================================================================
// Pseudo-terminals.
//======================================================================

test "what a child writes to its terminal reaches the master" {
    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.say_on_terminal,
        .stdio = .{ .pty = &pty },
        .detach = !is_windows,
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};
    // The one place the two systems want different timing, and the reason
    // `Pty.closeSlave` documents it at length.
    if (!is_windows) pty.closeSlave(io);

    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(pty.readFile());

    try sink.expect("on the terminal");
    _ = try child.killWait(io, budget_ms);
}

test "a child on a pty sees a terminal" {
    // POSIX only: `cmd.exe` has no way to ask, and on Windows the answer is
    // structural anyway -- a pseudoconsole client is attached to a console by
    // construction.
    if (is_windows) return error.SkipZigTest;

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

    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
}

test "a child on a pty reports the window size it was given, and the one it is resized to" {
    // POSIX only: this asks the child what size its terminal is, and `stty` is
    // how a shell asks. Windows has no equivalent a `cmd.exe` one-liner can
    // print; that a pseudoconsole takes the new size is `Pty`'s own test.
    if (is_windows) return error.SkipZigTest;

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

    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(pty.readFile());

    try sink.expect("30 100");

    try pty.resize(.{ .rows = 41, .cols = 121 });
    try pty.writeFile().writeStreamingAll(io, "\n");

    try sink.expect("41 121");
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
}

test "Ctrl-C written to the master reaches a detached pty child as SIGINT" {
    // POSIX only: the claim is that a line discipline turns a byte into a
    // signal for a foreground process group, and neither half of that sentence
    // has a Windows counterpart.
    if (is_windows) return error.SkipZigTest;

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
    try pty.writeFile().writeStreamingAll(io, "\x03");

    try testing.expectEqual(Child.Term{ .signal = .INT }, try waitWithin(&child));
}

test "the same Ctrl-C does not reach a child that has no controlling terminal" {
    if (is_windows) return error.SkipZigTest;

    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 100" },
        .stdio = .{ .pty = &pty },
        .detach = false,
    });
    defer child.deinit(io);
    pty.closeSlave(io);

    try pty.writeFile().writeStreamingAll(io, "\x03");

    // There is no foreground process group on this terminal, so the byte is
    // just a byte. The child is still there; `killWait` is what ends it.
    try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    try testing.expectEqual(@as(?Child.Term, null), try child.tryWait());
    try testing.expectEqual(Child.Term{ .signal = .TERM }, try child.killWait(io, 500));
}

test "stderr_to sends the child's standard error to a file of the caller's" {
    // POSIX only, for want of a fixture rather than for want of the feature:
    // the sink here is the terminal end of a second pair, which is the one
    // writable file this package can open without touching the filesystem, and
    // a pseudoconsole is not a file.
    if (is_windows) return error.SkipZigTest;

    var sink_pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer sink_pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'to stderr' 1>&2" },
        .stdio = .{ .pipes = .{ .stdin = false } },
        .stderr_to = sink_pty.slaveFile(),
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    // The stderr pipe was not created, because the file replaced it.
    try testing.expectEqual(@as(?std.Io.File, null), child.stderr);

    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(sink_pty.readFile());

    try sink.expect("to stderr");
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
}

//======================================================================
// Environment, working directory, and failure.
//======================================================================

test "the child's environment and working directory are the ones asked for" {
    var environ = try zpty.environ.inherit(gpa, &.{
        .{ .name = "ZPTY_TEST_VALUE", .value = "present" },
    });
    defer environ.deinit();

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.report_environment,
        .cwd = script.working_directory,
        .environ = &environ,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, result.stdout, "present") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, script.working_directory_mark) != null);
    try testing.expectEqual(Child.Term{ .exited = 0 }, result.term);
}

test "a program that is not there is an error, not a child that exits 127" {
    try testing.expectError(error.FileNotFound, Child.spawn(io, gpa, .{
        .argv = &.{"zpty-no-such-program-anywhere"},
        .stdio = .ignore,
    }));
    try testing.expectError(error.InvalidArgv, Child.spawn(io, gpa, .{
        .argv = &.{},
        .stdio = .ignore,
    }));
}

test "a working directory that is not there is an error" {
    const missing = if (is_windows)
        "C:\\zpty-no-such-directory\\at-all"
    else
        "/nonexistent/zpty-no-such-directory";
    try testing.expectError(error.BadWorkingDirectory, Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .cwd = missing,
        .stdio = .ignore,
    }));
}

test "a program at a path that is not there is an error" {
    // Windows resolves the program from the command line, and a path with no
    // such file is `ERROR_FILE_NOT_FOUND` all the same; the POSIX side goes
    // through a different branch of the search, which is why both are here.
    const missing = if (is_windows)
        "C:\\zpty-no-such-directory\\program.exe"
    else
        "/nonexistent/zpty-no-such-program";
    try testing.expectError(error.FileNotFound, Child.spawn(io, gpa, .{
        .argv = &.{missing},
        .stdio = .ignore,
    }));
}

test "a batch file is refused rather than handed to cmd.exe" {
    if (!is_windows) return error.SkipZigTest;
    try testing.expectError(error.UnsupportedBatchFile, Child.spawn(io, gpa, .{
        .argv = &.{ "C:\\zpty-no-such-script.bat", "arg" },
        .stdio = .ignore,
    }));
}

//======================================================================
// The shell.
//======================================================================

test "spawnShell starts the user's shell on a pair" {
    var shell = try zpty.spawnShell(io, gpa, .{
        .args = &script.shell_arguments,
        .size = .{ .rows = 40, .cols = 132 },
    });
    defer shell.deinit(io);

    try testing.expectEqual(@as(u16, 40), (try shell.pty.size()).rows);

    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(shell.pty.readFile());

    try sink.expect("hi");
    _ = try shell.child.killWait(io, budget_ms);
}

/// `getpgid` is not declared in `std.c`, and two of the tests above are about
/// exactly what it reports. Never referenced on Windows, where those tests
/// skip, so the declaration costs nothing there.
extern "c" fn getpgid(pid: posix.pid_t) posix.pid_t;
