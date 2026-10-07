//! Starting a child with `posix_spawn`, for the spawns that need nothing done
//! between the fork and the exec.
//!
//! `fork` copies a process's page tables, and the cost of that grows with how
//! much memory the parent has mapped. `posix_spawn` does not: the systems here
//! implement it with `vfork` or with a kernel call of their own, and the child
//! is described by a list of file actions and a set of attributes rather than
//! by code running in it.
//!
//! # What it cannot do
//!
//! The general path exists because there are things only code between a fork
//! and an exec can do, and every one of them sends a spawn back to it:
//!
//! * a pseudo-terminal on Darwin and the BSDs, which needs `setsid` and then
//!   `TIOCSCTTY`: there is no file action for an ioctl, and a BSD kernel
//!   gives a session its controlling terminal only when that ioctl asks. On
//!   Linux the child is started in a session of its own
//!   (`POSIX_SPAWN_SETSID`, glibc 2.26 and musl) and opens its terminal by
//!   name, without `O_NOCTTY`: glibc and musl both make the session before
//!   the file actions run, and Linux gives a session leader with no
//!   controlling terminal the first terminal it opens;
//! * `credentials` and `resource_limits`, which a process sets on itself;
//! * `cwd`, because the file action for it is `_np` on both systems, arrived
//!   late on each, and has a history of not working;
//! * `Stream.close`, because a file action that closes a descriptor the parent
//!   does not have is a failed spawn on some systems and a no-op on others,
//!   and this package promises the second;
//! * a caller's file at descriptor 0, 1 or 2, because `adddup2` of a
//!   descriptor onto itself is specified to clear close-on-exec and is not
//!   implemented that way everywhere;
//! * an `extra_fds` file whose number is below the last one the extras are
//!   placed at: the same `adddup2` onto itself, or a file the actions before
//!   it would already have written over, which the fork child moves out of
//!   the way first and a file action cannot.
//!
//! Everything else — pipes, the null device, inherited streams, `stderr_to`,
//! an environment, a search path, `detach` — is expressible, and the child
//! this path produces is the same child in every way a caller can observe.
//!
//! # A cgroup of the child's own
//!
//! On Linux a child that gets a cgroup is born in it where the C library can
//! say so: glibc 2.39 and later take the cgroup as an attribute
//! (`posix_spawnattr_setcgroup_np`) and start the child with `clone3`'s
//! `CLONE_INTO_CGROUP` (Linux 5.7). That is no fork, and no move of a running
//! process between cgroups, which takes a lock every fork on the system
//! waits for. With musl or an older glibc there is no attribute, and the
//! child is forked and joins its cgroup with a write; so it is too where the
//! kernel refuses the cgroup, which this path answers with `null`.
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

const Child = @import("../contract.zig");
const tree = @import("../../tree.zig");
const options_for_build = @import("conduit_options");

const SpawnError = Child.SpawnError;
const SpawnOptions = Child.SpawnOptions;

/// Whether this system has the `posix_spawn` interface this file uses, with
/// the attribute flags spelled the way it spells them.
pub const available = !options_for_build.force_fork_spawn and switch (builtin.target.os.tag) {
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

/// Whether `spawn` can start a child in a cgroup: glibc 2.39 and later, which
/// have `posix_spawnattr_setcgroup_np`. Decided by the target the program is
/// built for, whose glibc version is the oldest it runs on.
pub const into_cgroup = available and builtin.target.os.tag == .linux and builtin.target.abi.isGnu() and
    builtin.target.os.version_range.linux.glibc.order(.{ .major = 2, .minor = 39, .patch = 0 }) != .lt;

/// Whether the options ask for anything that has to happen between a fork and
/// an exec.
///
/// The descriptors are the other half of the question and are asked about in
/// `spawn`, which has the plan.
pub fn suits(options: SpawnOptions) bool {
    if (!available) return false;
    if (builtin.target.os.tag == .linux and options.descendants == .contain) return false;
    if (tree.Forks.supported and options.descendants == .contain) return false;
    // A terminal of the child's own session only where opening it makes it
    // the controlling one; an attached child is handed the terminal as it
    // is handed any stream.
    if (options.stdio == .pty and options.detach and !session_terminal) return false;
    if (options.cwd != null) return false;
    if (options.credentials.any()) return false;
    if (options.resource_limits.len != 0) return false;
    if (options.fd_policy != .close_on_exec) return false;
    // set between the fork and the exec, which file actions cannot say
    if (options.parent_death_signal != null) return false;
    return true;
}

/// Whether a detached child on a pseudo-terminal can start here: a session
/// of its own, and its terminal made the controlling one by opening it.
/// Linux, where the libc has `POSIX_SPAWN_SETSID` and the kernel gives the
/// first terminal a session leader opens to its session.
pub const session_terminal = builtin.target.os.tag == .linux;

/// A child `spawn` started, and the watch on its forks.
pub const Started = struct {
    pid: posix.pid_t,
    forks: tree.Forks,
};

/// Starts the child, or returns `null` if the descriptors it was given cannot
/// be described as file actions.
///
/// `null` is not a failure: the caller starts the same child through `fork`
/// and `execve` instead, and nothing the child sees is different.
///
/// With `into`, a cgroup directory and only where `into_cgroup` holds, the
/// child is born in that cgroup. Any failure but a program not found is then
/// `null` too: `posix_spawn` reports a kernel that refuses the cgroup and a
/// program that cannot run alike, and the fork, which joins the cgroup
/// with a write of its own, tells the two apart.
///
/// Where `tree.Forks` has a watch (Darwin), the child is started suspended,
/// with `POSIX_SPAWN_START_SUSPENDED`, the watch is registered, and only then
/// is it resumed with `SIGCONT`: so the watch is in before the program runs
/// its first instruction, and no fork it makes goes unnoted. The kernel stops
/// the task before it returns to user space for the first time, and the
/// `SIGCONT` that resumes it is discarded at its default action — every
/// signal is at its default in the child — and sends the parent no
/// `SIGCHLD`.
pub fn spawn(
    plan: [3]PlanTarget,
    extras: []const posix.fd_t,
    candidates: []const [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    options: SpawnOptions,
    into: ?posix.fd_t,
) SpawnError!?Started {
    std.debug.assert(into == null or into_cgroup);
    var actions: FileActions = undefined;
    if (posix_spawn_file_actions_init(&actions) != 0) return error.SystemResources;
    defer _ = posix_spawn_file_actions_destroy(&actions);

    // A detached child on a terminal opens it by name, in the session made
    // for it, so that the terminal is its controlling one; the other
    // standard streams that are the terminal are copies of that one.
    const session = options.stdio == .pty and options.detach;
    var terminal_name: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
    var terminal_slot: ?posix.fd_t = null;
    if (session) {
        const slave = options.stdio.pty.slaveHandle().?;
        if (ttyname_r(slave, &terminal_name, terminal_name.len) != 0) return null;
    }

    for (plan, 0..) |target, slot| switch (target) {
        .inherit => {},
        // See the file comment: neither of these two is expressible here in a
        // way that means the same thing on both systems.
        .close => return null,
        .place => |fd| {
            if (session and fd == options.stdio.pty.slaveHandle().?) {
                if (terminal_slot) |first| {
                    if (posix_spawn_file_actions_adddup2(&actions, first, @intCast(slot)) != 0) return error.SystemResources;
                } else {
                    const name: [*:0]const u8 = &terminal_name;
                    if (posix_spawn_file_actions_addopen(&actions, @intCast(slot), name, .{ .ACCMODE = .RDWR }, 0) != 0) return error.SystemResources;
                    terminal_slot = @intCast(slot);
                }
                continue;
            }
            if (fd < 3) return null;
            if (posix_spawn_file_actions_adddup2(&actions, fd, @intCast(slot)) != 0) {
                return error.SystemResources;
            }
        },
    };
    // After the standard three, which read their sources before anything
    // here is written: a source above every extra slot is still itself when
    // its turn comes.
    for (extras, 3..) |fd, slot| {
        if (fd < 3 + extras.len) return null;
        if (posix_spawn_file_actions_adddup2(&actions, fd, @intCast(slot)) != 0) return error.SystemResources;
    }

    var attr: Attr = undefined;
    if (posix_spawnattr_init(&attr) != 0) return error.SystemResources;
    defer _ = posix_spawnattr_destroy(&attr);

    var flags: Flags = .{ .setsigdef = true, .setsigmask = true };
    flags.set(.start_suspended, tree.Forks.supported);
    if (session) {
        // A session is a group as well, whose leader is the child: asking
        // for a group besides would fail, a leader cannot change its group.
        flags.set(.setsid, true);
    } else if (options.detach) {
        flags.setpgroup = true;
        // Zero is "a new group whose leader is the child", which is what
        // `setpgid(0, 0)` says in the fork child.
        if (posix_spawnattr_setpgroup(&attr, 0) != 0) return error.Unexpected;
    }
    if (comptime into_cgroup) if (into) |cgroup| {
        flags.setcgroup = true;
        if (posix_spawnattr_setcgroup_np(&attr, cgroup) != 0) return error.Unexpected;
    };
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
        if (rc == 0) {
            const spawned = try started(pid);
            return spawned;
        }
        switch (@as(posix.E, @fromBackingInt(@intCast(rc)))) {
            .NOENT, .NOTDIR => {},
            else => |err| {
                if (into != null) return null;
                best = err;
            },
        }
    }
    return spawnError(best);
}

/// The watch on a child started suspended, and the child resumed.
fn started(pid: posix.pid_t) SpawnError!Started {
    if (!tree.Forks.supported) return .{ .pid = pid, .forks = .none };
    var forks: tree.Forks = .watch(pid);
    if (c.kill(pid, .CONT) != 0) {
        // Nothing but a stopped child of this process, unreaped, is there to
        // refuse this. A child that cannot be resumed is not one to hand back.
        const err = c.errno(@as(c_int, -1));
        forks.close();
        _ = c.kill(pid, .KILL);
        var status: c_int = undefined;
        while (c.waitpid(pid, &status, 0) < 0 and c.errno(@as(c_int, -1)) == .INTR) {}
        return posix.unexpectedErrno(err);
    }
    return .{ .pid = pid, .forks = forks };
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
pub const PlanTarget = @import("../stdio_plan.zig").Target;

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

/// The attribute flags this file sets. The first four Linux and Darwin number
/// the same way; the BSDs do not, and `available` is false there.
/// `setcgroup` is glibc's alone, and set only where `into_cgroup` holds.
const Flags = packed struct(c_short) {
    resetids: bool = false,
    setpgroup: bool = false,
    setsigdef: bool = false,
    setsigmask: bool = false,
    _unused: u3 = 0,
    /// `POSIX_SPAWN_START_SUSPENDED` on Darwin and `POSIX_SPAWN_SETSID` in
    /// glibc and musl, which number the one bit each their own way: read
    /// through `start_suspended` and `setsid`, each set only on its system.
    bit7: bool = false,
    /// `POSIX_SPAWN_SETCGROUP`, glibc 2.39.
    setcgroup: bool = false,
    _rest: u7 = 0,

    fn set(f: *Flags, comptime field: enum { start_suspended, setsid }, on: bool) void {
        const here = switch (field) {
            .start_suspended => builtin.target.os.tag != .linux,
            .setsid => builtin.target.os.tag == .linux,
        };
        if (on) std.debug.assert(here);
        if (here and on) f.bit7 = true;
    }
};

extern "c" fn posix_spawnattr_init(attr: *Attr) c_int;
extern "c" fn posix_spawnattr_destroy(attr: *Attr) c_int;
extern "c" fn posix_spawnattr_setflags(attr: *Attr, flags: Flags) c_int;
extern "c" fn posix_spawnattr_setpgroup(attr: *Attr, pgroup: posix.pid_t) c_int;
extern "c" fn posix_spawnattr_setsigdefault(attr: *Attr, sigdefault: *const posix.sigset_t) c_int;
extern "c" fn posix_spawnattr_setsigmask(attr: *Attr, sigmask: *const posix.sigset_t) c_int;
/// glibc 2.39; referenced only where `into_cgroup` holds, so a program built
/// for an older glibc never links it.
extern "c" fn posix_spawnattr_setcgroup_np(attr: *Attr, cgroup: c_int) c_int;

extern "c" fn posix_spawn_file_actions_init(actions: *FileActions) c_int;
extern "c" fn posix_spawn_file_actions_destroy(actions: *FileActions) c_int;
extern "c" fn posix_spawn_file_actions_addopen(
    actions: *FileActions,
    filedes: posix.fd_t,
    path: [*:0]const u8,
    oflag: posix.O,
    mode: posix.mode_t,
) c_int;
extern "c" fn ttyname_r(fd: posix.fd_t, buf: [*]u8, len: usize) c_int;
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
