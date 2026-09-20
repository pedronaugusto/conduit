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
const c = std.c;

const conduit = @import("conduit.zig");
const Child = conduit.Child;
const Pty = conduit.Pty;
const handles = @import("handles.zig");
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
    /// `Start-Process` is `CreateProcess` with a console of its own, so the
    /// grandchild holds none of this child's handles and goes on running after
    /// the child has exited and been reaped. What relates the two afterwards is
    /// the job object, which is the whole of what `waitTree` and `deinit` are
    /// claims about. The id is printed the way `readMarkedNumber` reads it.
    ///
    /// Windows only, and used only by tests that skip elsewhere: POSIX has no
    /// container to ask after a tree with.
    const detached_grandchild = [_][]const u8{
        "powershell.exe",
        "-NoProfile",
        "-NonInteractive",
        "-Command",
        "$p = Start-Process -FilePath ping.exe -ArgumentList '-n','60','127.0.0.1' -PassThru; " ++
            "Write-Output ('pid ' + $p.Id + '.')",
    };
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
const Sink = struct {
    mutex: std.Io.Mutex = .init,
    bytes: std.ArrayList(u8) = .empty,
    group: std.Io.Group = .init,
    /// The file being read, for `deinit`.
    file: ?std.Io.File = null,
    /// Set by `deinit`, read by the task before every read it starts, so a
    /// reader that is between reads when the asking begins does not start
    /// another one.
    stopping: std.atomic.Value(bool) = .init(false),
    /// The reading has stopped, for any reason. Atomic and not under `mutex`:
    /// `deinit` waits on it while the task is inside a read, and a wait that
    /// took a lock the task also takes would be a wait on the task rather than
    /// on the read.
    finished: std.atomic.Value(bool) = .init(false),
    /// Why the reading stopped, when it stopped for a reason other than the
    /// end. The difference between "the child said nothing" and "nobody was
    /// listening".
    failed: ?anyerror = null,

    fn start(sink: *Sink, file: std.Io.File) !void {
        sink.file = file;
        try sink.group.concurrent(io, read, .{ sink, file });
    }

    /// Stops reading and releases the task.
    ///
    /// The task is blocked in a read that only the far end finishing, the
    /// handle going away, or the operating system being told to abandon it
    /// will end. On Windows the last of those is `CancelIoEx`, which ends the
    /// reads this process has pending on the handle whichever thread issued
    /// them, and is the one that does not involve closing a handle another
    /// thread is inside.
    ///
    /// **Once is not enough.** `CancelIoEx` reaches only what is pending when
    /// it is called, and a reader spends part of its time between reads, with
    /// the bytes it just got. Asking once ends the read about two times in
    /// three and leaves the reader to start another one that nothing will end
    /// — a pseudoconsole's output pipe has a writer for as long as the console
    /// does. So it is asked again each time round the wait, until the reader
    /// says it has stopped.
    fn deinit(sink: *Sink) void {
        sink.stopping.store(true, .release);
        if (is_windows) {
            if (sink.file) |f| {
                trace.print("sink: asking the read to stop", .{});
                var waited_ms: u32 = 0;
                while (waited_ms < budget_ms and !sink.ended()) : (waited_ms += 2) {
                    const asked = win32.CancelIoEx(f.handle, null);
                    if (trace.enabled() and waited_ms == 0) {
                        trace.print("sink: CancelIoEx returned {s}, last error {d}", .{
                            if (asked.toBool()) "TRUE" else "FALSE",
                            @intFromEnum(std.os.windows.GetLastError()),
                        });
                    }
                    std.Io.sleep(io, .fromMilliseconds(2), .awake) catch break;
                }
                trace.print("sink: done asking", .{});
            }
        }
        // Said out loud rather than traced: a join that is about to block is
        // the one thing a failure here has to be able to name, and by then
        // there may be no second chance to print anything.
        if (is_windows and !sink.ended()) {
            std.debug.print("\nsink: the read would not stop; joining anyway\n", .{});
        }
        trace.print("sink: joining the reader", .{});
        sink.group.cancel(io);
        trace.print("sink: reader joined", .{});
        sink.bytes.deinit(gpa);
    }

    fn read(sink: *Sink, file: std.Io.File) std.Io.Cancelable!void {
        var buffer: [512]u8 = undefined;
        while (true) {
            if (sink.stopping.load(.acquire)) return sink.stop(null);
            const n = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return sink.stop(if (handles.finished(err)) null else err),
            };
            if (n == 0) return sink.stop(null);
            sink.mutex.lockUncancelable(io);
            defer sink.mutex.unlock(io);
            sink.bytes.appendSlice(gpa, buffer[0..n]) catch return;
        }
    }

    /// Records how the reading ended: the end of the stream, or an error.
    ///
    /// The flag is stored last and outside the lock, so `deinit` can see it
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
        var waited_ms: u32 = 0;
        while (waited_ms < budget_ms) : (waited_ms += 2) {
            if (sink.contains(needle)) return;
            try std.Io.sleep(io, .fromMilliseconds(2), .awake);
        }
        sink.report(needle);
        return error.TestChildSaidNothing;
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
        std.debug.print("\nwaited {d} ms for \"{s}\"; the read stopped with {s}; {d} bytes arrived:\n  ", .{
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

/// How a child that `killWait` ended with a grace reports it.
///
/// POSIX names the signal, and for a child that does not catch it that is
/// exactly the one this package sent.
///
/// Windows has no signal to name and, for this path, no number of this
/// package's own either. `.terminate` there is a console control event, so a
/// child that obeys it ends on its own terms and reports whatever status it
/// chose — the system's control-exit status for one that does not handle the
/// event, which reaches `Term.exited` as the low byte of an `NTSTATUS`. The
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
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.echo_stdin,
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    try child.stdin.?.writeStreamingAll(io, "a line\n");
    child.closeStdin(io);

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, result.stdout, "a line") != null);
    try testing.expectEqual(Child.Term{ .exited = 0 }, result.term);
}

test "output stops at max_bytes and says it did" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
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
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
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
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.read_then_exit_7,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer child.deinit(io);
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
    defer child.deinit(io);

    var reaper: conduit.Reaper = .init(&child);
    try reaper.start(io);
    defer reaper.deinit(io);

    try testing.expectEqual(@as(?Child.Term, null), reaper.exit());

    child.closeStdin(io);

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
    defer child.deinit(io);

    var reaper: conduit.Reaper = .init(&child);
    try reaper.start(io);
    defer reaper.deinit(io);

    // Confirmed running: `exit` is null while the wait is in flight.
    try std.Io.sleep(io, .fromMilliseconds(50), .awake);
    try testing.expectEqual(@as(?Child.Term, null), reaper.exit());

    // No grace, so this is the shortest form of the sequence: the signal
    // nothing survives, and then a wait -- while another task is already
    // inside one. Two waits on one child are one status and one error about a
    // child nobody can account for.
    const term = try child.killWait(io, 0);
    try testing.expect(!conduit.succeeded(term));

    // The same term, by both routes, and nothing left to reap: a second wait
    // answers from what was published rather than asking the system again.
    var waited: u32 = 0;
    const reaped = while (waited < budget_ms) : (waited += 1) {
        if (reaper.exit()) |t| break t;
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
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    {
        var reaper: conduit.Reaper = .init(&child);
        try reaper.start(io);
        try std.Io.sleep(io, .fromMilliseconds(50), .awake);
        try testing.expectEqual(@as(?Child.Term, null), reaper.exit());
        reaper.deinit(io);
    }

    child.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 5 }, try waitWithin(&child));
}

test "stdinWriter and stdoutReader find the child's streams wherever they are" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
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
    child.closeStdin(io);

    // The same file the reader would come from, so the two agree.
    try testing.expectEqual(child.stdout.?.handle, child.stdoutFile().?.handle);

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "a line") != null);
}

test "closeStdin is the half-close a child reading to end of file waits for" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, gpa, .{
        .argv = &script.drain_then_exit_7,
        .stdio = .{ .pipes = .{ .stdout = false, .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    // Written, but not finished: the child is still reading, because this
    // process is still a writer.
    try child.stdin.?.writeStreamingAll(io, "a line\n");
    try testing.expectEqual(@as(?Child.Term, null), try child.waitTimeout(io, 50));

    child.closeStdin(io);
    try testing.expectEqual(@as(?std.Io.File, null), child.stdin);
    // Idempotent, which is what makes it safe to pair with `deinit`.
    child.closeStdin(io);

    try testing.expectEqual(Child.Term{ .exited = 7 }, try waitWithin(&child));
}

test "waitTimeout costs no more than the blocking wait it is a deadline on" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    // A budget, not a measurement. `waitTimeout` used to ask again on a
    // growing interval -- one millisecond, then two, then four -- which put a
    // millisecond and a half between a child ending and this call noticing,
    // whatever the machine. It waits on a handle the system makes ready now,
    // so the difference should be nothing but noise. Medians rather than
    // means, because one descheduled sample on a loaded machine is not the
    // claim.
    const samples = 32;
    const slack_us = 1250;

    // Up to five goes at it. One descheduled run on a loaded machine is not
    // the claim either, and a difference that is really there is there every
    // time.
    var attempt: usize = 0;
    while (attempt < 5) : (attempt += 1) {
        var blocking: [samples]i64 = undefined;
        var deadlined: [samples]i64 = undefined;
        for (&blocking) |*sample| sample.* = try timeOne(.blocking);
        for (&deadlined) |*sample| sample.* = try timeOne(.deadlined);

        std.mem.sort(i64, &blocking, {}, std.sort.asc(i64));
        std.mem.sort(i64, &deadlined, {}, std.sort.asc(i64));
        const with_wait = blocking[samples / 2];
        const with_deadline = deadlined[samples / 2];
        if (with_deadline <= with_wait + slack_us) return;

        std.debug.print(
            "\nwait() {d} us, waitTimeout() {d} us: {d} us more than the {d} us allowed\n",
            .{ with_wait, with_deadline, with_deadline - with_wait, slack_us },
        );
    }
    return error.TestWaitTimeoutCostsTooMuch;
}

/// Microseconds to start a child that exits at once and reap it, one way or
/// the other.
fn timeOne(how: enum { blocking, deadlined }) !i64 {
    const argv: []const []const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "exit 0" }
    else
        &.{ "/bin/sh", "-c", "exit 0" };

    const start: std.Io.Timestamp = .now(io, .awake);
    var child = try Child.spawn(io, gpa, .{ .argv = argv, .stdio = .ignore });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};
    switch (how) {
        .blocking => _ = try child.wait(io),
        .deadlined => if (try child.waitTimeout(io, budget_ms) == null) {
            return error.TestChildDidNotExit;
        },
    }
    const end: std.Io.Timestamp = .now(io, .awake);
    return start.durationTo(end).toMicroseconds();
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
    defer child.deinit(io);

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
    defer ok_child.deinit(io);
    errdefer _ = ok_child.killWait(io, 0) catch {};
    ok_child.closeStdin(io);

    const term = try waitWithin(&ok_child);
    try testing.expect(!conduit.succeeded(term));
    try testing.expectEqual(@as(?u8, 7), conduit.exitCode(term));
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
    defer killed.deinit(io);
    const killed_term = try killed.killWait(io, 0);
    if (is_windows) {
        try testing.expectEqual(@as(?u8, 1), conduit.exitCode(killed_term));
        try testing.expectEqual(@as(?[]const u8, null), conduit.signalName(killed_term));
    } else {
        try testing.expect(!conduit.succeeded(killed_term));
        try testing.expectEqual(@as(?u8, null), conduit.exitCode(killed_term));
        try testing.expectEqualStrings("KILL", conduit.signalName(killed_term).?);
    }
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
    defer child.deinit(io);

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

    var sink: Sink = .{};
    defer sink.deinit();

    var child = try Child.spawn(io, gpa, .{
        .argv = argv,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
        // On POSIX a signal is addressed to a process group and `detach` is
        // what makes one. On Windows the job is there either way.
        .detach = !is_windows,
    });
    defer child.deinit(io);
    defer _ = child.killWait(io, 0) catch {};
    try sink.start(child.stdout.?);

    // Both still running, so the pipe still has writers.
    try std.Io.sleep(io, .fromMilliseconds(200), .awake);
    try testing.expect(!sink.ended());

    _ = try child.killWait(io, 0);

    // The shell is gone. If what it started were still running it would still
    // be holding the pipe, and this would wait out the whole budget.
    var waited: u32 = 0;
    while (waited < budget_ms) : (waited += 10) {
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
    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "set -m; sleep 100 & printf 'pid %d.' \"$!\"; wait" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(io);
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
    if (getpgid(grandchild) == child.pgid.?) return error.SkipZigTest;

    _ = try child.killWait(io, 0);

    var waited: u32 = 0;
    while (waited < budget_ms) : (waited += 10) {
        if (!alive(grandchild)) return;
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    _ = c.kill(grandchild, .KILL);
    return error.TestGrandchildOutlivedTheKill;
}

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
    var waited_ms: u32 = 0;
    while (waited_ms < budget_ms) : (waited_ms += 2) {
        const found = found: {
            sink.mutex.lockUncancelable(io);
            defer sink.mutex.unlock(io);
            const said = sink.bytes.items;
            const at = std.mem.indexOf(u8, said, "pid ") orelse break :found null;
            const rest = said[at + "pid ".len ..];
            const end = std.mem.indexOfScalar(u8, rest, '.') orelse break :found null;
            break :found std.fmt.parseInt(Number, rest[0..end], 10) catch null;
        };
        if (found) |number| return number;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    return error.TestChildSaidNothing;
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
        win32.SYNCHRONIZE | win32.PROCESS_QUERY_LIMITED_INFORMATION,
        .FALSE,
        id,
    ) orelse error.TestProcessNotThere;
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
    // Windows only, and `Child.waitTree` says why at length: a job object is a
    // container the system accounts for, and a process group is an address to
    // send signals to.
    if (!is_windows) return error.SkipZigTest;

    var sink: Sink = .{};
    defer sink.deinit();

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.detached_grandchild,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer child.deinit(io);
    defer _ = child.killWait(io, 0) catch {};
    try sink.start(child.stdout.?);

    const grandchild = try openById(try readMarkedNumber(win32.DWORD, &sink));
    defer std.os.windows.CloseHandle(grandchild);

    // The child ends on its own, and is left unreaped until the end: `kill`
    // declines to signal a child it has already been told is gone, so a test
    // that reaped it here would be asking the job to end a tree nothing would
    // then ask it to end. The child's own handle is what says it has exited,
    // and looking at a handle reaps nothing.
    var waited: u32 = 0;
    while (waited < budget_ms and runningNow(child.id)) : (waited += 10) {
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    try testing.expect(!runningNow(child.id));

    // The child is gone and the tree is not, which is the whole of the
    // difference between this wait and `wait`.
    try testing.expect(runningNow(grandchild));
    try testing.expect(!try child.waitTree(io, 200));

    // `.kill` is `TerminateJobObject`: the job ends what is left in it, which
    // is the same end `deinit` reaches by closing the last handle to it, and
    // the port is what says so. `deinit` is the one this cannot use, because
    // it closes the port the answer would arrive on -- "deinit ends a
    // grandchild" is that half, asserted against the grandchild instead.
    try child.kill(.kill);
    try testing.expect(try child.waitTree(io, budget_ms));
    try testing.expect(endedWithin(grandchild));

    // The message is posted once and taking it off the port consumes it, so
    // the answer has to be remembered rather than asked for twice.
    try testing.expect(try child.waitTree(io, 0));

    _ = try waitWithin(&child);
}

test "deinit ends a grandchild the child started and left behind" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // Windows only: this is the job object's doing. On POSIX `deinit` signals
    // nothing and a grandchild of a reaped child keeps running, which
    // `Child.deinit` says out loud.
    if (!is_windows) return error.SkipZigTest;

    var sink: Sink = .{};
    defer sink.deinit();

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.detached_grandchild,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
    });
    defer child.deinit(io);
    defer _ = child.killWait(io, 0) catch {};
    try sink.start(child.stdout.?);

    const grandchild = try openById(try readMarkedNumber(win32.DWORD, &sink));
    defer std.os.windows.CloseHandle(grandchild);

    // The child is gone and reaped, and nothing has been killed: `killWait` on
    // a child that ended on its own signals nothing, so what is running now is
    // running because the job is still open.
    _ = try waitWithin(&child);
    try testing.expect(runningNow(grandchild));

    child.deinit(io);

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
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

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
    defer child.deinit(io);

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
    // The order out, for every test in this section: end the child, close the
    // pair, then join the reader. The child first because closing a
    // pseudoconsole waits for its client. The pair before the reader because
    // closing it is what ends the stream, and a read of a stream that has
    // ended comes back on its own -- there is then nothing to cancel and
    // nothing to wait for. Declaring the sink first is what puts its `deinit`
    // last.
    var sink: Sink = .{};
    defer sink.deinit();

    trace.print("master: opening a pair", .{});
    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &script.say_on_terminal,
        .stdio = .{ .pty = &pty },
        .detach = !is_windows,
    });
    defer child.deinit(io);
    defer _ = child.killWait(io, 0) catch {};
    if (trace.enabled()) trace.print("master: child started, id={d}", .{childId(child)});
    // The one place the two systems want different timing, and the reason
    // `Pty.closeSlave` documents it at length.
    if (!is_windows) pty.closeSlave(io);

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

    // The order out: see the first test in this section.
    var sink: Sink = .{};
    defer sink.deinit();

    var pty = try Pty.open(.{
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
    if (!pty.console.passthrough) {
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
    defer child.deinit(io);
    defer _ = child.killWait(io, 0) catch {};

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
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: this asks the child what size its terminal is, and `stty` is
    // how a shell asks. Windows has no equivalent a `cmd.exe` one-liner can
    // print; that a pseudoconsole takes the new size is `Pty`'s own test.
    if (is_windows) return error.SkipZigTest;

    // The order out: see the first test in this section.
    var sink: Sink = .{};
    defer sink.deinit();

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
    defer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

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
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

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

test "a detached pty child is the terminal's foreground process group, and an attached one is not" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: the claim is about the group a line discipline sends its
    // generated signals to, which is not a thing a console has.
    if (is_windows) return error.SkipZigTest;

    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 100" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(io);
    defer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    // `exec`, so the group the shell made is now the one `sleep` is in, and
    // the child's process id is that group's id.
    try testing.expectEqual(child.id, try conduit.foregroundGroup(pty.read.?));

    // The other half of the claim, and the reason this is worth asking at all:
    // a child on a pair without `detach` sees a terminal that has no
    // foreground group, so nothing typed at the master will ever become a
    // signal for it.
    var quiet = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer quiet.close(io);

    var attached = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 100" },
        .stdio = .{ .pty = &quiet },
        .detach = false,
    });
    defer attached.deinit(io);
    defer _ = attached.killWait(io, 0) catch {};
    quiet.closeSlave(io);

    try testing.expectError(
        error.NoForegroundGroup,
        conduit.foregroundGroup(quiet.read.?),
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

    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 100" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(io);
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

    // The order out: see the first test in the pseudo-terminal section.
    var sink: Sink = .{};
    defer sink.deinit();

    var sink_pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer sink_pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'to stderr' 1>&2" },
        .stdio = .{ .pipes = .{ .stdin = false } },
        .stderr_to = sink_pty.slaveFile(),
    });
    defer child.deinit(io);
    defer _ = child.killWait(io, 0) catch {};

    // The stderr pipe was not created, because the file replaced it.
    try testing.expectEqual(@as(?std.Io.File, null), child.stderr);

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
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    // Only the stream that asked for a pipe has one.
    try testing.expectEqual(@as(?std.Io.File, null), child.stdin);
    try testing.expect(child.stdout != null);
    try testing.expectEqual(@as(?std.Io.File, null), child.stderr);

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, result.stdout, "to stdout") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, "to stderr") == null);
    try testing.expectEqualStrings("", result.stderr);
    try testing.expectEqual(Child.Term{ .exited = 0 }, result.term);
}

test "the terminal end of a pair can be one stream and a pipe another" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only: the claim needs the terminal end to be a file, and on
    // Windows a pseudoconsole is an object a whole process is attached to.
    // `Pty.slaveFile` is a compile error there and says so.
    if (is_windows) return error.SkipZigTest;

    // The order out, both of them: see the first test in the pseudo-terminal
    // section.
    var on_terminal: Sink = .{};
    defer on_terminal.deinit();
    var on_pipe: Sink = .{};
    defer on_pipe.deinit();

    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
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
    defer child.deinit(io);
    defer _ = child.killWait(io, 0) catch {};
    // The terminal end is the caller's here, and this process is still holding
    // it: closing it is what lets a read of the master finish.
    pty.closeSlave(io);

    try on_terminal.start(pty.readFile());
    try on_pipe.start(child.stderr.?);

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
    defer closed.deinit(io);
    errdefer _ = closed.killWait(io, 0) catch {};
    try testing.expect(!conduit.succeeded(try waitWithin(&closed)));

    var ignored = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'x'" },
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .ignore, .stderr = .ignore } },
    });
    defer ignored.deinit(io);
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
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expectEqualStrings("", result.stdout);
    try testing.expectEqual(Child.Term{ .signal = .INT }, result.term);
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
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, result.stdout, "77") != null);
    try testing.expectEqual(Child.Term{ .exited = 0 }, result.term);
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
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    var wanted: [64]u8 = undefined;
    try testing.expect(std.mem.indexOf(
        u8,
        result.stdout,
        try std.fmt.bufPrint(&wanted, "{d}", .{uid}),
    ) != null);
    try testing.expectEqual(Child.Term{ .exited = 0 }, result.term);

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
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, result.stdout, "64") != null);
    try testing.expectEqual(Child.Term{ .exited = 0 }, result.term);

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
    defer free.deinit(io);
    errdefer _ = free.killWait(io, 0) catch {};
    var without = try free.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer without.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, without.stdout, "NESTED") != null);

    var bounded = try Child.spawn(io, gpa, .{
        .argv = argv,
        .stdio = .{ .pipes = .{ .stdin = false, .stderr = false } },
        .job_limits = .{ .active_processes = 1 },
    });
    defer bounded.deinit(io);
    errdefer _ = bounded.killWait(io, 0) catch {};
    var with = try bounded.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer with.deinit(gpa);
    try testing.expect(std.mem.indexOf(u8, with.stdout, "NESTED") == null);
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
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    try testing.expect(std.mem.indexOf(u8, result.stdout, "present") != null);
    try testing.expect(std.mem.indexOf(u8, result.stdout, script.working_directory_mark) != null);
    try testing.expectEqual(Child.Term{ .exited = 0 }, result.term);
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
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);

    // The variable that was asked for, and nothing else: not this process's
    // `HOME`, and not the `PATH` the spawn itself searched.
    try testing.expectEqualStrings("present|", result.stdout);
    try testing.expect(conduit.succeeded(result.term));
}

test "path_search decides which PATH a bare program name is looked up in" {
    if (is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

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
    defer found.deinit(io);
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
    defer direct.deinit(io);
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
    // before it and joined after it.
    var sink: Sink = .{};
    defer sink.deinit();

    trace.print("shell: opening a pair and starting the shell", .{});
    var shell = try conduit.spawnShell(io, gpa, .{
        .args = &script.shell_arguments,
        .size = .{ .rows = 40, .cols = 132 },
    });
    defer shell.deinit(io);
    defer _ = shell.child.killWait(io, 0) catch {};
    if (trace.enabled()) trace.print("shell: started, id={d}", .{childId(shell.child)});

    try testing.expectEqual(@as(u16, 40), (try shell.pty.size()).rows);

    try sink.start(shell.pty.readFile());
    trace.print("shell: reading the master", .{});

    try sink.expect("hi");
    trace.print("shell: the shell said what it was asked to", .{});

    _ = try shell.child.killWait(io, budget_ms);
    trace.print("shell: reaped", .{});
}

/// The child's operating-system name as a number, for a trace line that has to
/// compile on both systems: a process id on POSIX, a handle on Windows.
fn childId(child: Child) usize {
    return if (is_windows) @intFromPtr(child.id) else @intCast(child.id);
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
        defer child.deinit(io);
        errdefer _ = child.killWait(io, 0) catch {};

        // Detached either way, and the group is the child's own.
        try testing.expectEqual(child.id, child.pgid.?);
        try testing.expectEqual(child.id, getpgid(child.id));

        var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
        defer result.deinit(gpa);
        try testing.expectEqualStrings("out", result.stdout);
        try testing.expectEqualStrings("err", result.stderr);
        try testing.expectEqual(Child.Term{ .exited = 3 }, result.term);
    }
}

test "a child on the posix_spawn path starts with the same clean slate" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows or !fast_path) return error.SkipZigTest;

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
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);
    try testing.expectEqualStrings("", result.stdout);
    try testing.expectEqual(Child.Term{ .signal = .INT }, result.term);
}

test "the posix_spawn path is the faster one" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows or !fast_path) return error.SkipZigTest;

    // A budget, not a measurement, and a relative one so that a loaded machine
    // moves both numbers together. `fork` copies a process's page tables and
    // `posix_spawn` does not; measured on an M3 Max over 1000 spawns of
    // `/usr/bin/true` on the null device, that is 1304 us a spawn against
    // 902 us, a third less. A tenth less is the bar here.
    const program: []const u8 = program: {
        for ([_][]const u8{ "/usr/bin/true", "/bin/true" }) |path| {
            std.Io.Dir.accessAbsolute(io, path, .{}) catch continue;
            break :program path;
        }
        return error.SkipZigTest;
    };

    const rounds = 200;
    // A few of each first, so that neither path pays for a cold cache.
    _ = try timeOneSpawn(program, null);
    _ = try timeOneSpawn(program, "/");

    // Up to five goes at it: one descheduled run on a loaded machine is not
    // the claim, and a difference of a third is there every time.
    var attempt: usize = 0;
    while (attempt < 5) : (attempt += 1) {
        // The two are interleaved rather than measured in blocks, so that a
        // machine that gets busier while this runs makes both numbers worse
        // together instead of the second one alone.
        var fast_us: i64 = 0;
        var forked_us: i64 = 0;
        var round: usize = 0;
        while (round < rounds) : (round += 1) {
            fast_us += try timeOneSpawn(program, null);
            forked_us += try timeOneSpawn(program, "/");
        }
        if (fast_us * 10 <= forked_us * 9) return;

        std.debug.print(
            "\nposix_spawn {d} us against fork and exec {d} us, {d} spawns each: not the tenth faster this asks for\n",
            .{ fast_us, forked_us, rounds },
        );
    }
    return error.TestFastPathIsNotFaster;
}

/// Microseconds to start one child and reap it. A non-null `cwd` is what sends
/// the spawn down the fork path.
fn timeOneSpawn(program: []const u8, cwd: ?[]const u8) !i64 {
    const start: std.Io.Timestamp = .now(io, .awake);
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{program},
        .cwd = cwd,
        .stdio = .ignore,
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};
    _ = try child.wait(io);
    const end: std.Io.Timestamp = .now(io, .awake);
    return start.durationTo(end).toMicroseconds();
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
    defer without.deinit(io);
    errdefer _ = without.killWait(io, 0) catch {};
    var inherited = try without.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer inherited.deinit(gpa);

    var with = try Child.spawn(io, gpa, .{
        .argv = &list_descriptors,
        .stdio = streams,
        .fd_policy = .close_all,
    });
    defer with.deinit(io);
    errdefer _ = with.killWait(io, 0) catch {};
    var closed = try with.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer closed.deinit(gpa);

    // The default hands it on, whichever path started the child; the policy
    // does not.
    const mask = @as(u64, 1) << @intCast(inheritable);
    try testing.expect(descriptorSet(inherited.stdout) & mask != 0);
    try testing.expect(descriptorSet(closed.stdout) & mask == 0);
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
    defer child.deinit(io);
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
            child.deinit(io);
            changed.store(true, .release);
            return;
        };
        child.deinit(io);

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

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var secret = try tmp.dir.createFile(io, "secret", .{});
    defer secret.close(io);
    try testing.expect(win32.SetHandleInformation(
        secret.handle,
        win32.HANDLE_FLAG_INHERIT,
        win32.HANDLE_FLAG_INHERIT,
    ) != .FALSE);
    defer _ = win32.SetHandleInformation(secret.handle, win32.HANDLE_FLAG_INHERIT, 0);

    const command = try std.fmt.allocPrint(
        gpa,
        "$s='[DllImport(\"kernel32.dll\")] public static extern bool GetHandleInformation(IntPtr h, out uint f);'; " ++
            "Add-Type -MemberDefinition $s -Name Native -Namespace Conduit; $f=0; " ++
            "if ([Conduit.Native]::GetHandleInformation([IntPtr]{d},[ref]$f)) {{ exit 9 }} else {{ exit 0 }}",
        .{@intFromPtr(secret.handle)},
    );
    defer gpa.free(command);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", command },
        .stdio = .{ .streams = .{ .stdin = .close, .stdout = .close, .stderr = .close } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(&child));
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
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    var result = try child.output(io, gpa, .{ .timeout_ms = budget_ms });
    defer result.deinit(gpa);
    return descriptorSet(result.stdout);
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
        defer child.deinit(io);

        var result = child.output(io, gpa, .{ .timeout_ms = budget_ms }) catch {
            _ = child.killWait(io, 0) catch {};
            return;
        };
        defer result.deinit(gpa);

        const unexpected = descriptorSet(result.stdout) & ~control;
        if (unexpected != 0) {
            std.debug.print("\na child was given descriptors 0x{x} nothing gave the control child; it saw:\n{s}\n", .{
                unexpected,
                result.stdout,
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
    defer child.deinit(io);
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
    defer child.deinit(io);
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
