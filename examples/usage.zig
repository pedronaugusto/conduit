//! Runs a program on a pseudo-terminal, reads what it printed, and reports how
//! it ended.
//!
//! `zig build examples` builds AND runs this; `ci/readme_usage.sh` extracts the
//! region between the usage markers into README.md, so the snippet a reader
//! copies is code CI executes.

const builtin = @import("builtin");
const std = @import("std");
const zpty = @import("zpty");

/// What to run on the pair. The only platform-dependent thing in this file,
/// and it is the shell's language, not this package's API.
///
/// On POSIX `stty size` prints what the terminal says its geometry is and
/// `test -t 0` asks whether standard input is one, which together are the
/// proof that the child really is running on a terminal.
const argv: []const []const u8 = if (builtin.os.tag == .windows)
    &.{ "cmd.exe", "/c", "echo running on a pseudoconsole" }
else
    &.{ "/bin/sh", "-c", "stty size; echo \"is this a terminal? $(test -t 0 && echo yes || echo no)\"" };

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

    // A child on it. On POSIX `detach` makes it a session leader with the pair
    // as its controlling terminal, which is what turns a Ctrl-C written to the
    // master into a `SIGINT`; on Windows a pseudoconsole is the child's
    // console either way, and a new process group would only disable Ctrl-C.
    var child = try zpty.Child.spawn(io, gpa, .{
        .argv = argv,
        .stdio = .{ .pty = &pty },
        .detach = builtin.os.tag != .windows,
    });
    defer child.deinit(io);

    // The parent's copy of the terminal end has to go on POSIX, or reading the
    // master never reports end of file. On Windows this is
    // `ClosePseudoConsole`, which would end the child, so it waits until the
    // program is done -- `Pty.closeSlave` is where that difference is written
    // down.
    if (builtin.os.tag != .windows) pty.closeSlave(io);

    // Everything it writes to its terminal, and how it ends, with a bound on
    // the whole thing. Reading and waiting happen together on purpose: a child
    // whose output nobody is draining can block, on some systems even inside
    // its own exit.
    var result = try child.output(io, gpa, .{ .timeout_ms = 5000, .drain_ms = 250 });
    defer result.deinit(gpa);

    // --- README:usage ---

    var stdout_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const w = &stdout.interface;
    try w.print("the child said:\n", .{});
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, result.stdout, "\r\n"), '\n');
    while (lines.next()) |line| try w.print("  {s}\n", .{std.mem.trimEnd(u8, line, "\r")});
    try w.print("and ended: {any}\n", .{result.term});
    try w.flush();
}
