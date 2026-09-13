//! Moves bytes between a pseudo-terminal master and a pair of files, until the
//! terminal end closes.
//!
//! This is the loop at the centre of every program that puts another program on
//! a pseudo-terminal: everything read from `input` is written to the master as
//! if it had been typed, and everything the child writes to its terminal is
//! read from the master and written to `output`. Two directions, so two tasks;
//! the caller's task runs the one from the child, which is the one that ends.
//!
//! Window size is deliberately not handled here. A `SIGWINCH` handler is
//! process-wide state, and a library that installed one would be taking
//! something from the program that owns it. The program should install its own
//! and call `Pty.resize` with `zpty.winSize` of its own terminal; that is a
//! single ioctl and is safe to call while `run` is in flight.

const Proxy = @This();

const std = @import("std");

/// The files to move bytes between, and the buffers to move them in.
///
/// None of the files are owned: `run` closes nothing. The buffers must not
/// alias, and must outlive the call. A few kilobytes each is plenty; a buffer
/// smaller than a terminal's line is merely slower, not wrong.
pub const Options = struct {
    /// The master end of the pair the child is running on.
    master: std.Io.File,
    /// Where the child's input comes from, usually the program's own standard
    /// input in raw mode.
    input: std.Io.File,
    /// Where the child's output goes, usually the program's own standard
    /// output.
    output: std.Io.File,
    /// Carries `input` to `master`.
    input_buffer: []u8,
    /// Carries `master` to `output`.
    output_buffer: []u8,
};

pub const RunError = error{
    /// The `std.Io` implementation cannot run the second direction alongside
    /// the first.
    ConcurrencyUnavailable,
    /// `output` could not be written.
    WriteFailed,
    /// `master` could not be read, for a reason other than the child leaving.
    ReadFailed,
} || std.Io.Cancelable;

/// Pumps both directions until the child's end of the terminal closes.
///
/// Returns when reading the master reports end of file — which on some systems
/// is reported as an I/O error instead, and is treated the same — or when
/// writing `output` fails. The direction carrying `input` is cancelled on the
/// way out, so a read of the program's own standard input that will never
/// complete does not hold the call open.
///
/// A child that has exited does not by itself end this: bytes it wrote are
/// still in the terminal, and the master reports end of file only once the
/// slave end is closed everywhere. `Pty.closeSlave` in the parent, right after
/// `Child.spawn`, is what makes that happen.
pub fn run(io: std.Io, options: Options) RunError!void {
    var input_error: ?RunError = null;
    var group: std.Io.Group = .init;
    try group.concurrent(io, inputTask, .{ io, options, &input_error });

    const result = pump(io, options.master, options.output, options.output_buffer);

    // Unconditional, and before the result is examined: the group owns
    // resources either way, and the direction carrying `input` is blocked on a
    // read that may never complete.
    group.cancel(io);

    try result;
    if (input_error) |err| return err;
}

/// The direction carrying `input`, as a task.
///
/// `std.Io.Group` tasks may fail only with `error.Canceled`, so anything else
/// is left in `out_error` for `run` to return once the group has joined.
fn inputTask(io: std.Io, options: Options, out_error: *?RunError) std.Io.Cancelable!void {
    pump(io, options.input, options.master, options.input_buffer) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => out_error.* = err,
    };
}

/// One direction. Ends at the first sign that `from` has no more to give.
fn pump(io: std.Io, from: std.Io.File, to: std.Io.File, buffer: []u8) RunError!void {
    while (true) {
        const n = from.readStreaming(io, &.{buffer}) catch |err| switch (err) {
            // The far end of a pseudo-terminal is gone. Linux reports this as
            // an I/O error rather than as end of file, and both mean the same
            // thing here.
            error.EndOfStream, error.InputOutput => return,
            error.Canceled => return error.Canceled,
            else => return error.ReadFailed,
        };
        if (n == 0) return;
        to.writeStreamingAll(io, buffer[0..n]) catch |err| switch (err) {
            error.BrokenPipe => return,
            error.Canceled => return error.Canceled,
            else => return error.WriteFailed,
        };
    }
}

test "bytes written to one terminal reach the program on the other, and back" {
    const std_testing = std.testing;
    const io = std_testing.io;
    const gpa = std_testing.allocator;
    const Pty = @import("Pty.zig");
    const Child = @import("Child.zig");
    const tty = @import("tty.zig");

    // The terminal the "user" is at. Raw, so nothing it is sent is echoed
    // back and confused with the child's output.
    var user = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer user.close(io);
    _ = try tty.rawMode(user.slave);

    // The terminal the child runs on, also raw: `cat` is doing the echoing
    // here, and the terminal doing it too would double every line.
    var terminal = try Pty.open(.{ .rows = 24, .cols = 80 });
    defer terminal.close(io);
    _ = try tty.rawMode(terminal.slave);

    var child = try Child.spawn(io, gpa, .{
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
        .master = terminal.masterFile(),
        .input = user.slaveFile(),
        .output = user.slaveFile(),
        .input_buffer = &input_buffer,
        .output_buffer = &output_buffer,
    } });
    defer group.cancel(io);

    const user_master = user.masterFile();
    try user_master.writeStreamingAll(io, "round trip\n");

    var seen: [64]u8 = undefined;
    var filled: usize = 0;
    while (filled < "round trip\n".len) {
        filled += try user_master.readStreaming(io, &.{seen[filled..]});
    }
    try std_testing.expectEqualStrings("round trip\n", seen[0..filled]);

    // Ending the child closes the last descriptor for its terminal, which is
    // what makes `run` return.
    _ = try child.killWait(io, 500);
}

/// `run` under a `std.Io.Group`, which accepts only `error.Canceled`.
fn runQuietly(io: std.Io, options: Options) std.Io.Cancelable!void {
    run(io, options) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {},
    };
}
