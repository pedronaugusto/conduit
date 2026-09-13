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
const tty = @import("tty.zig");

const SpawnError = Child.SpawnError;
const SpawnOptions = Child.SpawnOptions;

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

    const path_value: ?[]const u8 = if (options.environ) |map|
        map.get("PATH")
    else
        environPath();
    const candidates = try searchPath(arena, options.argv[0], path_value);

    const cwd_z: ?[*:0]const u8 = if (options.cwd) |dir| (try arena.dupeZ(u8, dir)).ptr else null;

    // The descriptors the child will have as 0, 1 and 2, and the ones the
    // parent keeps. `plan` opens nothing the caller owns.
    var plan: Plan = try .init(io, options);
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

/// The descriptors involved in a spawn: what the child puts on 0, 1 and 2,
/// which of those this package opened and must therefore close in the parent
/// after the fork, and the pipe ends the parent keeps.
///
/// Every method is idempotent, so the failure path may close twice without
/// closing a descriptor number that has since been handed to something else.
const Plan = struct {
    /// Indexed by descriptor number in the child. `null` leaves the parent's
    /// descriptor in place.
    child: [3]?posix.fd_t = @splat(null),
    /// The subset of `child` this `Plan` opened. A `/dev/null` shared by all
    /// three appears once.
    owned: [3]?posix.fd_t = @splat(null),
    /// The parent's end of each pipe, by the descriptor number it serves in
    /// the child.
    parent: [3]?std.Io.File = @splat(null),

    fn init(io: std.Io, options: SpawnOptions) SpawnError!Plan {
        var plan: Plan = .{};
        errdefer plan.closeAll(io);

        switch (options.stdio) {
            .inherit => {},
            .pty => |pty| plan.child = @splat(pty.slave.?),
            .ignore => {
                const fd = c.open("/dev/null", .{ .ACCMODE = .RDWR });
                if (fd < 0) switch (c.errno(@as(c_int, -1))) {
                    .MFILE => return error.ProcessFdQuotaExceeded,
                    .NFILE => return error.SystemFdQuotaExceeded,
                    else => return error.NoDevice,
                };
                setCloseOnExec(fd);
                plan.child = @splat(fd);
                plan.owned[0] = fd;
            },
            .pipes => |which| {
                if (which.stdin) {
                    const ends = try makePipe();
                    plan.child[0] = ends[0];
                    plan.owned[0] = ends[0];
                    plan.parent[0] = file(ends[1]);
                }
                if (which.stdout) {
                    const ends = try makePipe();
                    plan.child[1] = ends[1];
                    plan.owned[1] = ends[1];
                    plan.parent[1] = file(ends[0]);
                }
                if (which.stderr) {
                    const ends = try makePipe();
                    plan.child[2] = ends[1];
                    plan.owned[2] = ends[1];
                    plan.parent[2] = file(ends[0]);
                }
            },
        }

        if (options.stderr_to) |f| {
            // A stderr pipe that was planned is undone: the caller asked for
            // the file instead, and the file is theirs, not this `Plan`'s.
            if (plan.owned[2]) |fd| {
                file(fd).close(io);
                plan.owned[2] = null;
            }
            if (plan.parent[2]) |pipe_end| {
                pipe_end.close(io);
                plan.parent[2] = null;
            }
            plan.child[2] = f.handle;
        }

        return plan;
    }

    /// Closes the descriptors that exist only for the child. Called in the
    /// parent once the fork has copied them.
    fn closeChildSide(plan: *Plan, io: std.Io) void {
        for (&plan.owned) |*slot| {
            const fd = slot.* orelse continue;
            file(fd).close(io);
            slot.* = null;
        }
    }

    /// Closes everything this `Plan` opened, on the path where no child was
    /// started or the child failed before `execve`.
    fn closeAll(plan: *Plan, io: std.Io) void {
        plan.closeChildSide(io);
        for (&plan.parent) |*slot| {
            const f = slot.* orelse continue;
            f.close(io);
            slot.* = null;
        }
    }
};

/// Where between the fork and the exec something went wrong, and with what
/// error number. Written to the report pipe by the fork child, read by the
/// parent, and turned back into one of `SpawnError`.
const Failure = extern struct {
    stage: Stage,
    errno: u32,

    const Stage = enum(u32) { detach, controlling_terminal, descriptors, chdir, exec };

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

    for (plan.child, 0..) |maybe_fd, target| {
        const fd = maybe_fd orelse continue;
        if (!place(fd, @intCast(target))) bail(report, .descriptors);
    }

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
fn searchPath(arena: Allocator, program: []const u8, path: ?[]const u8) Allocator.Error![]const [*:0]const u8 {
    if (std.mem.indexOfScalar(u8, program, '/') != null) {
        const one = try arena.alloc([*:0]const u8, 1);
        one[0] = (try arena.dupeZ(u8, program)).ptr;
        return one;
    }

    // The fallback matches what `confstr(_CS_PATH)` reports on the systems this
    // package supports, and is what a shell falls back to for the same reason.
    const search = path orelse "/usr/local/bin:/usr/bin:/bin";

    var list: std.ArrayList([*:0]const u8) = .empty;
    var it = std.mem.splitScalar(u8, search, ':');
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

/// A pipe whose two ends are both close-on-exec.
///
/// That is what both kinds of pipe here want. A standard stream is put on 0, 1
/// or 2 with `dup2`, which clears the flag on the copy, so the original goes
/// away at the `execve` and the parent's end never reaches an unrelated child.
/// The report pipe wants the write end to close at a successful `execve`,
/// which is exactly how the parent learns the exec happened.
fn makePipe() SpawnError![2]posix.fd_t {
    var ends: [2]posix.fd_t = undefined;
    if (c.pipe(&ends) != 0) switch (c.errno(@as(c_int, -1))) {
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => |err| return posix.unexpectedErrno(err),
    };
    setCloseOnExec(ends[0]);
    setCloseOnExec(ends[1]);
    return ends;
}

/// Best effort: a descriptor that could not be marked close-on-exec is still a
/// working descriptor, and there is no useful way for a caller to react.
fn setCloseOnExec(fd: posix.fd_t) void {
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
}

fn file(fd: posix.fd_t) std.Io.File {
    return .{ .handle = fd, .flags = .{ .nonblocking = false } };
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

    const one = try searchPath(arena, "/bin/sh", "/usr/bin:/bin");
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(one[0]));
}

test "searchPath joins a bare name onto every entry, and an empty entry is the current directory" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const many = try searchPath(arena, "sh", "/usr/bin::/bin");
    try std.testing.expectEqual(@as(usize, 3), many.len);
    try std.testing.expectEqualStrings("/usr/bin/sh", std.mem.span(many[0]));
    try std.testing.expectEqualStrings("./sh", std.mem.span(many[1]));
    try std.testing.expectEqualStrings("/bin/sh", std.mem.span(many[2]));
}
