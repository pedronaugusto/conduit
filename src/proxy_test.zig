//! `Proxy.run` between real pseudo-terminal pairs, with a child on one of them.
const builtin = @import("builtin");
const std = @import("std");
const conduit = @import("conduit.zig");
const handles = @import("handles.zig");
const tty = @import("conduit.tty");
const Child = conduit.Child;
const Pty = conduit.Pty;
const Deadline = tty.Deadline;
const Watchdog = @import("testing/support.zig").Watchdog;
const Options = conduit.Proxy.Options;
const run = conduit.Proxy.run;
const testing = std.testing;
const is_windows = builtin.target.os.tag == .windows;

test "input at end of file leaves the child's output flowing" {
    if (is_windows) return error.SkipZigTest;

    const io = testing.io;
    const gpa = testing.allocator;

    var terminal = try Pty.open(std.testing.allocator, .{});
    defer terminal.close(io);
    var child = try Child.spawn(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 0.3; echo hello-from-child" },
        .stdio = .{ .pty = &terminal },
        .detach = true,
    });
    defer child.deinit(io);
    terminal.closeSlave(io);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const output = try tmp.dir.createFile(io, "output", .{ .read = true });
    defer output.close(io);
    const input = try std.Io.Dir.cwd().openFile(io, "/dev/null", .{});
    defer input.close(io);

    var input_buffer: [64]u8 = undefined;
    var output_buffer: [64]u8 = undefined;
    try run(io, .{
        .master = terminal.master(),
        .input = input,
        .output = output,
        .input_buffer = &input_buffer,
        .output_buffer = &output_buffer,
    });
    _ = try child.wait(io);

    var seen: [128]u8 = undefined;
    const n = try output.readPositionalAll(io, &seen, 0);
    try testing.expect(std.mem.find(u8, seen[0..n], "hello-from-child") != null);
}

/// `run` under a `std.Io.Group`, which accepts only `error.Canceled`.
fn runQuietly(io: std.Io, options: Options) std.Io.Cancelable!void {
    run(io, options) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };
}

/// Reads from `file` until `want` has arrived or the budget runs out.
///
/// Polled rather than read straight, so a pump that never delivers fails the
/// test it is in instead of stopping the run.
fn expectWithin(io: std.Io, file: std.Io.File, seen: []u8, want: []const u8) !void {
    var filled: usize = 0;
    while (filled < want.len) {
        var fds = [_]std.posix.pollfd{.{
            .fd = file.handle,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        if (try std.posix.poll(&fds, 5000) == 0) return error.TestPumpDeliveredNothing;
        filled += try handles.readStreaming(io, file, &.{seen[filled..]});
    }
    try testing.expectEqualStrings(want, seen[0..filled]);
}

test "bytes written to one terminal reach the program on the other, and back" {
    // POSIX only: the test stands up a second pseudo-terminal to play the part
    // of the user's own, which a pseudoconsole cannot do -- there is nothing on
    // Windows that both is a console and can be read from.
    if (is_windows) return error.SkipZigTest;

    const io = testing.io;
    const gpa = testing.allocator;

    // The terminal the "user" is at. Raw, so nothing it is sent is echoed
    // back and confused with the child's output.
    var user = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer user.close(io);
    _ = try tty.rawMode(user.slaveHandle().?);

    // The terminal the child runs on, also raw: `cat` is doing the echoing
    // here, and the terminal doing it too would double every line.
    var terminal = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer terminal.close(io);
    _ = try tty.rawMode(terminal.slaveHandle().?);

    var child = try Child.spawn(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "cat" },
        .stdio = .{ .pty = &terminal },
        .detach = true,
    });
    defer child.deinit(io);
    terminal.closeSlave(io);

    var input_buffer: [256]u8 = undefined;
    var output_buffer: [256]u8 = undefined;
    var group: std.Io.Group = .init;
    try group.concurrent(io, runQuietly, .{ io, Options{
        .master = terminal.master(),
        .input = user.slaveFile(),
        .output = user.slaveFile(),
        .input_buffer = &input_buffer,
        .output_buffer = &output_buffer,
    } });
    defer group.cancel(io);

    try user.writeFile().writeStreamingAll(io, "round trip\n");

    var seen: [64]u8 = undefined;
    try expectWithin(io, user.readFile(), &seen, "round trip\n");

    // Ending the child closes the last descriptor for its terminal, which is
    // what makes `run` return.
    _ = try child.killWait(io, .fromMilliseconds(500));
}

test "a Ctrl-C typed at the proxy's input becomes SIGINT for the child" {
    if (is_windows) return error.SkipZigTest;

    const io = testing.io;
    const gpa = testing.allocator;

    // The user's terminal, raw: that is what turns Ctrl-C into a byte instead
    // of a signal for this process, which is the whole claim being tested.
    var user = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer user.close(io);
    _ = try tty.rawMode(user.slaveHandle().?);

    var terminal = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer terminal.close(io);

    var child = try Child.spawn(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "exec sleep 100" },
        .stdio = .{ .pty = &terminal },
        .detach = true,
    });
    defer child.deinit(io);
    errdefer _ = child.killWait(io, .zero) catch {};
    terminal.closeSlave(io);

    var input_buffer: [256]u8 = undefined;
    var output_buffer: [256]u8 = undefined;
    var group: std.Io.Group = .init;
    try group.concurrent(io, runQuietly, .{ io, Options{
        .master = terminal.master(),
        .input = user.slaveFile(),
        .output = user.slaveFile(),
        .input_buffer = &input_buffer,
        .output_buffer = &output_buffer,
    } });
    defer group.cancel(io);

    // Not written to the child's terminal: written to the *user's*, which the
    // proxy is reading, exactly as if it had been typed.
    try user.writeFile().writeStreamingAll(io, "\x03");

    const deadline: Deadline = .in(io, .fromMilliseconds(5000));
    const term = while (deadline.remainingMs(io) > 0) {
        if (try child.tryWait()) |term| break term;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    } else return error.TestChildWasNotInterrupted;
    try testing.expectEqual(Child.Term{ .signal = .INT }, term);
}

test "the window size is forwarded onto the pair" {
    if (is_windows) return error.SkipZigTest;

    const io = testing.io;

    // Two pairs again: one stands in for the program's own terminal, whose
    // size the forwarder reads, and one is the child's.
    var user = try Pty.open(std.testing.allocator, .{ .rows = 11, .cols = 37 });
    defer user.close(io);

    var terminal = try Pty.open(std.testing.allocator, .{ .rows = 24, .cols = 80 });
    defer terminal.close(io);

    var input_buffer: [64]u8 = undefined;
    var output_buffer: [64]u8 = undefined;
    var ticket: std.atomic.Value(u32) = .init(0);
    var group: std.Io.Group = .init;
    try group.concurrent(io, runQuietly, .{ io, Options{
        .master = terminal.master(),
        .input = user.slaveFile(),
        .output = user.slaveFile(),
        .input_buffer = &input_buffer,
        .output_buffer = &output_buffer,
        .resize = .{
            .pty = &terminal,
            .source = user.slaveHandle().?,
            .ticket = &ticket,
            .interval = .fromSeconds(1),
            .tick = .fromMilliseconds(1),
        },
    } });
    defer group.cancel(io);

    // The size the program is already at is copied straight away.
    try expectSizeWithin(io, &terminal, .{ .rows = 11, .cols = 37 });

    // And a change is picked up on the ticket rather than at the end of the
    // one-second interval, which is what the ticket is for.
    try user.resize(.{ .rows = 50, .cols = 160 });
    _ = ticket.fetchAdd(1, .release);
    try expectSizeWithin(io, &terminal, .{ .rows = 50, .cols = 160 });
}

fn expectSizeWithin(io: std.Io, pty: *Pty, want: tty.Size) !void {
    const deadline: Deadline = .in(io, .fromMilliseconds(5000));
    while (deadline.remainingMs(io) > 0) {
        const now = try pty.size();
        if (now.rows == want.rows and now.cols == want.cols) return;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
    return error.TestSizeWasNotForwarded;
}

test "an input error interrupts a silent output pump" {
    if (is_windows) return error.SkipZigTest;

    const io = testing.io;
    var watchdog: Watchdog = .init(@src(), 2000);
    try watchdog.start(io);
    defer watchdog.deinit(io);

    var terminal = try Pty.open(std.testing.allocator, .{});
    defer terminal.close(io);
    var input_buffer: [32]u8 = undefined;
    var output_buffer: [32]u8 = undefined;
    const invalid: std.Io.File = .{ .handle = -1, .flags = .{ .nonblocking = false } };

    try testing.expectError(error.ReadFailed, run(io, .{
        .master = terminal.master(),
        .input = invalid,
        .output = invalid,
        .input_buffer = &input_buffer,
        .output_buffer = &output_buffer,
    }));
}
