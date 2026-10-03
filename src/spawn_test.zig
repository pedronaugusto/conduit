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
const State = @import("child_state.zig");
const posix = std.posix;
const c = std.c;

const conduit = @import("conduit.zig");
const Child = conduit.Child;
const Deadline = @import("deadline.zig").Deadline;
const Pty = conduit.Pty;
const handles = @import("handles.zig");
const wait_for = if (is_windows) struct {} else @import("wait.zig");
const tree = if (is_windows) struct {} else @import("tree.zig");
const cgroup = if (is_windows) struct {} else @import("cgroup.zig");
const trace = @import("trace.zig");
const Watchdog = @import("test_support.zig").Watchdog;

const io = std.testing.io;
const gpa = std.testing.allocator;
const testing = std.testing;

const is_windows = builtin.os.tag == .windows;
const win32 = if (is_windows) @import("win32.zig") else struct {};

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
    // Reads standard input to end of file, rather than to the first line:
    // what a half-close, and only a half-close, finishes.
    const drain_then_exit_7 = [_][]const u8{ "cmd.exe", "/c", "sort > nul & exit 7" };
    const read_then_exit_5 = [_][]const u8{ "cmd.exe", "/c", "set /p line=& exit 5" };
    // Says its piece and then waits, rather than exiting at once: a
    // pseudoconsole is a surface a console host renders onto, and what it
    // sends the master is what that host has got round to drawing. A child
    // that is still there when the parent looks is the case the claim is
    // about, and it is the case a terminal program actually has. `set /p`
    // with no prompt is `cmd.exe` waiting for a line; the test ends it.
    const say_on_terminal = [_][]const u8{ "cmd.exe", "/c", "echo on the terminal& set /p ignored=" };
    const out_and_err = [_][]const u8{ "cmd.exe", "/c", "echo to stdout& echo to stderr 1>&2" };
    const sleep_forever = [_][]const u8{ "ping.exe", "-n", "101", "127.0.0.1" };
    /// Starts a process of its own that outlives it, and says which one.
    ///
    /// A native child creates a descendant in a separate console and prints
    /// its id. No shell launch, no inherited pipe, and both belong to the
    /// child's job. Built only for the test module.
    const detached_grandchild = [_][]const u8{@import("conduit_test_options").tree_fixture};
    /// Writes a cursor-shape sequence to its terminal and stays there.
    ///
    /// `DECSCUSR` is the one a console host that models what passes through it
    /// does not model, so it survives only where passthrough was granted.
    /// `[char]27` is the escape: `cmd.exe` has no way to spell one.
    const cursor_shape = [_][]const u8{
        "powershell.exe",
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "[Console]::Out.Write([char]27 + '[5 q'); Start-Sleep -Seconds 30",
    };
    const report_environment = [_][]const u8{ "cmd.exe", "/c", "echo %CONDUIT_TEST_VALUE% %CD%" };
    const working_directory = "C:\\Windows";
    const working_directory_mark = "Windows";
    const shell_arguments = [_][]const u8{ "/c", "echo hi" };
} else struct {
    const greeting = [_][]const u8{ "/bin/sh", "-c", "printf 'hello from the child'; exit 3" };
    const echo_stdin = [_][]const u8{ "/bin/sh", "-c", "read line; printf '%s' \"$line\"" };
    const read_then_exit_7 = [_][]const u8{ "/bin/sh", "-c", "read line; exit 7" };
    const drain_then_exit_7 = [_][]const u8{ "/bin/sh", "-c", "cat > /dev/null; exit 7" };
    const read_then_exit_5 = [_][]const u8{ "/bin/sh", "-c", "read line; exit 5" };
    const say_on_terminal = [_][]const u8{ "/bin/sh", "-c", "printf 'on the terminal\\n'; read ignored" };
    const out_and_err = [_][]const u8{ "/bin/sh", "-c", "printf 'to stdout'; printf 'to stderr' 1>&2" };
    const sleep_forever = [_][]const u8{ "/bin/sh", "-c", "sleep 100" };
    const report_environment = [_][]const u8{ "sh", "-c", "printf '%s %s' \"$CONDUIT_TEST_VALUE\" \"$PWD\"" };
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
///
/// A sink is declared after whatever owns the file it reads — the `Child`
/// whose pipe it is, the `Pty` whose master — so that its `deinit` runs first.
/// Closing a file under a task that is reading it is a race on the
/// descriptor, and ThreadSanitizer on Linux says so.
const Sink = struct {
    source_io: std.Io = io,
    mutex: std.Io.Mutex = .init,
    bytes: std.ArrayList(u8) = .empty,
    group: std.Io.Group = .init,
    /// Set by `deinit`, read by the task before every read it starts, so a
    /// reader that is between reads when `deinit` begins does not start
    /// another one.
    stopping: std.atomic.Value(bool) = .init(false),
    /// The reading has stopped, for any reason. Atomic and not under `mutex`,
    /// so it can be read without taking anything the task holds.
    finished: std.atomic.Value(bool) = .init(false),
    /// Why the reading stopped, when it stopped for a reason other than the
    /// end. The difference between "the child said nothing" and "nobody was
    /// listening".
    failed: ?anyerror = null,

    fn start(sink: *Sink, file: std.Io.File) !void {
        try sink.group.concurrent(io, read, .{ sink, file });
    }

    /// Stops reading and releases the task.
    ///
    /// The task is blocked in a read that only the far end finishing, the
    /// handle going away, or the task being cancelled will end, and a
    /// pseudoconsole's output pipe has a writer for as long as the console
    /// does. So this cancels, which is the one request the read answers:
    /// `std.Io.Threaded` interrupts it (`NtCancelSynchronousIoFile` on
    /// Windows, a signal on POSIX) and asks again until the task has seen it.
    /// `CancelIoEx` from here would abort the read too, but the read is
    /// issued again at once unless the task itself was cancelled.
    fn deinit(sink: *Sink) void {
        sink.stopping.store(true, .release);
        trace.print("sink: cancelling the reader", .{});
        sink.group.cancel(io);
        trace.print("sink: reader joined", .{});
        sink.bytes.deinit(gpa);
    }

    fn read(sink: *Sink, file: std.Io.File) std.Io.Cancelable!void {
        var buffer: [512]u8 = undefined;
        while (true) {
            if (sink.stopping.load(.acquire)) return sink.stop(null);
            const n = handles.readStreaming(file, sink.source_io, &.{&buffer}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return sink.stop(if (handles.finished(err)) null else err),
            };
            sink.mutex.lockUncancelable(io);
            defer sink.mutex.unlock(io);
            sink.bytes.appendSlice(gpa, buffer[0..n]) catch return;
        }
    }

    /// Records how the reading ended: the end of the stream, or an error.
    ///
    /// The flag is stored last and outside the lock, so `ended` can see it
    /// without taking anything the task holds.
    fn stop(sink: *Sink, err: ?anyerror) void {
        if (err) |e| {
            sink.mutex.lockUncancelable(io);
            defer sink.mutex.unlock(io);
            sink.failed = e;
        }
        sink.finished.store(true, .release);
    }

    /// Whether the reading has stopped, for any reason. A stream nothing is
    /// writing to any more is the shape of "every process that held it is
    /// gone". No lock: see `finished`.
    fn ended(sink: *Sink) bool {
        return sink.finished.load(.acquire);
    }

    fn contains(sink: *Sink, needle: []const u8) bool {
        sink.mutex.lockUncancelable(io);
        defer sink.mutex.unlock(io);
        return std.mem.indexOf(u8, sink.bytes.items, needle) != null;
    }

    /// Waits for `needle` to arrive, and fails the test if it does not.
    ///
    /// A failure prints why the read stopped and what did arrive, because
    /// "nothing that matched" and "nothing at all" are different faults and a
    /// bare error name cannot say which one this was.
    fn expect(sink: *Sink, needle: []const u8) !void {
        if (try sink.containsBefore(needle, .in(io, budget_ms))) return;
        sink.report(needle);
        return error.TestChildSaidNothing;
    }

    /// The same budget can be made before another operation delays this
    /// task; a delayed wake does not grant another full set of sleep steps.
    fn containsBefore(sink: *Sink, needle: []const u8, deadline: Deadline) !bool {
        while (deadline.remainingMs(io) > 0) {
            if (sink.contains(needle)) return true;
            try std.Io.sleep(io, .fromMilliseconds(2), .awake);
        }
        return sink.contains(needle);
    }

    /// What was being waited for, why the reading stopped, and the first of
    /// what did arrive with the unprintable bytes escaped.
    fn report(sink: *Sink, needle: []const u8) void {
        sink.mutex.lockUncancelable(io);
        defer sink.mutex.unlock(io);
        const why: []const u8 = if (sink.failed) |err|
            @errorName(err)
        else if (sink.ended())
            "the end of the stream"
        else
            "nothing -- it is still waiting in a read";
        std.debug.print("\nbudget {d} ms for \"{s}\"; the read stopped with {s}; {d} bytes arrived:\n  ", .{
            budget_ms,
            needle,
            why,
            sink.bytes.items.len,
        });
        for (sink.bytes.items[0..@min(sink.bytes.items.len, 512)]) |byte| {
            if (byte >= ' ' and byte < 0x7f) {
                std.debug.print("{c}", .{byte});
            } else {
                std.debug.print("\\x{x:0>2}", .{byte});
            }
        }
        std.debug.print("\n", .{});
    }
};

test "a test wait uses an already elapsed clock deadline" {
    var sink: Sink = .{};
    defer sink.deinit();
    const deadline: Deadline = .in(io, 1);
    try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    try testing.expect(!try sink.containsBefore("never", deadline));
}

/// Waits for the child to end, and kills it if it will not within
/// `budget_ms`.
///
/// This is what every test uses instead of `Child.wait`: a wait that cannot
/// outlast the test, so a child that misbehaves produces a failure rather than
/// a run that never finishes.
fn waitWithin(child: *Child) !Child.Term {
    const deadline: Deadline = .in(io, budget_ms);
    while (true) {
        if (try child.tryWait()) |term| return term;
        if (deadline.remainingMs(io) == 0) break;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    _ = child.killWait(io, 0) catch {};
    return error.TestChildDidNotExit;
}

/// How a child that `killWait` ended with a grace reports it.
///
/// POSIX names the signal, and for a child that does not catch it that is
/// exactly the one this package sent.
///
/// Windows has no signal to name and, for this path, no number of this
/// package's own either. `.terminate` there is a console control event, so a
/// child that obeys it ends on its own terms and reports whatever status it
/// chose — the system's control-exit status for one that does not handle the
/// event, whose full `NTSTATUS` reaches `Term.exited`. The
/// number this package does choose is the one `.kill` terminates with, and
/// `killWait` with no grace is what asks for it: "succeeded, exitCode and
/// signalName" below is where that 1 is asserted. Here the claim is the one
/// that is true on both systems — the child is gone, and it did not end the
/// way a program that finished its work ends.
fn expectKilled(term: Child.Term, signal: posix.SIG) !void {
    if (is_windows) {
        // An exit code and never a signal, because that notion does not exist
        // there -- and not zero, because the child did not get to finish.
        try testing.expect(conduit.signalName(term) == null);
        try testing.expect(conduit.exitCode(term) != null);
        try testing.expect(!conduit.succeeded(term));
        return;
    }
    return testing.expectEqual(Child.Term{ .signal = signal }, term);
}

//======================================================================
// Pipes.
//======================================================================

test "a child on pipes: its output is collected and its exit code is seen" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.greeting,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, result.stdout(), "hello from the child") != null);
    try testing.expect(!result.stdoutTruncated());
    try testing.expect(!result.timedOut());
    try testing.expectEqual(Child.Term{ .exited = 3 }, result.term());
}

test "a child on pipes can be written to" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.echo_stdin,
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    try child.stdinFile().?.writeStreamingAll(io, "a line\n");
    child.closeStdin(io);

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, result.stdout(), "a line") != null);
    try testing.expectEqual(Child.Term{ .exited = 0 }, result.term());
}

test "output stops at max_bytes and says it did" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.greeting,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .max_bytes = 5, .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expectEqualStrings("hello", result.stdout());
    try testing.expect(result.stdoutTruncated());
    // Capped, not cut short: the child still ran to the end and its status is
    // the real one.
    try testing.expectEqual(Child.Term{ .exited = 3 }, result.term());
}

test "output keeps draining after allocation failure and reports out of memory" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows) return error.SkipZigTest;

    // Much more than a pipe holds: a collector that stops at its first failed
    // allocation leaves this child blocked in write and reaches the timeout.
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "dd if=/dev/zero bs=65536 count=4 2>/dev/null" },
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, child.output(io, failing.allocator(), .{
        .timeout_ms = budget_ms,
    }));
    try testing.expectEqual(Child.Term{ .exited = 0 }, try child.wait(io));
}

test "output ends a silent child when its stream cannot be read" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    child.stdoutFile().?.close(io);
    State.get(&child).stdout.?.handle = -1;
    defer _ = child.takeStdout();
    try testing.expectError(error.ReadFailed, child.output(io, gpa, .{}));
    try testing.expect((try child.tryWait()) != null);
}

test "output gives up on a child that will not end, and ends it" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .{ .pipes = .{ .stdin = false } },
    });
    defer child.release(io) catch unreachable;

    var result = try child.output(io, gpa, .{ .timeout_ms = 50, .grace_ms = 50 });
    defer result.deinit(gpa);

    try testing.expect(result.timedOut());
    // Reaped by `output`, so this cannot block.
    try testing.expect((try child.tryWait()) != null);
}

test "tryWait is null while the child runs and a term once it has ended" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.read_then_exit_7,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    try testing.expectEqual(@as(?Child.Term, null), try child.tryWait());

    // Closing its standard input ends the read, and with it the shell.
    child.closeStdin(io);

    try testing.expectEqual(Child.Term{ .exited = 7 }, try waitWithin(&child));
    try testing.expectEqual(Child.Term{ .exited = 7 }, (try child.tryWait()).?);
}

test "Reaper.exit becomes non-null once the child has ended" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.read_then_exit_5,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer child.release(io) catch unreachable;

    var reaper: conduit.Reaper = .init(&child, .{});
    try reaper.start(io);
    defer reaper.deinit(io) catch unreachable;

    try testing.expectEqual(@as(?Child.Term, null), try reaper.exit());

    child.closeStdin(io);

    // The wait is on another task, so the result arrives when it arrives --
    // but not later than the budget every other wait in this file obeys.
    const deadline: Deadline = .in(io, budget_ms);
    const term = while (deadline.remainingMs(io) > 0) {
        if (try reaper.exit()) |term| break term;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    } else return error.TestChildDidNotExit;
    try testing.expectEqual(Child.Term{ .exited = 5 }, term);
    // The reaper's task did the reaping, so this answers from the same term.
    try testing.expectEqual(term, try child.wait(io));
}

test "a Reaper started after reaping never watches a reused identity" {
    if (is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.read_then_exit_5,
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};
    child.closeStdin(io);
    const term = try waitWithin(&child);

    var witness = try Child.spawn(io, gpa, .{
        .argv = &script.read_then_exit_5,
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
        .detach = true,
    });
    defer witness.release(io) catch unreachable;
    defer _ = witness.killWait(io, 0) catch {};
    // The published term is final. Replace the old numeric labels with a
    // live witness's, as if the OS had reused them: no watch or tree cleanup
    // may use those labels after retirement.
    State.get(&child).id = State.get(&witness).id;
    State.get(&child).pgid = State.get(&witness).pgid;
    var reaper: conduit.Reaper = .init(&child, .{ .end_tree = true });
    try reaper.start(io);
    defer reaper.deinit(io) catch unreachable;
    try testing.expectEqual(@as(?Child.Term, term), try reaper.waitTimeout(io, 20));
    try testing.expectEqual(@as(?Child.Term, null), try witness.tryWait());
}

test "killWait is legal while a Reaper is waiting, and the two share one reap" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    // The sequence the documentation used to forbid and now allows: a wait in
    // flight on a task of its own, `exit` asked and answering null, and then
    // the owner deciding the child has had long enough. Two reaps of one child
    // are one status and one error about a child nobody can account for, so
    // what this asserts is that only one of them happened.
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = true,
    });
    defer child.release(io) catch unreachable;

    var reaper: conduit.Reaper = .init(&child, .{});
    try reaper.start(io);
    defer reaper.deinit(io) catch unreachable;

    // Confirmed running: `exit` is null while the wait is in flight.
    try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    try testing.expectEqual(@as(?Child.Term, null), try reaper.exit());

    // No grace, so this is the shortest form of the sequence: the signal
    // nothing survives, and then a wait -- while another task is already
    // inside one. Two waits on one child are one status and one error about a
    // child nobody can account for.
    const term = try child.killWait(io, 0);
    try testing.expect(!conduit.succeeded(term));

    // The same term, by both routes, and nothing left to reap: a second wait
    // answers from what was published rather than asking the system again.
    const deadline: Deadline = .in(io, budget_ms);
    const reaped = while (deadline.remainingMs(io) > 0) {
        if (try reaper.exit()) |t| break t;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    } else return error.TestChildDidNotExit;
    try testing.expectEqual(term, reaped);
    try testing.expectEqual(term, try child.wait(io));
    try testing.expectEqual(@as(?Child.Term, term), try child.tryWait());
}

test "a wait whose Reaper was cancelled is still a wait" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    // A `Reaper` that is stopped before the child ends leaves the child
    // unreaped, and whoever asked for the wait while it held it has to end up
    // doing the wait itself rather than waiting forever for a publish that is
    // never coming.
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.read_then_exit_5,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    {
        var reaper: conduit.Reaper = .init(&child, .{});
        try reaper.start(io);
        try std.Io.sleep(io, .fromMilliseconds(50), .awake);
        try testing.expectEqual(@as(?Child.Term, null), try reaper.exit());
        reaper.deinit(io) catch unreachable;
    }

    child.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 5 }, try waitWithin(&child));
}

test "Reaper.wait blocks until the child has ended, and answers everyone who asks" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.read_then_exit_5,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var reaper: conduit.Reaper = .init(&child, .{});
    try reaper.start(io);
    defer reaper.deinit(io) catch unreachable;

    // Still running: a bounded wait says so, and says it no sooner than asked.
    try testing.expectEqual(@as(?Child.Term, null), try reaper.waitTimeout(io, 30));

    child.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 5 }, try reaper.wait(io));
    // Final, for every later asker, whichever way they ask.
    try testing.expectEqual(Child.Term{ .exited = 5 }, try reaper.wait(io));
    try testing.expectEqual(@as(?Child.Term, .{ .exited = 5 }), try reaper.waitTimeout(io, 0));
    try testing.expectEqual(Child.Term{ .exited = 5 }, try child.wait(io));
}

test "Reaper.stop returns at once and ends a child that ignores the request, by force, with its tree" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX: a request that can be ignored is a signal, and so is the force.
    if (is_windows) return error.SkipZigTest;

    // The shell and the `sleep` it starts both ignore `SIGTERM` — an ignored
    // signal is inherited across `execve` — and the `sleep` is the grandchild
    // the tree kill has to reach.
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "trap '' TERM; sleep 100 & printf 'pid %d.' \"$!\"; wait" },
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    // after the child, so it stops reading before the child closes its file
    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(child.stdoutFile().?);
    const grandchild = try readPid(&sink);

    var reaper: conduit.Reaper = .init(&child, .{});
    try reaper.start(io);
    defer reaper.deinit(io) catch unreachable;

    const grace_ms = 300;
    const Count = struct {
        var tasks: usize = 0;
        fn concurrent(userdata: ?*anyopaque, group: *std.Io.Group, context: []const u8, alignment: std.mem.Alignment, run: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
            tasks += 1;
            return io.vtable.groupConcurrent(userdata, group, context, alignment, run);
        }
    };
    Count.tasks = 0;
    var vtable = io.vtable.*;
    vtable.groupConcurrent = Count.concurrent;
    const counted_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    reaper.stop(counted_io, grace_ms);
    try testing.expectEqual(@as(usize, 1), Count.tasks);
    // Asked, not waited for: exactly one task owns the grace.
    // A second request with a grace changes nothing.
    reaper.stop(counted_io, grace_ms);
    try testing.expectEqual(@as(usize, 1), Count.tasks);

    const term = (try reaper.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
    try testing.expectEqual(Child.Term{ .signal = .KILL }, term);

    const deadline: Deadline = .in(io, budget_ms);
    while (alive(grandchild)) {
        if (deadline.remainingMs(io) == 0) {
            _ = c.kill(grandchild, .KILL);
            return error.TestGrandchildOutlivedTheStop;
        }
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}

test "Reaper.stop is over the moment a child that honours the request ends" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};

    var reaper: conduit.Reaper = .init(&child, .{});
    try reaper.start(io);
    defer reaper.deinit(io) catch unreachable;

    reaper.stop(io, 60_000);
    const term = (try reaper.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
    // The request, not the force: the grace was never waited out.
    try testing.expectEqual(Child.Term{ .signal = .TERM }, term);
}

test "Reaper.stop with no grace is the force, now" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows) return error.SkipZigTest;

    // The shell says so once it ignores the request, so the request cannot
    // arrive before it does.
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "trap '' TERM; printf 'pid %d.' $$; sleep 100; :" },
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(child.stdoutFile().?);
    _ = try readPid(&sink);

    var reaper: conduit.Reaper = .init(&child, .{});
    try reaper.start(io);
    defer reaper.deinit(io) catch unreachable;

    reaper.stop(io, 60_000);
    reaper.stop(io, 0);
    const term = (try reaper.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
    try testing.expectEqual(Child.Term{ .signal = .KILL }, term);
    const deadline: Deadline = .in(io, budget_ms);
    while (!sink.ended()) {
        if (deadline.remainingMs(io) == 0) return error.TestStoppedTreeRetainedPipe;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}

test "killWait retires a forced group only after closing its late fork's pipe" {
    if (is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    for (0..16) |_| {
        var child = try Child.spawn(io, gpa, .{
            .argv = &.{ "/bin/sh", "-c", "trap '' TERM; printf 'pid %d.' $$; sleep 100; :" },
            .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
            .detach = true,
        });
        defer child.release(io) catch unreachable;
        defer _ = child.killWait(io, 0) catch {};
        var sink: Sink = .{};
        defer sink.deinit();
        try sink.start(child.stdoutFile().?);
        _ = try readPid(&sink);
        try testing.expectEqual(Child.Term{ .signal = .KILL }, try child.killWait(io, 0));
        const deadline: Deadline = .in(io, budget_ms);
        while (!sink.ended()) {
            if (deadline.remainingMs(io) == 0) return error.TestForcedGroupRetainedPipe;
            try std.Io.sleep(io, .fromMilliseconds(2), .awake);
        }
    }
}

test "end_tree: what a child leaves in its group ends with it, before the child is reaped" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // A process group is a POSIX address; the Windows answer is the job.
    if (is_windows) return error.SkipZigTest;

    // Two left behind: one that goes when asked, and one that ignores the
    // request and has to be made to. The child's own end is an ordinary
    // exit, and that is the term published.
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{
            "/bin/sh", "-c",
            "sleep 100 & a=$!; (trap '' TERM; sleep 100) & b=$!; " ++
                "printf 'pid %d.\\n' \"$a\"; printf 'pid %d.\\n' \"$b\"; read x; exit 3",
        },
        .stdio = .{ .pipes = .{ .stderr = false } },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(child.stdoutFile().?);
    const polite = try readPid(&sink);
    const stubborn = stubborn: {
        const deadline: Deadline = .in(io, budget_ms);
        while (deadline.remainingMs(io) > 0) {
            sink.mutex.lockUncancelable(io);
            const said = gpa.dupe(u8, sink.bytes.items) catch "";
            sink.mutex.unlock(io);
            defer gpa.free(said);
            var lines = std.mem.tokenizeScalar(u8, said, '\n');
            _ = lines.next();
            if (lines.next()) |line| if (std.mem.endsWith(u8, line, ".")) {
                break :stubborn try std.fmt.parseInt(posix.pid_t, line["pid ".len .. line.len - 1], 10);
            };
            try std.Io.sleep(io, .fromMilliseconds(2), .awake);
        }
        return error.TestChildSaidNothing;
    };
    defer _ = c.kill(polite, .KILL);
    defer _ = c.kill(stubborn, .KILL);

    const grace_ms = 300;
    var reaper: conduit.Reaper = .init(&child, .{ .end_tree = true, .tree_grace_ms = grace_ms });
    try reaper.start(io);
    defer reaper.deinit(io) catch unreachable;

    child.closeStdin(io);
    const term = (try reaper.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
    try testing.expectEqual(Child.Term{ .exited = 3 }, term);
    // The one that would not go when asked was made to, once the grace had
    // passed, and the child was published only after it.
    // Ended, both: what is left is their new parent's reaping of them, which
    // this test cannot hurry and only waits out.
    const deadline: Deadline = .in(io, budget_ms);
    while (alive(polite) or alive(stubborn)) {
        if (deadline.remainingMs(io) == 0) return error.TestLeftBehindOutlivedTheChild;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}

test "end_tree: a child that ended before its Reaper started still takes what it left" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows) return error.SkipZigTest;

    // The child has ended, unreaped, before the Reaper's task first looks at
    // it. Darwin refuses a kqueue watch on a process in that state, and the
    // Reaper used to take that as "nothing to watch" and reap it without
    // touching its group -- which a slow start of the task, as under
    // ThreadSanitizer, made happen to the test above one run in a few.
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 100 & printf 'pid %d.' \"$!\"; exit 4" },
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(child.stdoutFile().?);
    const left = try readPid(&sink);
    defer _ = c.kill(left, .KILL);

    var deadline: Deadline = .in(io, budget_ms);
    while (wait_for.endedUnreaped(State.get(&child).id) != .ended) {
        if (deadline.remainingMs(io) == 0) return error.TestChildDidNotExit;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    try testing.expect(alive(left));

    var reaper: conduit.Reaper = .init(&child, .{ .end_tree = true, .tree_grace_ms = 300 });
    try reaper.start(io);
    defer reaper.deinit(io) catch unreachable;
    const term = (try reaper.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
    try testing.expectEqual(Child.Term{ .exited = 4 }, term);
    deadline = .in(io, budget_ms);
    while (alive(left)) {
        if (deadline.remainingMs(io) == 0) return error.TestLeftBehindOutlivedTheChild;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}

test "end_tree on Windows ends the child's job at the reap, not at deinit" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // Windows only: the job is the tree there. Without `end_tree` a grandchild
    // outlives the reap and goes at `deinit`, which the test below shows;
    // with it the job is ended when the child is reaped.
    if (!is_windows) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.detached_grandchild,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = true } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var sink: Sink = .{};
    defer sink.deinit();
    var errors: Sink = .{};
    defer errors.deinit();
    var stage: []const u8 = "starting readers and reading the grandchild id";
    errdefer |err| {
        std.debug.print("\nWindows tree fixture failed at {s}: {s}; child id {?d}, result {any}\n", .{ stage, @errorName(err), child.processId(), if (State.optional(&child) != null) child.result() else @as(Child.TryWaitError!?Child.Term, null) });
        sink.report("pid <number>.");
        errors.report("fixture stderr");
    }
    try sink.start(child.stdoutFile().?);
    try errors.start(child.stderrFile().?);

    const id = try readMarkedNumber(win32.DWORD, &sink);
    stage = "opening the reported grandchild";
    const grandchild = try openById(id);
    defer closeFixtureProcess(grandchild);
    try expectFixtureInJob(grandchild, &child);
    stage = "waiting for the child and ending its tree";

    var reaper: conduit.Reaper = .init(&child, .{ .end_tree = true });
    try reaper.start(io);
    defer reaper.deinit(io) catch unreachable;
    _ = (try reaper.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
    // Reaped, and the job ended with it: the grandchild is gone before
    // anything has called `deinit`.
    try testing.expect(endedWithin(grandchild));
}

test "end_tree: a child that leaves nothing is reaped without waiting on its group" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.read_then_exit_5,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var reaper: conduit.Reaper = .init(&child, .{ .end_tree = true, .tree_grace_ms = 60_000 });
    try reaper.start(io);
    defer reaper.deinit(io) catch unreachable;

    child.closeStdin(io);
    const term = (try reaper.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
    try testing.expectEqual(Child.Term{ .exited = 5 }, term);
}

test "a Reaper told to go while the child runs goes at once, and leaves the child to be waited for" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.read_then_exit_5,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
        .detach = !is_windows,
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var reaper: conduit.Reaper = .init(&child, .{ .end_tree = true });
    try reaper.start(io);
    try std.Io.sleep(io, .fromMilliseconds(20), .awake);
    {
        var join_watchdog: Watchdog = .init(@src());
        join_watchdog.limit_ms = budget_ms;
        try join_watchdog.start(io);
        defer join_watchdog.deinit(io);
        reaper.deinit(io) catch unreachable;
    }
    try testing.expectError(error.Canceled, reaper.exit());

    child.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 5 }, try waitWithin(&child));
}

test "output abandoned by a cancelation ends the child and reaps it" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
        .detach = !is_windows,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};

    const Run = struct {
        fn run(ch: *Child) void {
            var result = ch.output(io, gpa, .{}) catch return;
            result.deinit(gpa);
        }
    };
    var group: std.Io.Group = .init;
    try group.concurrent(io, Run.run, .{&child});
    try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    group.cancel(io);

    // Reaped by the call that was abandoned, not by the `defer` above.
    const term = (try child.tryWait()) orelse return error.TestChildOutlivedTheRun;
    try testing.expect(!conduit.succeeded(term));
}

test "stdinWriter and stdoutReader find the child's streams wherever they are" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.echo_stdin,
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var write_buffer: [64]u8 = undefined;
    var writer = child.stdinWriter(io, &write_buffer).?;
    try writer.interface.writeAll("a line\n");
    try writer.interface.flush();
    child.closeStdin(io);

    // The same file the reader would come from, so the two agree.
    try testing.expectEqual(State.get(&child).stdout.?.handle, child.stdoutFile().?.handle);

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, result.stdout(), "a line") != null);
}

test "closeStdin is the half-close a child reading to end of file waits for" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.drain_then_exit_7,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    // Written, but not finished: the child is still reading, because this
    // process is still a writer.
    try child.stdinFile().?.writeStreamingAll(io, "a line\n");
    try testing.expectEqual(@as(?Child.Term, null), try child.waitTimeout(io, 50));

    child.closeStdin(io);
    try testing.expectEqual(@as(?std.Io.File, null), child.stdinFile());
    // Idempotent, which is what makes it safe to pair with `deinit`.
    child.closeStdin(io);

    try testing.expectEqual(Child.Term{ .exited = 7 }, try waitWithin(&child));
}

test "waitTimeout uses the native exit wait without interval sleeps" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.read_then_exit_5,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    if (!is_windows) {
        const watch = wait_for.Watch.open(child.processId().?) orelse return error.SkipZigTest;
        watch.close();
    }
    const Count = struct {
        var sleeps: usize = 0;
        fn sleep(_: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
            sleeps += 1;
            return error.Canceled;
        }
    };
    Count.sleeps = 0;
    var vtable = io.vtable.*;
    vtable.sleep = Count.sleep;
    const counted_io: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
    try testing.expectEqual(@as(?Child.Term, null), try child.waitTimeout(counted_io, 20));
    try testing.expectEqual(@as(usize, 0), Count.sleeps);
    child.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 5 }, try waitWithin(&child));
}

test "waitTimeout gives up without ending the child" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = true,
    });
    defer child.release(io) catch unreachable;

    // The difference from `killWait`: the child is still there afterwards, and
    // deciding what to do about that is the caller's.
    try testing.expectEqual(@as(?Child.Term, null), try child.waitTimeout(io, 50));
    try testing.expectEqual(@as(?Child.Term, null), try child.tryWait());

    _ = try child.killWait(io, 0);
    // And once it has ended, the same call answers at once.
    try testing.expect((try child.waitTimeout(io, 0)) != null);
}

test "succeeded, exitCode and signalName say how a child ended" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var ok_child = try Child.spawn(io, gpa, .{
        .argv = &script.drain_then_exit_7,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer ok_child.release(io) catch unreachable;
    errdefer _ = ok_child.killWait(io, 0) catch {};
    ok_child.closeStdin(io);

    const term = try waitWithin(&ok_child);
    try testing.expect(!conduit.succeeded(term));
    try testing.expectEqual(@as(?u32, 7), conduit.exitCode(term));
    try testing.expectEqual(@as(?[]const u8, null), conduit.signalName(term));

    try testing.expect(conduit.succeeded(.{ .exited = 0 }));
    try testing.expect(!conduit.succeeded(.{ .exited = 1 }));

    // A signal is not a status, and this is where the two systems part: only
    // POSIX has a name to give.
    var killed = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = true,
    });
    defer killed.release(io) catch unreachable;
    const killed_term = try killed.killWait(io, 0);
    if (is_windows) {
        try testing.expectEqual(@as(?u32, 1), conduit.exitCode(killed_term));
        try testing.expectEqual(@as(?[]const u8, null), conduit.signalName(killed_term));
    } else {
        try testing.expect(!conduit.succeeded(killed_term));
        try testing.expectEqual(@as(?u32, null), conduit.exitCode(killed_term));
        try testing.expectEqualStrings("KILL", conduit.signalName(killed_term).?);
    }
}

test "shellStatus says an end as a shell's $? does, and signalNumber names every signal" {
    try testing.expectEqual(@as(u8, 0), conduit.shellStatus(.{ .exited = 0 }));
    try testing.expectEqual(@as(u8, 7), conduit.shellStatus(.{ .exited = 7 }));
    // A Windows code past a byte keeps its low byte, as a POSIX shell there says it.
    try testing.expectEqual(@as(u8, 0x01), conduit.shellStatus(.{ .exited = 0xC000_0101 }));
    try testing.expectEqual(@as(u8, 255), conduit.shellStatus(.{ .unknown = 3 }));
    try testing.expectEqual(@as(?u8, null), conduit.signalNumber(.{ .exited = 9 }));
    if (!is_windows) {
        try testing.expectEqual(@as(u8, 128 + 9), conduit.shellStatus(.{ .signal = .KILL }));
        try testing.expectEqual(@as(u8, 128 + 15), conduit.shellStatus(.{ .signal = .TERM }));
        try testing.expectEqual(@as(?u8, 9), conduit.signalNumber(.{ .signal = .KILL }));
        // A signal with no name still has a number, and a status.
        const unnamed: std.posix.SIG = @enumFromInt(40);
        try testing.expectEqual(@as(?[]const u8, null), conduit.signalName(.{ .signal = unnamed }));
        try testing.expectEqual(@as(?u8, 40), conduit.signalNumber(.{ .signal = unnamed }));
        try testing.expectEqual(@as(u8, 168), conduit.shellStatus(.{ .signal = unnamed }));
    }

    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var killed = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = true,
    });
    defer killed.release(io) catch unreachable;
    const killed_term = try killed.killWait(io, 0);
    try testing.expectEqual(@as(u8, if (is_windows) 1 else 128 + 9), conduit.shellStatus(killed_term));
}

test "processExists says whether a process has an id, until it is reaped" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const own: Child.Id = if (is_windows) std.os.windows.GetCurrentProcessId() else std.c.getpid();
    try testing.expectEqual(@as(?bool, true), conduit.processExists(own));
    if (!is_windows) {
        // Zero and below address groups, not a process.
        try testing.expectEqual(@as(?bool, false), conduit.processExists(0));
        try testing.expectEqual(@as(?bool, false), conduit.processExists(-1));
    }

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
    });
    defer child.release(io) catch unreachable;
    const pid = child.processId().?;
    try testing.expectEqual(@as(?bool, true), conduit.processExists(pid));
    _ = try child.killWait(io, 0);
    // Reaped on POSIX: the id is given back, and a pid is taken again only
    // once the counter wraps. On Windows the reap closes the Child's handle,
    // and the id goes back whenever the system lets the ended process go,
    // which it does not promise to do by any moment, so there is nothing to
    // ask there.
    if (!is_windows) try testing.expectEqual(@as(?bool, false), conduit.processExists(pid));
}

//======================================================================
// Killing, waiting, groups.
//======================================================================

test "killWait ends a child that would otherwise outlive the test, and says how" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = true,
    });
    defer child.release(io) catch unreachable;

    const term = try child.killWait(io, 200);
    try expectKilled(term, .TERM);
    // Reaped once: `wait` answers from what `killWait` learned, and so cannot
    // block here.
    try testing.expectEqual(term, try child.wait(io));
}

test "killWait reaches what the child started, not only the child" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    // Both systems, by different means: a job object on Windows, the child's
    // process group on POSIX. The fixture is a shell waiting on a program of
    // its own, so there is a grandchild, and both of them hold the standard
    // output pipe. The pipe finishing is the two of them being gone, which
    // needs no way of asking after a process by name.
    const argv: []const []const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "ping -n 30 127.0.0.1" }
    else
        // The `;` is what stops the shell replacing itself with `sleep`, which
        // would leave no grandchild to lose.
        &.{ "/bin/sh", "-c", "sleep 30; :" };

    var child = try Child.spawn(io, gpa, .{
        .argv = argv,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
        // On POSIX a signal is addressed to a process group and `detach` is
        // what makes one. On Windows the job is there either way.
        .detach = !is_windows,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(child.stdoutFile().?);

    // Both still running, so the pipe still has writers.
    try std.Io.sleep(io, .fromMilliseconds(200), .awake);
    try testing.expect(!sink.ended());

    _ = try child.killWait(io, 0);

    // The shell is gone. If what it started were still running it would still
    // be holding the pipe, and this would wait out the whole budget.
    const deadline: Deadline = .in(io, budget_ms);
    while (deadline.remainingMs(io) > 0) {
        if (sink.ended()) return;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    return error.TestGrandchildOutlivedTheKill;
}

test "killWait reaches a grandchild that put itself in a process group of its own" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: on Windows the job object holds everything the child starts
    // whatever it does with console groups, and the test above already asserts
    // that.
    if (is_windows) return error.SkipZigTest;

    // `set -m` turns job control on, and a shell with job control puts each
    // background job in a process group of its own. So the grandchild here is
    // a descendant of the child and *not* in the child's process group: the
    // one place a signal addressed to the group reaches nothing.
    //
    // On a pair rather than on pipes, because a shell with no controlling
    // terminal declines to turn job control on at all.
    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "set -m; sleep 100 & printf 'pid %d.' \"$!\"; wait" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(pty.readFile());

    const grandchild = try readPid(&sink);
    // Only a claim about this shell if it really did what the fixture asks. A
    // shell that declines job control leaves the grandchild in the child's
    // group, where the group signal reaches it and there is nothing here to
    // prove.
    if (getpgid(grandchild) == State.get(&child).pgid.?) return error.SkipZigTest;

    _ = try child.killWait(io, 0);

    const deadline: Deadline = .in(io, budget_ms);
    while (deadline.remainingMs(io) > 0) {
        if (!alive(grandchild)) return;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    _ = c.kill(grandchild, .KILL);
    return error.TestGrandchildOutlivedTheKill;
}

test "a child that has never forked is stopped by its signal alone, without the walk" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // Where nothing says a child has no children every stop walks, as it
    // always did, and there is nothing here to count. Darwin watches the
    // child's forks; Linux reads the child's `children` files.
    if (is_windows or !tree.knows_leaves) return error.SkipZigTest;

    // `sleep` itself rather than a shell, which may fork to run it. On pipes
    // it goes through `posix_spawn` (unless the build says always fork), on
    // a pair through the fork, and both ways with and without a group.
    for ([_]bool{ false, true }) |on_pty| for ([_]bool{ false, true }) |detach| {
        var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
        defer pty.close(io);
        var child = try Child.spawn(io, gpa, .{
            .argv = &.{ "/bin/sleep", "100" },
            .stdio = if (on_pty) .{ .pty = &pty } else .ignore,
            .detach = detach,
        });
        defer child.release(io) catch unreachable;
        defer _ = child.killWait(io, 0) catch {};

        const before = tree.walks.load(.monotonic);
        try child.kill(.kill);
        try testing.expectEqual(before, tree.walks.load(.monotonic));
        try expectKilled(try child.wait(io), .KILL);
    };
}

test "a child on a terminal opens it as one poll can wait on" {
    if (is_windows) return error.SkipZigTest;
    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{@import("conduit_test_options").tty_fixture},
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(pty.readFile());
    const deadline: Deadline = .in(io, budget_ms);
    while (true) {
        const said = said: {
            sink.mutex.lockUncancelable(io);
            defer sink.mutex.unlock(io);
            const at = std.mem.indexOf(u8, sink.bytes.items, "terminal ") orelse break :said null;
            const rest = sink.bytes.items[at + "terminal ".len ..];
            const end = std.mem.indexOfScalar(u8, rest, '.') orelse break :said null;
            break :said try gpa.dupe(u8, rest[0..end]);
        };
        if (said) |word| {
            defer gpa.free(word);
            return std.testing.expectEqualStrings("pollable", word);
        }
        if (sink.ended() or deadline.remainingMs(io) == 0) {
            sink.report("terminal <word>.");
            return error.TestChildSaidNothing;
        }
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}

test "a grandchild started at once, out of reach of the signal, still ends with the child" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows) return error.SkipZigTest;

    // The watch on the child's forks is registered late on purpose: long
    // after a child that was not being held would have started its shell,
    // forked, and said so. Held, the child has run nothing by then, and the
    // fork that follows is noted; a watch with a window would note nothing,
    // the stop would be the signal alone, and the grandchild would survive.
    //
    // Two grandchildren the signal to the child does not reach: on pipes,
    // one of a child with no group of its own (through `posix_spawn`, unless
    // the build says always fork); on a pair, one that job control has put
    // in a group of its own (through the fork).
    //
    // About the walk, so not in a cgroup, which would reach the grandchild
    // with no walk at all.
    cgroup.testing_hook.off = true;
    defer cgroup.testing_hook.off = false;
    for ([_]bool{ false, true }) |on_pty| {
        var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
        defer pty.close(io);
        if (tree.Forks.supported) tree.testing_hook.hold_ms = 200;
        defer tree.testing_hook.hold_ms = 0;
        var child = try Child.spawn(io, gpa, .{
            .argv = if (on_pty)
                &.{ "/bin/sh", "-c", "set -m; sleep 100 & printf 'pid %d.' \"$!\"; wait" }
            else
                &.{ "/bin/sh", "-c", "sleep 100 & printf 'pid %d.' \"$!\"; wait" },
            .stdio = if (on_pty) .{ .pty = &pty } else .{ .pipes = .{ .stdin = false, .stderr = false } },
            .detach = on_pty,
        });
        tree.testing_hook.hold_ms = 0;
        defer child.release(io) catch unreachable;
        defer _ = child.killWait(io, 0) catch {};
        const ran_before_watch = tree.testing_hook.ran_before_watch;
        if (on_pty) pty.closeSlave(io);

        var sink: Sink = .{};
        defer sink.deinit();
        try sink.start(if (on_pty) pty.readFile() else child.stdoutFile().?);
        const grandchild = try readPid(&sink);
        // Whatever this test finds, it leaves nothing behind.
        defer if (alive(grandchild)) {
            _ = c.kill(grandchild, .KILL);
        };
        if (on_pty and getpgid(grandchild) == State.get(&child).pgid.?) return error.SkipZigTest;

        const before = tree.walks.load(.monotonic);
        _ = try child.killWait(io, 0);

        const deadline: Deadline = .in(io, budget_ms);
        while (alive(grandchild)) {
            if (deadline.remainingMs(io) == 0) return error.TestGrandchildOutlivedTheKill;
            try std.Io.sleep(io, .fromMilliseconds(10), .awake);
        }
        try testing.expect(tree.walks.load(.monotonic) > before);
        // Held until the watch was in: the child had run nothing when it was
        // registered, the shell was the one waiting and not the watch.
        if (tree.Forks.supported) try testing.expectEqual(@as(?bool, false), ran_before_watch);
    }
}

//======================================================================
// Signals other than the three requests to end.
//======================================================================

/// A detached shell and a grandchild shell, each with a trap that says its
/// own name and the signal's for every signal these tests send, and each
/// waiting without end once it has said it is ready. The grandchild is
/// started with `&`, so it is in the child's group and reached as `kill`
/// reaches any descendant there.
const trapping_tree =
    \\for s in HUP USR1 USR2 WINCH ALRM CONT; do trap "echo parent-$s" $s; done
    \\sh -c 'for s in HUP USR1 USR2 WINCH ALRM CONT; do trap "echo child-$s" $s; done; echo child-ready; while :; do sleep 1; done' &
    \\printf 'pid %d.' "$!"
    \\echo parent-ready
    \\while :; do wait; done
;

/// Standard output to read, and the shell's own reports of a `sleep` a
/// signal ended kept out of the test's output.
const shell_reports: Child.Stdio = .{ .streams = .{ .stdout = .pipe, .stderr = .ignore } };

test "a signal other than the three reaches a detached child and what it started" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // Windows has none of these, and refuses them: the test below.
    if (is_windows) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", trapping_tree },
        .stdio = shell_reports,
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(child.stdoutFile().?);
    const grandchild = try readPid(&sink);
    defer if (alive(grandchild)) {
        _ = c.kill(grandchild, .KILL);
    };
    try sink.expect("parent-ready");
    try sink.expect("child-ready");

    const sent = [_]struct { Child.Signal, []const u8 }{
        .{ .hangup, "HUP" },
        .{ .user1, "USR1" },
        .{ .user2, "USR2" },
        .{ .window_change, "WINCH" },
        .{ .{ .posix = .ALRM }, "ALRM" },
    };
    for (sent) |entry| {
        try child.kill(entry[0]);
        var said: [32]u8 = undefined;
        try sink.expect(try std.fmt.bufPrint(&said, "parent-{s}", .{entry[1]}));
        try sink.expect(try std.fmt.bufPrint(&said, "child-{s}", .{entry[1]}));
        // Caught, so delivered and not an end.
        try testing.expectEqual(@as(?Child.Term, null), try child.tryWait());
    }
}

test "stop suspends a child and what it started, and continue resumes them" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", trapping_tree },
        .stdio = shell_reports,
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(child.stdoutFile().?);
    const grandchild = try readPid(&sink);
    defer if (alive(grandchild)) {
        _ = c.kill(grandchild, .KILL);
    };
    try sink.expect("parent-ready");
    try sink.expect("child-ready");

    try child.kill(.stop);
    try expectStopped(child.processId().?, true);
    try expectStopped(grandchild, true);
    // A stopped child has not ended, and no wait here says it has.
    try testing.expectEqual(@as(?Child.Term, null), try child.tryWait());

    try child.kill(.@"continue");
    try expectStopped(child.processId().?, false);
    try expectStopped(grandchild, false);
    try sink.expect("parent-CONT");
    try sink.expect("child-CONT");
}

test "a signal that is not a request to end leaves what the child started to its policy" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows) return error.SkipZigTest;

    // The child catches the signal and exits normally; the grandchild
    // ignores it. After `.terminate` the reap ends the grandchild: the
    // request was to end, and a child that cleaned up and exited still
    // takes its tree with it. After `.user1` the survival policy holds, as
    // it would for a child that had exited on its own.
    for ([_]struct { Child.Signal, []const u8, bool }{
        .{ .terminate, "TERM", false },
        .{ .user1, "USR1", true },
    }) |entry| {
        var line: [512]u8 = undefined;
        const text = try std.fmt.bufPrint(&line,
            \\trap 'exit 0' {0s}
            \\sh -c "trap '' {0s}; echo child-ready; while :; do sleep 1; done" &
            \\printf 'pid %d.' "$!"
            \\while :; do wait; done
        , .{entry[1]});
        var child = try Child.spawn(io, gpa, .{
            .argv = &.{ "/bin/sh", "-c", text },
            .stdio = shell_reports,
            .detach = true,
        });
        defer child.release(io) catch unreachable;
        defer _ = child.killWait(io, 0) catch {};
        var sink: Sink = .{};
        defer sink.deinit();
        try sink.start(child.stdoutFile().?);
        const grandchild = try readPid(&sink);
        defer if (alive(grandchild)) {
            _ = c.kill(grandchild, .KILL);
        };
        try sink.expect("child-ready");

        try child.kill(entry[0]);
        try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
        if (entry[2]) {
            try testing.expect(alive(grandchild));
        } else {
            try expectGone(grandchild);
        }
    }
}

test "a signal with no meaning on this system is refused by name" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};

    if (is_windows) {
        inline for (.{ .hangup, .quit, .user1, .user2, .stop, .@"continue", .window_change }) |signal| {
            try testing.expectError(error.Unsupported, child.kill(signal));
        }
        try testing.expectError(error.Unsupported, child.kill(.{ .posix = .TERM }));
    } else {
        try testing.expectError(error.Unsupported, child.kill(.{ .posix = @enumFromInt(0) }));
        try testing.expectError(error.Unsupported, child.kill(.{ .posix = @enumFromInt(200) }));
    }
    // Refused before anything was sent: the child is still running.
    try testing.expectEqual(@as(?Child.Term, null), try child.tryWait());
}

/// Waits for `pid` to be stopped, or to be running again, by the state the
/// system reports for it: the `/proc` state letter on Linux, `SSTOP` from
/// `proc_pidinfo` on Darwin. Skips where neither can be asked.
fn expectStopped(pid: posix.pid_t, stopped: bool) !void {
    const deadline: Deadline = .in(io, budget_ms);
    while (true) {
        const now = isStopped(pid) orelse return error.SkipZigTest;
        if (now == stopped) return;
        if (deadline.remainingMs(io) == 0) return error.TestStopNotObserved;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}

fn isStopped(pid: posix.pid_t) ?bool {
    if (builtin.os.tag == .linux) {
        const state = stateOf(pid);
        if (state == 0) return null;
        return state == 'T' or state == 't';
    }
    if (builtin.os.tag == .macos) {
        var info: DarwinBsdInfo = undefined;
        if (darwin_proc_pidinfo(pid, 3, 0, &info, @sizeOf(DarwinBsdInfo)) != @sizeOf(DarwinBsdInfo)) return null;
        // `SSTOP` from `<sys/proc.h>`.
        return info.status == 4;
    }
    return null;
}

/// `struct proc_bsdinfo` from `<sys/proc_info.h>`, which `proc_pidinfo`
/// fills only whole.
const DarwinBsdInfo = extern struct {
    flags: u32,
    status: u32,
    rest: [128]u8,
};

extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: ?*anyopaque, size: c_int) c_int;
const darwin_proc_pidinfo = if (builtin.os.tag == .macos) proc_pidinfo else struct {
    fn unavailable(_: c_int, _: c_int, _: u64, _: ?*anyopaque, _: c_int) c_int {
        return 0;
    }
}.unavailable;

//======================================================================
// A cgroup of the child's own (Linux, where one may be made).
//======================================================================

/// A shell line that starts a grandchild the classic way a daemon leaves:
/// a subshell starts it and exits, so it is orphaned, and it calls `setsid`,
/// so it is in a session and a group of its own. The only thing it still
/// shares with the child is what it was born into. It prints its pid.
const orphan_in_own_session = "(setsid sleep 100 & printf 'pid %d.' \"$!\")";

/// The `setsid` program, or `null` where the system has none.
fn setsidProgram() ?[]const u8 {
    for ([_][]const u8{ "/usr/bin/setsid", "/bin/setsid" }) |path| {
        std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
        return path;
    }
    return null;
}

/// Whether a child started here now is put in a cgroup of its own. Asked of a
/// child that leaves nothing behind, so a test can skip before it starts one
/// that would, and that only a cgroup would end.
fn cgroupsHere() !bool {
    if (is_windows or !cgroup.supported) return false;
    if (setsidProgram() == null) return false;
    var looked = try Child.spawn(io, gpa, .{ .argv = &.{"/bin/true"}, .stdio = .ignore });
    defer looked.release(io) catch unreachable;
    _ = try looked.wait(io);
    return State.get(&looked).cgroup.active();
}

/// Waits for `pid` to be gone altogether: not running and not a zombie.
fn expectGone(pid: posix.pid_t) !void {
    const deadline: Deadline = .in(io, budget_ms);
    while (alive(pid)) {
        if (deadline.remainingMs(io) == 0) return error.TestGrandchildOutlivedTheKill;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}

fn cgroupExists(path: [:0]const u8) bool {
    return c.access(path, 0) == 0;
}

test "a recorded cgroup opens only at its original directory identity and removes when empty" {
    if (is_windows or !try cgroupsHere()) return error.SkipZigTest;
    var child = try Child.spawn(io, gpa, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .stdio = .ignore });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var where: [std.fs.max_path_bytes + 64]u8 = undefined;
    const path = State.get(&child).cgroup.path(&where).?;
    const identity = State.get(&child).cgroup.id().?;
    try testing.expect(cgroup.Cgroup.openRecorded(path, identity +% 1) == null);
    var recorded = cgroup.Cgroup.openRecorded(path, identity).?;
    defer recorded.release();
    try testing.expectEqual(identity, recorded.id().?);
    try testing.expectEqual(cgroup.Populated.others, recorded.populated());
    try testing.expect(!recorded.remove());

    _ = try child.killWait(io, 0);
    try testing.expect(recorded.remove());
    try testing.expect(cgroup.Cgroup.openRecorded(path, identity) == null);
}

test "a recorded cgroup whose name now holds another is not removed through it" {
    if (is_windows or !try cgroupsHere()) return error.SkipZigTest;
    var child = try Child.spawn(io, gpa, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .stdio = .ignore });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var where: [std.fs.max_path_bytes + 64]u8 = undefined;
    const path = State.get(&child).cgroup.path(&where).?;
    var recorded = cgroup.Cgroup.openRecorded(path, State.get(&child).cgroup.id().?).?;
    defer recorded.release();

    // The recorded cgroup empties and goes, and a new empty one takes its
    // name: only the inode check stands between the handle and removing it.
    _ = try child.killWait(io, 0);
    try testing.expectEqual(@as(c_int, 0), c.rmdir(path));
    try testing.expectEqual(@as(c_int, 0), c.mkdir(path, 0o755));
    defer _ = c.rmdir(path);
    try testing.expect(!recorded.remove());
    try testing.expect(cgroupExists(path));
}

test "a recorded cgroup waits on population changes" {
    if (is_windows or !try cgroupsHere()) return error.SkipZigTest;
    var child = try Child.spawn(io, gpa, .{ .argv = &.{ "/bin/sh", "-c", "sleep 30" }, .stdio = .ignore });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var where: [std.fs.max_path_bytes + 64]u8 = undefined;
    var recorded = cgroup.Cgroup.openRecorded(State.get(&child).cgroup.path(&where).?, State.get(&child).cgroup.id().?).?;
    defer recorded.release();
    try testing.expect(!try recorded.waitEmpty(io, 20));
    _ = try child.killWait(io, 0);
    try testing.expect(try recorded.waitEmpty(io, 1000));
}

test "endRecorded ends a verified Linux cgroup and its detached grandchild" {
    if (is_windows or !try cgroupsHere()) return error.SkipZigTest;
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30 & wait" },
        .stdio = .ignore,
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var where: [std.fs.max_path_bytes + 64]u8 = undefined;
    var recorded = cgroup.Cgroup.openRecorded(State.get(&child).cgroup.path(&where).?, State.get(&child).cgroup.id().?).?;
    defer recorded.release();
    const since = (try tree.startTime(State.get(&child).id)).?;
    try testing.expect(try conduit.endRecorded(io, .{
        .pid = State.get(&child).id,
        .start = since,
        .group = State.get(&child).pgid,
        .cgroup = &recorded,
        .grace_ms = 20,
    }));
    _ = try child.wait(io);
    try testing.expect(!recorded.active());
}

test "a grandchild that double-forks and setsid()s away is still ended with the tree, in the child's cgroup" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // A system where this process may not make one: the walk, which does
    // not reach this grandchild, and nothing here to show.
    if (is_windows or !try cgroupsHere()) return error.SkipZigTest;

    // `.kill` (a grace of zero) is `cgroup.kill`; `.terminate` first (a
    // grace) reaches each member on its own. Both with and without a group,
    // since a member in the child's group is left to the group signal.
    for ([_]u32{ 0, 2000 }) |grace_ms| for ([_]bool{ false, true }) |detach| {
        var child = try Child.spawn(io, gpa, .{
            .argv = &.{ "/bin/sh", "-c", orphan_in_own_session ++ "; exec sleep 100" },
            .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
            .detach = detach,
        });
        defer child.release(io) catch unreachable;
        defer _ = child.killWait(io, 0) catch {};
        try testing.expect(State.get(&child).cgroup.active());

        // The reader is done with the child's output before `deinit` below
        // closes it.
        const orphan = orphan: {
            var sink: Sink = .{};
            defer sink.deinit();
            try sink.start(child.stdoutFile().?);
            break :orphan try readPid(&sink);
        };
        defer if (alive(orphan)) {
            _ = c.kill(orphan, .KILL);
        };
        // Orphaned and in a session of its own before the kill: the case a
        // group signal and a walk down from the child both miss.
        const deadline: Deadline = .in(io, budget_ms);
        while (parentOf(orphan) == c.getpid() or parentOf(orphan) == State.get(&child).id or getsid(orphan) != orphan) {
            if (deadline.remainingMs(io) == 0) return error.TestGrandchildNeverLeft;
            try std.Io.sleep(io, .fromMilliseconds(2), .awake);
        }
        try testing.expect(getpgid(orphan) != State.get(&child).id);

        var where: [std.fs.max_path_bytes + 64]u8 = undefined;
        const path = try gpa.dupeZ(u8, State.get(&child).cgroup.path(&where).?);
        defer gpa.free(path);
        try testing.expect(cgroupExists(path));

        const walks_before = tree.walks.load(.monotonic);
        const term = try child.killWait(io, grace_ms);
        try expectKilled(term, if (grace_ms == 0) .KILL else .TERM);
        try expectGone(orphan);
        // The cgroup did it: no walk was asked.
        try testing.expectEqual(walks_before, tree.walks.load(.monotonic));

        // Nothing left in it, so `deinit` removes it.
        child.release(io) catch unreachable;
        try testing.expect(!cgroupExists(path));
    };
}

test "end_tree: what a child left in its cgroup ends with it, orphaned and in a session of its own" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows or !try cgroupsHere()) return error.SkipZigTest;

    // Not detached: there is no group to end, and before the cgroup a child
    // like this one left its tree running.
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", orphan_in_own_session ++ "; read x; exit 3" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    try testing.expect(State.get(&child).cgroup.active());

    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(child.stdoutFile().?);
    const orphan = try readPid(&sink);
    defer if (alive(orphan)) {
        _ = c.kill(orphan, .KILL);
    };

    var reaper: conduit.Reaper = .init(&child, .{ .end_tree = true, .tree_grace_ms = 2000 });
    try reaper.start(io);
    defer reaper.deinit(io) catch unreachable;
    child.closeStdin(io);
    const term = (try reaper.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
    try testing.expectEqual(Child.Term{ .exited = 3 }, term);
    try expectGone(orphan);
}

test "deinit signals nothing in a child's cgroup, and the cgroup goes once what is in it has ended" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows or !try cgroupsHere()) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", orphan_in_own_session },
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    try testing.expect(State.get(&child).cgroup.active());

    // The reader is done with the child's output before `deinit` below
    // closes it.
    const orphan = orphan: {
        var sink: Sink = .{};
        defer sink.deinit();
        try sink.start(child.stdoutFile().?);
        break :orphan try readPid(&sink);
    };
    defer if (alive(orphan)) {
        _ = c.kill(orphan, .KILL);
    };
    var where: [std.fs.max_path_bytes + 64]u8 = undefined;
    const path = try gpa.dupeZ(u8, State.get(&child).cgroup.path(&where).?);
    defer gpa.free(path);

    try testing.expectEqual(Child.Term{ .exited = 0 }, try child.wait(io));
    child.release(io) catch unreachable;
    // Still running, still in the cgroup, which is still there.
    try testing.expect(alive(orphan));
    try testing.expect(cgroupExists(path));

    _ = c.kill(orphan, .KILL);
    try expectGone(orphan);
    // The next spawn here looks, and removes it.
    var next = try Child.spawn(io, gpa, .{ .argv = &.{"/bin/true"}, .stdio = .ignore });
    defer next.release(io) catch unreachable;
    _ = try next.wait(io);
    try testing.expect(!cgroupExists(path));
}

//======================================================================
// Orphans (Linux).
//======================================================================

const Orphans = conduit.Orphans;

/// Whether this process is a child subreaper now, as the kernel says.
fn subreaperNow() bool {
    if (builtin.os.tag != .linux) return false;
    var flag: c_int = 0;
    _ = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&flag), 0, 0, 0);
    return flag != 0;
}

/// `orphan_in_own_session`, then `done.` once the subshell that started the
/// orphan has ended: by then the orphan has been given its second parent.
const leaves_an_orphan = orphan_in_own_session ++ "; printf 'done.'";

/// Waits for `said` to arrive on the sink.
fn waitSaid(sink: *Sink, said: []const u8) !void {
    const deadline: Deadline = .in(io, budget_ms);
    while (deadline.remainingMs(io) > 0) {
        const found = found: {
            sink.mutex.lockUncancelable(io);
            defer sink.mutex.unlock(io);
            break :found std.mem.indexOf(u8, sink.bytes.items, said) != null;
        };
        if (found) return;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    return error.TestChildSaidNothing;
}

/// Waits for `pid` to be this process's child and in a session of its own.
fn expectAdopted(pid: posix.pid_t) !void {
    const deadline: Deadline = .in(io, budget_ms);
    while (parentOf(pid) != c.getpid() or getsid(pid) != pid) {
        if (deadline.remainingMs(io) == 0) return error.TestOrphanNotAdopted;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}

/// Waits for `Orphans.count` to say `expected`.
fn expectCount(orphans: *Orphans, expected: usize) !void {
    const deadline: Deadline = .in(io, budget_ms);
    while (try orphans.count() != expected) {
        if (deadline.remainingMs(io) == 0) return error.TestWrongOrphanCount;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}

/// The pid of the orphan a child running `leaves_an_orphan` left, once the
/// child has said `done.`.
fn orphanOf(child: *Child) !posix.pid_t {
    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(child.stdoutFile().?);
    const orphan = try readPid(&sink);
    try waitSaid(&sink, "done.");
    return orphan;
}

/// The state letter of a Linux process, from `/proc`: `Z` for a zombie, `0`
/// when there is no such process.
fn stateOf(pid: posix.pid_t) u8 {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/stat", .{pid}) catch return 0;
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    var text: [512]u8 = undefined;
    const n = c.read(fd, &text, text.len);
    if (n <= 0) return 0;
    const close = std.mem.lastIndexOfScalar(u8, text[0..@intCast(n)], ')') orelse return 0;
    if (close + 2 >= @as(usize, @intCast(n))) return 0;
    return text[close + 2];
}

/// Waits for `pid` to have ended and not been reaped.
fn expectZombie(pid: posix.pid_t) !void {
    const deadline: Deadline = .in(io, budget_ms);
    while (stateOf(pid) != 'Z') {
        if (deadline.remainingMs(io) == 0) return error.TestOrphanDidNotEnd;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}

test "an orphan that forked twice and called setsid is adopted, reaped at conduit's next event, and ended by Orphans.end" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows) return error.SkipZigTest;
    var orphans: Orphans = .init(gpa);
    defer orphans.deinit() catch unreachable;
    if (!Orphans.supported) {
        try testing.expectError(error.Unsupported, orphans.start());
        return error.SkipZigTest;
    }
    if (setsidProgram() == null) return error.SkipZigTest;
    orphans.start() catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };
    try testing.expect(subreaperNow());

    // One that stays until `end`, left by a child that is still running.
    var keeper = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", leaves_an_orphan ++ "; read x; exit 3" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
    });
    defer keeper.release(io) catch unreachable;
    defer _ = keeper.killWait(io, 0) catch {};
    const kept = try orphanOf(&keeper);
    defer if (alive(kept)) {
        _ = c.kill(kept, .KILL);
    };
    try expectAdopted(kept);
    try expectCount(&orphans, 1);
    // named, so a program can write it down for a later one to end
    var names: [4]Orphans.Record = undefined;
    const identities = try orphans.list(&names);
    try testing.expectEqual(@as(usize, 1), identities.len);
    try testing.expectEqual(kept, identities[0].pid);
    try testing.expectEqual((try conduit.startTime(kept)).?, identities[0].start);
    try testing.expectEqual(0, (try orphans.list(names[0..0])).len);

    // One that has ended by the time the child that left it is reaped: the
    // reap is the event, and takes it with it.
    {
        var leaver = try Child.spawn(io, gpa, .{
            .argv = &.{ "/bin/sh", "-c", leaves_an_orphan ++ "; read x; exit 0" },
            .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
        });
        defer leaver.release(io) catch unreachable;
        defer _ = leaver.killWait(io, 0) catch {};
        const orphan = try orphanOf(&leaver);
        defer if (alive(orphan)) {
            _ = c.kill(orphan, .KILL);
        };
        try expectAdopted(orphan);
        _ = c.kill(orphan, .KILL);
        try expectZombie(orphan);
        leaver.closeStdin(io);
        try testing.expectEqual(Child.Term{ .exited = 0 }, (try leaver.waitTimeout(io, budget_ms)) orelse
            return error.TestChildDidNotExit);
        try testing.expect(!alive(orphan));
    }

    // One that ends while nothing of conduit's happens stays a zombie, and a
    // spawn, the next event, reaps it.
    {
        var leaver = try Child.spawn(io, gpa, .{
            .argv = &.{ "/bin/sh", "-c", leaves_an_orphan },
            .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
        });
        defer leaver.release(io) catch unreachable;
        defer _ = leaver.killWait(io, 0) catch {};
        const orphan = try orphanOf(&leaver);
        defer if (alive(orphan)) {
            _ = c.kill(orphan, .KILL);
        };
        try expectAdopted(orphan);
        try testing.expectEqual(Child.Term{ .exited = 0 }, (try leaver.waitTimeout(io, budget_ms)) orelse
            return error.TestChildDidNotExit);
        _ = c.kill(orphan, .KILL);
        try expectZombie(orphan);
        try std.Io.sleep(io, .fromMilliseconds(100), .awake);
        try testing.expectEqual(@as(u8, 'Z'), stateOf(orphan));

        var next = try Child.spawn(io, gpa, .{ .argv = &.{"/bin/true"}, .stdio = .ignore });
        defer next.release(io) catch unreachable;
        try testing.expect(!alive(orphan));
        _ = try next.wait(io);
    }
    try expectCount(&orphans, 1);

    // The child that left the first still has its own status, and its orphan
    // runs on after it until `end`.
    keeper.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 3 }, (try keeper.waitTimeout(io, budget_ms)) orelse
        return error.TestChildDidNotExit);
    try testing.expect(alive(kept));
    try orphans.end(io, 2000);
    try expectGone(kept);
    try testing.expectEqual(@as(usize, 0), try orphans.count());

    orphans.deinit() catch unreachable;
    try testing.expect(!subreaperNow());
}

test "an idle Orphans wakes for nothing: no look runs over a quiet second" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows or !Orphans.supported) return error.SkipZigTest;
    if (setsidProgram() == null) return error.SkipZigTest;
    var orphans: Orphans = .init(gpa);
    defer orphans.deinit() catch unreachable;
    orphans.start() catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };

    // An adopted orphan running, and nothing of conduit's happening.
    var leaver = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", leaves_an_orphan },
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
    });
    defer leaver.release(io) catch unreachable;
    defer _ = leaver.killWait(io, 0) catch {};
    const orphan = try orphanOf(&leaver);
    defer if (alive(orphan)) {
        _ = c.kill(orphan, .KILL);
    };
    _ = try leaver.waitTimeout(io, budget_ms);
    try expectCount(&orphans, 1);

    const before = Orphans.looks.load(.monotonic);
    try std.Io.sleep(io, .fromMilliseconds(1000), .awake);
    try testing.expectEqual(before, Orphans.looks.load(.monotonic));

    try orphans.end(io, 0);
    try expectGone(orphan);
}

test "a Child's status is never taken by the reaping of orphans, however the two race" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows or !Orphans.supported) return error.SkipZigTest;

    // A child this process had before `start` is somebody's too.
    var before = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "read x; exit 4" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer before.release(io) catch unreachable;
    defer _ = before.killWait(io, 0) catch {};

    var orphans: Orphans = .init(gpa);
    defer orphans.deinit() catch unreachable;
    orphans.start() catch |err| switch (err) {
        error.Unsupported => return error.SkipZigTest,
        else => return err,
    };

    // Ended, and looked at, before it is waited for.
    before.closeStdin(io);
    try expectZombie(State.get(&before).id);
    _ = try orphans.count();
    try testing.expectEqual(Child.Term{ .exited = 4 }, (try before.waitTimeout(io, budget_ms)) orelse
        return error.TestChildDidNotExit);

    // Every spawn and every reap below is a look, on four tasks at once, while
    // orphans are adopted and reaped all along.
    var failures: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (0..race_tasks) |task| try group.concurrent(io, raceOrphans, .{ @as(u8, @intCast(task)), &failures });
    try group.await(io);
    try testing.expectEqual(@as(u32, 0), failures.load(.acquire));

    try orphans.end(io, 0);
    try testing.expectEqual(@as(usize, 0), try orphans.count());
}

const race_tasks = 4;
const race_children = 25;

/// Children that each exit with a status of their own and leave an orphan
/// that ends at once: every other one waited for at once, and the rest once
/// they have ended and the other tasks' spawns and reaps have looked at them.
fn raceOrphans(task: u8, failures: *std.atomic.Value(u32)) std.Io.Cancelable!void {
    for (0..race_children) |i| {
        const status: u8 = @intCast(task * race_children + i + 1);
        var line: [64]u8 = undefined;
        const said = std.fmt.bufPrint(&line, "(sleep 0 &); exit {d}", .{status}) catch unreachable;
        var child = Child.spawn(io, gpa, .{ .argv = &.{ "/bin/sh", "-c", said }, .stdio = .ignore }) catch {
            _ = failures.fetchAdd(1, .monotonic);
            continue;
        };
        defer child.release(io) catch unreachable;
        if (i % 2 == 1) try std.Io.sleep(io, .fromMilliseconds(3), .awake);
        const term = child.waitTimeout(io, budget_ms) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                _ = failures.fetchAdd(1, .monotonic);
                continue;
            },
        } orelse {
            _ = failures.fetchAdd(1, .monotonic);
            _ = child.killWait(io, 0) catch {};
            continue;
        };
        if (!std.meta.eql(term, Child.Term{ .exited = status })) _ = failures.fetchAdd(1, .monotonic);
    }
}

test "with Orphans not started, an orphan goes where it always went" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows or builtin.os.tag != .linux) return error.SkipZigTest;
    if (setsidProgram() == null) return error.SkipZigTest;
    try testing.expect(!subreaperNow());

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", leaves_an_orphan ++ "; exit 5" },
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    const orphan = try orphanOf(&child);
    defer if (alive(orphan)) {
        _ = c.kill(orphan, .KILL);
    };

    // Given its second parent before `done.`, and that is not this process.
    try testing.expect(parentOf(orphan) != c.getpid());
    const looks_before = Orphans.looks.load(.monotonic);
    try testing.expectEqual(Child.Term{ .exited = 5 }, (try child.waitTimeout(io, budget_ms)) orelse
        return error.TestChildDidNotExit);
    try testing.expectEqual(looks_before, Orphans.looks.load(.monotonic));
    try testing.expect(!subreaperNow());
}

/// The parent a Linux process has now, from `/proc`.
fn parentOf(pid: posix.pid_t) posix.pid_t {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/stat", .{pid}) catch return 0;
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return 0;
    defer _ = c.close(fd);
    var text: [512]u8 = undefined;
    const n = c.read(fd, &text, text.len);
    if (n <= 0) return 0;
    const close = std.mem.lastIndexOfScalar(u8, text[0..@intCast(n)], ')') orelse return 0;
    var fields = std.mem.tokenizeScalar(u8, text[close + 1 .. @intCast(n)], ' ');
    _ = fields.next();
    return std.fmt.parseInt(posix.pid_t, fields.next() orelse return 0, 10) catch 0;
}

extern "c" fn getsid(pid: posix.pid_t) posix.pid_t;

/// The number the child printed between `pid ` and `.`, as a process id.
fn readPid(sink: *Sink) !posix.pid_t {
    return readMarkedNumber(posix.pid_t, sink);
}

/// The number the child printed between `pid ` and `.`.
///
/// The two systems name a process with different types — a signed `pid_t` and
/// an unsigned `DWORD` — and the fixtures print the same thing either way, so
/// the type is the caller's to ask for.
fn readMarkedNumber(comptime Number: type, sink: *Sink) !Number {
    const deadline: Deadline = .in(io, budget_ms);
    while (true) {
        const found = found: {
            sink.mutex.lockUncancelable(io);
            defer sink.mutex.unlock(io);
            const said = sink.bytes.items;
            const at = std.mem.indexOf(u8, said, "pid ") orelse break :found null;
            const rest = said[at + "pid ".len ..];
            const end = std.mem.indexOfScalar(u8, rest, '.') orelse break :found null;
            const number = std.fmt.parseInt(Number, rest[0..end], 10) catch break :found @as(Number, 0);
            break :found number;
        };
        if (found) |number| {
            if (number != 0) return number;
            sink.report("a nonzero decimal process id between pid and .");
            return error.TestInvalidProcessId;
        }
        if (sink.ended() or deadline.remainingMs(io) == 0) {
            sink.report("pid <number>.");
            return error.TestChildSaidNothing;
        }
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}

/// Whether the operating system still knows that process id. A zombie counts
/// as alive; nothing here reaps a process it did not start.
fn alive(pid: posix.pid_t) bool {
    if (c.kill(pid, @as(posix.SIG, @enumFromInt(0))) == 0) return true;
    return c.errno(@as(c_int, -1)) != .SRCH;
}

/// A handle on a process this package did not start, from its id. Windows
/// only.
///
/// Opened while the process is known to be running, and held: a Windows
/// process id is reused, and a later question asked by number could be about
/// somebody else. A handle stays the one process for as long as it is open,
/// even after that process has ended.
fn openById(id: win32.DWORD) !win32.HANDLE {
    return win32.OpenProcess(
        win32.SYNCHRONIZE | win32.PROCESS_QUERY_LIMITED_INFORMATION | win32.PROCESS_TERMINATE,
        .FALSE,
        id,
    ) orelse {
        std.debug.print("\nOpenProcess({d}) failed: Windows error {d}\n", .{ id, @intFromEnum(std.os.windows.GetLastError()) });
        return error.TestProcessNotThere;
    };
}

/// A failed job assertion must still end the held witness, including one
/// that the fixture accidentally started outside the child's job.
fn closeFixtureProcess(process: win32.HANDLE) void {
    if (runningNow(process)) _ = win32.TerminateProcess(process, 1);
    std.os.windows.CloseHandle(process);
}

fn expectFixtureInJob(process: win32.HANDLE, child: *Child) !void {
    var member: win32.BOOL = .FALSE;
    if (win32.IsProcessInJob(process, State.get(child).job.?, &member) == .FALSE) {
        std.debug.print("\nIsProcessInJob failed: Windows error {d}\n", .{@intFromEnum(std.os.windows.GetLastError())});
        return error.TestJobQueryFailed;
    }
    if (member == .FALSE or !runningNow(process)) {
        std.debug.print("\nfixture grandchild: in child's job={}, running={}\n", .{ member != .FALSE, runningNow(process) });
        return error.TestGrandchildNotRunningInJob;
    }
}

/// Whether that process is still running. Windows only.
fn runningNow(handle: win32.HANDLE) bool {
    return win32.WaitForSingleObject(handle, 0) == win32.WAIT_TIMEOUT;
}

/// Waits for that process to end, and says whether it did within the budget.
/// Windows only.
fn endedWithin(handle: win32.HANDLE) bool {
    return win32.WaitForSingleObject(handle, budget_ms) == win32.WAIT_OBJECT_0;
}

test "waitTree says the tree has ended, and does not say it early" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // The job object; the Linux cgroup has the test below. `Child.waitTree`
    // says why the other systems have nothing: a process group is an address
    // to send signals to, not a container the system accounts for.
    if (!is_windows) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.detached_grandchild,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = true } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var sink: Sink = .{};
    defer sink.deinit();
    var errors: Sink = .{};
    defer errors.deinit();
    var stage: []const u8 = "starting readers and reading the grandchild id";
    errdefer |err| {
        std.debug.print("\nWindows tree fixture failed at {s}: {s}; child id {?d}, result {any}\n", .{ stage, @errorName(err), child.processId(), if (State.optional(&child) != null) child.result() else @as(Child.TryWaitError!?Child.Term, null) });
        sink.report("pid <number>.");
        errors.report("fixture stderr");
    }
    try sink.start(child.stdoutFile().?);
    try errors.start(child.stderrFile().?);

    const id = try readMarkedNumber(win32.DWORD, &sink);
    stage = "opening the reported grandchild";
    const grandchild = try openById(id);
    defer closeFixtureProcess(grandchild);
    try expectFixtureInJob(grandchild, &child);
    stage = "waiting for the child and ending its tree";

    // The child ends on its own, and is left unreaped until the end: `kill`
    // declines to signal a child it has already been told is gone, so a test
    // that reaped it here would be asking the job to end a tree nothing would
    // then ask it to end. The child's own handle is what says it has exited,
    // and looking at a handle reaps nothing.
    const deadline: Deadline = .in(io, budget_ms);
    while (deadline.remainingMs(io) > 0 and runningNow(State.get(&child).id)) {
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    try testing.expect(!runningNow(State.get(&child).id));

    // The child is gone and the tree is not, which is the whole of the
    // difference between this wait and `wait`.
    try testing.expect(runningNow(grandchild));
    try testing.expect(!try child.waitTree(io, 200));

    // `.kill` is `TerminateJobObject`: the job ends what is left in it, which
    // is the same end `deinit` reaches by closing the last handle to it, and
    // the port is what says so. `deinit` is the one this cannot use, because
    // it closes the port the answer would arrive on. Contained waits consume
    // that completion before releasing the lifecycle.
    try child.kill(.kill);
    try testing.expect(try child.waitTree(io, budget_ms));
    try testing.expect(endedWithin(grandchild));

    // The message is posted once and taking it off the port consumes it, so
    // the answer has to be remembered rather than asked for twice.
    try testing.expect(try child.waitTree(io, 0));

    _ = try waitWithin(&child);
}

test "waitTree on Linux says the child's cgroup has emptied, and does not say it early" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // Linux with a cgroup this process may make: the container is the cgroup.
    if (builtin.os.tag != .linux or !try cgroupsHere()) return error.SkipZigTest;

    // The child leaves an orphan in a session of its own and ends normally,
    // and the survival policy leaves the orphan running: nothing but the
    // cgroup still relates it to the child.
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", orphan_in_own_session ++ "; exit 0" },
        .stdio = .{ .streams = .{ .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(child.stdoutFile().?);
    const orphan = try readPid(&sink);
    defer if (alive(orphan)) {
        _ = c.kill(orphan, .KILL);
    };
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));

    // The child is gone and the tree is not.
    try testing.expect(alive(orphan));
    try testing.expect(!try child.waitTree(io, 200));
    try testing.expect(!try child.waitTree(io, 0));

    _ = c.kill(orphan, .KILL);
    try testing.expect(try child.waitTree(io, budget_ms));
    try testing.expect(try child.waitTree(io, 0));
}

test "waitTree on Linux refuses a child with no cgroup of its own" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    cgroup.testing_hook.off = true;
    defer cgroup.testing_hook.off = false;

    var child = try Child.spawn(io, gpa, .{ .argv = &.{ "/bin/sh", "-c", "exit 0" }, .stdio = .ignore });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
    try testing.expectError(error.Unsupported, child.waitTree(io, 0));
}

test "a contained wait ends a grandchild before lifecycle release" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // Windows only: contained completion confirms the whole Job.
    if (!is_windows) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.detached_grandchild,
        .descendants = .contain,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = true } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var sink: Sink = .{};
    defer sink.deinit();
    var errors: Sink = .{};
    defer errors.deinit();
    var stage: []const u8 = "starting readers and reading the grandchild id";
    errdefer |err| {
        std.debug.print("\nWindows tree fixture failed at {s}: {s}; child id {?d}, result {any}\n", .{ stage, @errorName(err), child.processId(), if (State.optional(&child) != null) child.result() else @as(Child.TryWaitError!?Child.Term, null) });
        sink.report("pid <number>.");
        errors.report("fixture stderr");
    }
    try sink.start(child.stdoutFile().?);
    try errors.start(child.stderrFile().?);

    const id = try readMarkedNumber(win32.DWORD, &sink);
    stage = "opening the reported grandchild";
    const grandchild = try openById(id);
    defer closeFixtureProcess(grandchild);
    try expectFixtureInJob(grandchild, &child);
    stage = "waiting for the child and ending its tree";

    // A contained wait ends and confirms the Job before publishing its root.
    // Resource release must have nothing left to end.
    _ = try waitWithin(&child);
    try testing.expect(!runningNow(grandchild));

    const closed: Deadline = .in(io, budget_ms);
    while (!sink.ended() or !errors.ended()) {
        if (closed.remainingMs(io) == 0) return error.TestGrandchildInheritedFixturePipe;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    child.release(io) catch unreachable;

    try testing.expect(endedWithin(grandchild));
}

test "a detached child has a process group of its own and an attached one does not" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var detached = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = true,
    });
    defer detached.release(io) catch unreachable;
    defer _ = detached.killWait(io, 0) catch {};
    try testing.expect(State.get(&detached).pgid != null);

    var attached = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = false,
    });
    defer attached.release(io) catch unreachable;
    defer _ = attached.killWait(io, 0) catch {};
    try testing.expectEqual(@as(?Child.ProcessGroupId, null), State.get(&attached).pgid);
}

test "a detached child's process group is the one the operating system reports" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: Windows has no `getpgid`, and the group a
    // `CREATE_NEW_PROCESS_GROUP` child is in is not something a parent can
    // read back.
    if (is_windows) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};

    try testing.expectEqual(State.get(&child).id, State.get(&child).pgid.?);
    try testing.expectEqual(State.get(&child).id, getpgid(State.get(&child).id));
    // Which is the point of it: a signal to this process's group, the one a
    // terminal sends on Ctrl-C, does not reach the child.
    try testing.expect(getpgid(0) != State.get(&child).id);
}

test "an attached child shares the parent's process group" {
    if (is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .detach = false,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};

    try testing.expectEqual(getpgid(0), getpgid(State.get(&child).id));
}

test "killWait with no grace goes straight to the signal nothing survives" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: the claim is about a child that ignores the polite request,
    // and Windows has no polite request for a process to ignore.
    if (is_windows) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "trap '' TERM; sleep 100" },
        .stdio = .ignore,
        .detach = true,
    });
    defer child.release(io) catch unreachable;

    try testing.expectEqual(Child.Term{ .signal = .KILL }, try child.killWait(io, 0));
}

//======================================================================
// Pseudo-terminals.
//======================================================================

test "what a child writes to its terminal reaches the master" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    // Traced stage by stage, like the shell test below and for the same
    // reason: this one has hung on a Windows runner with nothing to say.
    // The order out, for every test in this section: stop the reader, end the
    // child, then close the pair. The reader first because closing a file
    // another task is reading is a race on its descriptor -- the number can be
    // reused by the next open, and a read that starts after the close then
    // reads someone else's file -- so the sink is declared after the pair and
    // the child, which puts its `deinit` first. The child before the pair
    // because closing a pseudoconsole waits for its client; `Pty.close` reads
    // the master itself while it does.

    trace.print("master: opening a pair", .{});
    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.say_on_terminal,
        .stdio = .{ .pty = &pty },
        .detach = !is_windows,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    if (trace.enabled()) trace.print("master: child started, id={d}", .{childId(child)});
    // The one place the two systems want different timing, and the reason
    // `Pty.closeSlave` documents it at length.
    if (!is_windows) pty.closeSlave(io);

    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(pty.readFile());
    trace.print("master: reading the master", .{});

    try sink.expect("on the terminal");
    trace.print("master: the child said what it was asked to", .{});

    _ = try child.killWait(io, budget_ms);
    trace.print("master: reaped", .{});
}

test "a cursor shape the child wrote reaches the master where passthrough was granted" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // Windows only: this is a claim about `PSEUDOCONSOLE_PASSTHROUGH_MODE`,
    // and on POSIX there is nothing between the two ends of a pair rewriting
    // anything in the first place.
    if (!is_windows) return error.SkipZigTest;

    var pty = try Pty.open(std.testing.allocator, .{
        .rows = 24,
        .cols = 80,
        .console = .{ .passthrough = true },
    });
    defer pty.close(io);

    // The gate, and the reason it is one. Passthrough is Windows 11 22H2 and
    // newer; an older system refuses the whole call and `Pty.open` asks again
    // without it. On such a machine the console host interprets what the child
    // wrote and what reaches the master is its redraw, in which a sequence the
    // host does not model -- the cursor shape is the one people notice -- is
    // simply not there. That is the documented behaviour and not a failure, so
    // the test says which machine it is on and stops.
    if (!pty.consoleOptions().passthrough) {
        std.debug.print(
            "\nthis Windows did not grant PSEUDOCONSOLE_PASSTHROUGH_MODE; skipping\n",
            .{},
        );
        return error.SkipZigTest;
    }

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.cursor_shape,
        .stdio = .{ .pty = &pty },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};

    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(pty.readFile());

    // Byte for byte, as the child wrote it: `DECSCUSR` with parameter 5.
    try sink.expect("\x1b[5 q");

    _ = try child.killWait(io, budget_ms);
}

test "a child on a pty sees a terminal" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: `cmd.exe` has no way to ask, and on Windows the answer is
    // structural anyway -- a pseudoconsole client is attached to a console by
    // construction.
    if (is_windows) return error.SkipZigTest;

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "test -t 0 && test -t 1 && test -t 2" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
}

test "a child on a pty reports the window size it was given, and the one it is resized to" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: this asks the child what size its terminal is, and `stty` is
    // how a shell asks. Windows has no equivalent a `cmd.exe` one-liner can
    // print; that a pseudoconsole takes the new size is `Pty`'s own test.
    if (is_windows) return error.SkipZigTest;

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 30, .cols = 100 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        // Reports the size, waits for a byte, and reports it again: the second
        // report is taken after the resize below.
        .argv = &.{ "/bin/sh", "-c", "stty size; read ignored; stty size" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
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
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: the claim is that a line discipline turns a byte into a
    // signal for a foreground process group, and neither half of that sentence
    // has a Windows counterpart.
    if (is_windows) return error.SkipZigTest;

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    // `exec` so the shell is replaced and the signal has one process to reach.
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 100" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
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
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 100" },
        .stdio = .{ .pty = &pty },
        .detach = false,
    });
    defer child.release(io) catch unreachable;
    pty.closeSlave(io);

    try pty.writeFile().writeStreamingAll(io, "\x03");

    // There is no foreground process group on this terminal, so the byte is
    // just a byte. The child is still there; `killWait` is what ends it.
    try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    try testing.expectEqual(@as(?Child.Term, null), try child.tryWait());
    try testing.expectEqual(Child.Term{ .signal = .TERM }, try child.killWait(io, 500));
}

test "a detached pty child is the terminal's foreground process group, and an attached one is not" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: the claim is about the group a line discipline sends its
    // generated signals to, which is not a thing a console has.
    if (is_windows) return error.SkipZigTest;

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 100" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    // `exec`, so the group the shell made is now the one `sleep` is in, and
    // the child's process id is that group's id.
    try testing.expectEqual(State.get(&child).id, try conduit.foregroundGroup(pty.readHandle().?));

    // The other half of the claim, and the reason this is worth asking at all:
    // a child on a pair without `detach` sees a terminal that has no
    // foreground group, so nothing typed at the master will ever become a
    // signal for it.
    var quiet = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer quiet.close(io);

    var attached = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 100" },
        .stdio = .{ .pty = &quiet },
        .detach = false,
    });
    defer attached.release(io) catch unreachable;
    defer _ = attached.killWait(io, 0) catch {};
    quiet.closeSlave(io);

    try testing.expectError(
        error.NoForegroundGroup,
        conduit.foregroundGroup(quiet.readHandle().?),
    );
}

test "closing the master hangs the terminal up, and a detached child gets SIGHUP" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: there is no Windows counterpart. Closing a pseudoconsole is
    // `ClosePseudoConsole`, which ends the client outright rather than
    // signalling it, and that is `Pty.closeSlave`, not this.
    if (is_windows) return error.SkipZigTest;

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 100" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    // Dropping the last master descriptor is the pseudo-terminal spelling of a
    // modem dropping the line. The child is the session leader here -- that is
    // what `detach` with `.pty` made it -- so the kernel sends it `SIGHUP`,
    // whose default action it has not changed.
    pty.closeMaster(io);

    try testing.expectEqual(Child.Term{ .signal = .HUP }, try waitWithin(&child));
}

test "stderr_to sends the child's standard error to a file of the caller's" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only, for want of a fixture rather than for want of the feature:
    // the sink here is the terminal end of a second pair, which is the one
    // writable file this package can open without touching the filesystem, and
    // a pseudoconsole is not a file.
    if (is_windows) return error.SkipZigTest;

    var sink_pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer sink_pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'to stderr' 1>&2" },
        .stdio = .{ .pipes = .{ .stdin = false } },
        .stderr_to = sink_pty.slaveFile(),
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};

    // The stderr pipe was not created, because the file replaced it.
    try testing.expectEqual(@as(?std.Io.File, null), child.stderrFile());

    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(sink_pty.readFile());

    try sink.expect("to stderr");
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
}

//======================================================================
// Per-stream stdio.
//======================================================================

test "each stream is chosen on its own" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // A pipe for what is wanted and the null device for what is not, which is
    // the combination `.pipes` cannot say: it pipes a stream or leaves it the
    // parent's, and leaving standard error the parent's puts the child's
    // complaints on the test runner's own terminal.
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.out_and_err,
        .stdio = .{ .streams = .{
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    // Only the stream that asked for a pipe has one.
    try testing.expectEqual(@as(?std.Io.File, null), child.stdinFile());
    try testing.expect(child.stdoutFile() != null);
    try testing.expectEqual(@as(?std.Io.File, null), child.stderrFile());

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, result.stdout(), "to stdout") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout(), "to stderr") == null);
    try testing.expectEqualStrings("", result.stderr());
    try testing.expectEqual(Child.Term{ .exited = 0 }, result.term());
}

test "the terminal end of a pair can be one stream and a pipe another" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: the claim needs the terminal end to be a file, and on
    // Windows a pseudoconsole is an object a whole process is attached to.
    // `Pty.slaveFile` is a compile error there and says so.
    if (is_windows) return error.SkipZigTest;

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    // Standard output is the terminal; standard error is a pipe. The child
    // reports which of the two it thinks is one, so the answer comes from the
    // child rather than from this process looking at its own descriptors.
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{
            "/bin/sh",                                                                                "-c",
            "test -t 1 && printf 'stdout is a terminal\n'; test -t 2 || printf 'stderr is not' 1>&2",
        },
        .stdio = .{ .streams = .{
            .stdin = .ignore,
            .stdout = .{ .file = pty.slaveFile() },
            .stderr = .pipe,
        } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    // The terminal end is the caller's here, and this process is still holding
    // it: closing it is what lets a read of the master finish.
    pty.closeSlave(io);

    var on_terminal: Sink = .{};
    defer on_terminal.deinit();
    try on_terminal.start(pty.readFile());
    var on_pipe: Sink = .{};
    defer on_pipe.deinit();
    try on_pipe.start(child.stderrFile().?);

    try on_terminal.expect("stdout is a terminal");
    try on_pipe.expect("stderr is not");
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
}

test "a stream can be closed rather than connected to anything" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: the claim is what a child finds at a descriptor that is not
    // there, and `cmd.exe` has no way to report it.
    if (is_windows) return error.SkipZigTest;

    // With nothing on descriptor 1, the write fails and the shell says so with
    // its status. The same program with the null device there succeeds, which
    // is what makes this about `.close` and not about the program.
    var closed = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'x'" },
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .close, .stderr = .ignore } },
    });
    defer closed.release(io) catch unreachable;
    errdefer _ = closed.killWait(io, 0) catch {};
    try testing.expect(!conduit.succeeded(try waitWithin(&closed)));

    var ignored = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'x'" },
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .ignore, .stderr = .ignore } },
    });
    defer ignored.release(io) catch unreachable;
    errdefer _ = ignored.killWait(io, 0) catch {};
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&ignored));
}

test "the older stdio shapes are the per-stream ones under another name" {
    try testing.expectEqual(
        [3]Child.Stream{ .inherit, .inherit, .inherit },
        (Child.Stdio{ .inherit = {} }).perStream(),
    );
    try testing.expectEqual(
        [3]Child.Stream{ .ignore, .ignore, .ignore },
        (Child.Stdio{ .ignore = {} }).perStream(),
    );
    try testing.expectEqual(
        [3]Child.Stream{ .pipe, .inherit, .pipe },
        (Child.Stdio{ .pipes = .{ .stdout = false } }).perStream(),
    );
}

//======================================================================
// The clean slate before execve.
//======================================================================

test "a signal this process ignores is back at its default action in the child" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: the claim is about signal dispositions surviving `execve`,
    // and Windows has neither.
    if (is_windows) return error.SkipZigTest;

    // A shell that starts a background job ignores `SIGINT` in it, and
    // `execve` keeps an ignored signal ignored. So a child spawned from one
    // would be deaf to the Ctrl-C on its own terminal -- the one thing a
    // pseudo-terminal exists to deliver -- unless the spawn puts every
    // ignored signal back at its default action, which is what this asserts.
    var ignored: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    var previous: posix.Sigaction = undefined;
    posix.sigaction(.INT, &ignored, &previous);
    defer posix.sigaction(.INT, &previous, null);

    // The shell sends itself the signal. With the disposition reset it dies of
    // it; with the parent's ignore inherited it carries on and says so.
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "kill -INT $$; printf 'SURVIVED'" },
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expectEqualStrings("", result.stdout());
    try testing.expectEqual(Child.Term{ .signal = .INT }, result.term());
}

//======================================================================
// Credentials.
//======================================================================

test "a child's file-creation mask is the one it was given" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: a Windows process has no umask, and `credentials` there is
    // `error.Unsupported`, which the test below this one checks.
    if (is_windows) return error.SkipZigTest;

    // `umask` with no argument prints the mask, and 0077 is not a default
    // anywhere, so seeing it means this package set it and not the shell.
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "umask" },
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
        .credentials = .{ .umask = 0o077 },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, result.stdout(), "77") != null);
    try testing.expectEqual(Child.Term{ .exited = 0 }, result.term());
}

test "a uid and gid this process may take are taken, and one it may not is an error" {
    if (is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    // The ids this process already has. Changing to them is allowed without
    // privilege, so what this proves is that the calls are made and that the
    // child really runs under what they set -- which is the part a caller
    // cannot check any other way.
    const uid = std.c.getuid();
    const gid = std.c.getgid();

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "id -u; id -g" },
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
        .credentials = .{ .uid = uid, .gid = gid },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    var wanted: [64]u8 = undefined;
    try testing.expect(std.mem.indexOf(
        u8,
        result.stdout(),
        try std.fmt.bufPrint(&wanted, "{d}", .{uid}),
    ) != null);
    try testing.expectEqual(Child.Term{ .exited = 0 }, result.term());

    // And a change this process is not allowed to make is an error from
    // `spawn`, not a child that started anyway with the credentials it had.
    // Only asked where it is true: a suite running as root may become anyone.
    if (uid != 0) {
        try testing.expectError(error.CredentialsFailed, Child.spawn(io, gpa, .{
            .argv = &.{ "/bin/sh", "-c", "exit 0" },
            .stdio = .ignore,
            .credentials = .{ .uid = 0 },
        }));
    }
}

test "a resource limit set at spawn is the child's own" {
    // POSIX only: Windows has no `setrlimit`, and the test below this one
    // checks that the option is refused there rather than dropped.
    if (is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    // Lowering a soft limit needs no privilege, and `ulimit -n` is how a shell
    // reports the one for open files. The hard limit is left where it is: a
    // child cannot raise a hard limit back, so lowering it would be a
    // different claim.
    const current = try posix.getrlimit(.NOFILE);
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "ulimit -n" },
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
        .resource_limits = &.{.{
            .resource = .NOFILE,
            .limit = .{ .cur = 64, .max = current.max },
        }},
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, result.stdout(), "64") != null);
    try testing.expectEqual(Child.Term{ .exited = 0 }, result.term());

    // This process is not the one that was limited, which is the whole reason
    // the option exists: doing it here would have done it to everything this
    // process goes on to start.
    try testing.expectEqual(current.cur, (try posix.getrlimit(.NOFILE)).cur);

    // A limit the operating system refuses -- a soft limit above its hard one
    // is refused for anybody, privileged or not -- is an error from `spawn`
    // rather than a child that started without it.
    try testing.expectError(error.ResourceLimitsFailed, Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .stdio = .ignore,
        .resource_limits = &.{.{
            .resource = .NOFILE,
            .limit = .{ .cur = 100, .max = 10 },
        }},
    }));
}

test "a job limit bounds what the child's tree may do" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // Windows only: the limit is on the job object, which is the container the
    // child and everything it starts live in, and POSIX has no such thing.
    if (!is_windows) return error.SkipZigTest;

    // One process in the job, and the child is it: what the child tries to
    // start does not start. The same program without the limit does, which is
    // what makes this about the limit rather than about `cmd.exe`.
    const argv: []const []const u8 = &.{ "cmd.exe", "/c", "cmd.exe /c echo NESTED" };

    var free = try Child.spawn(io, gpa, .{
        .argv = argv,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer free.release(io) catch unreachable;
    errdefer _ = free.killWait(io, 0) catch {};
    var without = try free.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer without.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, without.stdout(), "NESTED") != null);

    var bounded = try Child.spawn(io, gpa, .{
        .argv = argv,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
        .job_limits = .{ .active_processes = 1 },
    });
    defer bounded.release(io) catch unreachable;
    errdefer _ = bounded.killWait(io, 0) catch {};
    var with = try bounded.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer with.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, with.stdout(), "NESTED") == null);
}

test "Windows CPU job limits reject values outside a whole-system percentage" {
    if (!is_windows) return error.SkipZigTest;

    inline for (.{ @as(u32, 0), @as(u32, 10_001) }) |rate| {
        try testing.expectError(error.InvalidJobLimit, Child.spawn(io, gpa, .{
            .argv = &.{ "cmd.exe", "/c", "exit 0" },
            .stdio = .ignore,
            .job_limits = .{ .cpu_rate = rate },
        }));
    }
}

test "job limits are refused on POSIX rather than quietly not applied" {
    if (is_windows) return error.SkipZigTest;
    try testing.expectError(error.Unsupported, Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .job_limits = .{ .active_processes = 1 },
    }));
}

test "resource limits are refused on Windows rather than quietly not applied" {
    if (!is_windows) return error.SkipZigTest;
    try testing.expectError(error.Unsupported, Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .resource_limits = &.{.{ .resource = {}, .limit = {} }},
    }));
}

test "credentials are refused on Windows rather than quietly not applied" {
    if (!is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    try testing.expectError(error.Unsupported, Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .stdio = .ignore,
        .credentials = .{ .umask = 0o077 },
    }));
}

//======================================================================
// Environment, working directory, and failure.
//======================================================================

test "the child's environment and working directory are the ones asked for" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var environ = try conduit.environ.inherit(gpa, &.{
        .{ .name = "CONDUIT_TEST_VALUE", .value = "present" },
    });
    defer environ.deinit();

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.report_environment,
        .cwd = script.working_directory,
        .environ = &environ,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, result.stdout(), "present") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout(), script.working_directory_mark) != null);
    try testing.expectEqual(Child.Term{ .exited = 0 }, result.term());
}

test "a scrubbed environment is the only thing the child sees" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only for the fixture, not for the feature: `cmd.exe` cannot be run
    // without the environment Windows starts it with, so a child with nothing
    // but one variable has nothing to report it with.
    if (is_windows) return error.SkipZigTest;

    var environ = try conduit.environ.only(gpa, &.{
        .{ .name = "CONDUIT_TEST_VALUE", .value = "present" },
    });
    defer environ.deinit();

    // `HOME`, because a shell invents a `PATH` for itself when it is handed
    // none and would make this test pass for the wrong reason. Nothing invents
    // a `HOME`.
    try testing.expect(std.c.getenv("HOME") != null);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "sh", "-c", "printf '%s|%s' \"$CONDUIT_TEST_VALUE\" \"$HOME\"" },
        .environ = &environ,
        // The child has no PATH, so the program has to be looked up in this
        // process's -- which is what this setting is for and the reason the
        // two features are tested together.
        .path_search = .parent_environ,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    // The variable that was asked for, and nothing else: not this process's
    // `HOME`, and not the `PATH` the spawn itself searched.
    try testing.expectEqualStrings("present|", result.stdout());
    try testing.expect(conduit.succeeded(result.term()));
}

test "path_search decides which PATH a bare program name is looked up in" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    if (is_windows) {
        var environment = try conduit.environ.inherit(gpa, &.{});
        defer environment.deinit();
        const comspec = environment.get("COMSPEC") orelse return error.SkipZigTest;

        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try std.Io.Dir.copyFile(
            std.Io.Dir.cwd(),
            comspec,
            tmp.dir,
            "conduit-child-path.exe",
            io,
            .{},
        );
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const path_len = try tmp.dir.realPath(io, &path_buffer);
        try conduit.environ.apply(&environment, &.{.{
            .name = "PATH",
            .value = path_buffer[0..path_len],
        }});

        var child = try Child.spawn(io, gpa, .{
            .argv = &.{ "conduit-child-path", "/c", "exit 0" },
            .environ = &environment,
            .stdio = .ignore,
        });
        defer child.release(io) catch unreachable;
        errdefer _ = child.killWait(io, 0) catch {};
        try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
        return;
    }

    var empty_path = try conduit.environ.inherit(gpa, &.{
        .{ .name = "PATH", .value = "/conduit-no-such-directory" },
    });
    defer empty_path.deinit();

    // The child's PATH, which is the default and what a shell does: the
    // program is looked for where the child would look for it, and it is not
    // there.
    try testing.expectError(error.FileNotFound, Child.spawn(io, gpa, .{
        .argv = &.{"sh"},
        .environ = &empty_path,
        .stdio = .ignore,
    }));

    // This process's PATH, whatever the child is being handed. Same arguments,
    // different answer, which is the whole reason the option is written down.
    var found = try Child.spawn(io, gpa, .{
        .argv = &.{ "sh", "-c", "exit 0" },
        .environ = &empty_path,
        .path_search = .parent_environ,
        .stdio = .ignore,
    });
    defer found.release(io) catch unreachable;
    errdefer _ = found.killWait(io, 0) catch {};
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&found));

    // And no search at all: a bare name is not a path, so there is nothing to
    // execute.
    try testing.expectError(error.FileNotFound, Child.spawn(io, gpa, .{
        .argv = &.{"sh"},
        .path_search = .none,
        .stdio = .ignore,
    }));

    // A full path is still a full path under that setting.
    var direct = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "exit 0" },
        .path_search = .none,
        .stdio = .ignore,
    });
    defer direct.release(io) catch unreachable;
    errdefer _ = direct.killWait(io, 0) catch {};
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&direct));
}

test "a program that is not there is an error, not a child that exits 127" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    try testing.expectError(error.FileNotFound, Child.spawn(io, gpa, .{
        .argv = &.{"conduit-no-such-program-anywhere"},
        .stdio = .ignore,
    }));
    try testing.expectError(error.InvalidArgv, Child.spawn(io, gpa, .{
        .argv = &.{},
        .stdio = .ignore,
    }));
    // A NUL would end the argument where it stands, on either system.
    try testing.expectError(error.InvalidArgv, Child.spawn(io, gpa, .{
        .argv = &.{ "conduit-no-such-program-anywhere", "a\x00b" },
        .stdio = .ignore,
    }));
    if (!is_windows) {
        try testing.expectError(error.FileNotFound, Child.spawn(io, gpa, .{
            .argv = &.{"conduit-no-such-program-anywhere"},
            .stdio = .ignore,
            .fd_policy = .close_all,
        }));
    }
}

test "a working directory that is not there is an error" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const missing = if (is_windows)
        "C:\\conduit-no-such-directory\\at-all"
    else
        "/nonexistent/conduit-no-such-directory";
    try testing.expectError(error.BadWorkingDirectory, Child.spawn(io, gpa, .{
        .argv = &script.sleep_forever,
        .cwd = missing,
        .stdio = .ignore,
    }));
}

test "a program at a path that is not there is an error" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // Windows resolves the program from the command line, and a path with no
    // such file is `ERROR_FILE_NOT_FOUND` all the same; the POSIX side goes
    // through a different branch of the search, which is why both are here.
    const missing = if (is_windows)
        "C:\\conduit-no-such-directory\\program.exe"
    else
        "/nonexistent/conduit-no-such-program";
    try testing.expectError(error.FileNotFound, Child.spawn(io, gpa, .{
        .argv = &.{missing},
        .stdio = .ignore,
    }));
}

test "a batch file is refused rather than handed to cmd.exe" {
    if (!is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    try testing.expectError(error.UnsupportedBatchFile, Child.spawn(io, gpa, .{
        .argv = &.{ "C:\\conduit-no-such-script.bat", "arg" },
        .stdio = .ignore,
    }));
}

//======================================================================
// The shell.
//======================================================================

test "spawnShell starts the user's shell on a pair" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    // This one is traced stage by stage. It has hung once on a Windows runner
    // with nothing to say for itself, and the stages are what a run that does
    // it again will have to say.
    // The order out: see the first test in the pseudo-terminal section. The
    // shell's own `deinit` is what closes the pair, so the sink is declared
    // after it and stopped before it.

    trace.print("shell: opening a pair and starting the shell", .{});
    var shell = try conduit.spawnShell(io, gpa, .{
        .args = &script.shell_arguments,
        .size = .{ .rows = 40, .cols = 132 },
    });
    defer shell.deinit(io);
    defer _ = shell.child().killWait(io, 0) catch {};
    if (trace.enabled()) trace.print("shell: started, id={d}", .{childId(shell.child().*)});

    try testing.expectEqual(@as(u16, 40), (try shell.pty().size()).rows);

    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(shell.pty().readFile());
    trace.print("shell: reading the master", .{});

    try sink.expect("hi");
    trace.print("shell: the shell said what it was asked to", .{});

    _ = try shell.child().killWait(io, budget_ms);
    trace.print("shell: reaped", .{});
}

/// The child's operating-system name as a number, for a trace line that has to
/// compile on both systems: a process id on POSIX, a handle on Windows.
fn childId(child: Child) usize {
    return if (is_windows) @intFromPtr(State.get(child).id) else @intCast(State.get(child).id);
}

/// `getpgid` is not declared in `std.c`, and two of the tests above are about
/// exactly what it reports. Never referenced on Windows, where those tests
/// skip, so the declaration costs nothing there.
extern "c" fn getpgid(pid: posix.pid_t) posix.pid_t;

//======================================================================
// The two spawn paths.
//======================================================================

/// Whether `Child.spawn` has a `posix_spawn` path in this build.
const fast_path = if (is_windows) false else @import("posix_spawn.zig").available;

test "both spawn paths start the same child" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows or !fast_path) return error.SkipZigTest;
    // A child in a cgroup of its own is always forked, so this is about the
    // spawns that take `posix_spawn`: those where no cgroup is made.
    cgroup.testing_hook.off = true;
    defer cgroup.testing_hook.off = false;

    // The same spawn twice, once down each path. `cwd` is what sends the
    // second one back to the fork -- there is no file action for a working
    // directory that means the same thing on both systems -- and `/` is a
    // directory every one of them has.
    for ([_]?[]const u8{ null, "/" }) |cwd| {
        var child = try Child.spawn(io, gpa, .{
            .argv = &.{ "/bin/sh", "-c", "printf 'out'; printf 'err' 1>&2; exit 3" },
            .cwd = cwd,
            .stdio = .{ .pipes = .{ .stdin = false } },
            .detach = true,
        });
        defer child.release(io) catch unreachable;
        errdefer _ = child.killWait(io, 0) catch {};

        // Detached either way, and the group is the child's own.
        try testing.expectEqual(State.get(&child).id, State.get(&child).pgid.?);
        try testing.expectEqual(State.get(&child).id, getpgid(State.get(&child).id));

        var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
        defer result.deinit(gpa);
        try testing.expectEqualStrings("out", result.stdout());
        try testing.expectEqualStrings("err", result.stderr());
        try testing.expectEqual(Child.Term{ .exited = 3 }, result.term());
    }
}

test "a child on the posix_spawn path starts with the same clean slate" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows or !fast_path) return error.SkipZigTest;
    // A child in a cgroup of its own is always forked, so this is about the
    // spawns that take `posix_spawn`: those where no cgroup is made.
    cgroup.testing_hook.off = true;
    defer cgroup.testing_hook.off = false;

    // The claim the fork child makes by hand, made here by an attribute: an
    // ignored signal is back at its default action.
    var ignored: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    var previous: posix.Sigaction = undefined;
    posix.sigaction(.INT, &ignored, &previous);
    defer posix.sigaction(.INT, &previous, null);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "kill -INT $$; printf 'SURVIVED'" },
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);
    try testing.expectEqualStrings("", result.stdout());
    try testing.expectEqual(Child.Term{ .signal = .INT }, result.term());
}

test "a spawn expressible by file actions makes no fork call" {
    if (is_windows or !fast_path) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    cgroup.testing_hook.off = true;
    defer cgroup.testing_hook.off = false;
    const calls = @import("test_support.zig").SpawnCalls;
    calls.forks = 0;
    calls.file_actions = 0;
    var child = try Child.spawn(io, gpa, .{ .argv = &.{ "/bin/sh", "-c", "exit 0" }, .stdio = .ignore });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
    try testing.expectEqual(@as(usize, 0), calls.forks);
    try testing.expectEqual(@as(usize, 1), calls.file_actions);

    // cwd cannot be expressed by this implementation's file actions.
    var forked = try Child.spawn(io, gpa, .{ .argv = &.{ "/bin/sh", "-c", "exit 0" }, .cwd = "/", .stdio = .ignore });
    defer forked.release(io) catch unreachable;
    defer _ = forked.killWait(io, 0) catch {};
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&forked));
    try testing.expectEqual(@as(usize, 1), calls.forks);
    try testing.expectEqual(@as(usize, 1), calls.file_actions);
}

//======================================================================
// Descriptor hygiene.
//======================================================================

test "fd_policy close_all leaves the child its three streams and nothing else" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: a Windows child is given the handles named in an attribute
    // list and nothing else, so `.close_all` is what it already does.
    if (is_windows) return error.SkipZigTest;

    // A descriptor this process opened without close-on-exec, which every
    // child it starts is otherwise handed a copy of. Put out of the way above
    // 16, where the listing program's own descriptors cannot be confused with
    // it.
    const opened = c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
    try testing.expect(opened >= 0);
    defer _ = c.close(opened);
    const inheritable = c.fcntl(opened, c.F.DUPFD, @as(c_int, 16));
    try testing.expect(inheritable >= 16 and inheritable < 64);
    defer _ = c.close(inheritable);

    const streams: Child.Stdio = .{ .streams = .{
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    } };

    var without = try Child.spawn(io, gpa, .{ .argv = &list_descriptors, .stdio = streams });
    defer without.release(io) catch unreachable;
    errdefer _ = without.killWait(io, 0) catch {};
    var inherited = try without.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer inherited.deinit(gpa);

    var with = try Child.spawn(io, gpa, .{
        .argv = &list_descriptors,
        .stdio = streams,
        .fd_policy = .close_all,
    });
    defer with.release(io) catch unreachable;
    errdefer _ = with.killWait(io, 0) catch {};
    var closed = try with.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer closed.deinit(gpa);

    // The default hands it on, whichever path started the child; the policy
    // does not.
    const mask = @as(u64, 1) << @intCast(inheritable);
    try testing.expect(descriptorSet(inherited.stdout()) & mask != 0);
    try testing.expect(descriptorSet(closed.stdout()) & mask == 0);
}

test "a caller's handle is as inheritable after a spawn as it was before" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // Windows only: inheritance there is a flag on the handle and
    // `CreateProcessW` takes every inheritable handle at once, so a spawn has
    // to set the flag on a file the caller opened -- and then put it back, or
    // a spawn elsewhere in the process inherits a handle nobody gave it. POSIX
    // says the same thing per-child with `dup2`, and has nothing to restore.
    if (!is_windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(io, "out", .{});
    defer sink.close(io);

    _ = win32.SetHandleInformation(sink.handle, win32.HANDLE_FLAG_INHERIT, 0);
    var before: u32 = 1;
    try testing.expect(win32.GetHandleInformation(sink.handle, &before) != .FALSE);
    try testing.expectEqual(@as(u32, 0), before & win32.HANDLE_FLAG_INHERIT);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "cmd.exe", "/c", "echo to the caller's file" },
        .stdio = .{ .streams = .{
            .stdin = .ignore,
            .stdout = .{ .file = sink },
            .stderr = .ignore,
        } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));

    // The child got it, and this process has it back the way it was.
    var after: u32 = 1;
    try testing.expect(win32.GetHandleInformation(sink.handle, &after) != .FALSE);
    try testing.expectEqual(@as(u32, 0), after & win32.HANDLE_FLAG_INHERIT);

    var contents: [64]u8 = undefined;
    const written = try tmp.dir.readFile(io, "out", &contents);
    try testing.expect(std.mem.indexOf(u8, written, "to the caller's file") != null);
}

test "concurrent Windows spawns never change a caller handle's inheritance flag" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (!is_windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var sink = try tmp.dir.createFile(io, "out", .{});
    defer sink.close(io);
    try testing.expect(win32.SetHandleInformation(sink.handle, win32.HANDLE_FLAG_INHERIT, 0) != .FALSE);

    var changed: std.atomic.Value(bool) = .init(false);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    var started: usize = 0;
    while (started < 6) : (started += 1) {
        group.concurrent(io, spawnWithSharedHandle, .{ sink, &changed }) catch break;
    }
    if (started == 0) return error.SkipZigTest;
    try group.await(io);

    var flags: u32 = 0;
    try testing.expect(win32.GetHandleInformation(sink.handle, &flags) != .FALSE);
    try testing.expectEqual(@as(u32, 0), flags & win32.HANDLE_FLAG_INHERIT);
    try testing.expect(!changed.load(.acquire));
}

fn spawnWithSharedHandle(sink: std.Io.File, changed: *std.atomic.Value(bool)) std.Io.Cancelable!void {
    var iteration: usize = 0;
    while (iteration < 8) : (iteration += 1) {
        var child = Child.spawn(io, gpa, .{
            .argv = &.{ "cmd.exe", "/c", "exit 0" },
            .stdio = .{ .streams = .{
                .stdin = .ignore,
                .stdout = .{ .file = sink },
                .stderr = .ignore,
            } },
        }) catch {
            changed.store(true, .release);
            return;
        };
        _ = child.wait(io) catch {
            _ = child.killWait(io, 0) catch {};
            child.release(io) catch unreachable;
            changed.store(true, .release);
            return;
        };
        child.release(io) catch unreachable;

        var flags: u32 = 0;
        if (win32.GetHandleInformation(sink.handle, &flags) == .FALSE or
            flags & win32.HANDLE_FLAG_INHERIT != 0)
        {
            changed.store(true, .release);
        }
    }
}

test "a Windows child with every stream closed inherits no unrelated handle" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (!is_windows) return error.SkipZigTest;
    const windows = std.os.windows;

    // A handle this process holds that is inheritable and has nothing to do
    // with the child: what `bInheritHandles` alone would hand over. An event,
    // because two handles to one event can be shown to be one thing --
    // signal through one, and the other is signalled -- which is a question
    // the operating system answers about the object rather than about a
    // number.
    var security: win32.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(win32.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = .TRUE,
    };
    const secret = win32.CreateEventW(&security, .TRUE, .FALSE, null) orelse return error.NoEvent;
    defer windows.CloseHandle(secret);

    // The question is put to the child's handle table from here, not to a
    // program running in the child: an inherited handle keeps its value, so
    // the child is asked for a copy of whatever it holds at that value, and
    // the copy is signalled. Asking the child whether the value is *valid*
    // would not do -- a handle value is an index into a table the child
    // fills with handles of its own, and a program the size of a shell holds
    // hundreds, so the number is nearly always in use for something else.
    // The child only has to exist to be asked, and is asked before it has
    // had time to do anything.
    //
    // First on this process, which certainly holds it: the probe has to be
    // able to see a handle before its not seeing one means anything.
    try testing.expectEqual(Probe.the_object, probe(windows.GetCurrentProcess(), secret));

    const sleep = [_][]const u8{
        "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 30",
    };

    var child = try Child.spawn(io, gpa, .{
        .argv = &sleep,
        .stdio = .{ .streams = .{ .stdin = .close, .stdout = .close, .stderr = .close } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    const found = probe(State.get(&child).id, secret);
    // A child that had already gone would hold nothing and prove nothing.
    if (try child.tryWait()) |term| {
        std.debug.print("the child ended before it was asked: {any}\n", .{term});
        return error.TestChildDidNotWait;
    }
    if (found != .nothing) std.debug.print("the child holds the value: {t}\n", .{found});
    try testing.expectEqual(Probe.nothing, found);

    // The control: the same program started the plain Windows way, with
    // `bInheritHandles` and no list, does hold it. Without this the claim
    // above would also be made by a probe that cannot see into a child. It
    // is started suspended and never resumed -- its handle table is filled
    // before `CreateProcessW` returns, and a process that never runs cannot
    // exit, write anywhere or care what its streams are.
    const control = try plainSpawn(&sleep);
    defer {
        _ = win32.TerminateProcess(control, 1);
        windows.CloseHandle(control);
    }
    const held = probe(control, secret);
    if (held != .the_object) std.debug.print("the control holds the value: {t}\n", .{held});
    try testing.expectEqual(Probe.the_object, held);
}

/// What a process holds at the value a handle has in this one.
const Probe = enum { nothing, something_else, the_object };

/// Asks `process` for a copy of what it holds at `event`'s value, signals
/// through the copy, and says whether `event` -- this process's handle --
/// was what got signalled. Prints what the system said wherever the answer
/// is not the plain one, so a failure names its cause.
fn probe(process: std.os.windows.HANDLE, event: std.os.windows.HANDLE) Probe {
    const windows = std.os.windows;
    var copy: windows.HANDLE = undefined;
    if (win32.DuplicateHandle(
        process,
        event,
        windows.GetCurrentProcess(),
        &copy,
        0,
        .FALSE,
        win32.DUPLICATE_SAME_ACCESS,
    ) == .FALSE) {
        const code = windows.GetLastError();
        if (code != .INVALID_HANDLE) {
            std.debug.print("DuplicateHandle of 0x{x} from the process: GetLastError({d})\n", .{
                @intFromPtr(event),
                @intFromEnum(code),
            });
        }
        return .nothing;
    }
    defer windows.CloseHandle(copy);

    _ = win32.ResetEvent(event);
    defer _ = win32.ResetEvent(event);
    if (win32.SetEvent(copy) == .FALSE) {
        std.debug.print("SetEvent on the copy of 0x{x}: GetLastError({d})\n", .{
            @intFromPtr(event),
            @intFromEnum(windows.GetLastError()),
        });
        return .something_else;
    }
    const waited = win32.WaitForSingleObject(event, 0);
    if (waited == win32.WAIT_OBJECT_0) return .the_object;
    std.debug.print("the copy of 0x{x} is another object: wait said {d}\n", .{ @intFromPtr(event), waited });
    return .something_else;
}

/// `CreateProcessW` as a program that has not thought about inheritance
/// calls it: every inheritable handle goes to the child. The child is
/// created suspended and given no standard handles, so it never runs; what
/// comes back is its process handle, for the caller to end and close.
fn plainSpawn(argv: []const []const u8) !std.os.windows.HANDLE {
    const windows = std.os.windows;
    const joined = try std.mem.join(gpa, " ", argv);
    defer gpa.free(joined);
    const line = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, joined);
    defer gpa.free(line);

    var startup: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    startup.cb = @sizeOf(windows.STARTUPINFOW);
    startup.dwFlags = win32.STARTF_USESTDHANDLES;
    var information: windows.PROCESS.INFORMATION = undefined;
    if (windows.kernel32.CreateProcessW(
        null,
        line.ptr,
        null,
        null,
        .TRUE,
        .{ .create_suspended = true },
        null,
        null,
        &startup,
        &information,
    ) == .FALSE) {
        std.debug.print("the control did not start: GetLastError({d})\n", .{@intFromEnum(windows.GetLastError())});
        return error.ControlDidNotStart;
    }
    windows.CloseHandle(information.hThread);
    return information.hProcess;
}

test "a child gets no descriptor of this process's but its own three" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: `/dev/fd` is where a process can see its own descriptors,
    // and Windows hands a child a named list of handles rather than a table it
    // might inherit the whole of.
    if (is_windows) return error.SkipZigTest;

    // Every descriptor this package opens for a spawn is close-on-exec, and
    // where the system will carry the flag on the opening call it is asked for
    // there rather than in a call after it: between an open and an `fcntl` the
    // descriptor has no flag, and another thread that forks in that gap hands
    // it to a child that has nothing to do with it. So the test is threads and
    // forks at once -- children started while descriptors are being opened and
    // closed around them -- and what it asserts is that no child was given a
    // number a child started on its own would not have had.
    //
    // That quiet child is the control, and it is what makes the claim about
    // this package rather than about the program it runs in: the listing
    // program opens a descriptor of its own to read the directory with, and
    // this process may itself have been started with inheritable descriptors
    // it did not open. Both are in the control, and a stranger is anything
    // else.
    const control = try descriptorsOfAChild();

    var churn: std.Io.Group = .init;
    defer churn.cancel(io);
    var stopping: std.atomic.Value(bool) = .init(false);
    churn.concurrent(io, openAndClose, .{&stopping}) catch return error.SkipZigTest;

    var spawners: std.Io.Group = .init;
    defer spawners.cancel(io);
    var strangers: std.atomic.Value(u32) = .init(0);
    var started: usize = 0;
    while (started < 6) : (started += 1) {
        spawners.concurrent(io, spawnAndList, .{ 8, control, &strangers }) catch break;
    }
    // At least one spawner has to have run for the claim to mean anything.
    if (started == 0) return error.SkipZigTest;
    try spawners.await(io);
    stopping.store(true, .release);

    try testing.expectEqual(@as(u32, 0), strangers.load(.acquire));
}

/// The descriptors one child, started with nothing else going on, was given.
fn descriptorsOfAChild() !u64 {
    var child = try Child.spawn(io, gpa, .{ .argv = &list_descriptors, .stdio = .{ .streams = .{
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    } } });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);
    return descriptorSet(result.stdout());
}

/// `/dev/fd` is this process's own descriptors on both systems.
const list_descriptors = [_][]const u8{ "/bin/sh", "-c", "ls /dev/fd" };

/// The numbers in a listing, as a set. Anything at 64 or above is out of the
/// set's reach and is counted as a stranger by not being in it.
fn descriptorSet(listing: []const u8) u64 {
    var set: u64 = 0;
    var numbers = std.mem.tokenizeAny(u8, listing, " \t\r\n");
    while (numbers.next()) |number| {
        const fd = std.fmt.parseInt(u6, number, 10) catch continue;
        set |= @as(u64, 1) << fd;
    }
    return set;
}

/// Opens and closes descriptors for as long as the test runs, so that the
/// children being started meanwhile are started in the middle of it.
///
/// Close-on-exec, and from the open rather than a call after it. A descriptor
/// this *test* left inheritable would be inherited, correctly and by every
/// child, and the claim being made is about the ones the package opens.
fn openAndClose(stopping: *std.atomic.Value(bool)) std.Io.Cancelable!void {
    while (!stopping.load(.acquire)) {
        const one = c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        const two = c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
        if (one >= 0) _ = c.close(one);
        if (two >= 0) _ = c.close(two);
    }
}

/// Starts `each` children that report the descriptors they were given, and
/// counts the ones the control child did not have.
fn spawnAndList(each: usize, control: u64, strangers: *std.atomic.Value(u32)) std.Io.Cancelable!void {
    var spawned: usize = 0;
    while (spawned < each) : (spawned += 1) {
        var child = Child.spawn(io, gpa, .{ .argv = &list_descriptors, .stdio = .{ .streams = .{
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .ignore,
        } } }) catch return;
        defer child.release(io) catch unreachable;

        var result = child.output(io, gpa, .{ .timeout_ms = budget_ms }) catch {
            _ = child.killWait(io, 0) catch {};
            return;
        };
        defer result.deinit(gpa);

        const unexpected = descriptorSet(result.stdout()) & ~control;
        if (unexpected != 0) {
            std.debug.print("\na child was given descriptors 0x{x} nothing gave the control child; it saw:\n{s}\n", .{
                unexpected,
                result.stdout(),
            });
            _ = strangers.fetchAdd(1, .release);
        }
    }
}

//======================================================================
// Descriptor placement.
//======================================================================

test "a stream whose file is a descriptor an earlier stream overwrites still gets its own file" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: the claim is about the order `dup2` puts descriptors in, and
    // Windows hands the child three named handles with no numbering to clash.
    if (is_windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // The caller's file is put on descriptor 0, which is also where the
    // child's own standard input is about to go. A placement that walks 0, 1,
    // 2 in order overwrites descriptor 0 before it reads it, and the child's
    // standard output ends up on whatever landed there instead.
    var sink = try tmp.dir.createFile(io, "out", .{});
    defer sink.close(io);

    var borrowed: BorrowedDescriptor = try .take(0, sink);
    defer borrowed.restore();

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'on the caller-supplied file'" },
        .stdio = .{ .streams = .{
            .stdin = .ignore,
            .stdout = .{ .file = .{ .handle = 0, .flags = .{ .nonblocking = false } } },
            .stderr = .ignore,
        } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));

    var contents: [64]u8 = undefined;
    const written = try tmp.dir.readFile(io, "out", &contents);
    try testing.expectEqualStrings("on the caller-supplied file", written);
}

test "two streams whose files are each other's descriptors are not crossed" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows) return error.SkipZigTest;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // One file on descriptor 1 and another on descriptor 2, handed to the
    // child crossed over: its standard output is the file this process holds
    // at 2, its standard error the file this process holds at 1. Placing them
    // in descriptor order destroys one before it is read.
    var first = try tmp.dir.createFile(io, "one", .{});
    defer first.close(io);
    var second = try tmp.dir.createFile(io, "two", .{});
    defer second.close(io);

    var borrowed_out: BorrowedDescriptor = try .take(1, first);
    defer borrowed_out.restore();
    var borrowed_err: BorrowedDescriptor = try .take(2, second);
    defer borrowed_err.restore();

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'out' >&1; printf 'err' >&2" },
        .stdio = .{ .streams = .{
            .stdin = .ignore,
            .stdout = .{ .file = .{ .handle = 2, .flags = .{ .nonblocking = false } } },
            .stderr = .{ .file = .{ .handle = 1, .flags = .{ .nonblocking = false } } },
        } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};
    const term = try waitWithin(&child);

    // Back before anything is printed: a failure below has to be able to
    // reach the test runner's own standard error.
    borrowed_out.restore();
    borrowed_err.restore();
    try testing.expectEqual(Child.Term{ .exited = 0 }, term);

    var contents: [64]u8 = undefined;
    try testing.expectEqualStrings("err", try tmp.dir.readFile(io, "one", &contents));
    try testing.expectEqualStrings("out", try tmp.dir.readFile(io, "two", &contents));
}

/// One of this process's own standard descriptors, borrowed for the length of
/// a test and put back afterwards.
///
/// The two tests above are about what the child finds at descriptors 0, 1 and
/// 2, which means the caller's file has to *be* at one of those numbers. So
/// the number is borrowed: the original is copied out of the way above 2, the
/// file is put in its place, and `restore` undoes both. `restore` is
/// idempotent, so a test may put a descriptor back before it starts printing
/// and still leave the `defer` in place.
//======================================================================
// Files beyond the standard three.
//======================================================================

const inherited_fixture = @import("conduit_test_options").input_fixture;

/// What the fixture wrote into the file at `name`: `fd <n>` for each
/// descriptor it was given that file at.
fn expectSaid(dir: std.Io.Dir, name: []const u8, expected: []const u8) !void {
    var contents: [4096]u8 = undefined;
    try testing.expectEqualStrings(expected, try dir.readFile(io, name, &contents));
}

test "extra files arrive at descriptor 3 and up, in order" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // About the spawn path, so not in a cgroup, which always forks.
    if (comptime !is_windows) cgroup.testing_hook.off = true;
    defer if (comptime !is_windows) {
        cgroup.testing_hook.off = false;
    };

    // The default policy, which takes posix_spawn where it can, and
    // `.close_all`, which forks and closes everything above the extras.
    for ([_]Child.FdPolicy{ .close_on_exec, .close_all }) |policy| {
        const names = [_][]const u8{ "three", "four", "five" };
        var files: [names.len]std.Io.File = undefined;
        for (names, &files) |name, *f| f.* = try tmp.dir.createFile(io, name, .{});
        defer for (files) |f| f.close(io);

        const calls = @import("test_support.zig").SpawnCalls;
        calls.file_actions = 0;
        var child = try Child.spawn(io, gpa, .{
            .argv = &.{ inherited_fixture, "inherited", "3" },
            .stdio = .ignore,
            .fd_policy = policy,
            .extra_fds = &files,
        });
        defer child.release(io) catch unreachable;
        errdefer _ = child.killWait(io, 0) catch {};
        try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));

        try expectSaid(tmp.dir, "three", "fd 3\n");
        try expectSaid(tmp.dir, "four", "fd 4\n");
        try expectSaid(tmp.dir, "five", "fd 5\n");
        // Every source above the slots: file actions say it, unless the
        // policy or the build asks for the fork.
        if (!is_windows and fast_path and policy == .close_on_exec) {
            const all_above = for (files) |f| {
                if (f.handle < 6) break false;
            } else true;
            if (all_above) try testing.expectEqual(@as(usize, 1), calls.file_actions);
        }
    }
}

test "extra files cross over correctly, however their numbers fall" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // The numbering is POSIX's; Windows lists handles by value.
    if (is_windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Eight files, given sixty-four times between them in reverse order of
    // their numbers, so most sources lie inside the range the extras are
    // placed at, some below their slot and some above, and each file whose
    // number is a slot also given at that very slot. The report pipe the
    // fork child keeps lies inside the range too. Then once more with the
    // last of them at descriptor 0, which the standard streams are placed
    // over first.
    const count = 64;
    const names = [_][]const u8{ "file0", "file1", "file2", "file3", "file4", "file5", "file6", "file7" };
    for ([_]bool{ false, true }) |at_zero| {
        for ([_]Child.FdPolicy{ .close_on_exec, .close_all }) |policy| {
            var files: [names.len]std.Io.File = undefined;
            for (names, &files) |name, *f| f.* = try tmp.dir.createFile(io, name, .{});
            defer for (files) |f| f.close(io);
            var extras: [count]std.Io.File = undefined;
            for (&extras, 0..) |*extra, i| extra.* = files[files.len - 1 - i % files.len];
            for (files) |f| if (f.handle >= 3 and f.handle < 3 + count) {
                extras[@intCast(f.handle - 3)] = f;
            };
            var borrowed: ?BorrowedDescriptor = if (at_zero) try .take(0, files[0]) else null;
            defer if (borrowed) |*b| b.restore();
            if (at_zero) extras[count - 1] = .{ .handle = 0, .flags = .{ .nonblocking = false } };

            var child = try Child.spawn(io, gpa, .{
                .argv = &.{ inherited_fixture, "inherited", std.fmt.comptimePrint("{d}", .{count}) },
                .stdio = .ignore,
                .fd_policy = policy,
                .extra_fds = &extras,
            });
            defer child.release(io) catch unreachable;
            errdefer _ = child.killWait(io, 0) catch {};
            try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));

            for (files, names) |f, name| {
                var expected: std.ArrayList(u8) = .empty;
                defer expected.deinit(gpa);
                for (extras, 3..) |extra, slot| {
                    const given = if (extra.handle == 0) files[0].handle else extra.handle;
                    if (given == f.handle) try expected.print(gpa, "fd {d}\n", .{slot});
                }
                try expectSaid(tmp.dir, name, expected.items);
            }
        }
    }
}

test "a program that cannot run is still reported when extra files cover the report pipe" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile(io, "out", .{});
    defer f.close(io);

    // The fork child reports a failed exec over a pipe whose number lies
    // among these slots. Placed over, the report would go into the file and
    // the spawn would come back as a child exiting 127.
    const extras: [64]std.Io.File = @splat(f);
    try testing.expectError(error.FileNotFound, Child.spawn(io, gpa, .{
        .argv = &.{"/nonexistent/conduit-no-such-program"},
        .stdio = .ignore,
        .fd_policy = .close_all,
        .extra_fds = &extras,
    }));
    try expectSaid(tmp.dir, "out", "");
}

test "a child on a terminal gets its extra files above the terminal's three" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile(io, "out", .{});
    defer f.close(io);

    // Windows names no handles beside a pseudoconsole: refused by name.
    if (is_windows) {
        try testing.expectError(error.Unsupported, Child.spawn(io, gpa, .{
            .argv = &.{ inherited_fixture, "inherited", "1" },
            .stdio = .{ .pty = &pty },
            .extra_fds = &.{f},
        }));
        return;
    }

    // Enough of them that the pair's own descriptors lie among the slots:
    // closing those after placement would close an extra file instead.
    const count = 32;
    const extras: [count]std.Io.File = @splat(f);
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ inherited_fixture, "inherited", std.fmt.comptimePrint("{d}", .{count}) },
        .stdio = .{ .pty = &pty },
        .detach = true,
        .extra_fds = &extras,
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);
    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(pty.readFile());
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    for (3..3 + count) |slot| try expected.print(gpa, "fd {d}\n", .{slot});
    try expectSaid(tmp.dir, "out", expected.items);
}

test "a child on the C runtime finds extra handles at descriptor 3" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // The other systems number descriptors themselves; the tests above.
    if (!is_windows) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var f = try tmp.dir.createFile(io, "out", .{});
    defer f.close(io);

    // `cmd.exe` redirects to a descriptor through its C runtime, which read
    // the table in the startup record when it started.
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "cmd.exe", "/c", "echo through the runtime>&3" },
        .stdio = .ignore,
        .extra_fds = &.{f},
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
    try expectSaid(tmp.dir, "out", "through the runtime\r\n");
}

const BorrowedDescriptor = struct {
    number: posix.fd_t,
    saved: ?posix.fd_t,

    fn take(number: posix.fd_t, file: std.Io.File) !BorrowedDescriptor {
        const copy = c.fcntl(number, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
        if (copy < 0) return error.TestUnexpectedResult;
        const borrowed: BorrowedDescriptor = .{ .number = number, .saved = @intCast(copy) };
        if (c.dup2(file.handle, number) < 0) {
            var mutable = borrowed;
            mutable.restore();
            return error.TestUnexpectedResult;
        }
        return borrowed;
    }

    fn restore(borrowed: *BorrowedDescriptor) void {
        const saved = borrowed.saved orelse return;
        borrowed.saved = null;
        _ = c.dup2(saved, borrowed.number);
        _ = c.close(saved);
    }
};

test "a fork spawn resets an ignored real-time signal in the child" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const signal: posix.SIG = @enumFromInt(std.os.linux.NSIG - 1);
    var saved: posix.Sigaction = undefined;
    const ignored: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(signal, &ignored, &saved);
    defer posix.sigaction(signal, &saved, null);
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sleep", "30" },
        .cwd = ".", // takes the fork path
        .stdio = .ignore,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    try testing.expectEqual(@as(c_int, 0), c.kill(State.get(&child).id, signal));
    try testing.expectEqual(Child.Term{ .signal = signal }, try waitWithin(&child));
}

test "a fork spawn reports exec failure even when all standard descriptors were closed" {
    if (is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io, "stand-in", .{ .read = true });
    defer file.close(io);
    var stdin: BorrowedDescriptor = try .take(0, file);
    defer stdin.restore();
    var stdout: BorrowedDescriptor = try .take(1, file);
    defer stdout.restore();
    var stderr: BorrowedDescriptor = try .take(2, file);
    defer stderr.restore();
    _ = c.close(0);
    _ = c.close(1);
    _ = c.close(2);
    const spawn_error: ?Child.SpawnError = if (Child.spawn(io, gpa, .{
        .argv = &.{"/conduit-test/no-such-executable"},
        .cwd = ".", // takes the fork path
        .stdio = .ignore,
    })) |started| ended: {
        var child = started;
        // An unexpected child can own a watch on a low descriptor too.
        // Close it before restoring the test runner's standard descriptors.
        _ = child.killWait(io, 0) catch {};
        child.release(io) catch unreachable;
        break :ended null;
    } else |err| err;
    stdin.restore();
    stdout.restore();
    stderr.restore();
    // Restore before printing an assertion.
    try testing.expectEqual(@as(?Child.SpawnError, error.FileNotFound), spawn_error);
}

test "a parent death signal is refused where the system has none" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    try testing.expectError(error.Unsupported, Child.spawn(io, gpa, .{
        .argv = &script.greeting,
        .parent_death_signal = .kill,
    }));
}

test "a child given a parent death signal ends with the thread that started it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // The parent the kernel watches is the thread that forked: a thread of
    // this test's own that spawns and ends stands in for a program that
    // crashes, since the test runner itself has to live on.
    const Spawner = struct {
        child: ?Child = null,
        failed: ?anyerror = null,
        fn run(s: *@This()) void {
            s.child = Child.spawn(io, gpa, .{
                .argv = &.{ "/bin/sh", "-c", "sleep 30" },
                .stdio = .ignore,
                .parent_death_signal = .kill,
            }) catch |err| {
                s.failed = err;
                return;
            };
        }
    };
    var spawner: Spawner = .{};
    const thread = try std.Thread.spawn(.{}, Spawner.run, .{&spawner});
    thread.join();
    if (spawner.failed) |err| return err;
    var child = spawner.child.?;
    defer child.release(io) catch unreachable;
    // ended by the kernel, long before its sleep is over
    try testing.expectEqual(Child.Term{ .signal = .KILL }, try waitWithin(&child));
}

test "a detached child on a pty takes posix_spawn where the platform can give it its terminal, and is the same child" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows or !fast_path) return error.SkipZigTest;
    const spawn_path = @import("posix_spawn.zig");
    // A cgroup of the child's own sends any spawn to the fork: this is about
    // the ones that take `posix_spawn`.
    cgroup.testing_hook.off = true;
    defer cgroup.testing_hook.off = false;

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 20, .cols = 70 });
    defer pty.close(io);
    const options: Child.SpawnOptions = .{
        // A terminal that is its controlling one (only such a process opens
        // /dev/tty), its size, and something it started, named.
        .argv = &.{ "/bin/sh", "-c", "exec 3</dev/tty && echo tty-ok; stty size; sleep 100 & echo \"pid $!.\"; wait" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    };
    // Linux has the session and the open; Darwin and the BSDs fork, for the
    // ioctl only code between a fork and an exec can make.
    try testing.expectEqual(spawn_path.session_terminal, spawn_path.suits(options));

    var child = try Child.spawn(io, gpa, options);
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    var sink: Sink = .{};
    defer sink.deinit();
    try sink.start(pty.readFile());
    try sink.expect("tty-ok");
    try sink.expect("20 70");
    const grandchild = try readPid(&sink);

    // A session and a group of its own, and the terminal's foreground group.
    try testing.expectEqual(State.get(&child).id, getpgid(State.get(&child).id));
    try testing.expectEqual(State.get(&child).id, getsid(State.get(&child).id));
    try testing.expectEqual(State.get(&child).id, try conduit.foregroundGroup(pty.readHandle().?));

    // Ended, and what it started with it.
    _ = try child.killWait(io, 0);
    try expectGone(grandchild);
}

test "a spawn with a parent death signal takes the fork, where the signal is set" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const spawn_path = @import("posix_spawn.zig");
    try testing.expect(!spawn_path.suits(.{ .argv = &script.greeting, .parent_death_signal = .kill }));
    try testing.expectEqual(spawn_path.available, spawn_path.suits(.{ .argv = &script.greeting }));
}

test "blocking waits and Reaper report status reaped elsewhere" {
    if (is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    for ([_]bool{ false, true }) |background| {
        var child = try Child.spawn(io, gpa, .{ .argv = &.{ "/bin/sh", "-c", "exit 7" }, .stdio = .ignore });
        defer child.release(io) catch unreachable;
        var status: c_int = undefined;
        while (c.waitpid(State.get(&child).id, &status, 0) < 0) {
            if (c.errno(@as(c_int, -1)) != .INTR) return error.TestWaitFailed;
        }
        if (background) {
            var reaper: conduit.Reaper = .init(&child, .{});
            try reaper.start(io);
            defer reaper.deinit(io) catch unreachable;
            try testing.expectError(error.ReapedElsewhere, reaper.waitTimeout(io, budget_ms));
        } else {
            try testing.expectError(error.ReapedElsewhere, child.wait(io));
        }
    }
}

test "Windows wait and Reaper preserve the control exit status" {
    if (!is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    for ([_]bool{ false, true }) |background| {
        var child = try Child.spawn(io, gpa, .{ .argv = &.{ "cmd.exe", "/c", "exit -1073741510" }, .stdio = .ignore });
        defer child.release(io) catch unreachable;
        defer _ = child.killWait(io, 0) catch {};
        const term = if (background) blk: {
            var reaper: conduit.Reaper = .init(&child, .{});
            try reaper.start(io);
            defer reaper.deinit(io) catch unreachable;
            break :blk (try reaper.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
        } else try waitWithin(&child);
        try testing.expectEqual(@as(u32, 0xc000013a), conduit.exitCode(term).?);
        try testing.expect(!conduit.succeeded(term));
    }
}

test "Child identity and result access share the Reaper's retirement" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{ .argv = &script.read_then_exit_7, .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } } });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    try testing.expect(child.processId() != null);
    try testing.expectEqual(@as(?Child.Term, null), try child.result());
    var reaper: conduit.Reaper = .init(&child, .{});
    try reaper.start(io);
    defer reaper.deinit(io) catch unreachable;
    var buffer: [32]u8 = undefined;
    var writer = child.stdinFile().?.writer(io, &buffer);
    try writer.interface.writeAll("exit\n");
    try writer.interface.flush();
    const deadline: Deadline = .in(io, budget_ms);
    while (try child.result() == null) {
        _ = child.processId();
        if (deadline.remainingMs(io) == 0) return error.TestChildDidNotExit;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try testing.expectEqual(Child.Term{ .exited = 7 }, (try child.result()).?);
    try testing.expectEqual(@as(?Child.Id, null), child.processId());
    try testing.expectEqual(Child.Term{ .exited = 7 }, try reaper.wait(io));
}

test "a PID fixture reports malformed output instead of a silent timeout" {
    var sink: Sink = .{};
    defer sink.deinit();
    try sink.bytes.appendSlice(gpa, "pid not-a-number.\n");
    sink.finished.store(true, .release);
    try testing.expectError(error.TestInvalidProcessId, readMarkedNumber(u32, &sink));
}

test "a Reaper started after status loss never watches a reused identity" {
    if (is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{ .argv = &.{ "/bin/sh", "-c", "exit 7" }, .stdio = .ignore });
    defer child.release(io) catch unreachable;
    var status: c_int = undefined;
    while (c.waitpid(State.get(&child).id, &status, 0) < 0) {
        if (c.errno(@as(c_int, -1)) != .INTR) return error.TestWaitFailed;
    }
    try testing.expectError(error.ReapedElsewhere, child.tryWait());
    var witness = try Child.spawn(io, gpa, .{ .argv = &.{ "/bin/sh", "-c", "read x" }, .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } }, .detach = true });
    defer witness.release(io) catch unreachable;
    defer _ = witness.killWait(io, 0) catch {};
    // Reuse a live witness's number deliberately instead of waiting for PID wrap.
    State.get(&child).id = State.get(&witness).id;
    State.get(&child).pgid = State.get(&witness).pgid;
    var reaper: conduit.Reaper = .init(&child, .{ .end_tree = true });
    try reaper.start(io);
    defer reaper.deinit(io) catch unreachable;
    try testing.expectError(error.ReapedElsewhere, reaper.waitTimeout(io, 100));
    try testing.expectEqual(@as(?Child.Term, null), try witness.tryWait());
}

test "the Windows PID fixture keeps reading after a successful empty read" {
    // Windows permits this when a pipe writer issues a zero-length write.
    // Inject that documented result on every platform, before the actual PID.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const written = try tmp.dir.createFile(io, "pid", .{});
    try written.writeStreamingAll(io, "pid 12345.\n");
    written.close(io);
    const source = try tmp.dir.openFile(io, "pid", .{});
    defer source.close(io);
    const EmptyOnce = struct {
        base: std.Io,
        empty: bool = true,

        fn checkCancel(userdata: ?*anyopaque) std.Io.Cancelable!void {
            const state: *@This() = @ptrCast(@alignCast(userdata.?));
            return state.base.vtable.checkCancel(state.base.userdata);
        }

        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            const state: *@This() = @ptrCast(@alignCast(userdata.?));
            if (operation == .file_read_streaming and state.empty) {
                state.empty = false;
                return .{ .file_read_streaming = 0 };
            }
            return state.base.vtable.operate(state.base.userdata, operation);
        }
    };

    var empty: EmptyOnce = .{ .base = io };
    var vtable = io.vtable.*;
    vtable.operate = EmptyOnce.operate;
    vtable.checkCancel = EmptyOnce.checkCancel;
    var sink: Sink = .{ .source_io = .{ .vtable = &vtable, .userdata = &empty } };
    defer sink.deinit();
    try sink.start(source);
    try testing.expectEqual(@as(u32, 12345), try readMarkedNumber(u32, &sink));
}

test "a containment snapshot survives reaping and deinit without owned handles" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.read_then_exit_5,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    const key = child.processId().?;
    var path_buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
    const record = try child.containment(&path_buffer);
    try testing.expectEqual(key, record.group.?);
    if (record.cgroup) |contained| {
        try testing.expect(contained.id != 0);
        try testing.expectEqual(@as(usize, 36), contained.boot.len);
        try testing.expect(contained.path.ptr == &path_buffer);
        try testing.expectError(error.BufferTooSmall, child.containment(&.{}));
    }
    var reaper: conduit.Reaper = .init(&child, .{});
    try reaper.start(io);
    defer reaper.deinit(io) catch unreachable;
    child.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 5 }, try reaper.wait(io));
    reaper.deinit(io) catch unreachable;
    try testing.expectEqual(@as(?Child.Id, null), child.processId());
    var retired_buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
    const retired = try child.containment(&retired_buffer);
    try testing.expectEqual(record.group, retired.group);
    if (record.cgroup) |contained| {
        try testing.expectEqualStrings(contained.path, retired.cgroup.?.path);
        try testing.expect(contained.path.ptr != retired.cgroup.?.path.ptr);
        try testing.expectEqual(contained.id, retired.cgroup.?.id);
        try testing.expectEqualStrings(&contained.boot, &retired.cgroup.?.boot);
    }
    child.release(io) catch unreachable;
    try testing.expectEqual(key, record.group.?);
    if (record.cgroup) |contained| try testing.expect(std.mem.startsWith(u8, contained.path, "/"));
}

test "Reaper start cannot replace an active task or restart a joined lifetime" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.read_then_exit_5,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var reaper: conduit.Reaper = .init(&child, .{});
    defer reaper.deinit(io) catch unreachable;
    try reaper.start(io);
    // Equality of errors keeps this regression compilable before the error
    // has been added to StartError. A duplicate task can be canceled safely.
    var rejected = false;
    reaper.start(io) catch |err| {
        try testing.expectEqual(error.AlreadyStarted, err);
        rejected = true;
    };
    try testing.expect(rejected);
    child.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 5 }, try reaper.wait(io));
    reaper.deinit(io) catch unreachable;
    try testing.expectError(error.AlreadyStarted, reaper.start(io));
}

test "HeldReap and Reaper expose no writable lifecycle fields" {
    try testing.expect(@typeInfo(Child.HeldReap) == .@"enum");
    try testing.expect(@typeInfo(conduit.Reaper) == .@"enum");
}

test "output reads a published result before watching a retired process number" {
    if (is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf retained; exit 7" },
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    try testing.expectEqual(Child.Term{ .exited = 7 }, try waitWithin(&child));
    var witness = try Child.spawn(io, gpa, .{
        .argv = &script.read_then_exit_5,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer witness.release(io) catch unreachable;
    defer _ = witness.killWait(io, 0) catch {};
    // A retired number may already name a live stranger. The published
    // answer must decide the wait before that number can open a watch.
    State.get(&child).id = witness.processId().?;
    var output = try child.output(io, gpa, .{ .timeout_ms = 20 });
    defer output.deinit(gpa);
    try testing.expectEqual(false, output.timedOut());
    try testing.expectEqualStrings("retained", output.stdout());
    try testing.expectEqual(Child.Term{ .exited = 7 }, output.term());
    try testing.expectEqual(@as(?Child.Term, null), try witness.tryWait());
}

test "Orphans list copies the held identity for a record kept after reaping" {
    if (!Orphans.supported) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var orphans: Orphans = .init(gpa);
    try orphans.start();
    defer orphans.deinit() catch unreachable;
    defer orphans.end(io, 0) catch {};
    var keeper = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", leaves_an_orphan ++ "; read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
    });
    defer keeper.release(io) catch unreachable;
    defer _ = keeper.killWait(io, 0) catch {};
    const kept = try orphanOf(&keeper);
    try expectAdopted(kept);
    try expectCount(&orphans, 1);
    var records: [4]Orphans.Record = undefined;
    const listed = try orphans.list(&records);
    try testing.expectEqual(@as(usize, 1), listed.len);
    const saved = listed[0];
    try testing.expectEqual(kept, saved.pid);
    try testing.expectEqual((try conduit.startTime(kept)).?, saved.start);
    try testing.expectEqual(getpgid(kept), saved.group);
    try testing.expectEqual(getsid(kept), saved.session);
    try orphans.end(io, 0);
    try testing.expectEqual(@as(usize, 0), (try orphans.list(&records)).len);
    try testing.expect((try conduit.captureStarted(saved.pid, saved.start)) == null);
}

test "a pty master in a standard slot cannot close the child's replacement stream" {
    if (is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var pair = try Pty.open(gpa, .{});
    defer pair.close(io);
    var stdin: BorrowedDescriptor = try .take(0, pair.readFile());
    defer stdin.restore();
    @import("Pty.zig").placeMasterForTest(&pair, 0);
    // Close the temporary master before restoring the runner's stdin,
    // including on a failed spawn or assertion.
    defer pair.closeMaster(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "read value && test \"$value\" = answer" },
        .stdio = .{ .pty = &pair },
        .detach = true,
        .cwd = ".", // Both platforms use the fork implementation here.
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    pair.closeSlave(io);
    var sink: Sink = .{};
    try sink.start(pair.readFile());
    var reading = true;
    defer if (reading) sink.deinit();
    try pair.writeFile().writeStreamingAll(io, "answer\n");
    const term = try waitWithin(&child);
    sink.deinit();
    reading = false;
    pair.closeMaster(io);
    stdin.restore();
    try testing.expectEqual(Child.Term{ .exited = 0 }, term);
}

test "collected output transfers bytes before releasing its owner" {
    var child = try Child.spawn(io, gpa, .{ .argv = &script.out_and_err, .stdio = .{ .pipes = .{ .stdin = false } } });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var collected = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer collected.deinit(gpa);
    const kept = collected.takeStdout();
    defer gpa.free(kept);
    try testing.expectEqual(@as(usize, 0), collected.stdout().len);
    collected.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, kept, "to stdout") != null);
}
