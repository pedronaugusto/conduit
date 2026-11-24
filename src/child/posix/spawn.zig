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
//! * `cwd` on Linux, because glibc's file action for it arrived late and has
//!   a history of not working. Darwin's `posix_spawn_file_actions_addchdir_np`
//!   (macOS 10.15) is the file action used there;
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
//! * on Linux, a C library without `posix_spawn_file_actions_addclosefrom_np`
//!   (glibc before 2.34, and musl): see the next section.
//!
//! Everything else — pipes, the null device, inherited streams, `stderr_to`,
//! an environment, a search path, `detach` — is expressible, and the child
//! this path produces is the same child in every way a caller can observe.
//!
//! # The descriptors a child gets
//!
//! Its three standard streams and `extra_fds`, and nothing else of this
//! process's, whatever a descriptor's close-on-exec flag says. A flag cannot
//! be trusted to be there: Darwin has no `SOCK_CLOEXEC`, `accept4` or
//! `pipe2`, so a socket or pipe opened there by anyone in the program, the
//! standard library included, has no flag between the call that makes it and
//! the `fcntl` that marks it, and a child started in that moment would keep
//! it — and keep its far end waiting for a close that never comes. So the
//! child is told which descriptors it gets rather than which it does not:
//! `POSIX_SPAWN_CLOEXEC_DEFAULT` on Darwin, which closes every descriptor no
//! file action names, with `posix_spawn_file_actions_addinherit_np` for an
//! inherited standard stream; `posix_spawn_file_actions_addclosefrom_np`
//! above the extras with glibc 2.34 and later. The fork path does the same by
//! its own means (`Replacement` on Darwin, `close_range` on Linux).
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
const exit = @import("../../exit.zig");
const reactor = @import("reactor");
const options_for_build = @import("conduit_options");
const aegis = @import("aegis");

const SpawnError = Child.SpawnError;
const SpawnOptions = Child.SpawnOptions;

const is_darwin = builtin.target.os.tag.isDarwin();

/// What the tests set to send a spawn down the fork path that would otherwise
/// take this one.
pub const testing_hook = if (builtin.is_test) struct {
    pub var fork: std.atomic.Value(bool) = .init(false);
} else struct {};

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

/// Whether a file action closes every descriptor from a number up: glibc 2.34
/// and later, `posix_spawn_file_actions_addclosefrom_np`. Darwin says the same
/// with `POSIX_SPAWN_CLOEXEC_DEFAULT`; a Linux C library without it sends
/// every spawn to the fork, which closes them with `close_range`.
pub const close_from_action = available and builtin.target.os.tag == .linux and builtin.target.abi.isGnu() and
    builtin.target.os.version_range.linux.glibc.order(.{ .major = 2, .minor = 34, .patch = 0 }) != .lt;

/// Whether a file action changes the child's working directory where it can
/// be trusted: Darwin's `posix_spawn_file_actions_addchdir_np`.
pub const chdir_action = available and is_darwin;

/// Whether the options ask for anything that has to happen between a fork and
/// an exec.
///
/// The descriptors are the other half of the question and are asked about in
/// `spawn`, which has the plan.
pub fn suits(options: SpawnOptions) bool {
    if (!available) return false;
    if (builtin.is_test and testing_hook.fork.load(.monotonic)) return false;
    if (builtin.target.os.tag == .linux and !close_from_action) return false;
    if (builtin.target.os.tag == .linux and options.descendants == .contain) return false;
    if (tree.Forks.supported and options.descendants == .contain) return false;
    // A terminal of the child's own session only where opening it makes it
    // the controlling one; an attached child is handed the terminal as it
    // is handed any stream.
    if (options.stdio == .pty and options.detach and !session_terminal) return false;
    if (options.cwd != null and !chdir_action) return false;
    if (options.credentials.any()) return false;
    if (options.resource_limits.len != 0) return false;
    // set between the fork and the exec, which file actions cannot say
    if (options.parent_death_signal != null) return false;
    return true;
}

/// Whether a detached child on a pseudo-terminal can start here: a session
/// of its own, and its terminal made the controlling one by opening it.
/// Linux, where the libc has `POSIX_SPAWN_SETSID` and the kernel gives the
/// first terminal a session leader opens to its session.
pub const session_terminal = builtin.target.os.tag == .linux;

/// A child `spawn` started, and the watches on it: on its forks and on its end.
pub const Started = struct {
    pid: posix.pid_t,
    forks: tree.Forks,
    exit_watch: ?reactor.Process,
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
    io: std.Io,
    plan: [3]PlanTarget,
    extras: []const posix.fd_t,
    candidates: []const [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: ?[*:0]const u8,
    options: SpawnOptions,
    into: ?posix.fd_t,
) SpawnError!?Started {
    aegis.assert.invariant(cwd == null or chdir_action, "cwd == null or chdir_action");
    aegis.assert.invariant(into == null or into_cgroup, "into == null or into_cgroup");
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
        // ttyname_r(3) writes the terminal's name, NUL-terminated, where it answers 0
        if (ttyname_r(slave, &terminal_name, terminal_name.len) != 0) return null;
    }

    for (plan, 0..) |target, slot| switch (target) {
        .inherit => {},
        // See the file comment: neither of these two is expressible here in a
        // way that means the same thing on both systems.
        .close => return null,
        // The actions run in order, so standard output is in place by now.
        .stdout => if (posix_spawn_file_actions_adddup2(&actions, posix.STDOUT_FILENO, @intCast(slot)) != 0) {
            return error.SystemResources;
        },
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
    // Nothing else of this process's: see "The descriptors a child gets".
    // Darwin closes every descriptor no action names, so an inherited
    // standard stream is named; one this process does not have open is left
    // out, and the child does not have it either, as a fork child would not.
    if (comptime is_darwin) {
        for (plan, 0..) |target, slot| if (target == .inherit and isOpen(@intCast(slot))) {
            if (posix_spawn_file_actions_addinherit_np(&actions, @intCast(slot)) != 0) return error.SystemResources;
        };
        if (cwd) |dir| if (posix_spawn_file_actions_addchdir_np(&actions, dir) != 0) return error.SystemResources;
    }
    if (comptime close_from_action) {
        if (posix_spawn_file_actions_addclosefrom_np(&actions, @intCast(3 + extras.len)) != 0) return error.SystemResources;
    }

    var attr: Attr = undefined;
    if (posix_spawnattr_init(&attr) != 0) return error.SystemResources;
    defer _ = posix_spawnattr_destroy(&attr);

    try describe(&attr, options, session, into);

    // Every candidate in turn, and the error worth reporting is the one from
    // the last attempt that got past "no such file" -- the same rule the fork
    // child follows, for the same reason. A candidate that is not there is
    // passed over without a spawn: a `posix_spawn` that fails is a child made
    // and ended, where the fork child's `execve` that fails costs a system
    // call, and a search path names many directories without the program.
    var best: posix.E = .NOENT;
    for (candidates) |candidate| {
        // A relative candidate is looked for in the child's working
        // directory, which the file actions change: left to `posix_spawn`.
        if ((cwd == null or candidate[0] == '/') and absent(candidate)) continue;
        var pid: posix.pid_t = undefined;
        const rc = posix_spawn(&pid, candidate, &actions, &attr, argv, envp);
        if (rc == 0) {
            const spawned = try started(io, pid);
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
    // A working directory the file action could not enter fails the spawn
    // as a missing program does, where the fork child reports its own stage:
    // told apart by whether it is a directory this process can enter.
    if (cwd) |dir| if (chdirError(dir)) |err| return err;
    return spawnError(best);
}

/// The attributes of the child `spawn` starts: its group or session, its
/// cgroup, the descriptors it keeps, and its signals.
fn describe(attr: *Attr, options: SpawnOptions, session: bool, into: ?posix.fd_t) SpawnError!void {
    var flags: Flags = .{ .setsigdef = true, .setsigmask = true, .cloexec_default = is_darwin };
    flags.set(.start_suspended, tree.Forks.supported);
    if (session) {
        // A session is a group as well, whose leader is the child: asking
        // for a group besides would fail, a leader cannot change its group.
        flags.set(.setsid, true);
    } else if (options.detach) {
        flags.setpgroup = true;
        // Zero is "a new group whose leader is the child", which is what
        // `setpgid(0, 0)` says in the fork child.
        if (posix_spawnattr_setpgroup(attr, 0) != 0) return error.Unexpected;
    }
    if (comptime into_cgroup) if (into) |cgroup| {
        flags.setcgroup = true;
        if (posix_spawnattr_setcgroup_np(attr, cgroup) != 0) return error.Unexpected;
    };
    if (posix_spawnattr_setflags(attr, flags) != 0) return error.Unexpected;

    // The same clean slate the fork child is given, said as two attributes.
    // Every signal back at its default action rather than only the ignored
    // ones, which comes to the same thing: `execve` resets a signal the parent
    // had a handler for, and leaves an ignored one ignored. The two that
    // cannot be caught cannot be reset either.
    var defaults = posix.sigfillset();
    posix.sigdelset(&defaults, .KILL);
    posix.sigdelset(&defaults, .STOP);
    if (posix_spawnattr_setsigdefault(attr, &defaults) != 0) return error.Unexpected;
    const unblocked = posix.sigemptyset();
    if (posix_spawnattr_setsigmask(attr, &unblocked) != 0) return error.Unexpected;
}

/// What the fork child's `chdir` into `path` would have failed with, as the
/// fork path reports it, or `null` where it would have gone in. Asked after a
/// `posix_spawn` with a working directory failed, which reports a directory
/// it could not enter as it reports a program it could not find.
fn chdirError(path: [*:0]const u8) ?SpawnError {
    if (c.access(path, posix.X_OK) == 0) {
        // There and searchable: a directory, or a file `chdir` refuses.
        var probe: [std.Io.Dir.max_path_bytes:0]u8 = undefined;
        const name = std.mem.span(path);
        if (name.len + 2 >= probe.len) return error.NameTooLong;
        @memcpy(probe[0..name.len], name);
        probe[name.len] = '/';
        probe[name.len + 1] = '.';
        probe[name.len + 2] = 0;
        if (c.access(probe[0 .. name.len + 2 :0], posix.F_OK) == 0) return null;
        return error.BadWorkingDirectory;
    }
    return switch (c.errno(@as(c_int, -1))) {
        .ACCES => error.AccessDenied,
        .NOENT, .NOTDIR => error.BadWorkingDirectory,
        .NAMETOOLONG => error.NameTooLong,
        .LOOP => error.SymLinkLoop,
        else => null,
    };
}

/// Whether this process has a descriptor open at `fd`.
fn isOpen(fd: posix.fd_t) bool {
    return c.fcntl(fd, c.F.GETFD) != -1;
}

/// What the fork child on Darwin becomes the program with, in place of
/// `execve`: `posix_spawn` with `POSIX_SPAWN_SETEXEC`, which replaces the
/// calling process as `execve` does, and `POSIX_SPAWN_CLOEXEC_DEFAULT`, which
/// closes every descriptor no file action names. The child is handed the
/// descriptors it was meant to have and no others, with no loop over every
/// number a process may hold, which on Darwin can be millions.
///
/// Made in the parent, before the fork: the attribute and the actions are
/// allocated by the C library, which a fork child of a threaded process may
/// not do. The child only reads them.
pub const Replacement = struct {
    actions: FileActions,
    attr: Attr,

    /// Whether the fork child replaces itself this way: Darwin.
    pub const used = is_darwin;

    /// The descriptors the child keeps: each of its first three that `plan`
    /// gives it -- an inherited one only where this process has it open --
    /// and `extras` more from 3 up. The fork child has put them there by the
    /// time it calls `exec`.
    pub fn init(r: *Replacement, plan: [3]PlanTarget, extras: usize) SpawnError!void {
        if (comptime !used) @compileError("Replacement is Darwin's");
        if (posix_spawn_file_actions_init(&r.actions) != 0) return error.SystemResources;
        errdefer _ = posix_spawn_file_actions_destroy(&r.actions);
        for (plan, 0..) |target, slot| {
            const kept = switch (target) {
                .inherit => isOpen(@intCast(slot)),
                .close => false,
                .place, .stdout => true,
            };
            if (kept and posix_spawn_file_actions_addinherit_np(&r.actions, @intCast(slot)) != 0) return error.SystemResources;
        }
        for (3..3 + extras) |slot| {
            if (posix_spawn_file_actions_addinherit_np(&r.actions, @intCast(slot)) != 0) return error.SystemResources;
        }
        if (posix_spawnattr_init(&r.attr) != 0) return error.SystemResources;
        errdefer _ = posix_spawnattr_destroy(&r.attr);
        // The fork child has already put its signals where a new program
        // starts; these flags leave them as they are.
        if (posix_spawnattr_setflags(&r.attr, .{ .setexec = true, .cloexec_default = true }) != 0) return error.Unexpected;
    }

    pub fn deinit(r: *Replacement) void {
        _ = posix_spawnattr_destroy(&r.attr);
        _ = posix_spawn_file_actions_destroy(&r.actions);
        r.* = undefined;
    }

    /// In the fork child: becomes the program at `path`, and returns only
    /// with why it could not.
    pub fn exec(
        r: *const Replacement,
        path: [*:0]const u8,
        argv: [*:null]const ?[*:0]const u8,
        envp: [*:null]const ?[*:0]const u8,
    ) posix.E {
        var pid: posix.pid_t = undefined;
        const rc = posix_spawn(&pid, path, &r.actions, &r.attr, argv, envp);
        aegis.assert.invariant(rc != 0, "rc != 0");
        return @fromBackingInt(@intCast(rc));
    }
};

/// Whether nothing is at `path` for an `execve` to find: what it would
/// fail with as "no such file", asked without starting a child. Anything
/// else, a file that cannot be run included, is left to `posix_spawn` to
/// report.
fn absent(path: [*:0]const u8) bool {
    if (c.access(path, posix.F_OK) == 0) return false;
    return switch (c.errno(@as(c_int, -1))) {
        .NOENT, .NOTDIR => true,
        else => false,
    };
}

/// The watches on a child started suspended, and the child resumed.
fn started(io: std.Io, pid: posix.pid_t) SpawnError!Started {
    var exit_watch = exit.open(io, pid);
    if (!tree.Forks.supported) return .{ .pid = pid, .forks = .none, .exit_watch = exit_watch };
    var forks: tree.Forks = .watch(pid);
    if (c.kill(pid, .CONT) != 0) {
        // Nothing but a stopped child of this process, unreaped, is there to
        // refuse this. A child that cannot be resumed is not one to hand back.
        const err = c.errno(@as(c_int, -1));
        forks.close();
        if (exit_watch) |*watch| watch.close(io);
        _ = c.kill(pid, .KILL);
        var status: c_int = undefined;
        while (c.waitpid(pid, &status, 0) < 0 and c.errno(@as(c_int, -1)) == .INTR) {}
        return posix.unexpectedErrno(err);
    }
    return .{ .pid = pid, .forks = forks, .exit_watch = exit_watch };
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
    _unused: u2 = 0,
    /// `POSIX_SPAWN_SETEXEC`, Darwin's: the calling process becomes the
    /// program, as `execve` makes it. glibc's bit here is `USEVFORK`, which it
    /// ignores; it is set only on Darwin.
    setexec: bool = false,
    /// `POSIX_SPAWN_START_SUSPENDED` on Darwin and `POSIX_SPAWN_SETSID` in
    /// glibc and musl, which number the one bit each their own way: read
    /// through `start_suspended` and `setsid`, each set only on its system.
    bit7: bool = false,
    /// `POSIX_SPAWN_SETCGROUP`, glibc 2.39.
    setcgroup: bool = false,
    _rest: u5 = 0,
    /// `POSIX_SPAWN_CLOEXEC_DEFAULT`, Darwin's: every descriptor no file
    /// action names is closed in the child. Set only on Darwin.
    cloexec_default: bool = false,
    _last: u1 = 0,

    fn set(f: *Flags, comptime field: enum { start_suspended, setsid }, on: bool) void {
        const here = switch (field) {
            .start_suspended => builtin.target.os.tag != .linux,
            .setsid => builtin.target.os.tag == .linux,
        };
        if (on) aegis.assert.invariant(here, "here");
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
/// Darwin; referenced only there.
extern "c" fn posix_spawn_file_actions_addinherit_np(actions: *FileActions, filedes: posix.fd_t) c_int;
/// Darwin, macOS 10.15; referenced only there.
extern "c" fn posix_spawn_file_actions_addchdir_np(actions: *FileActions, path: [*:0]const u8) c_int;
/// glibc 2.34; referenced only where `close_from_action` holds.
extern "c" fn posix_spawn_file_actions_addclosefrom_np(actions: *FileActions, from: posix.fd_t) c_int;

extern "c" fn posix_spawn(
    pid: *posix.pid_t,
    path: [*:0]const u8,
    file_actions: ?*const FileActions,
    attrp: ?*const Attr,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) c_int;
