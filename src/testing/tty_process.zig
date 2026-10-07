//! A child that checks its own terminal or writes a cursor shape into it.
const std = @import("std");
const builtin = @import("builtin");
const tty = @import("conduit.tty");

pub fn main(init: std.process.Init) !void {
    if (comptime builtin.target.os.tag == .windows) {
        const args = try init.minimal.args.toSlice(init.arena.allocator());
        if (args.len > 1 and std.mem.eql(u8, args[1], "cursor")) {
            const out = std.Io.File.stdout();
            var mode: std.os.windows.DWORD = undefined;
            if (tty.console.GetConsoleMode(out.handle, &mode) == .FALSE) return error.FixtureNoConsole;
            if (tty.console.SetConsoleMode(out.handle, mode | tty.console.enable_virtual_terminal_processing) == .FALSE)
                return error.FixtureConsoleModeFailed;
            try out.writeStreamingAll(init.io, "\x1b[5 q");
            try init.io.sleep(.fromSeconds(30), .awake);
        }
        return;
    }
    // POSIX only: a console is waited on through its handle, not poll
    const out = std.Io.File.stdout();
    const own = tty.openControlling(init.io) catch {
        try out.writeStreamingAll(init.io, "terminal none.");
        return;
    };
    defer own.close(init.io);
    var fds = [_]std.posix.pollfd{.{ .fd = own.input.handle, .events = std.posix.POLL.IN, .revents = 0 }};
    _ = try std.posix.poll(&fds, 0);
    const said = if (fds[0].revents & std.posix.POLL.NVAL != 0) "terminal refused." else "terminal pollable.";
    try out.writeStreamingAll(init.io, said);
}
