//! Starting a child process on POSIX: `fork`, the small amount of work that
//! has to happen in the child before `execve`, and the pipe the child reports
//! a failure back over.
//!
//! The public contract lives on `Child.spawn`; this file is the half of it
//! that only exists here.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;
const Allocator = std.mem.Allocator;

const Child = @import("Child.zig").Child;
const State = @import("child_state.zig");
const handles = @import("handles.zig");
const posix_spawn = @import("posix_spawn.zig");
const stdio_plan = @import("stdio_plan.zig");
const tty = @import("conduit.tty");
const tree = @import("tree.zig");
const cgroup = @import("cgroup.zig");
const Orphans = @import("Orphans.zig").Orphans;
const supervisor = if (builtin.os.tag == .linux) @import("supervisor.zig") else struct {};

const file = handles.file;

const SpawnError = Child.SpawnError;
const SpawnOptions = Child.SpawnOptions;

/// The descriptors a spawn involves. `stdio_plan` holds the policy; what is
/// here is the two calls that open a descriptor on this system.
const Plan = stdio_plan.Plan(struct {
    pub const Error = SpawnError;
    pub const openNull = openNullDevice;

    pub fn openPipe(child_reads: bool) SpawnError!stdio_plan.Pipe {
        const ends = try makePipe();
        return if (child_reads)
            .{ .child = ends[0], .parent = ends[1] }
        else
            .{ .child = ends[1], .parent = ends[0] };
    }
});

/// See `Child.spawn`.
pub fn spawn(io: std.Io, allocator: Allocator, options: SpawnOptions, state: *State) SpawnError!Child {
    // Everything the fork child needs is built here, in the parent: between
    // `fork` and `execve` only async-signal-safe calls are allowed, which rules
    // out allocating.
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = try arena.allocSentinel(?[*:0]const u8, options.argv.len, null);
    for (options.argv, argv[0..options.argv.len]) |arg, *slot| {
        slot.* = (try arena.dupeZ(u8, arg)).ptr;
    }

    const envp: [*:null]const ?[*:0]const u8 = if (options.environ) |map| envp: {
        const block = try map.createPosixBlock(arena, .{});
        break :envp block.slice.ptr;
    } else c.environ;

    const path_value: ?[]const u8 = switch (options.path_search) {
        .child_environ => if (options.environ) |map| map.get("PATH") else environPath(),
        .parent_environ => environPath(),
        .none => null,
    };
    const candidates = try searchPath(
        arena,
        options.argv[0],
        path_value,
        options.path_search != .none,
    );

    const cwd_z: ?[*:0]const u8 = if (options.cwd) |dir| (try arena.dupeZ(u8, dir)).ptr else null;

    // The descriptors the child will have as 0, 1 and 2, and the ones the
    // parent keeps. `plan` opens nothing the caller owns.
    var plan: Plan = try .init(io, options, switch (options.stdio) {
        .pty => |pty| pty.slaveHandle().?,
        else => null,
    });
    errdefer plan.closeAll(io);

    // A cgroup of the child's own, where this process may make one: the
    // fork child joins it before it does anything else, so nothing it ever
    // starts is outside it. `null` elsewhere, and on every system but Linux.
    var contained: ?cgroup.Pending = cgroup.Cgroup.prepare();
    errdefer if (contained) |*pending| pending.abandon();

    // Held from before the child exists until it is on the list of children
    // that are conduit's own, so that where `Orphans` runs, its look never
    // takes a child started here for one it adopted; and a look after, since
    // a spawn is one of the moments it has. Nothing where it does not run.
    var adoption: Orphans.Spawn = .begin();
    defer adoption.finish();

    // Nothing has to happen between a fork and an exec for this one, so it
    // need not be a fork at all. `posix_spawn` describes the child with file
    // actions instead, without copying the parent's page tables. It answers
    // `null` for a set of descriptors it cannot
    // describe, and then this falls through to the fork below. A contained
    // child is always forked: joining its cgroup is a write, and there is no
    // file action for one.
    if (contained == null and posix_spawn.suits(options)) {
        const started_child = child: {
            handles.ForkGap.startingAChild();
            defer handles.ForkGap.release();
            break :child try posix_spawn.spawn(plan.child, candidates, argv.ptr, envp, options);
        };
        if (started_child) |child| {
            adoption.started(child.pid) catch |err| {
                var forks = child.forks;
                forks.close();
                discard(child.pid);
                return err;
            };
            adoption.finish();
            plan.closeChildSide(io);
            return started(state, child.pid, child.forks, .none, &plan, options);
        }
    }

    // How the fork child reports a failure that happens after the fork. The
    // write end is close-on-exec, so a successful `execve` closes it and the
    // parent's read below returns end of file instead of a record.
    const supervised = builtin.os.tag == .linux and options.descendants == .contain;
    var channel_ends: ?[2]posix.fd_t = if (supervised) try supervisor.channel() else null;
    errdefer if (channel_ends) |ends| {
        _ = c.close(ends[0]);
        _ = c.close(ends[1]);
    };
    const scope_kill: ?posix.fd_t = if (supervised) if (contained) |pending| cgroup.supervisorKillDescriptor(pending) else null else null;
    defer if (scope_kill) |fd| {
        _ = c.close(fd);
    };
    const report = try controlPipe();
    // Where there is a watch on the child's forks (`tree.Forks`), the fork
    // child waits on this before its `execve` until the parent has registered
    // it, so the program the child becomes cannot fork before the watch is
    // in. Without a pipe there is no watch, and `kill` walks as it always
    // did.
    const go: ?[2]posix.fd_t = if (tree.Forks.supported or supervised) controlPipe() catch |err| failed: {
        if (options.descendants == .contain) {
            file(report[0]).close(io);
            file(report[1]).close(io);
            return err;
        }
        break :failed null;
    } else null;
    // Who the child's parent is before the fork: the child compares it with
    // its own parent once its death signal is set, to catch a parent that
    // was gone before it.
    const parent = c.getpid();

    handles.ForkGap.startingAChild();
    if (builtin.is_test) @import("test_support.zig").SpawnCalls.forks += 1;
    const pid = c.fork();
    if (pid == 0) {
        var root_parent = parent;
        if (comptime builtin.os.tag == .linux) if (channel_ends) |ends| {
            _ = c.close(ends[0]);
            clearSignals();
            const prepared = switch (supervisor.prepare()) {
                .ready => |prepared| prepared,
                .failed => |errno| {
                    const record: Failure = .{ .stage = .supervisor, .errno = @intFromEnum(errno) };
                    _ = c.write(report[1], std.mem.asBytes(&record), @sizeOf(Failure));
                    c._exit(127);
                },
            };
            root_parent = c.getpid();
            const root = c.fork();
            if (root < 0) bail(report[1], .supervisor);
            if (root != 0) {
                const root_record: Failure = .{ .stage = .supervisor_root, .errno = @intCast(root) };
                _ = c.write(report[1], std.mem.asBytes(&root_record), @sizeOf(Failure));
                supervisor.run(root, ends[1], options.detach, prepared, scope_kill);
            }
            _ = c.close(ends[1]);
            _ = c.close(prepared.signals);
            _ = c.close(prepared.children);
            if (scope_kill) |fd| _ = c.close(fd);
        };
        // The child inherits the lock as held, and the only thing it does with
        // it is not touch it: it runs a handful of system calls and execs.
        const join: posix.fd_t = if (contained) |pending| pending.joinDescriptor() else -1;
        childMain(options, plan, candidates, argv.ptr, envp, cwd_z, report[1], root_parent, go, join);
    }
    handles.ForkGap.release();

    if (pid < 0) {
        file(report[0]).close(io);
        file(report[1]).close(io);
        if (go) |ends| {
            file(ends[0]).close(io);
            file(ends[1]).close(io);
        }
        switch (c.errno(@as(c_int, -1))) {
            .AGAIN => return error.ResourceLimitReached,
            .NOMEM => return error.SystemResources,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
    adoption.started(pid) catch |err| {
        discard(pid);
        file(report[0]).close(io);
        file(report[1]).close(io);
        if (go) |ends| {
            file(ends[0]).close(io);
            file(ends[1]).close(io);
        }
        return err;
    };
    adoption.finish();
    if (channel_ends) |*ends| {
        _ = c.close(ends[1]);
        ends[1] = -1;
    }
    file(report[1]).close(io);
    plan.closeChildSide(io);

    // The watch, then the word to go on. This end of the pipe's reading side
    // is still open while the byte is written, so the write cannot meet a
    // pipe with no reader however the child has fared.
    var lineage: ?*@import("lineage.zig").Tracker = null;
    if (comptime @import("lineage.zig").supported) if (options.descendants == .contain) {
        lineage = @import("lineage.zig").Tracker.start(pid) catch |err| {
            discard(pid);
            file(report[0]).close(io);
            if (go) |ends| {
                file(ends[0]).close(io);
                file(ends[1]).close(io);
            }
            return err;
        };
    };
    errdefer if (lineage) |tracker| tracker.deinit();
    const scope_record: ?Child.SupervisorRecord = if (supervised) .{
        .pid = pid,
        .start = (tree.startTime(pid) catch null) orelse {
            discard(pid);
            file(report[0]).close(io);
            if (go) |ends| {
                file(ends[0]).close(io);
                file(ends[1]).close(io);
            }
            return error.Unexpected;
        },
        .boot = cgroup.bootIdentity() orelse {
            discard(pid);
            file(report[0]).close(io);
            if (go) |ends| {
                file(ends[0]).close(io);
                file(ends[1]).close(io);
            }
            return error.Unexpected;
        },
    } else null;
    var forks: tree.Forks = .none;
    if (go) |ends| {
        forks = .watch(pid);
        while (c.write(ends[1], "g", 1) < 0 and c.errno(@as(c_int, -1)) == .INTR) {}
        file(ends[1]).close(io);
        file(ends[0]).close(io);
    }

    // One report or end of file. A short read cannot happen: the child writes
    // the whole record with one `write` to a pipe, and eight bytes is far below
    // `PIPE_BUF`. The read is the raw one rather than `std.Io`'s because
    // `spawn` is not a cancelation point: a child exists from the `fork` above
    // until this function returns it, and there is no point in between at
    // which it would be safe to stop.
    var record: Failure = undefined;
    var n = readAll(report[0], std.mem.asBytes(&record));
    // A child that could not join its cgroup says so and carries on; the
    // record after it, if any, is the one that ends the spawn.
    var root_pid = pid;
    if (n == @sizeOf(Failure) and record.stage == .supervisor_root) {
        root_pid = @intCast(record.errno);
        n = readAll(report[0], std.mem.asBytes(&record));
    }
    var joined = contained != null;
    if (n == @sizeOf(Failure) and record.stage == .containment) {
        joined = false;
        n = readAll(report[0], std.mem.asBytes(&record));
    }
    file(report[0]).close(io);

    if (n == @sizeOf(Failure)) {
        // The child is about to exit, if it has not already; reap it so it does
        // not linger as a zombie nobody is going to wait for.
        var status: c_int = undefined;
        while (c.waitpid(pid, &status, 0) < 0 and c.errno(@as(c_int, -1)) == .INTR) {}
        forks.close();
        return record.toError();
    }

    const kept: cgroup.Cgroup = if (contained) |*pending| pending.started(joined) else .none;
    contained = null;
    const child = started(state, pid, forks, kept, &plan, options);
    state.lineage = lineage;
    if (comptime builtin.os.tag == .linux) if (channel_ends) |ends| {
        state.supervisor = .{ .channel = ends[0], .record = scope_record.? };
        state.process_id = root_pid;
        state.pgid = if (options.detach) root_pid else null;
    };
    return child;
}

/// Ends and reaps a child that has just been started and will not be handed
/// back.
fn discard(pid: posix.pid_t) void {
    _ = c.kill(pid, .KILL);
    var status: c_int = undefined;
    while (c.waitpid(pid, &status, 0) < 0 and c.errno(@as(c_int, -1)) == .INTR) {}
}

/// The `Child` a started process is, whichever path started it.
fn started(
    state: *State,
    pid: posix.pid_t,
    forks: tree.Forks,
    contained: cgroup.Cgroup,
    plan: *const Plan,
    options: SpawnOptions,
) Child {
    state.* = .{
        .allocator = state.allocator,
        .descendants = options.descendants,
        .process_id = pid,
        .id = pid,
        .thread = {},
        .handles_open = {},
        .job = {},
        .job_port = {},
        .tree_ended = {},
        .pgid = if (options.detach) pid else null,
        .forks = forks,
        .cgroup = contained,
        .term = null,
        .stdin = plan.parent[0],
        .stdout = plan.parent[1],
        .stderr = plan.parent[2],
        .pty = switch (options.stdio) {
            .pty => |pty| pty.master(),
            else => null,
        },
    };
    return State.owner(state);
}

/// Where between the fork and the exec something went wrong, and with what
/// error number. Written to the report pipe by the fork child, read by the
/// parent, and turned back into one of `SpawnError`.
const Failure = extern struct {
    stage: Stage,
    errno: u32,

    const Stage = enum(u32) {
        detach,
        controlling_terminal,
        descriptors,
        resource_limits,
        credentials,
        chdir,
        exec,
        parent_death_signal,
        /// Not a failure: the child could not join its cgroup and runs
        /// without one. Written before the exec, and followed by a failure
        /// or by nothing.
        containment,
        supervisor,
        supervisor_root,
    };

    fn toError(record: Failure) SpawnError {
        const err: posix.E = @enumFromInt(record.errno);
        return switch (record.stage) {
            .detach => error.DetachFailed,
            .controlling_terminal => error.ControllingTerminalFailed,
            .descriptors => switch (err) {
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                else => posix.unexpectedErrno(err),
            },
            .resource_limits => error.ResourceLimitsFailed,
            .credentials => error.CredentialsFailed,
            .chdir => switch (err) {
                .ACCES => error.AccessDenied,
                .NOENT, .NOTDIR => error.BadWorkingDirectory,
                .NAMETOOLONG => error.NameTooLong,
                .LOOP => error.SymLinkLoop,
                else => posix.unexpectedErrno(err),
            },
            .exec => Child.execError(err),
            .parent_death_signal => posix.unexpectedErrno(err),
            .supervisor => switch (err) {
                .AGAIN => error.ResourceLimitReached,
                .NOMEM => error.SystemResources,
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NOSYS, .INVAL, .NOENT => error.Unsupported,
                else => error.Unexpected,
            },
            .supervisor_root => error.Unexpected,
            // Never the record that ends a spawn; a second one would be.
            .containment => posix.unexpectedErrno(err),
        };
    }
};

/// Runs in the fork child and never returns.
///
/// Everything it calls is async-signal-safe, which is the rule for a fork child
/// in a process that may have other threads: no allocation, no locks, no
/// standard library machinery. All the memory it reads was prepared before the
/// fork.
fn childMain(
    options: SpawnOptions,
    plan: Plan,
    candidates: []const [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: ?[*:0]const u8,
    report: posix.fd_t,
    parent: posix.pid_t,
    go: ?[2]posix.fd_t,
    join: posix.fd_t,
) noreturn {
    // Only the parent writes the word to go on. With this copy of the writing
    // end closed, a parent that has gone reads as end of file rather than as
    // a wait with no end.
    if (go) |ends| _ = c.close(ends[1]);

    // Into the child's cgroup before anything else, so that nothing it
    // starts, from here to the end of its tree, is started outside it. The
    // descriptor is close-on-exec and goes with the `execve`.
    if (join >= 0 and !cgroup.join(join)) note(report, .containment);

    clearSignals();

    // `spawn` refuses the option anywhere but Linux.
    if (builtin.os.tag == .linux) if (if (options.descendants == .contain) @as(?Child.Signal, .kill) else options.parent_death_signal) |signal| {
        const sig = signal.toPosix();
        const rc = std.os.linux.prctl(@intFromEnum(std.os.linux.PR.SET_PDEATHSIG), @intFromEnum(sig), 0, 0, 0);
        if (std.os.linux.errno(rc) != .SUCCESS) bail(report, .parent_death_signal);
        // The parent may have ended between the fork and the line above,
        // and then nothing will send it: the child is an orphan already.
        if (c.getppid() != parent) {
            _ = c.kill(c.getpid(), sig);
            c._exit(127);
        }
    };

    if (options.detach) {
        switch (options.stdio) {
            .pty => |pty| {
                if (c.setsid() < 0) bail(report, .detach);
                if (c.ioctl(pty.slaveHandle().?, @bitCast(tty.T.SCTTY), @as(usize, 0)) != 0) {
                    bail(report, .controlling_terminal);
                }
            },
            else => if (c.setpgid(0, 0) != 0) bail(report, .detach),
        }
    }

    // Before the descriptors are placed, which may write over a low one, and
    // after the work above, which gives the parent the time it needs: the
    // byte is usually there by now. End of file is a parent that is gone,
    // and the child goes on as it would have without a watch.
    if (go) |ends| {
        var byte: [1]u8 = undefined;
        while (c.read(ends[0], &byte, 1) < 0 and c.errno(@as(c_int, -1)) == .INTR) {}
        _ = c.close(ends[0]);
    }

    if (!placeDescriptors(plan)) bail(report, .descriptors);

    switch (options.stdio) {
        // The master end has no business in the child. While a descriptor for
        // it stays open there, the parent closing its own copy does not hang
        // up the child's terminal, and a grandchild would inherit it too. The
        // spare copy of the slave goes the same way; the child's terminal is
        // on 0, 1 and 2 now. Those slots belong to the placed streams: a pair
        // originally opened there has already been replaced, and its old
        // number can no longer authorize closing the new descriptor.
        .pty => |pty| {
            for ([_]posix.fd_t{ pty.readHandle().?, pty.slaveHandle().? }) |fd| {
                if (fd > 2) _ = c.close(fd);
            }
        },
        else => {},
    }

    if (options.fd_policy == .close_all) closeFromThreeExcept(report);

    // Before the credentials below: a privileged parent can still raise a hard
    // limit for a child it is about to hand to somebody else, and after
    // `setuid` it could not.
    for (options.resource_limits) |entry| {
        if (setrlimitSym(entry.resource, &entry.limit) != 0) bail(report, .resource_limits);
    }

    // Last of the things that change what this process is, and before the
    // `chdir` below, so a working directory the new user may not enter is an
    // error rather than a child running somewhere it could not have reached.
    // `umask` returns the old mask and cannot fail.
    if (options.credentials.umask) |mask| _ = c.umask(mask);
    // The group before the user: once the user has been lowered there may be
    // no privilege left to change the group with.
    if (options.credentials.gid) |gid| {
        if (c.setgid(gid) != 0) bail(report, .credentials);
    }
    if (options.credentials.uid) |uid| {
        if (c.setuid(uid) != 0) bail(report, .credentials);
    }

    if (cwd) |dir| if (c.chdir(dir) != 0) bail(report, .chdir);

    // Every candidate is tried in turn, and the error worth reporting is the
    // one from the last attempt that got past "no such file": a program found
    // but not executable is more informative than the missing entry after it.
    var best: posix.E = .NOENT;
    for (candidates) |candidate| {
        _ = c.execve(candidate, argv, envp);
        const err = c.errno(@as(c_int, -1));
        switch (err) {
            .NOENT, .NOTDIR => {},
            else => best = err,
        }
    }
    const record: Failure = .{ .stage = .exec, .errno = @intFromEnum(best) };
    _ = c.write(report, std.mem.asBytes(&record), @sizeOf(Failure));
    c._exit(127);
}

/// The clean slate the child is given before `execve`.
fn clearSignals() void {
    // A fork child inherits the parent's signal mask, and `execve` keeps it.
    // A program started here must not begin life unable to receive the signals
    // its terminal generates -- a child whose `SIGINT` is blocked ignores
    // Ctrl-C no matter how correctly the pseudo-terminal is wired -- so the
    // mask is emptied first.
    const no_signals_blocked = posix.sigemptyset();
    posix.sigprocmask(posix.SIG.SETMASK, &no_signals_blocked, null);

    // `execve` resets a signal the parent had a handler for, but a signal the
    // parent set to "ignore" stays ignored in the new program. A shell that
    // starts a background job ignores `SIGINT` and `SIGQUIT` in it, so a child
    // spawned from one would be deaf to the Ctrl-C on its own terminal -- the
    // one thing a pseudo-terminal exists to deliver. Every ignored signal goes
    // back to its default action here, which is what a shell does when it puts
    // a job in the foreground.
    clearDispositions(SpawnSignals);
}

const SpawnSignals = struct {
    const SIG = posix.SIG;
    const Sigaction = posix.Sigaction;
    const sigaction = c.sigaction;
    const limit = if (@hasDecl(c.SIG, "RTMAX")) @max(c.NSIG, c.SIG.RTMAX + 1) else c.NSIG;
};

fn clearDispositions(comptime system: type) void {
    var number: u32 = 1;
    while (number < system.limit) : (number += 1) {
        const signal: system.SIG = @enumFromInt(number);
        // The two that cannot be caught cannot be reset either.
        if (signal == .KILL or signal == .STOP) continue;
        var current: system.Sigaction = undefined;
        // Reserved numbers cannot carry a caller's disposition. In
        // particular, libc refuses its threading signals on Linux.
        if (system.sigaction(signal, null, &current) != 0) continue;
        if (current.handler.handler != system.SIG.IGN) continue;
        current.handler = .{ .handler = system.SIG.DFL };
        current.flags = 0;
        _ = system.sigaction(signal, &current, null);
    }
}

/// Puts the descriptors the child was given at 0, 1 and 2, and returns false if
/// the system refused one.
fn placeDescriptors(plan: Plan) bool {
    // A descriptor the caller handed over may itself be one of the three
    // numbers about to be written. Placing 0, 1 and 2 in order would then read
    // a number an earlier `dup2` had already overwritten -- `.stdout` given
    // the file this process holds at 1 and `.stderr` given the one at 2, say,
    // crossed over -- and the child would silently get one of them twice. Any
    // source below the slot it serves is therefore copied out of the way
    // first, above 2, before a single placement happens. A source at or above
    // its own slot needs no copy: the placements run in increasing order, so
    // nothing has touched it yet.
    var placement = plan.child;
    for (&placement, 0..) |*target, slot| switch (target.*) {
        .place => |fd| if (fd < @as(posix.fd_t, @intCast(slot))) {
            // Close-on-exec: the copy exists only to be `dup2`'d from, and
            // `dup2` clears the flag on the descriptor it writes.
            const moved = c.fcntl(fd, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
            if (moved < 0) return false;
            target.* = .{ .place = @intCast(moved) };
        },
        else => {},
    };

    for (placement, 0..) |target, slot| switch (target) {
        .inherit => {},
        .place => |fd| if (!place(fd, @intCast(slot))) return false,
        // A close that finds nothing there is not a failure of the spawn: the
        // child was asked to have no descriptor at that number, and it does
        // not.
        .close => _ = c.close(@intCast(slot)),
    };

    // Everything above the child's own three, if that was asked for. After
    // the placements, so the descriptors being placed are still there to place
    // -- and after the master and spare slave of a pair are closed below, for
    // the same reason, which is why this is not simply first.
    return true;
}

/// Closes every descriptor from 3 upwards except `kept`, in the fork child.
///
/// `kept` is the close-on-exec report pipe. It has to survive long enough to
/// report a failure below, while a successful exec still closes it and gives
/// the parent end of file.
///
/// `close_range` is one system call and has been in Linux since 5.9; the
/// fallback is a loop to the soft descriptor limit, which is what a program
/// may have open rather than what it does have. Both are async-signal-safe,
/// which is what the fork child needs; neither can fail in a way that means
/// anything here, because a descriptor that was not there is a descriptor the
/// child does not have.
fn closeFromThreeExcept(kept: posix.fd_t) void {
    if (builtin.os.tag == .linux) {
        const before = if (kept > 3)
            std.os.linux.close_range(3, @intCast(kept - 1), .{ .UNSHARE = false, .CLOEXEC = false })
        else
            0;
        const after = std.os.linux.close_range(@intCast(@max(kept + 1, 3)), std.math.maxInt(i32), .{
            .UNSHARE = false,
            .CLOEXEC = false,
        });
        if (std.os.linux.errno(before) == .SUCCESS and std.os.linux.errno(after) == .SUCCESS) return;
    }
    var limit: posix.rlimit = undefined;
    const ceiling: posix.fd_t = if (c.getrlimit(.NOFILE, &limit) == 0)
        std.math.lossyCast(posix.fd_t, limit.cur)
    else
        4096;
    var fd: posix.fd_t = 3;
    while (fd < ceiling) : (fd += 1) {
        if (fd != kept) _ = c.close(fd);
    }
}

/// Makes `fd` the child's descriptor number `target`, clearing close-on-exec so
/// it survives the `execve`.
fn place(fd: posix.fd_t, target: posix.fd_t) bool {
    if (fd == target) return c.fcntl(target, c.F.SETFD, @as(c_int, 0)) != -1;
    return c.dup2(fd, target) != -1;
}

/// Tells the parent something that is not a failure, and goes on.
fn note(report: posix.fd_t, stage: Failure.Stage) void {
    const record: Failure = .{
        .stage = stage,
        .errno = @intFromEnum(c.errno(@as(c_int, -1))),
    };
    _ = c.write(report, std.mem.asBytes(&record), @sizeOf(Failure));
}

fn bail(report: posix.fd_t, stage: Failure.Stage) noreturn {
    const record: Failure = .{
        .stage = stage,
        .errno = @intFromEnum(c.errno(@as(c_int, -1))),
    };
    _ = c.write(report, std.mem.asBytes(&record), @sizeOf(Failure));
    c._exit(127);
}

/// The paths `execve` should be tried on, in order.
///
/// A program name containing `/` is a path and is the only candidate. Anything
/// else is joined onto each entry of `path`, an empty entry meaning the current
/// directory, exactly as a shell would. Entries that would make an
/// over-long path are skipped rather than failing the spawn.
///
/// The candidates are built here, in the parent, and tried in the child after
/// its `chdir`. So a relative entry -- an empty one, or a `.` -- and a relative
/// `argv[0]` both resolve against `cwd` rather than against the parent's
/// working directory. That is what a shell does with the same two options, and
/// the alternative would be a program found at a path the child could not then
/// name.
///
/// With `search` false there is no list: a bare name is its own only
/// candidate, and the `execve` of a name with no separator fails the way a
/// missing file does, which is what `PathSearch.none` promises.
fn searchPath(
    arena: Allocator,
    program: []const u8,
    path: ?[]const u8,
    search: bool,
) Allocator.Error![]const [*:0]const u8 {
    if (!search or std.mem.indexOfScalar(u8, program, '/') != null) {
        const one = try arena.alloc([*:0]const u8, 1);
        one[0] = (try arena.dupeZ(u8, program)).ptr;
        return one;
    }

    // The fallback matches what `confstr(_CS_PATH)` reports on the systems this
    // package supports, and is what a shell falls back to for the same reason.
    const directories = path orelse "/usr/local/bin:/usr/bin:/bin";

    var list: std.ArrayList([*:0]const u8) = .empty;
    var it = std.mem.splitScalar(u8, directories, ':');
    while (it.next()) |dir| {
        const prefix = if (dir.len == 0) "." else dir;
        if (prefix.len + 1 + program.len >= std.fs.max_path_bytes) continue;
        const joined = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ prefix, program }, 0);
        try list.append(arena, joined.ptr);
    }
    return list.items;
}

/// `PATH` from this process's own environment, without a `std.process.Environ`
/// to read it from.
fn environPath() ?[]const u8 {
    var i: usize = 0;
    while (c.environ[i]) |entry| : (i += 1) {
        const pair = std.mem.span(entry);
        if (std.mem.startsWith(u8, pair, "PATH=")) return pair["PATH=".len..];
    }
    return null;
}

/// `setrlimit` under whichever name this libc exports it.
///
/// glibc on 32-bit systems has two, with different widths for the limit, and
/// the standard library's `posix.lfs64_abi` is the same test `std.posix` makes
/// to choose between them. This file calls the symbol directly rather than
/// going through `std.posix.setrlimit`, because it runs in a fork child, where
/// what is legal is a system call and not a wrapper.
const setrlimitSym = if (posix.lfs64_abi) c.setrlimit64 else c.setrlimit;

/// The null device, opened for both directions so one descriptor can serve any
/// of the three streams, and close-on-exec so the copy `dup2` makes is the only
/// one the child keeps.
///
/// `O_CLOEXEC` in the open rather than an `fcntl` after it: between an open and
/// a second call there is a descriptor without the flag, and another thread
/// that forks in that gap hands it to a child it has nothing to do with.
fn openNullDevice() SpawnError!posix.fd_t {
    const fd = c.open("/dev/null", .{ .ACCMODE = .RDWR, .CLOEXEC = true });
    if (fd < 0) switch (c.errno(@as(c_int, -1))) {
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => return error.NoDevice,
    };
    return fd;
}

/// A pipe whose two ends are both close-on-exec.
///
/// That is what both kinds of pipe here want. A standard stream is put on 0, 1
/// or 2 with `dup2`, which clears the flag on the copy, so the original goes
/// away at the `execve` and the parent's end never reaches an unrelated child.
/// The report pipe wants the write end to close at a successful `execve`,
/// which is exactly how the parent learns the exec happened.
///
/// `pipe2` where the system has it, because the flag then arrives with the
/// descriptors rather than a call later: in that gap the two ends have no flag
/// at all, and another thread that forks through it hands them to a child that
/// has nothing to do with this one. Darwin has no `pipe2` and takes the gap.
fn makePipe() SpawnError![2]posix.fd_t {
    return handles.pipe();
}

/// The fork handshake is owned by spawn, outside the slots the stdio plan
/// replaces. A parent with closed standard descriptors can otherwise get
/// the exec report on descriptor 2 and overwrite it while placing stderr.
fn controlPipe() SpawnError![2]posix.fd_t {
    var ends = try makePipe();
    errdefer {
        for (ends) |fd| _ = c.close(fd);
    }
    for (&ends) |*fd| {
        if (fd.* > 2) continue;
        const moved = c.fcntl(fd.*, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
        if (moved < 0) return switch (c.errno(@as(c_int, -1))) {
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NOMEM => error.SystemResources,
            else => |err| posix.unexpectedErrno(err),
        };
        _ = c.close(fd.*);
        fd.* = @intCast(moved);
    }
    return ends;
}

/// Reads until the buffer is full or the writer is gone. Used on the report
/// pipe, where the answer is always either nothing or the whole record.
fn readAll(fd: posix.fd_t, buffer: []u8) usize {
    var filled: usize = 0;
    while (filled < buffer.len) {
        const n = c.read(fd, buffer.ptr + filled, buffer.len - filled);
        if (n > 0) {
            filled += @intCast(n);
            continue;
        }
        if (n == 0) return filled;
        if (c.errno(@as(c_int, -1)) == .INTR) continue;
        return filled;
    }
    return filled;
}

test "fork signal defaults include ignored real-time signals and leave reserved numbers alone" {
    const System = struct {
        const Handler = enum { default, ignored, caught };
        const SIG = enum(u32) {
            KILL = 9,
            STOP = 19,
            _,
            const IGN: Handler = .ignored;
            const DFL: Handler = .default;
        };
        const Sigaction = struct {
            handler: union(enum) { handler: Handler },
            flags: u32 = 0,
        };
        const limit = 65;
        var actions: [limit]Sigaction = undefined;
        var reserved_writes: usize = 0;

        fn sigaction(signal: SIG, action: ?*const Sigaction, previous: ?*Sigaction) c_int {
            const number = @intFromEnum(signal);
            if (number == 32 or number == 33) {
                if (action != null) reserved_writes += 1;
                return -1;
            }
            if (previous) |old| old.* = actions[number];
            if (action) |new| actions[number] = new.*;
            return 0;
        }
    };
    System.actions = @splat(.{ .handler = .{ .handler = .default } });
    System.reserved_writes = 0;
    System.actions[2].handler = .{ .handler = .ignored };
    System.actions[64].handler = .{ .handler = .ignored };
    System.actions[32].handler = .{ .handler = .caught };
    clearDispositions(System);
    try std.testing.expectEqual(System.Handler.default, System.actions[2].handler.handler);
    try std.testing.expectEqual(System.Handler.default, System.actions[64].handler.handler);
    try std.testing.expectEqual(System.Handler.caught, System.actions[32].handler.handler);
    try std.testing.expectEqual(@as(usize, 0), System.reserved_writes);
}

test "searchPath returns the program itself when it is a path" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const one = try searchPath(arena, "/bin/sh", "/usr/bin:/bin", true);
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(one[0]));
}

test "searchPath joins a bare name onto every entry, and an empty entry is the current directory" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const many = try searchPath(arena, "sh", "/usr/bin::/bin", true);
    try std.testing.expectEqual(@as(usize, 3), many.len);
    try std.testing.expectEqualStrings("/usr/bin/sh", std.mem.span(many[0]));
    try std.testing.expectEqualStrings("./sh", std.mem.span(many[1]));
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(many[2]));
}

//======================================================================
// The search path, against the shape a candidate has to have.
//======================================================================

test "every candidate is an entry of PATH with the program on the end of it" {
    try std.testing.fuzz({}, candidatesKeepTheirShape, .{});
}

/// The property: a bare program name produces one candidate per entry of
/// `PATH`, in the order the entries are written, each of them that entry and
/// the program with a single separator between them; a program that is
/// already a path produces itself and nothing else.
///
/// What a fuzzer is for here is the punctuation. A candidate is built out of
/// the two bytes that mean something in a path — the one entries are split on
/// and the one they are joined with — and a program name is a caller's bytes,
/// which may hold either. An entry lost, an entry run together with the next,
/// or a separator that doubles would each send the child looking somewhere the
/// caller did not name.
fn candidatesKeepTheirShape(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    // A NUL is left out: a name holding one is not a name a path can spell,
    // and what `execve` would make of it is not this function's question.
    const alphabet: []const std.testing.Smith.Weight = &.{
        .rangeAtMost(u8, 'a', 'c', 2),
        .value(u8, '/', 4),
        .value(u8, ':', 4),
        .value(u8, '.', 1),
    };

    var program_bytes: [16]u8 = undefined;
    const program = program_bytes[0..smith.sliceWeightedBytes(&program_bytes, alphabet)];

    var path_bytes: [48]u8 = undefined;
    const path: ?[]const u8 = if (smith.value(bool))
        path_bytes[0..smith.sliceWeightedBytes(&path_bytes, alphabet)]
    else
        null;
    const search = smith.value(bool);

    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const candidates = try searchPath(arena, program, path, search);

    if (!search or std.mem.indexOfScalar(u8, program, '/') != null) {
        try std.testing.expectEqual(@as(usize, 1), candidates.len);
        try std.testing.expectEqualStrings(program, std.mem.span(candidates[0]));
        return;
    }

    var joined: std.ArrayList(u8) = .empty;
    var entries = std.mem.splitScalar(u8, path orelse "/usr/local/bin:/usr/bin:/bin", ':');
    var index: usize = 0;
    while (entries.next()) |entry| {
        // An empty entry is the current directory, which is what a shell makes
        // of it and the one entry that is not written down.
        const prefix = if (entry.len == 0) "." else entry;
        joined.clearRetainingCapacity();
        try joined.print(arena, "{s}/{s}", .{ prefix, program });
        if (joined.items.len >= std.fs.max_path_bytes) continue;

        try std.testing.expect(index < candidates.len);
        try std.testing.expectEqualStrings(joined.items, std.mem.span(candidates[index]));
        index += 1;
    }
    try std.testing.expectEqual(index, candidates.len);
}
