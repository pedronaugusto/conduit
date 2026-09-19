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

const Child = @import("Child.zig");
const Pty = @import("Pty.zig");
const handles = @import("handles.zig");
const stdio_plan = @import("stdio_plan.zig");
const tty = @import("tty.zig");

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
pub fn spawn(io: std.Io, allocator: Allocator, options: SpawnOptions) SpawnError!Child {
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
    } else @ptrCast(c.environ);

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
        .pty => |pty| pty.slave.?,
        else => null,
    });
    errdefer plan.closeAll(io);

    // How the fork child reports a failure that happens after the fork. The
    // write end is close-on-exec, so a successful `execve` closes it and the
    // parent's read below returns end of file instead of a record.
    const report = try makePipe();

    const pid = c.fork();
    if (pid < 0) {
        file(report[0]).close(io);
        file(report[1]).close(io);
        switch (c.errno(@as(c_int, -1))) {
            .AGAIN => return error.ResourceLimitReached,
            .NOMEM => return error.SystemResources,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
    if (pid == 0) childMain(options, plan, candidates, argv.ptr, envp, cwd_z, report[1]);

    file(report[1]).close(io);
    plan.closeChildSide(io);

    // One report or end of file. A short read cannot happen: the child writes
    // the whole record with one `write` to a pipe, and eight bytes is far below
    // `PIPE_BUF`. The read is the raw one rather than `std.Io`'s because
    // `spawn` is not a cancelation point: a child exists from the `fork` above
    // until this function returns it, and there is no point in between at
    // which it would be safe to stop.
    var record: Failure = undefined;
    const n = readAll(report[0], std.mem.asBytes(&record));
    file(report[0]).close(io);

    if (n == @sizeOf(Failure)) {
        // The child is about to exit, if it has not already; reap it so it does
        // not linger as a zombie nobody is going to wait for.
        var status: c_int = undefined;
        while (c.waitpid(pid, &status, 0) < 0 and c.errno(@as(c_int, -1)) == .INTR) {}
        return record.toError();
    }

    return .{
        .id = pid,
        .thread = {},
        .handles_open = {},
        .job = {},
        .pgid = if (options.detach) pid else null,
        .stdin = plan.parent[0],
        .stdout = plan.parent[1],
        .stderr = plan.parent[2],
        .pty = switch (options.stdio) {
            .pty => |pty| pty.master(),
            else => null,
        },
        .term = null,
    };
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
            .exec => switch (err) {
                .ACCES => error.AccessDenied,
                .PERM => error.PermissionDenied,
                .NOENT => error.FileNotFound,
                .NOTDIR => error.NotDir,
                .ISDIR => error.IsDir,
                .NAMETOOLONG => error.NameTooLong,
                .LOOP => error.SymLinkLoop,
                .NOEXEC => error.InvalidExe,
                .TXTBSY => error.FileBusy,
                .NOMEM => error.SystemResources,
                .@"2BIG" => error.SystemResources,
                else => posix.unexpectedErrno(err),
            },
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
) noreturn {
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
    // Up to 32, which is where the named signals end. Above it are the
    // real-time signals, and on Linux the threading implementation owns the
    // first two of those and sets them up before `main` runs: resetting them
    // in a fork child would be taking them from it. Nothing a program is meant
    // to ignore lives up there.
    var number: u6 = 1;
    while (number < 32) : (number += 1) {
        const signal: posix.SIG = @enumFromInt(number);
        // The two that cannot be caught cannot be reset either.
        if (signal == .KILL or signal == .STOP) continue;
        var current: posix.Sigaction = undefined;
        posix.sigaction(signal, null, &current);
        if (current.handler.handler != posix.SIG.IGN) continue;
        current.handler = .{ .handler = posix.SIG.DFL };
        current.flags = 0;
        posix.sigaction(signal, &current, null);
    }

    if (options.detach) {
        switch (options.stdio) {
            .pty => |pty| {
                if (c.setsid() < 0) bail(report, .detach);
                if (c.ioctl(pty.slave.?, tty.T.SCTTY, @as(usize, 0)) != 0) {
                    bail(report, .controlling_terminal);
                }
            },
            else => if (c.setpgid(0, 0) != 0) bail(report, .detach),
        }
    }

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
            if (moved < 0) bail(report, .descriptors);
            target.* = .{ .place = @intCast(moved) };
        },
        else => {},
    };

    for (placement, 0..) |target, slot| switch (target) {
        .inherit => {},
        .place => |fd| if (!place(fd, @intCast(slot))) bail(report, .descriptors),
        // A close that finds nothing there is not a failure of the spawn: the
        // child was asked to have no descriptor at that number, and it does
        // not.
        .close => _ = c.close(@intCast(slot)),
    };

    switch (options.stdio) {
        // The master end has no business in the child. While a descriptor for
        // it stays open there, the parent closing its own copy does not hang
        // up the child's terminal, and a grandchild would inherit it too. The
        // spare copy of the slave goes the same way; the child's terminal is
        // on 0, 1 and 2 now.
        .pty => |pty| {
            _ = c.close(pty.read.?);
            if (pty.slave.? > 2) _ = c.close(pty.slave.?);
        },
        else => {},
    }

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

/// Makes `fd` the child's descriptor number `target`, clearing close-on-exec so
/// it survives the `execve`.
fn place(fd: posix.fd_t, target: posix.fd_t) bool {
    if (fd == target) return c.fcntl(target, c.F.SETFD, @as(c_int, 0)) != -1;
    return c.dup2(fd, target) != -1;
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
    var ends: [2]posix.fd_t = undefined;
    const failed = if (@TypeOf(c.pipe2) == void) failed: {
        const rc = c.pipe(&ends);
        if (rc == 0) {
            handles.setCloseOnExec(ends[0]);
            handles.setCloseOnExec(ends[1]);
        }
        break :failed rc != 0;
    } else c.pipe2(&ends, .{ .CLOEXEC = true }) != 0;

    if (failed) switch (c.errno(@as(c_int, -1))) {
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => |err| return posix.unexpectedErrno(err),
    };
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
