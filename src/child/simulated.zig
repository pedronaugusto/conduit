//! A child the simulated route starts (`conduit.testing`): `std.process`
//! on the route's `Io`, so a program registered on a shakedown simulation
//! runs as a simulated process, and every later call conduit makes for it
//! (a signal, a wait with a deadline, a wait that does not wait) goes to
//! the route. The streams are the same five; a pseudo-terminal is the
//! simulated pair `Pty.open` made through the same route.
//!
//! What a simulation cannot be is refused, never pretended: credentials,
//! resource limits, a job object's limits, a parent-death signal and extra
//! descriptors are `error.Unsupported`. A simulated child's group is the
//! child alone: a signal reaches it and not what it started.
const builtin = @import("builtin");
const std = @import("std");
const seam = @import("seam");
const contract = @import("contract.zig");
const State = @import("State.zig");
const tree = @import("../tree.zig");
const cgroups = @import("../cgroup.zig");

const is_windows = builtin.target.os.tag == .windows;
const StdIo = std.process.SpawnOptions.StdIo;

pub fn spawn(io: std.Io, options: contract.SpawnOptions, state: *State) contract.SpawnError!*State {
    if (options.credentials.any() or options.resource_limits.len != 0 or options.job_limits.any() or
        options.parent_death_signal != null or options.extra_fds.len != 0) return error.Unsupported;
    var streams: [3]StdIo = undefined;
    switch (options.stdio) {
        .pty => |pty| {
            // A simulated child is on a simulated pair or on none.
            const slave = pty.simulatedSlave() orelse return error.Unsupported;
            streams = @splat(.{ .file = slave });
        },
        else => for (options.stdio.perStream(), 0..) |stream, i| {
            streams[i] = switch (stream) {
                .inherit => .inherit,
                .file => |f| .{ .file = f },
                .ignore => .ignore,
                .pipe => .pipe,
                .close => .close,
            };
        },
    }
    if (options.stderr_to) |f| streams[2] = .{ .file = f };
    var child = std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = if (options.cwd) |path| .{ .path = path } else .inherit,
        .environ_map = options.environ,
        .stdin = streams[0],
        .stdout = streams[1],
        .stderr = streams[2],
    }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.FileNotFound => error.FileNotFound,
        error.AccessDenied => error.AccessDenied,
        error.NotDir => error.NotDir,
        error.NameTooLong => error.NameTooLong,
        error.SymLinkLoop => error.SymLinkLoop,
        error.InvalidExe => error.InvalidExe,
        error.SystemResources => error.SystemResources,
        else => error.Unexpected,
    };
    // The streams are the Child's to close, never std's wait.
    const stdin = child.stdin;
    const stdout = child.stdout;
    const stderr = child.stderr;
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
    const id = child.id.?;
    state.* = .{
        .gpa = state.gpa,
        .descendants = options.descendants,
        .process_id = if (is_windows) @truncate(@intFromPtr(id)) else id, // safe: a simulated process's handle is a number the simulation chose, never dereferenced
        .id = id,
        .thread = if (is_windows) child.thread_handle else {},
        .handles_open = if (is_windows) false else {},
        .job = if (is_windows) null else {},
        .job_events = if (is_windows) null else {},
        .tree_ended = if (is_windows) false else {},
        .pgid = null,
        .forks = if (is_windows) {} else tree.Forks.none,
        .exit_watch = if (is_windows) {} else null,
        .cgroup = if (is_windows) {} else cgroups.Cgroup.none,
        .term = null,
        .stdin = stdin,
        .stdout = stdout,
        .stderr = stderr,
        .pty = switch (options.stdio) {
            .pty => |pty| pty.master(),
            else => null,
        },
        .simulated = child,
    };
    return state;
}

/// The term a signal the program does not catch ends it with; null for one
/// whose default is to be ignored, or to stop, which a simulated process
/// does not do.
pub fn termOf(signal: contract.Signal) ?seam.Term {
    if (is_windows) return switch (signal) {
        // `TerminateProcess(1)`, and the console control event's exit,
        // which is wider than `std.process`'s exit code.
        .kill => .{ .exited = 1 },
        .interrupt, .terminate => .{ .unknown = 0xC000013A },
        else => null,
    };
    const sig = signal.toPosix();
    return switch (sig) {
        .CHLD, .CONT, .URG, .WINCH, .STOP, .TSTP, .TTIN, .TTOU => null,
        else => .{ .signal = sig },
    };
}

/// The term as conduit reports it.
pub fn termFrom(term: seam.Term) contract.Term {
    // On Windows every end is an exit code.
    return switch (term) {
        .exited => |code| .{ .exited = code },
        .signal => |sig| .{ .signal = sig },
        .stopped => |sig| .{ .stopped = sig },
        .unknown => |n| if (is_windows) .{ .exited = n } else .{ .unknown = n },
    };
}
