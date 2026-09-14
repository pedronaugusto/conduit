//! A conversation with a child: wait for what it says, then say something
//! back.
//!
//! `Proxy` moves bytes and `Child.output` collects them. Neither is a
//! conversation, which is the thing a program driving another program
//! actually does: wait for the prompt, answer it, wait for the next one.
//! `until` waits for a byte pattern to appear on the master, `bytes` waits
//! for a count of them, and `send` writes the reply. Every wait takes a
//! deadline, because a program waiting for a line the child will never print
//! should fail rather than stop.
//!
//! # The buffer is the caller's
//!
//! Nothing here allocates. `init` takes a buffer, and that buffer is where
//! everything the child says is kept until a match accounts for it. A match
//! hands back two slices *into* that buffer — what arrived before the pattern
//! and the pattern itself — and they stay readable until the next call on the
//! same `Expect`.
//!
//! A buffer that fills with bytes no pattern has matched is
//! `error.BufferFull`. Nothing is dropped behind the caller's back: the
//! reading stops, the child's own terminal fills up instead, and the caller
//! decides — a larger buffer, or `discard` to say the pending bytes do not
//! matter.
//!
//! # Patterns are bytes
//!
//! A pattern is a byte string, matched literally. Zig's standard library has
//! no regular-expression engine, and a pattern language shipped inside a
//! process package would be a second, worse one.
//!
//! # The reading runs on a task
//!
//! A child writes when it wants to, not when the parent asks. So the reading
//! begins at `start` and continues between calls: the prompt a child printed
//! while the parent was busy elsewhere is already in the buffer when the
//! parent comes back for it, and a deadline stays a deadline instead of
//! becoming a blocked read nobody can interrupt. No signal handler and no
//! thread of this package's own is involved; the task is an `std.Io.Group`
//! task and the `std.Io` implementation decides what it runs on.
//!
//! That task holds a pointer to the `Expect`, which makes the lifetime rules
//! the same ones `Reaper` has:
//!
//! * the files in `master` must outlive the `Expect`;
//! * an `Expect` must not be copied or moved once `start` has been called;
//! * `deinit` must run before it goes out of scope, including on the path
//!   where the child never says anything.

const Expect = @This();

const builtin = @import("builtin");
const std = @import("std");

const Pty = @import("Pty.zig");

const is_windows = builtin.os.tag == .windows;
const win32 = if (is_windows) @import("win32.zig") else struct {};

/// What the child says, and where a reply goes.
///
/// `Child.pty` is already this shape, and `Child.expect` builds one for a
/// child on pipes out of its standard output and standard input. Borrowed:
/// `deinit` closes neither file.
master: Pty.Master,
/// Where what the child says is kept. The caller's, and borrowed: nothing
/// here frees it, and it must outlive the `Expect`.
buffer: []u8,
/// How much of `buffer` has arrived.
filled: usize,
/// How much of `buffer[0..filled]` a match has already accounted for.
///
/// Those bytes are not dropped when the match is returned but at the start of
/// the next call, which is what keeps the slices in a `Match` readable after
/// the call that produced them.
consumed: usize,
/// The reading task reached the end of the stream.
ended: bool,
/// The reading task could not read, for a reason other than the end.
failed: bool,
/// Guards the four fields above: the reading task appends to them, and the
/// caller's task consumes from them.
mutex: std.Io.Mutex,
/// Set by the reading task whenever one of those fields changes, so a wait
/// ends the moment the child speaks rather than at the end of a poll
/// interval.
arrived: std.Io.Event,
/// The task doing the reading.
group: std.Io.Group,
/// Set by `deinit`, read by the task before every read it starts, so a reader
/// that is between reads when `deinit` begins does not start another one.
stopping: std.atomic.Value(bool),

/// Where a pattern was found, in the bytes that had arrived when it was.
///
/// Both slices point into the caller's buffer and are valid until the next
/// call on the same `Expect`.
pub const Match = struct {
    /// Everything that arrived before the pattern, in the order it arrived.
    /// Empty when the pattern was the next thing the child said.
    before: []const u8,
    /// The pattern, as it was found. The same bytes that were asked for; it
    /// is here so that `before.ptr + before.len` needs no arithmetic and a
    /// caller keeping the whole exchange can print the two together.
    found: []const u8,
};

/// An `Expect` that is not reading yet. `start` puts the reading task in
/// flight.
///
/// The buffer should be at least as large as the longest pattern that will be
/// waited for plus whatever the child may say before it; a few kilobytes is
/// generous for a line-oriented conversation.
pub fn init(master: Pty.Master, buffer: []u8) Expect {
    return .{
        .master = master,
        .buffer = buffer,
        .filled = 0,
        .consumed = 0,
        .ended = false,
        .failed = false,
        .mutex = .init,
        .arrived = .unset,
        .group = .init,
        .stopping = .init(false),
    };
}

pub const StartError = std.Io.ConcurrentError;

/// Begins reading.
///
/// The task must be able to run alongside the caller, so an `std.Io`
/// implementation with no concurrency to offer fails here rather than
/// deadlocking at the first `until`. Everything the child says from this
/// moment is kept; anything it said before it is not.
pub fn start(expect: *Expect, io: std.Io) StartError!void {
    return expect.group.concurrent(io, read, .{ expect, io });
}

/// Stops reading and releases the task.
///
/// Idempotent, and safe after the child has gone. Bytes that had arrived and
/// were never matched are simply forgotten; the buffer is the caller's and is
/// untouched.
///
/// The task is inside a read, and a read ends when the far end finishes, when
/// the handle goes away, or when the operating system is told to abandon it.
/// For a pseudo-terminal master whose console is still open the first two do
/// not happen, so on Windows this asks for the third — `CancelIoEx`, which
/// reaches only what is pending when it is called, so it is asked again until
/// the task says it has stopped. A reader between reads is told by `stopping`
/// not to start another.
pub fn deinit(expect: *Expect, io: std.Io) void {
    expect.stopping.store(true, .release);
    if (is_windows) {
        var waited_ms: u32 = 0;
        while (waited_ms < stop_budget_ms and !expect.stopped(io)) : (waited_ms += 2) {
            _ = win32.CancelIoEx(expect.master.read.handle, null);
            std.Io.sleep(io, .fromMilliseconds(2), .awake) catch break;
        }
    }
    expect.group.cancel(io);
}

/// How long `deinit` will keep asking before it joins anyway. Generous: the
/// first ask is usually the one that lands.
const stop_budget_ms: u32 = 2000;

/// Whether the reading task has stopped, for `deinit`'s wait.
fn stopped(expect: *Expect, io: std.Io) bool {
    expect.mutex.lockUncancelable(io);
    defer expect.mutex.unlock(io);
    return expect.ended or expect.failed;
}

pub const WaitError = error{
    /// The deadline passed with the pattern still not there. The bytes that
    /// did arrive are still pending, and `pending` is where to look at them.
    Timeout,
    /// The child's end of the stream closed with the pattern still not there.
    /// Final: nothing more will ever arrive.
    EndOfStream,
    /// The buffer is full of bytes the pattern does not match, or the pattern
    /// — or the count — is longer than the buffer could ever hold. Nothing
    /// was dropped; `discard` is how to make room.
    BufferFull,
    /// The stream could not be read, for a reason other than ending.
    ReadFailed,
} || std.Io.Cancelable;

/// Waits for `pattern` to appear in what the child says, and consumes
/// everything up to and including it.
///
/// The match is literal and the first one wins. Bytes that arrived before it
/// come back in `Match.before`; bytes that arrived after it stay pending for
/// the next call, which is what makes a sequence of `until` calls a
/// conversation rather than a series of races.
///
/// An empty pattern matches at once, before anything has arrived.
pub fn until(
    expect: *Expect,
    io: std.Io,
    pattern: []const u8,
    timeout_ms: u32,
) WaitError!Match {
    expect.compact(io);
    if (pattern.len == 0) return .{ .before = expect.buffer[0..0], .found = expect.buffer[0..0] };
    if (pattern.len > expect.buffer.len) return error.BufferFull;

    const deadline = deadlineIn(io, timeout_ms);
    // Where the next search starts. Bytes already searched cannot become a
    // match on their own; only the tail that a new pattern could straddle is
    // looked at again.
    var from: usize = 0;
    while (true) {
        expect.arrived.reset();

        var at: ?usize = null;
        var full = false;
        var ended = false;
        var failed = false;
        {
            expect.mutex.lockUncancelable(io);
            defer expect.mutex.unlock(io);
            at = std.mem.indexOfPos(u8, expect.buffer[0..expect.filled], from, pattern);
            if (at) |i| {
                expect.consumed = i + pattern.len;
            } else {
                from = expect.filled -| (pattern.len - 1);
                full = expect.filled == expect.buffer.len;
                ended = expect.ended;
                failed = expect.failed;
            }
        }

        if (at) |i| return .{
            .before = expect.buffer[0..i],
            .found = expect.buffer[i .. i + pattern.len],
        };
        if (failed) return error.ReadFailed;
        if (ended) return error.EndOfStream;
        if (full) return error.BufferFull;
        try expect.sleepUntil(io, deadline);
    }
}

/// Waits for `count` bytes to arrive, and consumes them.
///
/// The counterpart of `until` for a child whose output has a length rather
/// than a shape — a fixed-width record, or the body a header just announced.
/// A count larger than the buffer is `error.BufferFull`, because no wait
/// could ever satisfy it.
pub fn bytes(
    expect: *Expect,
    io: std.Io,
    count: usize,
    timeout_ms: u32,
) WaitError![]const u8 {
    expect.compact(io);
    if (count > expect.buffer.len) return error.BufferFull;

    const deadline = deadlineIn(io, timeout_ms);
    while (true) {
        expect.arrived.reset();

        var enough = false;
        var ended = false;
        var failed = false;
        {
            expect.mutex.lockUncancelable(io);
            defer expect.mutex.unlock(io);
            enough = expect.filled >= count;
            if (enough) {
                expect.consumed = count;
            } else {
                ended = expect.ended;
                failed = expect.failed;
            }
        }

        if (enough) return expect.buffer[0..count];
        if (failed) return error.ReadFailed;
        if (ended) return error.EndOfStream;
        try expect.sleepUntil(io, deadline);
    }
}

pub const SendError = error{
    /// Nothing is reading the other end any more: the child has gone, or
    /// closed its terminal.
    BrokenPipe,
    /// The reply could not be written, for another reason.
    WriteFailed,
} || std.Io.Cancelable;

/// Writes `reply` to the child, as if it had been typed at its terminal.
///
/// Whole or not at all, as far as the operating system allows: this returns
/// once every byte has been handed over. A terminal in its default mode ends
/// a line on `"\n"`, and the end-of-file the line discipline makes is
/// `"\x04"`.
pub fn send(expect: *Expect, io: std.Io, reply: []const u8) SendError!void {
    expect.master.write.writeStreamingAll(io, reply) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.BrokenPipe => return error.BrokenPipe,
        else => return error.WriteFailed,
    };
}

/// What has arrived and no match has accounted for yet.
///
/// A snapshot: more may arrive the moment it returns, and the slice is valid
/// only until the next call on this `Expect`. This is what to print when a
/// wait fails — a `Timeout` whose message says what the child said instead is
/// worth a great deal more than one that does not.
pub fn pending(expect: *Expect, io: std.Io) []const u8 {
    expect.mutex.lockUncancelable(io);
    defer expect.mutex.unlock(io);
    return expect.buffer[expect.consumed..expect.filled];
}

/// Forgets everything pending, and starts the buffer again from empty.
///
/// The answer to `error.BufferFull` for a caller who does not need what
/// filled it — a child that paints a screen before it asks a question, say.
/// Reading resumes at once.
pub fn discard(expect: *Expect, io: std.Io) void {
    expect.mutex.lockUncancelable(io);
    defer expect.mutex.unlock(io);
    expect.filled = 0;
    expect.consumed = 0;
}

//======================================================================
// The reading task.
//======================================================================

/// Reads the master into the caller's buffer until the stream ends, the read
/// fails, or the task is cancelled.
fn read(expect: *Expect, io: std.Io) std.Io.Cancelable!void {
    var chunk: [512]u8 = undefined;
    while (true) {
        if (expect.stopping.load(.acquire)) return expect.finish(io, .ended);
        const room = room: {
            expect.mutex.lockUncancelable(io);
            defer expect.mutex.unlock(io);
            break :room expect.buffer.len - expect.filled;
        };
        if (room == 0) {
            // The buffer is full of bytes no pattern has matched. Reading
            // stops rather than dropping them: what the child wrote stays in
            // the child's own terminal, and the caller is told `BufferFull`
            // and can `discard`. This is the one place that polls, because it
            // is waiting on the caller rather than on the child.
            try std.Io.sleep(io, .fromMilliseconds(2), .awake);
            continue;
        }

        const n = expect.master.read.readStreaming(io, &.{chunk[0..@min(room, chunk.len)]}) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // A pseudo-terminal whose child is gone reports this where a pipe
            // reports end of stream. Both mean the same thing here.
            error.EndOfStream, error.InputOutput => return expect.finish(io, .ended),
            else => return expect.finish(io, .failed),
        };
        if (n == 0) return expect.finish(io, .ended);

        {
            expect.mutex.lockUncancelable(io);
            defer expect.mutex.unlock(io);
            @memcpy(expect.buffer[expect.filled..][0..n], chunk[0..n]);
            expect.filled += n;
        }
        expect.arrived.set(io);
    }
}

/// Records why the reading stopped, and wakes whoever is waiting.
fn finish(expect: *Expect, io: std.Io, why: enum { ended, failed }) void {
    {
        expect.mutex.lockUncancelable(io);
        defer expect.mutex.unlock(io);
        switch (why) {
            .ended => expect.ended = true,
            .failed => expect.failed = true,
        }
    }
    expect.arrived.set(io);
}

//======================================================================
// Waiting, and the buffer.
//======================================================================

fn deadlineIn(io: std.Io, timeout_ms: u32) std.Io.Clock.Timestamp {
    return .fromNow(io, .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake });
}

/// Waits for the reading task to say something has changed, or for the
/// deadline.
fn sleepUntil(expect: *Expect, io: std.Io, deadline: std.Io.Clock.Timestamp) WaitError!void {
    expect.arrived.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        // A wakeup is allowed to be spurious and to report itself as a
        // timeout, so the clock decides whether there is time left rather
        // than the return value.
        error.Timeout => {
            const now: std.Io.Clock.Timestamp = .now(io, deadline.clock);
            if (deadline.compare(.lte, now)) return error.Timeout;
        },
    };
}

/// Drops the bytes a previous match accounted for, moving what is left to the
/// front of the buffer.
///
/// Called at the start of a wait rather than at the end of the one before it,
/// which is what keeps a `Match`'s slices readable until the caller asks for
/// something else.
fn compact(expect: *Expect, io: std.Io) void {
    expect.mutex.lockUncancelable(io);
    defer expect.mutex.unlock(io);
    if (expect.consumed == 0) return;
    const rest = expect.filled - expect.consumed;
    std.mem.copyForwards(u8, expect.buffer[0..rest], expect.buffer[expect.consumed..expect.filled]);
    expect.filled = rest;
    expect.consumed = 0;
}

//======================================================================
// Tests.
//======================================================================

const testing = std.testing;
const Child = @import("Child.zig");
const Watchdog = @import("test_support.zig").Watchdog;

/// Generous: it is a failure budget, not a timing assertion.
const budget_ms = 5000;

test "a conversation over pipes: wait for what the child echoes, then answer" {
    const io = testing.io;
    const gpa = testing.allocator;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // Both systems. The shell that reads a line and echoes it is the smallest
    // program that can be talked to, and `Child.expect` finds the two pipes.
    const argv: []const []const u8 = if (is_windows)
        &.{ "cmd.exe", "/v:on", "/c", "set /p line=& echo you said !line!" }
    else
        &.{ "/bin/sh", "-c", "read line; printf 'you said %s\\n' \"$line\"" };

    var child = try Child.spawn(io, gpa, .{
        .argv = argv,
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    var buffer: [256]u8 = undefined;
    var expect = child.expect(&buffer).?;
    try expect.start(io);
    defer expect.deinit(io);

    try expect.send(io, "a line\n");
    const match = try expect.until(io, "you said a line", budget_ms);
    try testing.expectEqualStrings("you said a line", match.found);

    child.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(io, &child));
}

test "a conversation on a pseudo-terminal, one prompt at a time" {
    const io = testing.io;
    const gpa = testing.allocator;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only for the fixture, not for the feature: this needs a shell that
    // prompts, reads and prompts again, which is three words of `sh` and no
    // words of `cmd.exe`.
    if (is_windows) return error.SkipZigTest;

    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{
            "/bin/sh",                                                                                      "-c",
            "printf 'first? '; read a; printf 'second? '; read b; printf 'got %s and %s\\n' \"$a\" \"$b\"",
        },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    var buffer: [1024]u8 = undefined;
    var expect: Expect = .init(child.pty.?, &buffer);
    try expect.start(io);
    defer expect.deinit(io);

    // Each wait consumes through its pattern, so the second prompt is found in
    // what arrived after the first rather than in the terminal's echo of the
    // answer to it.
    _ = try expect.until(io, "first? ", budget_ms);
    try expect.send(io, "one\n");
    _ = try expect.until(io, "second? ", budget_ms);
    try expect.send(io, "two\n");

    const match = try expect.until(io, "got one and two", budget_ms);
    try testing.expectEqualStrings("got one and two", match.found);

    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(io, &child));
}

test "bytes waits for a count, and what follows stays pending" {
    const io = testing.io;
    const gpa = testing.allocator;
    if (is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'ABCDEFGH'" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    var buffer: [64]u8 = undefined;
    var expect: Expect = .init(child.pty.?, &buffer);
    try expect.start(io);
    defer expect.deinit(io);

    try testing.expectEqualStrings("ABCD", try expect.bytes(io, 4, budget_ms));
    try testing.expectEqualStrings("EFGH", try expect.bytes(io, 4, budget_ms));

    // And the stream really has ended, which is a different answer from a
    // deadline running out.
    try testing.expectError(error.EndOfStream, expect.bytes(io, 1, budget_ms));

    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(io, &child));
}

test "a pattern that never comes is a timeout, and what did come is still pending" {
    const io = testing.io;
    const gpa = testing.allocator;
    if (is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    var pty = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'here I am\\n'; exec sleep 100" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(io);
    defer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    var buffer: [256]u8 = undefined;
    var expect: Expect = .init(child.pty.?, &buffer);
    try expect.start(io);
    defer expect.deinit(io);

    _ = try expect.until(io, "here I am", budget_ms);
    // The child is alive and quiet, which is exactly the case a deadline
    // exists for: not an ended stream, not a match.
    try testing.expectError(error.Timeout, expect.until(io, "never said", 50));
}

test "a buffer that fills says so, and discard makes room" {
    const io = testing.io;
    const gpa = testing.allocator;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only for the fixture, not for the feature: this needs a child that
    // writes an exact number of bytes and then waits, which `printf` says in
    // one word and `cmd.exe` cannot say at all.
    if (is_windows) return error.SkipZigTest;

    // Pipes rather than a pair, so the byte counts here are the child's alone:
    // a terminal would echo the answer back and turn every newline into two
    // bytes.
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'aaaaaaaa'; read go; printf 'done\n'" },
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, 0) catch {};

    var buffer: [8]u8 = undefined;
    var expect = child.expect(&buffer).?;
    try expect.start(io);
    defer expect.deinit(io);

    // Eight bytes of 'a' and no 'z' anywhere: the buffer fills with bytes the
    // pattern cannot match, and nothing is thrown away to make room.
    try testing.expectError(error.BufferFull, expect.until(io, "zzz", budget_ms));
    try testing.expectEqualStrings("aaaaaaaa", expect.pending(io));
    // A pattern longer than the buffer could ever hold is the same answer,
    // and it does not wait to give it.
    try testing.expectError(error.BufferFull, expect.until(io, "zzzzzzzzzzzz", budget_ms));

    expect.discard(io);
    try expect.send(io, "go\n");
    const match = try expect.until(io, "done", budget_ms);
    try testing.expectEqualStrings("done", match.found);

    child.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(io, &child));
}

/// Waits for the child to end, and kills it if it will not within the budget,
/// so a misbehaving child fails a test rather than stopping the run.
fn waitWithin(io: std.Io, child: *Child) !Child.Term {
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
