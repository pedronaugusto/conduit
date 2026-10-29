//! `Expect`'s matching, timed: 1 MiB of what a child might say with the
//! match at its very end, written into a pipe in 4 KiB pieces while one
//! `Expect` waits on the other end. One JSON line per row on standard
//! output, in nanoseconds per wait.
//!
//!     expect-match [--smoke]
//!
//! - literal: `until` for the closing word, searched incrementally;
//! - windowed: a caller's matcher for a run of digits, shown a 16-byte tail;
//! - unwindowed: the same matcher shown everything pending at each arrival,
//!   the cost a matcher with no window pays.
//!
//! POSIX: the pipe is the system's.
const std = @import("std");
const conduit = @import("conduit");
const Io = std.Io;
const Expect = conduit.Expect;

const piece = 4096;

const Digits = struct {
    fn find(_: ?*anyopaque, said: []const u8, ended: bool) ?Expect.Found {
        const at = for (said, 0..) |c, i| {
            if (std.ascii.isDigit(c)) break i;
        } else return null;
        var end = at;
        while (end < said.len and std.ascii.isDigit(said[end])) end += 1;
        if (end == said.len and !ended) return null;
        return .{ .at = at, .len = end - at };
    }
};

const Row = enum { literal, windowed, unwindowed };

fn feed(io: Io, file: Io.File, total: usize) void {
    var chunk: [piece]u8 = @splat('a');
    var sent: usize = 0;
    while (sent < total) : (sent += piece) {
        var w = file.writerStreaming(io, &.{});
        w.interface.writeAll(chunk[0..@min(piece, total - sent)]) catch return;
    }
    var w = file.writerStreaming(io, &.{});
    w.interface.writeAll(" END 4711\n") catch return;
}

fn wait(io: Io, gpa: std.mem.Allocator, row: Row, total: usize) !u64 {
    const fds = try conduit.pipe(.{});
    var read = conduit.held.own(fds[0]);
    defer read.deinit(io);
    var write = conduit.held.own(fds[1]);
    defer write.deinit(io);
    const buffer = try gpa.alloc(u8, total + 64);
    defer gpa.free(buffer);
    var expect = Expect.init(.{ .read = read.borrow().*, .write = write.borrow().* }, buffer);
    try expect.start(io);
    defer expect.deinit(io);
    const t0 = Io.Clock.awake.now(io);
    var writer = try io.concurrent(feed, .{ io, write.borrow().*, total });
    const timeout: Io.Timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } };
    switch (row) {
        .literal => _ = try expect.until(io, "END", timeout),
        .windowed => _ = try expect.untilMatch(io, .{ .context = null, .findFn = Digits.find, .window = 16 }, timeout),
        .unwindowed => _ = try expect.untilMatch(io, .{ .context = null, .findFn = Digits.find }, timeout),
    }
    const took = t0.durationTo(Io.Clock.awake.now(io)).nanoseconds;
    writer.await(io);
    return @intCast(took);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var smoke = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) smoke = true;
    }
    const total: usize = if (smoke) 64 << 10 else 1 << 20;
    var out_buffer: [256]u8 = undefined;
    var out = Io.File.stdout().writerStreaming(io, &out_buffer);
    inline for (.{ Row.literal, Row.windowed, Row.unwindowed }) |row| {
        const ns = try wait(io, gpa, row, total);
        try out.interface.print("{{\"row\":\"expect_match/{s}\",\"unit\":\"wait\",\"bytes\":{d},\"ns\":{d}}}\n", .{ @tagName(row), total, ns });
        try out.interface.flush();
    }
}
