//! Runs a shell on a pseudo-terminal, reads what it printed, and reports how
//! it ended.
//!
//! `zig build examples` builds AND runs this; `ci/readme_usage.sh` extracts the
//! region between the usage markers into README.md, so the snippet a reader
//! copies is code CI executes.

const builtin = @import("builtin");
const std = @import("std");
const conduit = @import("conduit");

/// What to have the shell do. The only platform-dependent thing in this file,
/// and it is the shell's language, not this package's API.
///
/// On POSIX `stty size` prints what the terminal says its geometry is and
/// `test -t 0` asks whether standard input is one, which together are the
/// proof that the child really is running on a terminal.
const shell_arguments: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "/c", "echo running on a pseudoconsole" }
else
    &.{ "-c", "stty size; echo \"is this a terminal? $(test -t 0 && echo yes || echo no)\"" };

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var io_threaded: std.Io.Threaded = .init(gpa, .{});
    defer io_threaded.deinit();
    const io = io_threaded.io();

    // --- README:usage ---

    // The user's shell on a new pseudo-terminal, 24 rows by 80 columns, with
    // `TERM` set and — on POSIX — the pair as its controlling terminal, so a
    // Ctrl-C written to the master would arrive as `SIGINT`.
    var shell = try conduit.spawnShell(io, gpa, .{
        .size = .{ .rows = 24, .cols = 80 },
        .args = shell_arguments,
    });
    defer shell.deinit(io);

    // Everything it writes to its terminal, and how it ends, with a bound on
    // the whole thing. A terminal is one stream, so a child on a pair has no
    // separate standard error to collect.
    var result = try shell.child.output(io, gpa, .{ .timeout_ms = 5000, .drain_ms = 250 });
    defer result.deinit(gpa);

    // --- README:usage ---

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const w = &stdout.interface;
    try w.print("the shell said:\n", .{});
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, result.stdout, "\r\n"), '\n');
    while (lines.next()) |line| try w.print("  {s}\n", .{std.mem.trimEnd(u8, line, "\r")});
    try w.print("and ended: {any}\n", .{result.term});
    try w.flush();
}
