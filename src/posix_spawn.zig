//! Starting a child with `posix_spawn`, for the spawns that need nothing done
//! between the fork and the exec.
//!
//! `fork` copies a process's page tables, and the cost of that grows with how
//! much memory the parent has mapped. `posix_spawn` does not: the systems here
//! implement it with `vfork` or with a kernel call of their own, and the child
//! is described by a list of file actions and a set of attributes rather than
//! by code running in it. Measured on an M3 Max, 1000 spawns of `/usr/bin/true`
//! on the null device: 1336 µs a spawn through `fork` and `execve`, 946 µs
//! through `posix_spawn`.
//!
//! # What it cannot do
//!
//! The general path exists because there are things only code between a fork
//! and an exec can do, and every one of them sends a spawn back to it:
//!
//! * a pseudo-terminal, which needs `setsid` and then `TIOCSCTTY` — there is
//!   no file action for an ioctl;
//! * `credentials` and `resource_limits`, which a process sets on itself;
//! * `cwd`, because the file action for it is `_np` on both systems, arrived
//!   late on each, and has a history of not working;
//! * `Stream.close`, because a file action that closes a descriptor the parent
//!   does not have is a failed spawn on some systems and a no-op on others,
//!   and this package promises the second;
//! * a caller's file at descriptor 0, 1 or 2, because `adddup2` of a
//!   descriptor onto itself is specified to clear close-on-exec and is not
//!   implemented that way everywhere.
//!
//! Everything else — pipes, the null device, inherited streams, `stderr_to`,
//! an environment, a search path, `detach` — is expressible, and the child
//! this path produces is the same child in every way a caller can observe.
//!
//! # Where it runs
//!
//! Linux and Darwin. The attribute flags `posix_spawn` takes have the same
//! values on both, and the suite runs on both. The BSDs number them
//! differently and are cross-compiled rather than tested here, so they keep
//! the fork.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;

const Child = @import("Child.zig");
const options_for_build = @import("conduit_options");

const SpawnError = Child.SpawnError;
const SpawnOptions = Child.SpawnOptions;

/// Whether this system has the `posix_spawn` interface this file uses, with
/// the attribute flags spelled the way it spells them.
pub const available = !options_for_build.force_fork_spawn and switch (builtin.os.tag) {
    .linux,
    .driverkit,
    .ios,
    .maccatalyst,
    .macos,
    .tvos,
    .visionos,
    .watchos,
    => true,
    else => false,
};

/// Whether the options ask for anything that has to happen between a fork and
/// an exec.
///
/// The descriptors are the other half of the question and are asked about in
/// `spawn`, which has the plan.
pub fn suits(options: SpawnOptions) bool {
    if (!available) return false;
    if (options.stdio == .pty) return false;
    if (options.cwd != null) return false;
    if (options.credentials.any()) return false;
    if (options.resource_limits.len != 0) return false;
    if (options.fd_policy != .close_on_exec) return false;
    return true;
}

/// Starts the child, or returns `null` if the descriptors it was given cannot
/// be described as file actions.
///
/// `null` is not a failure: the caller starts the same child through `fork`
/// and `execve` instead, and nothing the child sees is different.
pub fn spawn(
    plan: [3]PlanTarget,
    candidates: []const [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    options: SpawnOptions,
) SpawnError!?posix.pid_t {
    var actions: FileActions = undefined;
    if (posix_spawn_file_actions_init(&actions) != 0) return error.SystemResources;
    defer _ = posix_spawn_file_actions_destroy(&actions);

    for (plan, 0..) |target, slot| switch (target) {
        .inherit => {},
        // See the file comment: neither of these two is expressible here in a
        // way that means the same thing on both systems.
        .close => return null,
        .place => |fd| {
            if (fd < 3) return null;
            if (posix_spawn_file_actions_adddup2(&actions, fd, @intCast(slot)) != 0) {
                return error.SystemResources;
            }
        },
    };

    var attr: Attr = undefined;
    if (posix_spawnattr_init(&attr) != 0) return error.SystemResources;
    defer _ = posix_spawnattr_destroy(&attr);

    var flags: Flags = .{ .setsigdef = true, .setsigmask = true };
    if (options.detach) {
        flags.setpgroup = true;
        // Zero is "a new group whose leader is the child", which is what
        // `setpgid(0, 0)` says in the fork child.
        if (posix_spawnattr_setpgroup(&attr, 0) != 0) return error.Unexpected;
    }
    if (posix_spawnattr_setflags(&attr, flags) != 0) return error.Unexpected;

    // The same clean slate the fork child is given, said as two attributes.
    // Every signal back at its default action rather than only the ignored
    // ones, which comes to the same thing: `execve` resets a signal the parent
    // had a handler for, and leaves an ignored one ignored. The two that
    // cannot be caught cannot be reset either.
    var defaults = posix.sigfillset();
    posix.sigdelset(&defaults, .KILL);
    posix.sigdelset(&defaults, .STOP);
    if (posix_spawnattr_setsigdefault(&attr, &defaults) != 0) return error.Unexpected;
    const unblocked = posix.sigemptyset();
    if (posix_spawnattr_setsigmask(&attr, &unblocked) != 0) return error.Unexpected;

    // Every candidate in turn, and the error worth reporting is the one from
    // the last attempt that got past "no such file" -- the same rule the fork
    // child follows, for the same reason.
    var best: posix.E = .NOENT;
    for (candidates) |candidate| {
        var pid: posix.pid_t = undefined;
        const rc = posix_spawn(&pid, candidate, &actions, &attr, argv, envp);
        if (rc == 0) return pid;
        switch (@as(posix.E, @enumFromInt(rc))) {
            .NOENT, .NOTDIR => {},
            else => |err| best = err,
        }
    }
    return spawnError(best);
}

/// `posix_spawn` reports a failure in the child by returning its error number,
/// so the two kinds arrive together: the ones the fork itself can fail with,
/// and the ones the `execve` can.
fn spawnError(err: posix.E) SpawnError {
    return switch (err) {
        .AGAIN => error.ResourceLimitReached,
        .NOMEM => error.SystemResources,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => Child.execError(err),
    };
}

/// The shape `child_posix.Plan` hands over: what the child gets at each of its
/// first three descriptors.
pub const PlanTarget = @import("stdio_plan.zig").Target;

//======================================================================
// The interface.
//======================================================================

/// `posix_spawnattr_t` and `posix_spawn_file_actions_t` are opaque, and what
/// is behind them differs: a pointer on Darwin, a struct of a few hundred
/// bytes on Linux. Nothing here looks inside one, so a block large enough for
/// either and aligned for a pointer is the portable spelling — and it lives on
/// the stack, which is why `spawn` takes no allocator.
const Attr = extern struct { opaque_storage: [512]u8 align(16) };
const FileActions = extern struct { opaque_storage: [256]u8 align(16) };

/// The four attribute flags this file sets, which Linux and Darwin number the
/// same way. The BSDs do not, and `available` is false there.
const Flags = packed struct(c_short) {
    resetids: bool = false,
    setpgroup: bool = false,
    setsigdef: bool = false,
    setsigmask: bool = false,
    _rest: u12 = 0,
};

extern "c" fn posix_spawnattr_init(attr: *Attr) c_int;
extern "c" fn posix_spawnattr_destroy(attr: *Attr) c_int;
extern "c" fn posix_spawnattr_setflags(attr: *Attr, flags: Flags) c_int;
extern "c" fn posix_spawnattr_setpgroup(attr: *Attr, pgroup: posix.pid_t) c_int;
extern "c" fn posix_spawnattr_setsigdefault(attr: *Attr, sigdefault: *const posix.sigset_t) c_int;
extern "c" fn posix_spawnattr_setsigmask(attr: *Attr, sigmask: *const posix.sigset_t) c_int;

extern "c" fn posix_spawn_file_actions_init(actions: *FileActions) c_int;
extern "c" fn posix_spawn_file_actions_destroy(actions: *FileActions) c_int;
extern "c" fn posix_spawn_file_actions_adddup2(
    actions: *FileActions,
    filedes: posix.fd_t,
    newfiledes: posix.fd_t,
) c_int;

extern "c" fn posix_spawn(
    pid: *posix.pid_t,
    path: [*:0]const u8,
    file_actions: ?*const FileActions,
    attrp: ?*const Attr,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) c_int;
