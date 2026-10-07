const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.target.os.tag == .windows;
const Pty = @import("pty.zig").Pty;
const Expect = @import("expect.zig").Expect;
const access = @import("expect.zig").test_access;
const Search = access.Search;
const Match = Expect.Match;
const SendError = Expect.SendError;
const StartError = Expect.StartError;
const WaitError = Expect.WaitError;
const bytes = Expect.bytes;
const deinit = Expect.deinit;
const discard = Expect.discard;
const init = Expect.init;
const pending = Expect.pending;
const send = Expect.send;
const start = Expect.start;
const until = Expect.until;
const untilAny = Expect.untilAny;
const testing = std.testing;
const Child = @import("child.zig").Child;
const Watchdog = @import("testing/support.zig").Watchdog;
const Deadline = @import("conduit.tty").Deadline;
const FaultIo = @import("shakedown").FaultIo;

/// Generous: it is a failure budget, not a timing assertion.
const budget_ms = 5000;
const budget: std.Io.Duration = .fromMilliseconds(budget_ms);
const within_budget: std.Io.Timeout = .{ .duration = .{ .raw = budget, .clock = .awake } };

test "a canceled reading task publishes that it finished" {
    const io = testing.io;
    const canceled = try FaultIo.init(testing.allocator, io, .{ .plan = &.{.{
        .at = .{ .nth = .{ .call = .file_read_streaming, .n = 1 } },
        .fault = .cancel,
    }} });
    defer canceled.deinit();

    var buffer: [32]u8 = undefined;
    var expect: Expect = .init(undefined, &buffer);
    try testing.expectError(error.Canceled, access.read(&expect, canceled.io()));
    try testing.expect(expect.finished.load(.acquire));
}

test "start refuses to put a second reader over the buffer" {
    const io = testing.io;
    const gpa = testing.allocator;

    const argv: []const []const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "echo one reader" }
    else
        &.{ "/bin/sh", "-c", "printf 'one reader'" };
    var child = try Child.spawn(gpa, io, .{
        .argv = argv,
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, .zero) catch {};

    var buffer: [64]u8 = undefined;
    var expect = child.expect(&buffer).?;
    try expect.start(io);
    defer expect.deinit(io);
    try testing.expectError(error.AlreadyStarted, expect.start(io));
    try testing.expectEqualStrings("one reader", (try expect.until(io, "one reader", within_budget)).found);
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(io, &child));
}

test "a conversation over pipes: wait for what the child echoes, then answer" {
    const io = testing.io;
    const gpa = testing.allocator;
    // Both systems. The shell that reads a line and echoes it is the smallest
    // program that can be talked to, and `Child.expect` finds the two pipes.
    const argv: []const []const u8 = if (is_windows)
        &.{ "cmd.exe", "/v:on", "/c", "set /p line=& echo you said !line!" }
    else
        &.{ "/bin/sh", "-c", "read line; printf 'you said %s\\n' \"$line\"" };

    var child = try Child.spawn(gpa, io, .{
        .argv = argv,
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, .zero) catch {};

    var buffer: [256]u8 = undefined;
    var expect = child.expect(&buffer).?;
    try expect.start(io);
    defer expect.deinit(io);

    try expect.send(io, "a line\n");
    const match = try expect.until(io, "you said a line", within_budget);
    try testing.expectEqualStrings("you said a line", match.found);

    child.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(io, &child));
}

test "a conversation on a pseudo-terminal, one prompt at a time" {
    const io = testing.io;
    const gpa = testing.allocator;
    // POSIX only for the fixture, not for the feature: this needs a shell that
    // prompts, reads and prompts again, which is three words of `sh` and no
    // words of `cmd.exe`.
    if (is_windows) return error.SkipZigTest;

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(gpa, io, .{
        .argv = &.{
            "/bin/sh",                                                                                      "-c",
            "printf 'first? '; read a; printf 'second? '; read b; printf 'got %s and %s\\n' \"$a\" \"$b\"",
        },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, .zero) catch {};
    pty.closeSlave(io);

    var buffer: [1024]u8 = undefined;
    var expect: Expect = .init(child.terminalMaster().?, &buffer);
    try expect.start(io);
    defer expect.deinit(io);

    // Each wait consumes through its pattern, so the second prompt is found in
    // what arrived after the first rather than in the terminal's echo of the
    // answer to it.
    _ = try expect.until(io, "first? ", within_budget);
    try expect.send(io, "one\n");
    _ = try expect.until(io, "second? ", within_budget);
    try expect.send(io, "two\n");

    const match = try expect.until(io, "got one and two", within_budget);
    try testing.expectEqualStrings("got one and two", match.found);

    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(io, &child));
}

test "deinit stops the reader while the terminal is still open" {
    const io = testing.io;
    const gpa = testing.allocator;
    // Both systems, and Windows is the one this is about. The child says its
    // piece and waits for a line, so its console stays open and nothing but
    // `deinit` will end the read the task is in. Asked with `CancelIoEx`, a
    // Windows read of the master was issued again at once, and `deinit` did
    // not return before the test runner's watchdog fired.
    const argv: []const []const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "echo ready& set /p ignored=" }
    else
        &.{ "/bin/sh", "-c", "printf 'ready\\n'; read ignored" };

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(gpa, io, .{
        .argv = argv,
        .stdio = .{ .pty = &pty },
        .detach = !is_windows,
    });
    defer child.deinit(io);
    defer _ = child.killWait(io, .zero) catch {};
    if (!is_windows) pty.closeSlave(io);

    var buffer: [1024]u8 = undefined;
    var expect: Expect = .init(child.terminalMaster().?, &buffer);
    try expect.start(io);
    defer expect.deinit(io);
    _ = try expect.until(io, "ready", within_budget);

    {
        var join_watchdog: Watchdog = .init(@src(), budget_ms);
        try join_watchdog.start(io);
        defer join_watchdog.deinit(io);
        expect.stop(io);
    }
    try testing.expect(expect.finished.load(.acquire));
    try testing.expectError(error.AlreadyStarted, expect.start(io));
    {
        // Nothing more will arrive once reading has stopped, and a wait says
        // so at once instead of spending its whole timeout.
        var wait_watchdog: Watchdog = .init(@src(), budget_ms);
        try wait_watchdog.start(io);
        defer wait_watchdog.deinit(io);
        try testing.expectError(error.EndOfStream, expect.until(io, "never", Deadline.within(.fromMilliseconds(30_000))));
        try testing.expectError(error.EndOfStream, expect.bytes(io, 512, Deadline.within(.fromMilliseconds(30_000))));
    }
    // Still running: the read ended because it was asked to, not because the
    // stream did.
    try testing.expectEqual(@as(?Child.Term, null), try child.tryWait(io));
}

test "untilAny says which of several answers came, and leaves the rest" {
    const io = testing.io;
    const gpa = testing.allocator;
    // Both systems. The shape is the one a single pattern cannot express: a
    // child that will say one of two things, and a caller that has to wait for
    // either without knowing which.
    const argv: []const []const u8 = if (is_windows)
        &.{ "cmd.exe", "/v:on", "/c", "set /p line=& if !line!==a (echo GOOD) else (echo BAD)" }
    else
        &.{ "/bin/sh", "-c", "read x; case $x in a) echo GOOD;; *) echo BAD;; esac" };

    var child = try Child.spawn(gpa, io, .{
        .argv = argv,
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, .zero) catch {};

    var buffer: [256]u8 = undefined;
    var expect = child.expect(&buffer).?;
    try expect.start(io);
    defer expect.deinit(io);

    try expect.send(io, "a\n");
    const match = try expect.untilAny(io, &.{ "GOOD", "BAD" }, within_budget);
    try testing.expectEqual(@as(usize, 0), match.index);
    try testing.expectEqualStrings("GOOD", match.found);

    child.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(io, &child));
}

test "untilAny takes the earliest match and leaves the later one pending" {
    const io = testing.io;
    const gpa = testing.allocator;
    // POSIX only for the fixture: this needs a child that writes two words in
    // one breath, which `printf` says in one word.
    if (is_windows) return error.SkipZigTest;

    var child = try Child.spawn(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'first SECOND\n'" },
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, .zero) catch {};

    var buffer: [256]u8 = undefined;
    var expect = child.expect(&buffer).?;
    try expect.start(io);
    defer expect.deinit(io);

    // `SECOND` is listed first and arrives second, so the order in the list is
    // not what decides: the earliest match is.
    const match = try expect.untilAny(io, &.{ "SECOND", "first" }, within_budget);
    try testing.expectEqual(@as(usize, 1), match.index);
    try testing.expectEqualStrings("first", match.found);
    try testing.expectEqualStrings("", match.before);

    // And the one that lost is still there to be waited for.
    const later = try expect.until(io, "SECOND", within_budget);
    try testing.expectEqual(@as(usize, 0), later.index);
    try testing.expectEqualStrings("SECOND", later.found);
    try testing.expectEqualStrings(" ", later.before);

    child.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(io, &child));
}

test "untilAny with nothing to wait for ends the way a pattern that never comes does" {
    const io = testing.io;
    const gpa = testing.allocator;
    if (is_windows) return error.SkipZigTest;

    var child = try Child.spawn(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'here\n'; exec sleep 100" },
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.deinit(io);
    defer _ = child.killWait(io, .zero) catch {};

    var buffer: [256]u8 = undefined;
    var expect = child.expect(&buffer).?;
    try expect.start(io);
    defer expect.deinit(io);

    try testing.expectError(error.Timeout, expect.untilAny(io, &.{}, Deadline.within(.fromMilliseconds(50))));
    // An empty pattern is the other end of it: it matches before anything has
    // arrived, and says which one it was.
    const empty = try expect.untilAny(io, &.{ "never", "" }, within_budget);
    try testing.expectEqual(@as(usize, 1), empty.index);
    try testing.expectEqualStrings("", empty.found);
}

test "bytes waits for a count, and what follows stays pending" {
    const io = testing.io;
    const gpa = testing.allocator;
    if (is_windows) return error.SkipZigTest;

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'ABCDEFGH'" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, .zero) catch {};
    pty.closeSlave(io);

    var buffer: [64]u8 = undefined;
    var expect: Expect = .init(child.terminalMaster().?, &buffer);
    try expect.start(io);
    defer expect.deinit(io);

    try testing.expectEqualStrings("ABCD", try expect.bytes(io, 4, within_budget));
    try testing.expectEqualStrings("EFGH", try expect.bytes(io, 4, within_budget));

    // And the stream really has ended, which is a different answer from a
    // deadline running out.
    try testing.expectError(error.EndOfStream, expect.bytes(io, 1, within_budget));

    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(io, &child));
}

test "a pattern that never comes is a timeout, and what did come is still pending" {
    const io = testing.io;
    const gpa = testing.allocator;
    if (is_windows) return error.SkipZigTest;

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'here I am\\n'; exec sleep 100" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(io);
    defer _ = child.killWait(io, .zero) catch {};
    pty.closeSlave(io);

    var buffer: [256]u8 = undefined;
    var expect: Expect = .init(child.terminalMaster().?, &buffer);
    try expect.start(io);
    defer expect.deinit(io);

    _ = try expect.until(io, "here I am", within_budget);
    // The child is alive and quiet, which is exactly the case a deadline
    // exists for: not an ended stream, not a match.
    try testing.expectError(error.Timeout, expect.until(io, "never said", Deadline.within(.fromMilliseconds(50))));
}

test "a buffer that fills says so, and discard makes room" {
    const io = testing.io;
    const gpa = testing.allocator;
    // POSIX only for the fixture, not for the feature: this needs a child that
    // writes an exact number of bytes and then waits, which `printf` says in
    // one word and `cmd.exe` cannot say at all.
    if (is_windows) return error.SkipZigTest;

    // Pipes rather than a pair, so the byte counts here are the child's alone:
    // a terminal would echo the answer back and turn every newline into two
    // bytes.
    var child = try Child.spawn(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'aaaaaaaa'; read go; printf 'done\n'" },
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, .zero) catch {};

    var buffer: [8]u8 = undefined;
    var expect = child.expect(&buffer).?;
    try expect.start(io);
    defer expect.deinit(io);

    // Eight bytes of 'a' and no 'z' anywhere: the buffer fills with bytes the
    // pattern cannot match, and nothing is thrown away to make room.
    try testing.expectError(error.BufferFull, expect.until(io, "zzz", within_budget));
    try testing.expectEqualStrings("aaaaaaaa", expect.pending(io));
    // A pattern longer than the buffer could ever hold is the same answer,
    // and it does not wait to give it.
    try testing.expectError(error.BufferFull, expect.until(io, "zzzzzzzzzzzz", within_budget));

    expect.discard(io);
    try expect.send(io, "go\n");
    const match = try expect.until(io, "done", within_budget);
    try testing.expectEqualStrings("done", match.found);

    child.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(io, &child));
}

/// Waits for the child to end, and kills it if it will not within the budget,
/// so a misbehaving child fails a test rather than stopping the run.
fn waitWithin(io: std.Io, child: *Child) !Child.Term {
    const deadline: Deadline = .in(io, budget);
    while (true) {
        if (try child.tryWait(io)) |term| return term;
        if (deadline.remainingMs(io) == 0) break;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    // ziglint-ignore: Z026 the test fails either way; the kill only keeps the child from outliving it
    _ = child.killWait(io, .zero) catch {};
    return error.TestChildDidNotExit;
}

//======================================================================
// The search, against a search that keeps nothing.
//======================================================================

test "the incremental search finds what a search of the whole buffer would" {
    try testing.fuzz({}, searchMatchesAFullScan, .{});
}

/// The property: however the child's bytes are cut into arrivals, the
/// incremental search reports the same match, at the same place, as a search
/// that starts from the beginning every time — and reports none while a full
/// scan finds none.
///
/// This is where `Search.from` earns its keep or loses it. A bound that moved
/// too far would step over a pattern straddling two arrivals and the wait
/// would hang until its deadline; one that never moved would be correct and
/// quadratic. Only the first is a fault a reader would not see, and it is the
/// one an arrival split at an awkward byte finds.
fn searchMatchesAFullScan(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    // A three-letter alphabet, so that patterns actually occur: over 256 bytes
    // a match would be a rare accident and the fuzzer would be exercising the
    // miss and nothing else.
    const alphabet: []const std.testing.Smith.Weight = &.{.rangeAtMost(u8, 'a', 'c', 1)};

    var pattern_storage: [4][8]u8 = undefined;
    var patterns: [4][]const u8 = undefined;
    const count = smith.valueRangeAtMost(u8, 1, patterns.len);
    for (patterns[0..count], pattern_storage[0..count]) |*pattern, *storage| {
        // An empty pattern matches before anything arrives and `untilAny`
        // answers it without searching, so the search never sees one.
        const length = smith.valueRangeAtMost(u8, 1, storage.len);
        smith.bytesWeighted(storage[0..length], alphabet);
        pattern.* = storage[0..length];
    }
    const wanted = patterns[0..count];

    var stream: [64]u8 = undefined;
    const said = stream[0..smith.sliceWeightedBytes(&stream, alphabet)];

    var search: Search = access.searchInit(wanted);
    var arrived: usize = 0;
    while (arrived < said.len) {
        arrived += smith.valueRangeAtMost(u8, 1, @intCast(said.len - arrived));
        const so_far = said[0..arrived];

        const full = fullScan(so_far, wanted);
        if (access.searchFind(&search, so_far, wanted)) |found| {
            // Nothing may be reported that a full scan does not also find, in
            // the same place and as the same pattern.
            try testing.expect(full != null);
            try testing.expectEqual(full.?.at, found.at);
            try testing.expectEqual(full.?.index, found.index);
            // A match ends the call, so the search stops here too.
            return;
        }
        // And nothing may be missed.
        try testing.expect(full == null);
    }
}

/// The same question asked the expensive way: every pattern against every
/// byte, every time.
fn fullScan(said: []const u8, patterns: []const []const u8) ?access.Found {
    @disableInstrumentation();
    var winner: ?access.Found = null;
    for (patterns, 0..) |pattern, index| {
        const at = std.mem.find(u8, said, pattern) orelse continue;
        if (winner) |already| if (at >= already.at) continue;
        winner = .{ .index = index, .at = at };
    }
    return winner;
}

test "a stopped Expect refuses a start, and stopping again does nothing" {
    var buffer: [1]u8 = undefined;
    var expect = Expect.init(undefined, &buffer);
    defer expect.deinit(std.testing.io);
    expect.stop(std.testing.io);
    expect.stop(std.testing.io);
    try std.testing.expectError(error.AlreadyStarted, expect.start(std.testing.io));
}

test "a full Expect buffer waits for its consumer without interval sleeps" {
    // Any interval sleep, and the wait for the consumer, are canceled.
    const observed = try FaultIo.init(testing.allocator, testing.io, .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .sleep, .n = 1 } }, .fault = .cancel, .times = 0 },
        .{ .at = .{ .nth = .{ .call = .futexWait, .n = 1 } }, .fault = .cancel, .times = 0 },
    } });
    defer observed.deinit();
    var buffer: [1]u8 = .{'x'};
    var expect = Expect.init(undefined, &buffer);
    expect.filled = buffer.len;
    try testing.expectError(error.Canceled, access.read(&expect, observed.io()));
    try testing.expectEqual(@as(u64, 0), observed.count(.sleep));
    try testing.expectEqual(@as(u64, 1), observed.count(.futexWait));
}

test "Expect discard and consumption wake a full reader at the wait boundary" {
    const io = testing.io;
    const Room = struct {
        const Self = @This();
        expect: *Expect,
        consume: bool,

        /// The reader has checked that it is full and is entering its
        /// wait. Make room here: this notification must not be lost, or
        /// the wait that follows never returns.
        fn make(base: std.Io, context: *anyopaque) void {
            const room: *Self = @ptrCast(@alignCast(context)); // safe: the plan hands this test's Room as the context
            if (room.consume) {
                room.expect.consumed = 1;
                access.compact(base, room.expect);
            } else room.expect.discard(base);
        }
    };
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "said", .data = "b" });
    for ([_]bool{ false, true }) |consume| {
        // What the reader reads once there is room.
        const f = try tmp.dir.openFile(io, "said", .{});
        defer f.close(io);
        var buffer: [1]u8 = .{'a'};
        var expect = Expect.init(.{ .read = f, .write = f }, &buffer);
        expect.filled = buffer.len;
        var room: Room = .{ .expect = &expect, .consume = consume };
        const observed = try FaultIo.init(testing.allocator, io, .{ .plan = &.{
            .{ .at = .{ .nth = .{ .call = .futexWait, .n = 1 } }, .fault = .{ .call = .{ .ctx = &room, .f = Room.make } } },
            .{ .at = .{ .nth = .{ .call = .futexWait, .n = 2 } }, .fault = .cancel },
        } });
        defer observed.deinit();
        try testing.expectError(error.Canceled, access.read(&expect, observed.io()));
        try testing.expectEqual(@as(u64, 2), observed.count(.futexWait));
        try testing.expectEqual(@as(u64, 1), observed.count(.file_read_streaming));
        try testing.expectEqualStrings("b", expect.pending(io));
    }
}
