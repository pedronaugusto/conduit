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

const conduit = @import("conduit.zig");
const Child = conduit.Child;
const Pty = conduit.Pty;
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
                // A pseudo-terminal whose child is gone reports an I/O error
                // where a pipe reports end of stream.
                error.EndOfStream, error.InputOutput => return sink.stop(null),
                else => return sink.stop(err),
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
