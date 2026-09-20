//! The user's shell on a pseudo-terminal, with the defaults a terminal
//! program would otherwise write out by hand every time.
//!
//! This is `Pty.open` plus `Child.spawn` plus the two or three decisions that
//! are the same in every program that does it: which program the user's shell
//! is, what `TERM` should say, and — the part worth having — the one place
//! where POSIX and Windows want different things done right after the spawn.

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const Child = @import("Child.zig");
const Pty = @import("Pty.zig");
const environ = @import("environ.zig");
const tty = @import("tty.zig");

const is_windows = builtin.os.tag == .windows;
const win32 = if (is_windows) @import("win32.zig") else struct {};

/// The longest program path `fromEnvironment` will take from the environment,
/// in WTF-16 units.
///
/// Windows allows a path of 32767 units, and `std.fs.max_path_bytes` is three
/// times that. Reserving it twice over as static buffers for the sake of a
/// shell's pathname would be a third of a megabyte spent on a case nobody has:
/// `%COMSPEC%` is twenty-odd characters, and a value longer than this is one
/// this package declines to run rather than one it truncates.
const max_program_units = 1024;

/// A shell running on a pseudo-terminal, and the pair it runs on.
pub const Shell = struct {
    /// The pair. Read it with `pty.readFile()` and write it with
    /// `pty.writeFile()`; on POSIX the terminal end is already closed, which
    /// is what lets a read of the master finish when the shell exits.
    pty: Pty,
    /// The shell process.
    child: Child,

    /// Closes the pair and the streams the `Child` owns.
    ///
    /// Reap the child first — `child.killWait(io, grace)` or `child.wait(io)`
    /// — or this leaves a process behind. On Windows closing the pair is
    /// `ClosePseudoConsole`, which ends a shell that is still running, but
    /// there is still nobody left to collect how it ended.
    pub fn deinit(shell: *Shell, io: std.Io) void {
        shell.child.deinit(io);
        shell.pty.close(io);
    }
};

pub const Options = struct {
    /// The program to run. `null` is the user's shell: `SHELL` from the
    /// environment on POSIX, falling back to `/bin/sh`; `COMSPEC` on Windows,
    /// falling back to `cmd.exe`.
    program: ?[]const u8 = null,
    /// Arguments after the program. Empty starts an interactive shell, which
    /// is what a terminal wants.
    args: []const []const u8 = &.{},
    /// The geometry of the pair.
    size: tty.Size = .{ .rows = 24, .cols = 80 },
    /// What the console on the far side of the pair is asked to do. Windows
    /// only; `Shell.pty.console` says which of them the system granted.
    console: Pty.ConsoleOptions = .{},
    /// The shell's working directory. `null` inherits this process's.
    cwd: ?[]const u8 = null,
    /// The shell's environment. `null` inherits this process's, with `term`
    /// applied — which is the reason this option exists at all, since a child
    /// on a pseudo-terminal that inherits a `TERM` of `dumb` will behave like
    /// one.
    environ: ?*const std.process.Environ.Map = null,
    /// What `TERM` should say, when `environ` is `null`. `null` leaves
    /// whatever this process has.
    ///
    /// Ignored on Windows, where a console is not described by `TERM` and
    /// programs ask the console API instead. It is still set, because a
    /// program built for both may look.
    term: ?[]const u8 = "xterm-256color",
};

pub const SpawnShellError = Pty.OpenError || Child.SpawnError || environ.InheritError;

/// Starts the user's shell on a new pseudo-terminal.
///
/// The defaults are the ones a terminal emulator would choose: a 24×80 pair,
/// the user's shell with no arguments, this process's environment with `TERM`
/// set, and — on POSIX — `detach`, so the shell becomes a session leader with
/// the pair as its controlling terminal and Ctrl-C written to the master
/// becomes `SIGINT`. On Windows `detach` is deliberately *not* used: a
/// pseudoconsole is the child's console either way, and a new process group
/// there starts with Ctrl-C disabled, which is the opposite of what a terminal
/// wants.
///
/// The terminal end of the pair is closed here on POSIX, where leaving it open
/// would stop a read of the master from ever finishing, and left open on
/// Windows, where closing it would end the shell. That difference is the one
/// thing this function exists to absorb.
///
/// On success the caller owns the `Shell` and must reap the child and call
/// `Shell.deinit`.
pub fn spawnShell(io: std.Io, allocator: Allocator, options: Options) SpawnShellError!Shell {
    var owned_program: ?[]u8 = null;
    defer if (owned_program) |program| allocator.free(program);
    const program = options.program orelse program: {
        owned_program = try defaultShell(allocator);
        break :program owned_program.?;
    };

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.append(allocator, program);
    try argv.appendSlice(allocator, options.args);

    // Built here and freed on the way out: `Child.spawn` copies everything it
    // needs before there is a child at all.
    var inherited: ?std.process.Environ.Map = null;
    defer if (inherited) |*map| map.deinit();
    const environ_map: ?*const std.process.Environ.Map = map: {
        if (options.environ) |given| break :map given;
        const term = options.term orelse break :map null;
        inherited = try environ.inherit(allocator, &.{.{ .name = "TERM", .value = term }});
        break :map &inherited.?;
    };

    var pty: Pty = try .open(.{
        .rows = options.size.rows,
        .cols = options.size.cols,
        .x_pixel = options.size.x_pixel,
        .y_pixel = options.size.y_pixel,
        .console = options.console,
    });
    errdefer pty.close(io);

    var child = try Child.spawn(io, allocator, .{
        .argv = argv.items,
        .cwd = options.cwd,
        .environ = environ_map,
        .stdio = .{ .pty = &pty },
        .detach = !is_windows,
    });
    errdefer _ = child.killWait(io, 0) catch {};

    if (!is_windows) pty.closeSlave(io);

    return .{ .pty = pty, .child = child };
}

/// The user's shell, or the one every system is guaranteed to have.
fn defaultShell(allocator: Allocator) Allocator.Error![]u8 {
    if (try fromEnvironment(allocator, if (is_windows) "COMSPEC" else "SHELL")) |program| {
        return program;
    }
    return allocator.dupe(u8, if (is_windows) "cmd.exe" else "/bin/sh");
}

/// An owned copy of one variable from this process's environment.
///
/// On Windows the environment block moves when it is modified, so the value is
/// copied rather than pointed at. `GetEnvironmentVariableW` does the copying:
/// one call, rather than a walk of the process environment block under the
/// loader's lock with an assertion about every entry it passes.
fn fromEnvironment(allocator: Allocator, name: []const u8) Allocator.Error!?[]u8 {
    if (is_windows) {
        var value: [max_program_units]u16 = undefined;
        // Three bytes of WTF-8 for every WTF-16 unit is the worst case.
        var buffer: [max_program_units * 3]u8 = undefined;
        var name_w: [64]u16 = undefined;
        if (name.len + 1 > name_w.len) return null;
        const name_len = std.unicode.wtf8ToWtf16Le(&name_w, name) catch return null;
        name_w[name_len] = 0;

        const written = win32.GetEnvironmentVariableW(
            name_w[0..name_len :0].ptr,
            &value,
            value.len,
        );
        // Zero is "there is no such variable" and the fall-back is used
        // instead. A count at or past the buffer's length is the variable not
        // fitting, which for a program name means it is not one this package
        // is going to run; the count `GetEnvironmentVariableW` reports in that
        // case is what it would have needed, not what it wrote, so nothing has
        // been written and there is nothing to read.
        if (written == 0 or written >= value.len) return null;
        const len = std.unicode.wtf16LeToWtf8(&buffer, value[0..written]);
        return try allocator.dupe(u8, buffer[0..len]);
    }
    var index: usize = 0;
    while (std.c.environ[index]) |entry| : (index += 1) {
        const pair = std.mem.span(entry);
        if (pair.len <= name.len) continue;
        if (!std.mem.eql(u8, pair[0..name.len], name)) continue;
        if (pair[name.len] != '=') continue;
        const value = pair[name.len + 1 ..];
        if (value.len == 0) continue;
        return try allocator.dupe(u8, value);
    }
    return null;
}

test "the default shell is a program that exists" {
    const program = try defaultShell(std.testing.allocator);
    defer std.testing.allocator.free(program);
    try std.testing.expect(program.len > 0);
    if (!is_windows) try std.testing.expect(std.mem.indexOfScalar(u8, program, '/') != null);
}

test "default shell calls retain independent values" {
    if (!is_windows) return error.SkipZigTest;

    const first = try defaultShell(std.testing.allocator);
    defer std.testing.allocator.free(first);
    const second = try defaultShell(std.testing.allocator);
    defer std.testing.allocator.free(second);
    try std.testing.expect(first.ptr != second.ptr);
    if (first.len > 0 and second.len > 0) {
        const second_first = second[0];
        first[0] +%= 1;
        try std.testing.expectEqual(second_first, second[0]);
    }
}
