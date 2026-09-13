//! Runs a program on a pseudo-terminal, reads what it prints, and reports how
//! it ended.
//!
//! `zig build examples` builds AND runs this; `ci/readme_usage.sh` extracts the
//! region between the usage markers into README.md, so the snippet a reader
//! copies is code CI executes.

const std = @import("std");
const zpty = @import("zpty");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    // --- README:usage ---

    // A pseudo-terminal pair, 24 rows by 80 columns.
    var pty = try zpty.Pty.open(.{ .rows = 24, .cols = 80 });
    defer pty.close(io);

    // A child on it, in its own session, with the pair as its controlling
    // terminal. `stty size` reports what the terminal says, which is proof the
    // child is talking to one.
    var child = try zpty.Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "stty size; echo 'is this a terminal? '$(test -t 0 && echo yes || echo no)" },
        .stdio = .{ .pty = &pty },
        .detach = true,
    });
    defer child.deinit(io);

    // The parent's copy of the slave end has to go, or reading the master will
    // never report end of file.
    pty.closeSlave(io);

    // Everything the child wrote to its terminal, read from the master end.
    var buffer: [1024]u8 = undefined;
    var reader = pty.masterFile().readerStreaming(io, &buffer);
    const output = reader.interface.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
        // A pseudo-terminal whose child is gone reports this on some systems
        // where a pipe reports end of file.
        error.ReadFailed => try gpa.dupe(u8, reader.interface.buffered()),
        else => |e| return e,
    };
    defer gpa.free(output);

    // And how it ended: `SIGTERM` after a two-second grace if it is still
    // running, which this one is not.
    const term = try child.killWait(io, 2000);

    // --- README:usage ---

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const w = &stdout.interface;
    try w.print("the child said:\n", .{});
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, output, "\r\n"), '\n');
    while (lines.next()) |line| try w.print("  {s}\n", .{std.mem.trimEnd(u8, line, "\r")});
    try w.print("and ended: {any}\n", .{term});
    try w.flush();
}
