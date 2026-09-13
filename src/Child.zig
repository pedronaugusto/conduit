//! A child process, running on a pseudo-terminal or on pipes.
//!
//! `spawn` forks and executes; `wait`, `tryWait`, `kill` and `killWait` are
//! what a parent does with the result. The descriptors the child was given are
//! owned by the `Child` when the `Child` created them (`.pipes`), and by the
//! caller when the caller supplied them (`.pty`, `stderr_to`); `deinit` closes
//! only the former.
//!
//! Nothing here is thread-safe. One task at a time may call the methods of a
//! given `Child`; `Reaper` is the supported way to have a wait in flight while
//! another task does something else.

const Child = @This();

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;
const Allocator = std.mem.Allocator;

const Pty = @import("Pty.zig");
const tty = @import("tty.zig");

/// The process id. Still readable after the child is reaped, where it is only
/// good for reporting: the operating system may have handed the number to an
/// unrelated process by then.
pid: posix.pid_t,
/// The child's process group, when `detach` asked for one. `null` means the
/// child is in the process group it inherited, and signals are addressed to
/// `pid` alone.
pgid: ?posix.pid_t,
/// The writing end of the child's standard input, when `.pipes` asked for one.
/// Owned by this `Child`.
stdin: ?std.Io.File,
/// The reading end of the child's standard output, when `.pipes` asked for
/// one. Owned by this `Child`.
stdout: ?std.Io.File,
/// The reading end of the child's standard error, when `.pipes` asked for one.
/// Owned by this `Child`.
stderr: ?std.Io.File,
/// For a child spawned on a pseudo-terminal, the master end of that pair: the
/// one file that is the child's input and its output. Borrowed from the `Pty`
/// the caller passed, and closed by that `Pty`, not by `deinit`.
pty: ?std.Io.File,
/// How the child ended, once it has been reaped. While this is `null` the
/// child is still a process the operating system knows about.
term: ?Term,

/// How a child process ended.
///
/// This is `std.process.Child.Term` rather than a parallel type of this
/// package's own, so a program can hand the result to code that already speaks
/// the standard library's vocabulary. `.stopped` is never produced here:
/// neither `wait` nor `tryWait` asks for stop notifications.
pub const Term = std.process.Child.Term;

/// Which of the child's three standard streams get pipes.
///
/// A stream that is not piped is inherited from the parent. Piping only what
/// is read avoids the deadlock of a full pipe nobody drains.
pub const PipeOptions = struct {
    stdin: bool = true,
    stdout: bool = true,
    stderr: bool = true,
};

/// What the child's standard input, output and error are connected to.
pub const Stdio = union(enum) {
    /// All three streams are the slave end of this pair, so the child sees a
    /// terminal: `isatty` is true for it, it can ask for the window size, and
    /// with `detach` it receives the signals the line discipline generates.
    ///
    /// The `Pty` is borrowed, not owned: `deinit` does not close it. As soon
    /// as `spawn` returns, the parent should call `Pty.closeSlave`. Until it
    /// does, the terminal still has a reader in this process, so reading the
    /// master blocks forever instead of reporting end of file when the child
    /// exits.
    pty: *Pty,
    /// The selected streams get pipes, which `spawn` creates and the `Child`
    /// owns.
    pipes: PipeOptions,
    /// All three streams are the parent's.
    inherit,
    /// All three streams are `/dev/null`.
    ignore,
};

/// Everything `spawn` needs.
pub const SpawnOptions = struct {
    /// The program and its arguments. `argv[0]` is the program: if it contains
    /// a `/` it is a path, and otherwise it is looked up in `PATH`. Must not be
    /// empty.
    argv: []const []const u8,
    /// The child's working directory. `null` inherits the parent's.
    cwd: ?[]const u8 = null,
    /// The child's environment. `null` inherits the parent's.
    environ: ?*const std.process.Environ.Map = null,
    stdio: Stdio = .inherit,
    /// Put the child out of reach of signals aimed at the parent's process
    /// group, such as the `SIGINT` a terminal sends on Ctrl-C.
    ///
    /// With `.pty`, the child calls `setsid` and then claims the pseudo-terminal
    /// as its controlling terminal. That is what makes the pair a terminal in
    /// full: the child becomes a session leader, the pty gets a foreground
    /// process group, and Ctrl-C written to the master turns into `SIGINT` for
    /// the child. A child spawned on a pty without this still sees a terminal,
    /// but no signal the line discipline generates will ever reach it.
    ///
    /// Otherwise the child calls `setpgid(0, 0)`: a new process group in the
    /// same session, which is the usual shape for a background helper.
    detach: bool = false,
    /// Send the child's standard error to this file, whatever `stdio` says
    /// about the other two streams. The file is borrowed: `deinit` does not
    /// close it, and it must stay open until `spawn` returns.
    stderr_to: ?std.Io.File = null,
};

pub const SpawnError = error{
    OutOfMemory,
    /// `argv` was empty.
    InvalidArgv,
    /// The program was not found, under that path or anywhere on `PATH`.
    FileNotFound,
    /// The program is not executable by this process, or `cwd` cannot be
    /// entered.
    AccessDenied,
    PermissionDenied,
    /// A component of the program's path is not a directory.
    NotDir,
    IsDir,
    NameTooLong,
    SymLinkLoop,
    /// The file is not in a format this system can execute.
    InvalidExe,
    /// The program is open for writing.
    FileBusy,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    /// The user's process limit was reached, so no child could be forked.
    ResourceLimitReached,
    /// `.ignore` was asked for and `/dev/null` could not be opened.
    NoDevice,
    /// The child could not be put into its own process group or session. With
    /// `detach` and `.pty`, the most likely cause is that the process was
    /// already a session leader.
    DetachFailed,
    /// The pseudo-terminal could not be made the child's controlling terminal,
    /// usually because it is already the controlling terminal of another
    /// session.
    ControllingTerminalFailed,
    /// `cwd` does not exist or is not a directory.
    BadWorkingDirectory,
} || std.posix.UnexpectedError;

/// Starts `options.argv` as a child process.
///
/// `allocator` is used only for the duration of the call, to build the
/// argument, environment and search-path arrays that must exist before the
/// fork; nothing is retained. `io` closes every descriptor the parent opened
/// here and does not keep.
///
/// This is not a cancelation point. Between the `fork` and the return there is
/// a child process that only this function knows about, so there is nowhere in
/// the middle it could stop without leaking one.
///
/// On success the caller owns the returned `Child` and must eventually reap it
/// (`wait`, `tryWait`, `killWait` or a `Reaper`) and call `deinit`. A `Child`
/// that is dropped without being reaped leaves a zombie.
///
/// If the program cannot be executed, this returns the error the child would
/// have reported rather than a `Child` that exits 127: the fork child sends
/// the failure back over a close-on-exec pipe before `spawn` returns.
///
/// The child starts with an empty signal mask and with every signal at its
/// default action. `execve` on its own resets neither a blocked signal nor an
/// ignored one, so without this a program started from, say, a shell's
/// background job would inherit an ignored `SIGINT` and be deaf to Ctrl-C on
/// its own terminal.
pub fn spawn(io: std.Io, allocator: Allocator, options: SpawnOptions) SpawnError!Child {
    if (options.argv.len == 0) return error.InvalidArgv;

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
        .pid = pid,
        .pgid = if (options.detach) pid else null,
        .stdin = plan.parent[0],
        .stdout = plan.parent[1],
        .stderr = plan.parent[2],
        .pty = switch (options.stdio) {
            .pty => |pty| pty.masterFile(),
            else => null,
        },
        .term = null,
    };
}

/// Closes the descriptors this `Child` owns: the pipes `spawn` created, if
/// any. Descriptors the caller supplied are left alone.
///
/// Safe to call more than once, and safe to call before the child has been
/// reaped, though closing a pipe the child is still writing to earns it a
/// `SIGPIPE`.
pub fn deinit(child: *Child, io: std.Io) void {
    if (child.stdin) |f| f.close(io);
    if (child.stdout) |f| f.close(io);
    if (child.stderr) |f| f.close(io);
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
}

pub const WaitError = std.process.Child.WaitError;

/// Blocks until the child ends, and returns how.
///
/// Returns the same value on every later call: the child is reaped once. This
/// is the standard library's wait, so it is a cancelation point and uses
/// whatever the `std.Io` implementation has for the job.
pub fn wait(child: *Child, io: std.Io) WaitError!Term {
    if (child.term) |term| return term;
    var proc: std.process.Child = .{
        .id = child.pid,
        .thread_handle = {},
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
    const term = try proc.wait(io);
    child.term = term;
    return term;
}

pub const TryWaitError = std.posix.UnexpectedError;

/// Reaps the child if it has already ended, and returns `null` if it has not.
///
/// Never blocks. Once this has returned a term, `wait` returns the same one.
pub fn tryWait(child: *Child) TryWaitError!?Term {
    if (child.term) |term| return term;
    var status: c_int = undefined;
    while (true) {
        const rc = c.waitpid(child.pid, &status, c.W.NOHANG);
        if (rc == 0) return null;
        if (rc > 0) {
            const term = statusToTerm(@bitCast(status));
            child.term = term;
            return term;
        }
        switch (c.errno(rc)) {
            .INTR => continue,
            // `ECHILD` here means something else reaped this child -- a
            // `SIGCHLD` handler in the program, most likely. This package has
            // to be the one that reaps, and once it is not, there is no term
            // left for anyone to report.
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

pub const KillError = error{
    /// This process may not signal the child.
    PermissionDenied,
} || std.posix.UnexpectedError;

/// Sends `signal` to the child.
///
/// A detached child is signalled through its process group, so the signal
/// reaches everything it started; an attached one is signalled by process id
/// alone. A child that has already ended is not signalled, because the process
/// id no longer belongs to it; that case is not an error, and it may reap the
/// child as a side effect.
///
/// This does not wait. The child is still a process, and still needs reaping,
/// when this returns.
pub fn kill(child: *Child, signal: posix.SIG) KillError!void {
    if (child.term != null) return;
    const target: posix.pid_t = if (child.pgid) |pgid| -pgid else child.pid;
    if (c.kill(target, signal) == 0) return;
    switch (c.errno(@as(c_int, -1))) {
        .PERM => {
            // Darwin refuses a signal addressed to a process group whose only
            // remaining member has exited and not yet been reaped. That is not
            // a permission problem in any sense the caller can act on, so it is
            // reported as what it is: the child is already gone.
            if ((child.tryWait() catch null) != null) return;
            return error.PermissionDenied;
        },
        // No such process: the child ended between the check above and here.
        .SRCH => return,
        // The signal number comes from an enum of valid ones.
        .INVAL => unreachable,
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub const KillWaitError = KillError || WaitError || TryWaitError || std.Io.Cancelable;

/// Asks the child to end, insists after `grace_ms`, and reaps it.
///
/// `SIGTERM` first, so a program that cleans up gets to; then `SIGKILL` once
/// the grace has passed, which nothing survives; then a wait, which therefore
/// terminates. A `grace_ms` of zero goes straight to `SIGKILL`.
///
/// The grace is polled rather than slept through in one piece, so the common
/// case of a child that exits promptly returns promptly. The poll interval
/// grows to a few milliseconds, which is the resolution of the grace.
pub fn killWait(child: *Child, io: std.Io, grace_ms: u32) KillWaitError!Term {
    // A child that has already ended is reaped rather than signalled.
    if (try child.tryWait()) |term| return term;

    if (grace_ms > 0) {
        try child.kill(.TERM);
        var waited_ms: u32 = 0;
        var interval_ms: u32 = 1;
        while (waited_ms < grace_ms) {
            if (try child.tryWait()) |term| return term;
            const step = @min(interval_ms, grace_ms - waited_ms);
            try std.Io.sleep(io, .fromMilliseconds(step), .awake);
            waited_ms += step;
            interval_ms = @min(interval_ms * 2, 4);
        }
        if (try child.tryWait()) |term| return term;
    }

    try child.kill(.KILL);
    return child.wait(io);
}

//======================================================================
// The fork child, and the plan it executes.
//======================================================================

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
            .pty => |pty| plan.child = @splat(pty.slave),
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
                if (c.ioctl(pty.slave, tty.T.SCTTY, @as(usize, 0)) != 0) {
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
            _ = c.close(pty.master);
            if (pty.slave > 2) _ = c.close(pty.slave);
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

//======================================================================
// Small helpers.
//======================================================================

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
    const FD_CLOEXEC: c_int = 1;
    _ = c.fcntl(fd, c.F.SETFD, FD_CLOEXEC);
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

/// The `wait` status word, as `Term`. The same mapping the standard library
/// uses, needed here because `tryWait` calls `waitpid` directly.
fn statusToTerm(status: u32) Term {
    return if (c.W.IFEXITED(status))
        .{ .exited = c.W.EXITSTATUS(status) }
    else if (c.W.IFSIGNALED(status))
        .{ .signal = c.W.TERMSIG(status) }
    else if (c.W.IFSTOPPED(status))
        .{ .stopped = c.W.STOPSIG(status) }
    else
        .{ .unknown = status };
}
