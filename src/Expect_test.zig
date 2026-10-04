const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const Pty = @import("Pty.zig").Pty;
const handles = @import("handles.zig");
const Expect = @import("Expect.zig").Expect;
const access = @import("Expect.zig").test_access;
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
const Child = @import("Child.zig").Child;
const Watchdog = @import("testing/support.zig").Watchdog;

/// Generous: it is a failure budget, not a timing assertion.
const budget_ms = 5000;

test "a canceled reading task publishes that it finished" {
    const io = testing.io;
    const CancelRead = struct {
        base: std.Io,

        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            const state: *@This() = @ptrCast(@alignCast(userdata.?));
            if (operation == .file_read_streaming) return error.Canceled;
            return state.base.vtable.operate(state.base.userdata, operation);
        }
    };
    var state: CancelRead = .{ .base = io };
    var vtable = io.vtable.*;
    vtable.operate = CancelRead.operate;
    const cancel_io: std.Io = .{ .userdata = &state, .vtable = &vtable };

    var buffer: [32]u8 = undefined;
    var expect: Expect = .init(undefined, &buffer);
    try testing.expectError(error.Canceled, access.read(&expect, cancel_io));
    try testing.expect(access.inner(&expect).finished.load(.acquire));
}

test "start refuses to put a second reader over the buffer" {
    const io = testing.io;
    const gpa = testing.allocator;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    const argv: []const []const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "echo one reader" }
    else
        &.{ "/bin/sh", "-c", "printf 'one reader'" };
    var child = try Child.spawn(io, gpa, .{
        .argv = argv,
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var buffer: [64]u8 = undefined;
    var expect = child.expect(&buffer).?;
    try expect.start(io);
    defer expect.deinit(io);
    try testing.expectError(error.AlreadyStarted, expect.start(io));
    try testing.expectEqualStrings("one reader", (try expect.until(io, "one reader", budget_ms)).found);
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(io, &child));
}

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
    defer child.release(io) catch unreachable;
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

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{
            "/bin/sh",                                                                                      "-c",
            "printf 'first? '; read a; printf 'second? '; read b; printf 'got %s and %s\\n' \"$a\" \"$b\"",
        },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    var buffer: [1024]u8 = undefined;
    var expect: Expect = .init(child.terminalMaster().?, &buffer);
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

test "deinit stops the reader while the terminal is still open" {
    const io = testing.io;
    const gpa = testing.allocator;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // Both systems, and Windows is the one this is about. The child says its
    // piece and waits for a line, so its console stays open and nothing but
    // `deinit` will end the read the task is in. Asked with `CancelIoEx`, a
    // Windows read of the master was issued again at once, and `deinit` did
    // not return within the watchdog's thirty seconds.
    const argv: []const []const u8 = if (is_windows)
        &.{ "cmd.exe", "/c", "echo ready& set /p ignored=" }
    else
        &.{ "/bin/sh", "-c", "printf 'ready\\n'; read ignored" };

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = argv,
        .stdio = .{ .pty = &pty },
        .detach = !is_windows,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    if (!is_windows) pty.closeSlave(io);

    var buffer: [1024]u8 = undefined;
    var expect: Expect = .init(child.terminalMaster().?, &buffer);
    try expect.start(io);
    defer expect.deinit(io);
    _ = try expect.until(io, "ready", budget_ms);

    {
        var join_watchdog: Watchdog = .init(@src());
        join_watchdog.limit_ms = budget_ms;
        try join_watchdog.start(io);
        defer join_watchdog.deinit(io);
        expect.deinit(io);
    }
    try testing.expect(access.inner(&expect).finished.load(.acquire));
    // Still running: the read ended because it was asked to, not because the
    // stream did.
    try testing.expectEqual(@as(?Child.Term, null), try child.tryWait());
}

test "untilAny says which of several answers came, and leaves the rest" {
    const io = testing.io;
    const gpa = testing.allocator;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // Both systems. The shape is the one a single pattern cannot express: a
    // child that will say one of two things, and a caller that has to wait for
    // either without knowing which.
    const argv: []const []const u8 = if (is_windows)
        &.{ "cmd.exe", "/v:on", "/c", "set /p line=& if !line!==a (echo GOOD) else (echo BAD)" }
    else
        &.{ "/bin/sh", "-c", "read x; case $x in a) echo GOOD;; *) echo BAD;; esac" };

    var child = try Child.spawn(io, gpa, .{
        .argv = argv,
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var buffer: [256]u8 = undefined;
    var expect = child.expect(&buffer).?;
    try expect.start(io);
    defer expect.deinit(io);

    try expect.send(io, "a\n");
    const match = try expect.untilAny(io, &.{ "GOOD", "BAD" }, budget_ms);
    try testing.expectEqual(@as(usize, 0), match.index);
    try testing.expectEqualStrings("GOOD", match.found);

    child.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(io, &child));
}

test "untilAny takes the earliest match and leaves the later one pending" {
    const io = testing.io;
    const gpa = testing.allocator;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // POSIX only for the fixture: this needs a child that writes two words in
    // one breath, which `printf` says in one word.
    if (is_windows) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'first SECOND\n'" },
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};

    var buffer: [256]u8 = undefined;
    var expect = child.expect(&buffer).?;
    try expect.start(io);
    defer expect.deinit(io);

    // `SECOND` is listed first and arrives second, so the order in the list is
    // not what decides: the earliest match is.
    const match = try expect.untilAny(io, &.{ "SECOND", "first" }, budget_ms);
    try testing.expectEqual(@as(usize, 1), match.index);
    try testing.expectEqualStrings("first", match.found);
    try testing.expectEqualStrings("", match.before);

    // And the one that lost is still there to be waited for.
    const later = try expect.until(io, "SECOND", budget_ms);
    try testing.expectEqual(@as(usize, 0), later.index);
    try testing.expectEqualStrings("SECOND", later.found);
    try testing.expectEqualStrings(" ", later.before);

    child.closeStdin(io);
    try testing.expectEqual(Child.Term{ .exited = 0 }, try waitWithin(io, &child));
}

test "untilAny with nothing to wait for ends the way a pattern that never comes does" {
    const io = testing.io;
    const gpa = testing.allocator;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    if (is_windows) return error.SkipZigTest;

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'here\n'; exec sleep 100" },
        .stdio = .{ .pipes = .{ .stderr = false } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};

    var buffer: [256]u8 = undefined;
    var expect = child.expect(&buffer).?;
    try expect.start(io);
    defer expect.deinit(io);

    try testing.expectError(error.Timeout, expect.untilAny(io, &.{}, 50));
    // An empty pattern is the other end of it: it matches before anything has
    // arrived, and says which one it was.
    const empty = try expect.untilAny(io, &.{ "never", "" }, budget_ms);
    try testing.expectEqual(@as(usize, 1), empty.index);
    try testing.expectEqualStrings("", empty.found);
}

test "bytes waits for a count, and what follows stays pending" {
    const io = testing.io;
    const gpa = testing.allocator;
    if (is_windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'ABCDEFGH'" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    errdefer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    var buffer: [64]u8 = undefined;
    var expect: Expect = .init(child.terminalMaster().?, &buffer);
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

    var pty = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'here I am\\n'; exec sleep 100" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    pty.closeSlave(io);

    var buffer: [256]u8 = undefined;
    var expect: Expect = .init(child.terminalMaster().?, &buffer);
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
    defer child.release(io) catch unreachable;
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
    const deadline: @import("deadline.zig").Deadline = .in(io, budget_ms);
    while (true) {
        if (try child.tryWait()) |term| return term;
        if (deadline.remainingMs(io) == 0) break;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    _ = child.killWait(io, 0) catch {};
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
        const at = std.mem.indexOf(u8, said, pattern) orelse continue;
        if (winner) |already| if (at >= already.at) continue;
        winner = .{ .index = index, .at = at };
    }
    return winner;
}

test "Expect exposes no writable conversation state" {
    try testing.expect(@typeInfo(Expect) == .@"enum");
}

test "Expect refuses a start after deinit before its first reader" {
    var buffer: [1]u8 = undefined;
    var expect = Expect.init(undefined, &buffer);
    defer expect.deinit(std.testing.io);
    expect.deinit(std.testing.io);
    try std.testing.expectError(error.AlreadyStarted, expect.start(std.testing.io));
}

test "a full Expect buffer waits for its consumer without interval sleeps" {
    const Backend = struct {
        sleeps: usize = 0,
        waits: usize = 0,
        fn sleep(userdata: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
            const backend: *@This() = @ptrCast(@alignCast(userdata.?)); // safe: this test supplies its Backend as userdata.
            backend.sleeps += 1;
            return error.Canceled;
        }
        fn wait(userdata: ?*anyopaque, _: *const u32, _: u32, _: std.Io.Timeout) std.Io.Cancelable!void {
            const backend: *@This() = @ptrCast(@alignCast(userdata.?)); // safe: this test supplies its Backend as userdata.
            backend.waits += 1;
            return error.Canceled;
        }
        fn wake(_: ?*anyopaque, _: *const u32, _: u32) void {}
    };
    var backend: Backend = .{};
    var vtable = std.testing.io.vtable.*;
    vtable.sleep = Backend.sleep;
    vtable.futexWait = Backend.wait;
    vtable.futexWake = Backend.wake;
    const observed_io: std.Io = .{ .userdata = &backend, .vtable = &vtable };
    var buffer: [1]u8 = .{'x'};
    var expect = Expect.init(undefined, &buffer);
    access.inner(&expect).filled = buffer.len;
    try std.testing.expectError(error.Canceled, access.read(&expect, observed_io));
    try std.testing.expectEqual(@as(usize, 0), backend.sleeps);
    try std.testing.expectEqual(@as(usize, 1), backend.waits);
}

test "Expect discard and consumption wake a full reader at the wait boundary" {
    const Backend = struct {
        expect: *Expect,
        io: std.Io = undefined,
        consume: bool,
        waits: usize = 0,
        reads: usize = 0,
        fn wait(userdata: ?*anyopaque, _: *const u32, _: u32, _: std.Io.Timeout) std.Io.Cancelable!void {
            const backend: *@This() = @ptrCast(@alignCast(userdata.?)); // safe: this test supplies its Backend as userdata.
            backend.waits += 1;
            if (backend.waits != 1) return error.Canceled;
            // The reader has checked that it is full and is entering its
            // wait. Make room here: this notification must not be lost.
            if (backend.consume) {
                access.inner(&backend.expect).consumed = 1;
                access.compact(&backend.expect, backend.io);
            } else backend.expect.discard(backend.io);
        }
        fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
            const backend: *@This() = @ptrCast(@alignCast(userdata.?)); // safe: this test supplies its Backend as userdata.
            backend.reads += 1;
            operation.file_read_streaming.data[0][0] = 'b';
            return .{ .file_read_streaming = 1 };
        }
        fn wake(_: ?*anyopaque, _: *const u32, _: u32) void {}
    };
    for ([_]bool{ false, true }) |consume| {
        var buffer: [1]u8 = .{'a'};
        const f = handles.file(if (is_windows) std.os.windows.INVALID_HANDLE_VALUE else -1);
        var expect = Expect.init(.{ .read = f, .write = f }, &buffer);
        access.inner(&expect).filled = buffer.len;
        var backend: Backend = .{ .expect = &expect, .consume = consume };
        var vtable = std.testing.io.vtable.*;
        vtable.futexWait = Backend.wait;
        vtable.futexWake = Backend.wake;
        vtable.operate = Backend.operate;
        backend.io = .{ .userdata = &backend, .vtable = &vtable };
        try std.testing.expectError(error.Canceled, access.read(&expect, backend.io));
        try std.testing.expectEqual(@as(usize, 2), backend.waits);
        try std.testing.expectEqual(@as(usize, 1), backend.reads);
        try std.testing.expectEqualStrings("b", expect.pending(backend.io));
    }
}
