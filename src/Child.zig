//! A child process, running on a pseudo-terminal or on pipes.
//!
//! `spawn` starts it; `wait`, `tryWait`, `kill`, `killWait` and `output` are
//! what a parent does with the result. The streams the child was given are
//! owned by the `Child` when the `Child` created them (`.pipes`), and by the
//! caller when the caller supplied them (`.pty`, `stderr_to`); `deinit` closes
//! only the former.
//!
//! Nothing here is thread-safe. One task at a time may call the methods of a
//! given `Child`; `Reaper` is the supported way to have a wait in flight while
//! another task does something else, and `output` is the supported way to read
//! two streams at once.
//!
//! # The two platforms
//!
//! On POSIX this forks and executes, and does between the two the things there
//! is no other place to do: `setsid`, `TIOCSCTTY`, an empty signal mask and
//! every signal back at its default action.
//!
//! On Windows it is `CreateProcessW`. A child on a pseudo-terminal is attached
//! to the pseudoconsole through `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` in a
//! `PROC_THREAD_ATTRIBUTE_LIST`, which is the ConPTY counterpart of the
//! controlling-terminal dance, and `detach` is `CREATE_NEW_PROCESS_GROUP`.
//! What the two systems do *not* share is spelled out on `SpawnOptions.detach`
//! and on `Signal`.

const Child = @This();

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

const Pty = @import("Pty.zig");
const tty = @import("tty.zig");

const is_windows = builtin.os.tag == .windows;
const win32 = if (is_windows) @import("win32.zig") else struct {};

/// The operating system's name for the child: the process id on POSIX, the
/// process `HANDLE` on Windows. An alias for `std.process.Child.Id`.
pub const Id = std.process.Child.Id;

/// A process group. The process group id on POSIX; on Windows the id of the
/// group `CREATE_NEW_PROCESS_GROUP` made, which is the child's process id.
pub const ProcessGroupId = if (is_windows) windows.DWORD else posix.pid_t;

/// The operating system's name for the child.
///
/// On POSIX this stays meaningful after the child is reaped only as a label:
/// the operating system may have handed the number to an unrelated process by
/// then. On Windows it is a handle, and it is closed once the child is reaped
/// — see `handles_open`.
id: Id,
/// Windows only: the handle to the child's initial thread, which
/// `CreateProcessW` hands back and nothing else here uses. It is closed
/// alongside `id`.
thread: if (is_windows) windows.HANDLE else void,
/// Windows only: whether `id` and `thread` are still open handles.
///
/// Reaping a child closes them, and a closed handle must not be closed again.
/// POSIX has no such thing: a process id is a number.
handles_open: if (is_windows) bool else void,
/// The child's process group, when `detach` asked for one. `null` means the
/// child is in the process group it inherited, and a signal is addressed to
/// the child alone.
pgid: ?ProcessGroupId,
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
/// two files that are the child's input and its output. Borrowed from the
/// `Pty` the caller passed, and closed by that `Pty`, not by `deinit`.
pty: ?Pty.Master,
/// How the child ended, once it has been reaped. While this is `null` the
/// child is still a process the operating system knows about.
term: ?Term,

/// How a child process ended.
///
/// This is `std.process.Child.Term` rather than a parallel type of this
/// package's own, so a program can hand the result to code that already speaks
/// the standard library's vocabulary. `.stopped` is never produced here:
/// neither `wait` nor `tryWait` asks for stop notifications, and Windows has
/// no such state. `.signal` is POSIX-only for the same reason — a Windows
/// process that is terminated reports the exit code it was terminated with.
pub const Term = std.process.Child.Term;

/// Whether the child ended the way a program that did its job ends: exited,
/// with a status of zero.
///
/// Every other end is false, and they are not the same as each other: a
/// non-zero status is the program saying something went wrong, and a signal is
/// the program not getting to say anything. `exitCode` and `signalName` are
/// for telling them apart.
///
/// This is the one question almost every caller has, and `Term` is a tagged
/// union of the standard library's rather than a type of this package's own,
/// so it cannot be a method on it. A function it is.
pub fn succeeded(term: Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// The status the child exited with, or `null` if it did not exit -- which on
/// POSIX means a signal ended it.
pub fn exitCode(term: Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

/// The name of the signal that ended the child, without the `SIG`: `"INT"`,
/// `"TERM"`, `"KILL"`. `null` if a signal did not end it.
///
/// Always `null` on Windows, where `Term.signal` is never produced: a
/// terminated process there reports the exit code it was terminated with, and
/// `killWait` uses 1. A portable program that wants to say why a child stopped
/// has to accept that the Windows answer is a number.
pub fn signalName(term: Term) ?[]const u8 {
    return switch (term) {
        .signal, .stopped => |signal| @tagName(signal),
        else => null,
    };
}

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
    /// The child runs on this pseudo-terminal pair, so it sees a terminal:
    /// `isatty` is true for it, it can ask for the window size, and — on
    /// POSIX, with `detach` — it receives the signals the line discipline
    /// generates.
    ///
    /// The `Pty` is borrowed, not owned: `deinit` does not close it. On POSIX
    /// the parent should call `Pty.closeSlave` as soon as `spawn` returns;
    /// until it does, the terminal still has a reader in this process, so
    /// reading the master blocks forever instead of reporting end of file when
    /// the child exits. On Windows `Pty.closeSlave` ends the child, so it is
    /// called when the program is done with it instead. That difference is the
    /// whole of the platform divergence in this package's usage, and
    /// `Pty.closeSlave` documents it.
    pty: *Pty,
    /// The selected streams get pipes, which `spawn` creates and the `Child`
    /// owns.
    pipes: PipeOptions,
    /// All three streams are the parent's.
    inherit,
    /// All three streams are `/dev/null`, or `NUL` on Windows.
    ignore,
};

/// Everything `spawn` needs.
pub const SpawnOptions = struct {
    /// The program and its arguments.
    ///
    /// On POSIX `argv[0]` is the program: if it contains a `/` it is a path,
    /// and otherwise it is looked up in `PATH`. On Windows the list is
    /// serialised into the one command-line string `CreateProcessW` takes, by
    /// the rules `CommandLineToArgvW` parses, and the system does the looking
    /// up. Must not be empty.
    argv: []const []const u8,
    /// The child's working directory. `null` inherits the parent's.
    cwd: ?[]const u8 = null,
    /// The child's environment. `null` inherits the parent's. `environ` in the
    /// root module builds one of these from the parent's with overrides.
    environ: ?*const std.process.Environ.Map = null,
    stdio: Stdio = .inherit,
    /// Which `PATH` a bare program name is looked up in.
    ///
    /// This only matters when `environ` is set *and* `argv[0]` has no
    /// separator, and it is the sort of thing that is a silent surprise either
    /// way round, so it is a decision rather than a default nobody wrote down.
    /// The standard library resolves from the parent's environment always; a
    /// shell resolves from the environment it is handing over. Both are
    /// defensible and they find different programs.
    path_search: PathSearch = .child_environ,
    /// Put the child out of reach of signals aimed at the parent's process
    /// group, such as the `SIGINT` a terminal sends on Ctrl-C.
    ///
    /// **POSIX.** With `.pty`, the child calls `setsid` and then claims the
    /// pseudo-terminal as its controlling terminal. That is what makes the
    /// pair a terminal in full: the child becomes a session leader, the pty
    /// gets a foreground process group, and Ctrl-C written to the master turns
    /// into `SIGINT` for the child. A child spawned on a pty without this
    /// still sees a terminal, but no signal the line discipline generates will
    /// ever reach it. Without `.pty` the child calls `setpgid(0, 0)`: a new
    /// process group in the same session, the usual shape for a background
    /// helper.
    ///
    /// **Windows.** This is `CREATE_NEW_PROCESS_GROUP`, and it means only half
    /// as much. A pseudoconsole is the child's console whether or not this is
    /// set, so there is no controlling-terminal half to ask for. What it buys
    /// is a group `kill` can address with `GenerateConsoleCtrlEvent`; what it
    /// costs is that Windows starts such a group with Ctrl-C *disabled*, so a
    /// `Ctrl-C` typed at a pseudoconsole will not interrupt it. For a child on
    /// a pty on Windows the useful setting is therefore `false`, which is what
    /// `spawnShell` picks there.
    detach: bool = false,
    /// Send the child's standard error to this file, whatever `stdio` says
    /// about the other two streams. The file is borrowed: `deinit` does not
    /// close it, and it must stay open until `spawn` returns.
    ///
    /// Not available together with `.pty` on Windows, where it is
    /// `error.Unsupported`: a pseudoconsole is attached through an attribute
    /// list, and Windows documents that as incompatible with naming the
    /// child's standard handles. On POSIX the two compose, because there the
    /// terminal is a descriptor like any other.
    stderr_to: ?std.Io.File = null,
};

/// Where the `PATH` that resolves a bare `argv[0]` comes from.
///
/// Windows resolves the program itself, inside `CreateProcessW`, from the
/// environment the child is being given -- so `.child_environ` is what that
/// system does and the other two are `error.Unsupported` there rather than a
/// promise this package cannot keep.
pub const PathSearch = enum {
    /// The `PATH` in `SpawnOptions.environ`, or the parent's when that is
    /// `null`. What a shell does: the program is looked for where the child
    /// would look for it.
    child_environ,
    /// The `PATH` this process has, whatever the child is being given. What
    /// `std.process.spawn` does, and what a caller who is scrubbing the
    /// environment usually means -- an empty `PATH` for the child should not
    /// also mean this spawn cannot find its program.
    parent_environ,
    /// No search. `argv[0]` is a path, and a bare name is `error.FileNotFound`
    /// rather than whatever happens to be on a search path.
    none,
};

pub const SpawnError = error{
    OutOfMemory,
    /// `argv` was empty, or — on Windows — its first element contains a
    /// double quote, which cannot be serialised into a command line without
    /// letting characters leak into the arguments after it.
    InvalidArgv,
    /// Windows only: a name in `argv` or in the environment is not valid
    /// WTF-8, so it has no UTF-16 spelling to pass on.
    InvalidWtf8,
    /// Windows only: the program is a `.bat` or `.cmd` script. Those are
    /// parsed by `cmd.exe` with rules no argument serialisation survives, so
    /// this package refuses rather than offering a way to smuggle a command
    /// into one. Run `cmd.exe /c script.bat ...` deliberately if that is what
    /// you want.
    UnsupportedBatchFile,
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
    /// The user's process limit was reached, so no child could be started.
    ResourceLimitReached,
    /// `.ignore` was asked for and the null device could not be opened.
    NoDevice,
    /// POSIX: the child could not be put into its own process group or
    /// session. With `detach` and `.pty`, the most likely cause is that the
    /// process was already a session leader.
    DetachFailed,
    /// POSIX: the pseudo-terminal could not be made the child's controlling
    /// terminal, usually because it is already the controlling terminal of
    /// another session.
    ControllingTerminalFailed,
    /// `cwd` does not exist or is not a directory.
    BadWorkingDirectory,
    /// The combination asked for has no meaning on this system: `stderr_to`
    /// together with `.pty` on Windows, or a `path_search` other than
    /// `.child_environ` there. The option that cannot be honoured says so.
    Unsupported,
} || std.Io.UnexpectedError;

/// Starts `options.argv` as a child process.
///
/// `allocator` is used only for the duration of the call, to build the
/// argument, environment and search-path arrays that must exist before the
/// child does; nothing is retained. `io` closes every handle the parent opened
/// here and does not keep.
///
/// This is not a cancelation point. On POSIX, between the `fork` and the
/// return there is a child process that only this function knows about, so
/// there is nowhere in the middle it could stop without leaking one.
///
/// On success the caller owns the returned `Child` and must eventually reap it
/// (`wait`, `tryWait`, `killWait`, `output` or a `Reaper`) and call `deinit`.
/// A `Child` that is dropped without being reaped leaves a zombie on POSIX and
/// an orphan plus two leaked handles on Windows.
///
/// If the program cannot be executed, this returns the error the child would
/// have reported rather than a `Child` that exits 127: on POSIX the fork child
/// sends the failure back over a close-on-exec pipe before `spawn` returns,
/// and on Windows `CreateProcessW` fails outright.
///
/// On POSIX the child starts with an empty signal mask and with every signal
/// at its default action. `execve` on its own resets neither a blocked signal
/// nor an ignored one, so without this a program started from, say, a shell's
/// background job would inherit an ignored `SIGINT` and be deaf to Ctrl-C on
/// its own terminal.
pub fn spawn(io: std.Io, allocator: Allocator, options: SpawnOptions) SpawnError!Child {
    if (options.argv.len == 0) return error.InvalidArgv;
    if (is_windows) return @import("child_windows.zig").spawn(io, allocator, options);
    return @import("child_posix.zig").spawn(io, allocator, options);
}

/// Closes the streams this `Child` owns: the pipes `spawn` created, if any,
/// and on Windows the process and thread handles when the child was never
/// reaped.
///
/// Streams the caller supplied are left alone.
///
/// Safe to call more than once, and safe to call before the child has been
/// reaped, though closing a pipe the child is still writing to earns it a
/// `SIGPIPE` on POSIX and a broken-pipe error on Windows.
pub fn deinit(child: *Child, io: std.Io) void {
    if (child.stdin) |f| f.close(io);
    if (child.stdout) |f| f.close(io);
    if (child.stderr) |f| f.close(io);
    child.stdin = null;
    child.stdout = null;
    child.stderr = null;
    if (is_windows) {
        if (child.handles_open) child.closeHandles();
    }
}

/// Closes the child's standard input, and nothing else.
///
/// This is half-close, and for a great many children it is the only way the
/// conversation ends: a program that reads until end of file keeps reading
/// while any writer remains, and the parent is one. Writing everything and
/// then waiting, without this, is the shape of a parent and a child waiting
/// for each other.
///
/// Only the pipe `.pipes` created is closed. A child on a pseudo-terminal has
/// no separate input to close -- the master carries both directions, and
/// closing it hangs the terminal up on the child rather than ending its input
/// (`Pty.closeMaster` says what that does). The way to say "no more input" on
/// a terminal is to write the end-of-file character the line discipline turns
/// into one, which is `\x04` on a terminal in its default mode.
///
/// Idempotent, and safe after the child has been reaped.
pub fn closeStdin(child: *Child, io: std.Io) void {
    const f = child.stdin orelse return;
    child.stdin = null;
    f.close(io);
}

pub const WaitError = std.process.Child.WaitError;

/// Blocks until the child ends, and returns how.
///
/// Returns the same value on every later call: the child is reaped once. This
/// is the standard library's wait, so it is a cancelation point and uses
/// whatever the `std.Io` implementation has for the job.
///
/// **Read the child's output while you wait for it.** A child that fills a
/// pipe nobody is draining stops there, and a child on a pseudo-terminal can
/// do worse: on Darwin a process whose terminal still holds output it has
/// written blocks *inside exit* until the master is read, so a parent that
/// waits first and reads afterwards waits forever. `output` is the version of
/// this that reads and waits at once, and `Proxy` is the version that keeps
/// reading.
pub fn wait(child: *Child, io: std.Io) WaitError!Term {
    if (child.term) |term| return term;
    var proc: std.process.Child = .{
        .id = child.id,
        .thread_handle = child.thread,
        .stdin = null,
        .stdout = null,
        .stderr = null,
        .request_resource_usage_statistics = false,
    };
    const term = try proc.wait(io);
    // The standard library's Windows wait closes the process and thread
    // handles as part of reaping. Recording that here is what keeps `deinit`
    // from closing them a second time.
    if (is_windows) child.handles_open = false;
    child.term = term;
    return term;
}

pub const WaitTimeoutError = TryWaitError || std.Io.Cancelable;

/// Reaps the child if it ends within `timeout_ms`, and returns `null` if it
/// does not.
///
/// Unlike `killWait` this does nothing to the child when the time runs out:
/// it is still running, and still needs reaping. That is what makes it the
/// call to build a policy on -- ask again, ask the user, then `killWait`.
///
/// **Read the child's output while you wait**, for the reasons `wait` gives:
/// a child blocked on a pipe nobody drains will not exit within any timeout,
/// and reporting that as "it took too long" would be this call believing its
/// own deadlock.
///
/// The wait is polled rather than slept through in one piece, so a child that
/// exits promptly is noticed promptly. The poll interval grows to a few
/// milliseconds, which is the resolution of the timeout.
pub fn waitTimeout(child: *Child, io: std.Io, timeout_ms: u32) WaitTimeoutError!?Term {
    var waited_ms: u32 = 0;
    var interval_ms: u32 = 1;
    while (true) {
        if (try child.tryWait()) |term| return term;
        if (waited_ms >= timeout_ms) return null;
        const step = @min(interval_ms, timeout_ms - waited_ms);
        try std.Io.sleep(io, .fromMilliseconds(step), .awake);
        waited_ms += step;
        interval_ms = @min(interval_ms * 2, 4);
    }
}

pub const TryWaitError = std.Io.UnexpectedError;

/// Reaps the child if it has already ended, and returns `null` if it has not.
///
/// Never blocks. Once this has returned a term, `wait` returns the same one.
pub fn tryWait(child: *Child) TryWaitError!?Term {
    if (child.term) |term| return term;
    if (is_windows) return child.tryWaitWindows();

    var status: c_int = undefined;
    while (true) {
        const rc = c.waitpid(child.id, &status, c.W.NOHANG);
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

/// The ways this package can ask a child to stop, on either system.
///
/// POSIX has more signals than these and a program that wants one can send it
/// itself with `std.posix.kill` and `child.id`. What is here is the subset
/// that means the same thing on Windows, which is the only thing a portable
/// API can promise.
pub const Signal = enum {
    /// The interrupt a terminal generates. POSIX: `SIGINT`. Windows:
    /// `CTRL_C_EVENT` to the child's process group, which exists only for a
    /// child spawned with `detach`; without one this is `error.Unsupported`.
    interrupt,
    /// Ask the child to stop, in a way it can catch and clean up after.
    /// POSIX: `SIGTERM`. Windows: `CTRL_BREAK_EVENT` to the child's process
    /// group when it has one — and, when it does not, `TerminateProcess`,
    /// which it cannot catch. Windows offers nothing else: there is no
    /// catchable request that reaches a process outside your console.
    terminate,
    /// End the child now. POSIX: `SIGKILL`. Windows: `TerminateProcess`.
    /// Neither can be caught.
    kill,

    /// The POSIX signal number this stands for. POSIX only: Windows has no
    /// `SIGKILL` to name.
    pub const toPosix = if (is_windows)
        @compileError("Signal.toPosix is POSIX-only")
    else
        toPosixImpl;

    fn toPosixImpl(signal: Signal) posix.SIG {
        return switch (signal) {
            .interrupt => .INT,
            .terminate => .TERM,
            .kill => .KILL,
        };
    }
};

pub const KillError = error{
    /// This process may not signal the child.
    PermissionDenied,
    /// Windows: `.interrupt` was asked for and the child has no process group
    /// of its own, so there is nothing a console control event can be
    /// addressed to. Spawn with `detach` to get one.
    Unsupported,
} || std.Io.UnexpectedError;

/// Asks the child to stop, with `signal`.
///
/// A detached child is signalled through its process group, so the signal
/// reaches everything it started; an attached one is signalled alone. A child
/// that has already ended is not signalled, because its name no longer belongs
/// to it; that case is not an error, and it may reap the child as a side
/// effect.
///
/// This does not wait. The child is still a process, and still needs reaping,
/// when this returns.
pub fn kill(child: *Child, signal: Signal) KillError!void {
    if (child.term != null) return;
    if (is_windows) return child.killWindows(signal);

    const target: posix.pid_t = if (child.pgid) |pgid| -pgid else child.id;
    if (c.kill(target, signal.toPosix()) == 0) return;
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
/// `.terminate` first, so a program that cleans up gets to; then `.kill` once
/// the grace has passed, which nothing survives; then a wait, which therefore
/// terminates. A `grace_ms` of zero goes straight to `.kill`.
///
/// A `.terminate` that the operating system refuses is not an error here: on
/// Windows a console control event fails for a child that shares no console
/// with this process, and the answer in that case is the `.kill` that follows
/// anyway.
///
/// The grace is polled rather than slept through in one piece, so the common
/// case of a child that exits promptly returns promptly. The poll interval
/// grows to a few milliseconds, which is the resolution of the grace.
pub fn killWait(child: *Child, io: std.Io, grace_ms: u32) KillWaitError!Term {
    // A child that has already ended is reaped rather than signalled.
    if (try child.tryWait()) |term| return term;

    if (grace_ms > 0) {
        child.kill(.terminate) catch {};
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

    try child.kill(.kill);
    return child.wait(io);
}

//======================================================================
// The child's streams, wherever they are.
//======================================================================

/// The file the child reads its input from: the standard-input pipe when
/// `.pipes` made one, the pseudo-terminal master when the child is on a pair,
/// and `null` when the child's input is something this process does not hold.
///
/// Borrowed either way. The pipe is closed by `deinit` and the master by the
/// `Pty`.
pub fn stdinFile(child: Child) ?std.Io.File {
    if (child.stdin) |f| return f;
    if (child.pty) |m| return m.write;
    return null;
}

/// The file the child's output arrives on: the standard-output pipe when
/// `.pipes` made one, the pseudo-terminal master when the child is on a pair,
/// and `null` otherwise.
///
/// A child on a pseudo-terminal has one stream for output and error together,
/// because a terminal is one stream. That is the terminal's doing, not this
/// package's.
pub fn stdoutFile(child: Child) ?std.Io.File {
    if (child.stdout) |f| return f;
    if (child.pty) |m| return m.read;
    return null;
}

/// `stdinFile` as a buffered `std.Io.Writer`.
///
/// `buffer` must outlive the writer, and the writer must be flushed before the
/// bytes reach the child. The returned value is not a `std.Io.Writer` itself;
/// the writer is its `.interface` field, which is the standard library's shape
/// for this.
pub fn stdinWriter(child: Child, io: std.Io, buffer: []u8) ?std.Io.File.Writer {
    const f = child.stdinFile() orelse return null;
    return f.writerStreaming(io, buffer);
}

/// `stdoutFile` as a buffered `std.Io.Reader`, whose reader is the `.interface`
/// field.
///
/// `buffer` must outlive the reader.
pub fn stdoutReader(child: Child, io: std.Io, buffer: []u8) ?std.Io.File.Reader {
    const f = child.stdoutFile() orelse return null;
    return f.readerStreaming(io, buffer);
}

//======================================================================
// Run and collect.
//======================================================================

/// Everything the child wrote, and how it ended.
pub const Output = struct {
    /// What arrived on `stdoutFile`. For a child on a pseudo-terminal this is
    /// the whole terminal, output and error together, with the carriage
    /// returns a terminal inserts.
    stdout: []u8,
    /// What arrived on the standard-error pipe, or empty when there was none.
    stderr: []u8,
    /// The child produced more than `OutputOptions.max_bytes` on that stream
    /// and the rest was dropped, or the stream had not finished when
    /// `drain_ms` ran out.
    stdout_truncated: bool,
    stderr_truncated: bool,
    /// How the child ended.
    term: Term,
    /// `timeout_ms` elapsed and the child was ended by `killWait` rather than
    /// on its own.
    timed_out: bool,

    /// Frees `stdout` and `stderr` with the allocator they were collected
    /// with.
    pub fn deinit(collected: *Output, allocator: Allocator) void {
        allocator.free(collected.stdout);
        allocator.free(collected.stderr);
        collected.stdout = &.{};
        collected.stderr = &.{};
    }
};

pub const OutputOptions = struct {
    /// The most that will be kept from each stream. Bytes past it are read and
    /// dropped — the child is never blocked by a full pipe — and the matching
    /// `_truncated` flag is set.
    max_bytes: usize = 10 * 1024 * 1024,
    /// How long the child gets before `killWait` ends it. `null` waits as long
    /// as it takes.
    timeout_ms: ?u32 = null,
    /// The grace `killWait` gives on a timeout, in the same sense as its own
    /// parameter.
    grace_ms: u32 = 200,
    /// How long to keep reading after the child has ended.
    ///
    /// A stream normally finishes the moment the child does, because the child
    /// held the only other end. It does not when something the child started
    /// inherited that end and is still running — and then a read that waited
    /// for end of file would wait for the grandchild, which is not what a call
    /// with a timeout on it means. So the drain is bounded too, and a stream
    /// that has not finished is reported as truncated.
    drain_ms: u32 = 1000,
};

pub const OutputError = error{
    OutOfMemory,
    /// A stream could not be read, for a reason other than ending.
    ReadFailed,
    /// The `std.Io` implementation cannot run the readers alongside the wait.
    /// Two streams have to be read at once or a full pipe deadlocks the child.
    ConcurrencyUnavailable,
} || WaitError || TryWaitError || WaitTimeoutError || KillError || std.Io.Cancelable;

/// Runs the child to the end and collects what it wrote.
///
/// The two streams are read on tasks of their own, because a child that fills
/// one pipe while the parent is reading the other deadlocks, and because a
/// timeout that a blocked read can defeat is not a timeout. That is also why
/// `allocator` must be safe to use from more than one thread when the
/// `std.Io` implementation runs tasks on threads: the collected bytes are
/// grown on those tasks.
///
/// The child is reaped when this returns, whether it ended on its own or was
/// killed, so `wait` afterwards answers from the same term. `deinit` is still
/// the caller's to make.
pub fn output(
    child: *Child,
    io: std.Io,
    allocator: Allocator,
    options: OutputOptions,
) OutputError!Output {
    var out: Collector = .init;
    var err: Collector = .init;
    errdefer out.list.deinit(allocator);
    errdefer err.list.deinit(allocator);

    var group: std.Io.Group = .init;
    // Unconditional: the group owns resources as soon as one task starts, and
    // a reader blocked on a stream that never ends is exactly what the bounded
    // drain below is for.
    defer group.cancel(io);

    // A stream this process does not hold -- an inherited one, or the standard
    // error of a child on a pseudo-terminal, which has none -- is finished
    // before it starts. Saying so here is what keeps the drain below from
    // waiting out its budget and then calling an empty stream truncated.
    if (child.stdoutFile()) |f| {
        try group.concurrent(io, collect, .{ io, allocator, f, options.max_bytes, &out });
    } else out.done.store(true, .release);
    if (child.stderr) |f| {
        try group.concurrent(io, collect, .{ io, allocator, f, options.max_bytes, &err });
    } else err.done.store(true, .release);

    var timed_out = false;
    const term = term: {
        const timeout_ms = options.timeout_ms orelse break :term try child.wait(io);
        if (try child.waitTimeout(io, timeout_ms)) |term| break :term term;
        timed_out = true;
        break :term try child.killWait(io, options.grace_ms);
    };

    // The child is gone, so its ends of the pipes are closed and the readers
    // are finishing. Anything still holding a stream open is not the child,
    // and is not what this call promised to wait for.
    var drained_ms: u32 = 0;
    while (drained_ms < options.drain_ms) {
        if (out.done.load(.acquire) and err.done.load(.acquire)) break;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
        drained_ms += 2;
    }
    // Joins the tasks, so the lists below are this task's alone again.
    group.cancel(io);

    if (out.failed or err.failed) return error.ReadFailed;
    const stdout_bytes = try out.list.toOwnedSlice(allocator);
    errdefer allocator.free(stdout_bytes);
    const stderr_bytes = try err.list.toOwnedSlice(allocator);
    return .{
        .stdout = stdout_bytes,
        .stderr = stderr_bytes,
        .stdout_truncated = out.truncated or !out.done.load(.acquire),
        .stderr_truncated = err.truncated or !err.done.load(.acquire),
        .term = term,
        .timed_out = timed_out,
    };
}

/// One stream's worth of collected bytes, shared between the task reading it
/// and the task that started it. `done` is the handshake; everything else is
/// read only after the group has joined.
const Collector = struct {
    list: std.ArrayList(u8),
    truncated: bool,
    failed: bool,
    done: std.atomic.Value(bool),

    const init: Collector = .{
        .list = .empty,
        .truncated = false,
        .failed = false,
        .done = .init(false),
    };
};

fn collect(
    io: std.Io,
    allocator: Allocator,
    f: std.Io.File,
    max_bytes: usize,
    into: *Collector,
) std.Io.Cancelable!void {
    defer into.done.store(true, .release);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = f.readStreaming(io, &.{&buffer}) catch |e| switch (e) {
            // A pseudo-terminal whose child is gone reports this where a pipe
            // reports end of stream. Both mean the same thing here.
            error.EndOfStream, error.InputOutput => return,
            error.Canceled => return error.Canceled,
            else => {
                into.failed = true;
                return;
            },
        };
        if (n == 0) return;
        const room = max_bytes -| into.list.items.len;
        if (room == 0) {
            // Still read, so the child is never blocked on a full pipe; just
            // stop keeping it.
            into.truncated = true;
            continue;
        }
        const keep = @min(room, n);
        if (keep < n) into.truncated = true;
        into.list.appendSlice(allocator, buffer[0..keep]) catch {
            into.failed = true;
            return;
        };
    }
}

//======================================================================
// Windows.
//======================================================================

fn closeHandles(child: *Child) void {
    windows.CloseHandle(child.id);
    windows.CloseHandle(child.thread);
    child.handles_open = false;
}

fn tryWaitWindows(child: *Child) TryWaitError!?Term {
    switch (win32.WaitForSingleObject(child.id, 0)) {
        win32.WAIT_OBJECT_0 => {},
        win32.WAIT_TIMEOUT => return null,
        else => return windows.unexpectedError(windows.GetLastError()),
    }
    var code: win32.DWORD = undefined;
    const term: Term = if (win32.GetExitCodeProcess(child.id, &code) != .FALSE)
        .{ .exited = @truncate(code) }
    else
        .{ .unknown = 0 };
    child.closeHandles();
    child.term = term;
    return term;
}

fn killWindows(child: *Child, signal: Signal) KillError!void {
    const event: win32.DWORD = switch (signal) {
        .interrupt => win32.CTRL_C_EVENT,
        .terminate => win32.CTRL_BREAK_EVENT,
        .kill => return child.terminateWindows(),
    };
    const group = child.pgid orelse switch (signal) {
        // There is no console control event that reaches a process outside a
        // group, and no catchable Windows equivalent of `SIGTERM`. `.terminate`
        // falls back to the uncatchable one, which is what it documents;
        // `.interrupt` has nothing honest to fall back to.
        .interrupt => return error.Unsupported,
        else => return child.terminateWindows(),
    };
    if (win32.GenerateConsoleCtrlEvent(event, group) != .FALSE) return;
    return switch (windows.GetLastError()) {
        .ACCESS_DENIED => error.PermissionDenied,
        // The group is gone, which is the Windows spelling of "the child ended
        // between the check and here".
        .INVALID_PARAMETER, .INVALID_HANDLE => {},
        else => |err| windows.unexpectedError(err),
    };
}

fn terminateWindows(child: *Child) KillError!void {
    if (win32.TerminateProcess(child.id, 1) != .FALSE) return;
    return switch (windows.GetLastError()) {
        .ACCESS_DENIED => {
            // Usually this means the process has already exited; the reap
            // below is what tells the two apart.
            if ((child.tryWait() catch null) != null) return;
            return error.PermissionDenied;
        },
        .INVALID_HANDLE => {},
        else => |err| windows.unexpectedError(err),
    };
}

//======================================================================
// POSIX.
//======================================================================

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

test {
    if (is_windows) {
        _ = @import("child_windows.zig");
    } else {
        _ = @import("child_posix.zig");
    }
}
