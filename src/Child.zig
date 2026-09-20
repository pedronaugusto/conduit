//! A child process, running on a pseudo-terminal or on pipes.
//!
//! `spawn` starts it; `wait`, `tryWait`, `kill`, `killWait` and `output` are
//! what a parent does with the result. The streams the child was given are
//! owned by the `Child` when the `Child` created them (`.pipes`), and by the
//! caller when the caller supplied them (`.pty`, `stderr_to`); `deinit` closes
//! only the former.
//!
//! One task at a time may call the methods of a given `Child`, with one
//! exception that is the whole point of `Reaper`: a wait may be in flight on
//! another task while the owner calls `kill`, `killWait`, `wait` or `tryWait`.
//! Exactly one of them is inside the operating system's wait at a time and it
//! publishes the term to the others, so the child is reaped once however many
//! ask. `output` is the supported way to read two streams at once.
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

const Expect = @import("Expect.zig");
const Pty = @import("Pty.zig");
const trace = @import("trace.zig");
const handles = @import("handles.zig");
const tty = @import("tty.zig");

const is_windows = builtin.os.tag == .windows;
const win32 = if (is_windows) @import("win32.zig") else struct {};
const tree = if (is_windows) struct {} else @import("tree.zig");
const wait_for = if (is_windows) struct {} else @import("wait.zig");

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
/// Windows only: the job object holding the child and everything it starts.
///
/// This is what makes `kill` and `killWait` reach the whole tree there, the
/// way a signal to a process group does on POSIX. `null` once `deinit` has
/// closed it, and closing it ends whatever is still in it — see `deinit`.
job: if (is_windows) ?windows.HANDLE else void,
/// Windows only: the completion port the job posts to, which is how
/// `waitTree` learns that the job has emptied. Closed alongside `job`.
job_port: if (is_windows) ?windows.HANDLE else void,
/// Windows only: whether the job has been heard to empty. `waitTree` sets it,
/// and answers from it thereafter: the message is posted once and taking it
/// off the port consumes it.
tree_ended: if (is_windows) bool else void,
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
///
/// Written once, by whichever call reaps the child, and published through
/// `reaped`. **Read it with `tryWait`**, which does that load: a `Reaper` may
/// be the one that writes it, and a plain read of the field from another task
/// is then a race on a value that is not a single word.
term: ?Term,
/// Whether `term` has been written and may be read.
///
/// Stored with release ordering after `term`, and loaded with acquire
/// ordering before every read of it, so that a task which sees a term sees
/// the whole of it. That pairing is what makes `Reaper` legal alongside
/// `kill`, `killWait` and `tryWait` on the same `Child`.
reaped: std.atomic.Value(bool) = .init(false),
/// Whether some task is inside the operating system's wait for this child.
///
/// Exactly one may be: two waits on one child are one status and one `ECHILD`,
/// and the second is a child nobody can account for. Whoever does not take
/// this reads the answer the one who did publishes — `tryWait` by saying the
/// child is still running, `wait` by waiting for the answer to appear.
reaping: std.atomic.Value(bool) = .init(false),

/// How a child process ended.
///
/// This is `std.process.Child.Term` rather than a parallel type of this
/// package's own, so a program can hand the result to code that already speaks
/// the standard library's vocabulary. `.stopped` is never produced here:
/// neither `wait` nor `tryWait` asks for stop notifications, and Windows has
/// no such state. `.signal` is POSIX-only for the same reason — a Windows
/// process that is terminated reports the exit code it was terminated with.
///
/// **A Windows exit code is a `DWORD` and `Term.exited` is a byte**, so what
/// arrives there is the low byte of it. That matters because the codes Windows
/// produces itself are not small: a console process ended by a control event
/// it does not handle exits with the system's control-exit status, an
/// `NTSTATUS` in the `0xC000_0000` range, and the byte that reaches `Term` is
/// the last two digits of it. The truncation is `std.process.Child.wait`'s,
/// and `tryWait` does the same thing for the same reason: the two calls must
/// not report a child differently.
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
/// `"TERM"`, `"KILL"`. `null` if a signal did not end it, and `null` too for a
/// signal this system has no name for — a real-time signal is a number and
/// nothing else, and asking a non-exhaustive enum for the name of a value
/// nobody named is illegal behaviour rather than an answer. The number is in
/// the `Term` either way.
///
/// Always `null` on Windows, where `Term.signal` is never produced: a
/// terminated process there reports the exit code it was terminated with, and
/// `killWait` uses 1. A portable program that wants to say why a child stopped
/// has to accept that the Windows answer is a number.
pub fn signalName(term: Term) ?[]const u8 {
    return switch (term) {
        .signal, .stopped => |signal| std.enums.tagName(posix.SIG, signal),
        else => null,
    };
}

/// Which of the child's three standard streams get pipes.
///
/// A stream that is not piped is inherited from the parent, on both systems.
/// Piping only what is read avoids the deadlock of a full pipe nobody drains.
pub const PipeOptions = struct {
    stdin: bool = true,
    stdout: bool = true,
    stderr: bool = true,
};

/// What one of the child's three standard streams is connected to.
///
/// The five are the standard library's — `std.process.SpawnOptions.StdIo` has
/// the same ones under the same names — because a caller who already knows
/// that vocabulary should not have to learn a second one here.
pub const Stream = union(enum) {
    /// The parent's own descriptor for that stream.
    ///
    /// A stream the parent does not have cannot be inherited, and on Windows a
    /// process may genuinely have none — a service, or a program started with
    /// no console and no redirection. That slot then behaves as `.close`.
    inherit,
    /// A file the caller opened. Borrowed: `deinit` does not close it, and it
    /// must stay open until `spawn` returns.
    ///
    /// The terminal end of a pair is one of these — `pty.slaveFile()` — which
    /// is how a child is given a terminal for one stream and a pipe or a file
    /// for the others. POSIX only for that particular file: a pseudoconsole is
    /// not a stream, and `Pty.slaveFile` is a compile error on Windows.
    file: std.Io.File,
    /// The null device: `/dev/null`, or `NUL` on Windows. One handle serves
    /// every stream that asks for it.
    ignore,
    /// A pipe `spawn` creates and the `Child` owns, reachable afterwards as
    /// `child.stdin`, `child.stdout` or `child.stderr`.
    pipe,
    /// Nothing: the child starts with no descriptor at that number.
    ///
    /// A child that writes to it gets `EBADF` on POSIX and an invalid handle
    /// on Windows, and — worse, and the reason this is never a default — the
    /// next file such a child opens may be given that number, so its output
    /// arrives somewhere nobody meant. For the rare program that requires it,
    /// not for tidiness: `.ignore` is what "I do not want this output" means.
    close,
};

/// The child's three standard streams, each named on its own.
pub const Streams = struct {
    stdin: Stream = .inherit,
    stdout: Stream = .inherit,
    stderr: Stream = .inherit,
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
    /// Each stream named on its own.
    ///
    /// The general case. `.inherit`, `.ignore` and `.pipes` are each some
    /// value of this one, kept because they are the three shapes almost every
    /// spawn wants and are shorter to write; `perStream` is where they turn
    /// into it.
    streams: Streams,

    /// The three streams this shape means, in descriptor order.
    ///
    /// `.pty` has no answer and is not asked: a pseudoconsole is attached to a
    /// process rather than handed to it on a descriptor, so on Windows it is
    /// not a per-stream choice at all.
    pub fn perStream(stdio: Stdio) [3]Stream {
        return switch (stdio) {
            .pty => unreachable,
            .inherit => .{ .inherit, .inherit, .inherit },
            .ignore => .{ .ignore, .ignore, .ignore },
            .pipes => |which| .{
                if (which.stdin) .pipe else .inherit,
                if (which.stdout) .pipe else .inherit,
                if (which.stderr) .pipe else .inherit,
            },
            .streams => |streams| .{ streams.stdin, streams.stdout, streams.stderr },
        };
    }
};

/// Everything `spawn` needs.
pub const SpawnOptions = struct {
    /// The program and its arguments.
    ///
    /// On POSIX `argv[0]` is the program: if it contains a `/` it is a path,
    /// and otherwise it is looked up in `PATH`. On Windows the list is
    /// serialised into the one command-line string `CreateProcessW` takes, by
    /// the rules `CommandLineToArgvW` parses; a bare program is resolved first
    /// when a custom environment selects its PATH. Must not be empty.
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
    /// The one-case version of `Stdio.streams`, kept because it is the case
    /// that comes up: `.{ .streams = .{ .stderr = .{ .file = f } } }` says the
    /// same thing about all three streams at once. Applied last, so it wins
    /// over whatever `stdio` said about standard error.
    ///
    /// Not available together with `.pty` on Windows, where it is
    /// `error.Unsupported`: a pseudoconsole is attached through an attribute
    /// list, and Windows documents that as incompatible with naming the
    /// child's standard handles. On POSIX the two compose, because there the
    /// terminal is a descriptor like any other.
    stderr_to: ?std.Io.File = null,
    /// The user, group and file-creation mask the child runs with. POSIX
    /// only: anything set here is `error.Unsupported` on Windows.
    credentials: Credentials = .{},
    /// Resource limits to set in the child, in order, before `execve`.
    ///
    /// Applied before `credentials`, so a privileged parent can still raise a
    /// hard limit for a child it is about to hand to somebody else. The list
    /// is read by the fork child and nothing is copied, so it must stay valid
    /// until `spawn` returns; it is not retained past that.
    ///
    /// POSIX only: a non-empty list is `error.Unsupported` on Windows.
    resource_limits: []const ResourceLimit = &.{},
    /// What the child does with the descriptors above 2 that this process
    /// holds.
    fd_policy: FdPolicy = .close_on_exec,
    /// What the child and everything it starts may use. Windows only:
    /// anything set here is `error.Unsupported` elsewhere.
    job_limits: JobLimits = .{},
};

/// What the job object holding the child and its tree may use. Windows only.
///
/// This is the Windows answer to `resource_limits`, and it is a different
/// answer: a POSIX limit is set on a process by itself between a fork and an
/// exec, and a job limit is set on the container the child and everything it
/// starts live in. So it bounds the *tree* rather than the child, which is
/// more than `setrlimit` gives and is the reason the two are separate options
/// rather than one with a translation in the middle.
///
/// The job is created for every child on that system whether or not anything
/// here is set — it is what makes `kill` reach the tree — so a limit costs
/// nothing but the call that sets it. A field left `null` is not limited.
///
/// A `JobLimits` with anything set is `error.Unsupported` on POSIX, where
/// `resource_limits` is the option that exists.
pub const JobLimits = struct {
    /// The most memory any one process in the job may commit, in bytes.
    /// `JOB_OBJECT_LIMIT_PROCESS_MEMORY`.
    process_memory_bytes: ?usize = null,
    /// The most memory every process in the job may commit between them, in
    /// bytes. `JOB_OBJECT_LIMIT_JOB_MEMORY`.
    job_memory_bytes: ?usize = null,
    /// The most processes the job may hold at once, the child itself
    /// included. `JOB_OBJECT_LIMIT_ACTIVE_PROCESS`: a process the job is
    /// already full for does not start, so a child given 1 cannot start
    /// anything.
    active_processes: ?u32 = null,
    /// A hard ceiling on the share of the whole machine's processor time the
    /// job may use, in hundredths of a percent: 5_000 is 50% of all available
    /// CPU, however many processors the machine has.
    /// `JobObjectCpuRateControlInformation` with a hard cap. Must be between 1
    /// and 10_000 inclusive.
    cpu_rate: ?u32 = null,

    /// Whether any of them asks for a limit. `spawn` sets nothing at all when
    /// this is false, which is what keeps the default free.
    pub fn any(limits: JobLimits) bool {
        return limits.process_memory_bytes != null or
            limits.job_memory_bytes != null or
            limits.active_processes != null or
            limits.cpu_rate != null;
    }
};

/// What a child is given of the descriptors above 2 that the parent holds.
///
/// A descriptor is inherited unless something says otherwise, and on POSIX the
/// something is close-on-exec. Every descriptor this package opens for a spawn
/// has it, and so does every descriptor the standard library opens — but a
/// program that opened a socket, a log or a lock file with plain `open` is
/// handing a copy to every child it starts afterwards, and a child that keeps
/// one open keeps the far end of it waiting.
///
/// On Windows there is no choice to make. A child is given the handles named
/// in an attribute list and nothing else, which is `close_all` already; both
/// values mean the same thing there.
pub const FdPolicy = enum {
    /// Inherit whatever close-on-exec allows. The default, and what a spawn is
    /// without an opinion.
    close_on_exec,
    /// Close every descriptor above 2 in the child before the program starts,
    /// whatever its flags say. The child gets its three standard streams and
    /// nothing else.
    ///
    /// `close_range` on Linux, which is one call; elsewhere a loop up to the
    /// descriptor limit, which is thousands of calls that fail and is
    /// therefore worth asking for rather than doing by default.
    close_all,
};

/// The user, group and file-creation mask a child starts with. POSIX only.
///
/// A field left `null` is not changed, and the child keeps what it inherited.
/// A `Credentials` with anything set is `error.Unsupported` on Windows, where
/// a process runs as the token it is created with and changing that is a
/// different operation with a different shape.
///
/// These can only be set between `fork` and `execve`, which is the reason they
/// are options here rather than something a caller could do around the call:
/// this process changing its own user before spawning would change it for
/// everything else this process goes on to do.
///
/// **Supplementary groups are the parent's.** Nothing here calls `setgroups`:
/// deciding which groups a user should have means reading the group database,
/// which is not something a fork child may do. So `uid` alone lowers a child's
/// user without lowering the groups that user was in here, and a caller who
/// needs those dropped too should start the child through a program that does
/// it — `su`, or one of their own.
pub const Credentials = struct {
    /// The user the child runs as. `setuid` in the fork child.
    uid: ?posix.uid_t = null,
    /// The child's primary group. `setgid` in the fork child, before `setuid`:
    /// after the user has been lowered there may be no privilege left to
    /// change the group with.
    gid: ?posix.gid_t = null,
    /// The mode bits taken away from files the child creates. `umask` in the
    /// fork child, which cannot fail.
    umask: ?posix.mode_t = null,

    /// Whether any of the three asks for a change. `spawn` does nothing at all
    /// when this is false, which is what keeps the default free.
    pub fn any(credentials: Credentials) bool {
        return credentials.uid != null or
            credentials.gid != null or
            credentials.umask != null;
    }
};

/// One resource limit to set in the child before `execve`. POSIX only.
///
/// The other thing that can only be done between `fork` and `execve`: a limit
/// belongs to a process, so a parent that set it on itself would be setting it
/// on everything it does afterwards as well, and `execve` carries what the
/// child had into the program it becomes.
///
/// Both fields are the operating system's own types, because there is no
/// portable set of resources to enumerate and inventing one would only hide
/// what a system offers. `std.posix.rlimit_resource` is `.NOFILE`, `.CPU`,
/// `.AS` and whatever else the target has; `std.posix.rlimit` is the soft and
/// hard pair `setrlimit` takes. Neither exists as anything but `void` on
/// Windows, where a non-empty list is `error.Unsupported`.
pub const ResourceLimit = struct {
    /// Which resource to limit.
    resource: posix.rlimit_resource,
    /// The soft limit the child starts with, and the hard limit it may raise
    /// the soft one back to. A soft limit above the hard one is refused by the
    /// operating system, and a hard limit above the one this process already
    /// has needs privilege.
    limit: posix.rlimit,
};

/// Where the `PATH` that resolves a bare `argv[0]` comes from.
///
/// On Windows the package resolves `.child_environ` before `CreateProcessW`,
/// because that call otherwise searches the parent's PATH even when given a
/// different environment. The other two remain `error.Unsupported` there.
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
    /// Not `ResourceLimitsFailed`, which is `resource_limits` being refused.
    ResourceLimitReached,
    /// `.ignore` was asked for and the null device could not be opened.
    NoDevice,
    /// POSIX: the child could not be put into its own process group or
    /// session. With `detach` and `.pty`, the most likely cause is that the
    /// process was already a session leader.
    DetachFailed,
    /// Windows: the child could not be put into its job object, so `kill`
    /// could not have reached what the child started. Jobs have nested since
    /// Windows 8 and this package's floor is Windows 10, so the way to get
    /// here is a job that forbids it — and rather than start a child whose
    /// tree it cannot end, `spawn` ends the child it just made and says so.
    JobAssignmentFailed,
    /// POSIX: the pseudo-terminal could not be made the child's controlling
    /// terminal, usually because it is already the controlling terminal of
    /// another session.
    ControllingTerminalFailed,
    /// POSIX: `credentials` could not be applied. Almost always because this
    /// process is not privileged enough to become that user or group; the
    /// child did not start.
    CredentialsFailed,
    /// POSIX: one of `resource_limits` could not be set — a soft limit above
    /// its hard limit, or a hard limit above the one this process has and no
    /// privilege to raise it. Not `ResourceLimitReached`, which is this
    /// process running out of room to start a child at all.
    ResourceLimitsFailed,
    /// `cwd` does not exist or is not a directory.
    BadWorkingDirectory,
    /// The combination asked for has no meaning on this system: `stderr_to`
    /// together with `.pty` on Windows, a `path_search` other than
    /// `.child_environ` there, `credentials` or `resource_limits` anywhere on
    /// Windows, or `job_limits` anywhere else. The option that cannot be
    /// honoured says so.
    Unsupported,
    /// Windows: `job_limits.cpu_rate` was outside its inclusive 1–10,000
    /// range. No child was started.
    InvalidJobLimit,
} || std.Io.UnexpectedError;

/// What an `execve` that failed means, as one of `SpawnError`.
///
/// Both spawn paths on POSIX end here: the fork child reports the number it
/// got back over its pipe, and `posix_spawn` returns it.
pub fn execError(err: posix.E) SpawnError {
    return switch (err) {
        .ACCES => error.AccessDenied,
        .PERM => error.PermissionDenied,
        .NOENT => error.FileNotFound,
        .NOTDIR => error.NotDir,
        .ISDIR => error.IsDir,
        .NAMETOOLONG => error.NameTooLong,
        .LOOP => error.SymLinkLoop,
        .NOEXEC => error.InvalidExe,
        .TXTBSY => error.FileBusy,
        .NOMEM, .@"2BIG" => error.SystemResources,
        else => posix.unexpectedErrno(err),
    };
}

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
    // A job object is what these bound, and POSIX has no such container.
    // `resource_limits` is the option that exists here.
    if (options.job_limits.any()) return error.Unsupported;
    return @import("child_posix.zig").spawn(io, allocator, options);
}

/// Closes the streams this `Child` owns: the pipes `spawn` created, if any,
/// and on Windows the process and thread handles when the child was never
/// reaped, the job object, and the port the job reports on.
///
/// Streams the caller supplied are left alone.
///
/// **On Windows this ends whatever is left of the child's tree.** The job is
/// created with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so letting go of the
/// `Child` lets go of everything the child started — including anything that
/// outlived the child itself. That is a difference from POSIX, where `deinit`
/// signals nothing and a grandchild of a reaped child keeps running: Windows
/// has a container for a tree and POSIX has only an address to send signals
/// to. A program that wants a grandchild to outlive it on Windows has to
/// arrange that itself; this package will not leave one behind by accident.
/// `waitTree` is how to watch that happen, and it has to be asked before this:
/// the job is what reports, and this is what closes it.
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
        child.closeJob();
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
/// waits first and reads afterwards waits forever. It is not a full buffer
/// that does it but any unread byte — a hundred of them was enough to
/// reproduce it here — so "the child only prints a line" is not a way out.
/// `output` is the version of this that reads and waits at once, and `Proxy`
/// is the version that keeps reading.
pub fn wait(child: *Child, io: std.Io) WaitError!Term {
    // Another task may already be inside the wait -- a `Reaper`, in practice.
    // It will publish the term, and a second wait on the same child would only
    // take the status away from it; so this waits for the answer instead, and
    // asks for the wait itself again each time round, because the task that
    // had it may have been cancelled before it reaped anything.
    var interval_ms: u32 = 1;
    while (true) {
        if (child.settled()) |term| return term;
        if (child.claimReap()) break;
        try std.Io.sleep(io, .fromMilliseconds(interval_ms), .awake);
        interval_ms = @min(interval_ms * 2, 4);
    }
    defer child.releaseReap();
    if (child.settled()) |term| return term;

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
    // from closing them a second time, and it is written before the publish
    // below so that whoever reads the term reads this too.
    if (is_windows) child.handles_open = false;
    child.publish(term);
    return term;
}

//======================================================================
// One reap, whoever asks for it.
//======================================================================

/// The term, if whoever reaped the child has published it.
///
/// The acquire load pairs with the release store in `publish`, so a caller
/// that sees a term sees every field the reaper wrote before it.
fn settled(child: *const Child) ?Term {
    if (!child.reaped.load(.acquire)) return null;
    return child.term;
}

/// Records how the child ended and lets everyone else read it.
fn publish(child: *Child, term: Term) void {
    child.term = term;
    child.reaped.store(true, .release);
}

/// Takes the right to be inside the operating system's wait for this child.
fn claimReap(child: *Child) bool {
    return child.reaping.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
}

fn releaseReap(child: *Child) void {
    child.reaping.store(false, .release);
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
/// **How it waits.** On a handle the operating system makes ready the moment
/// the child ends: a `pidfd` on Linux, a kqueue registration on Darwin and
/// the BSDs, and the process handle itself on Windows. So a child that ends
/// is noticed then and not at the end of an interval — which used to cost a
/// millisecond and a half on every wait. Where there is no such handle, the
/// wait asks again on a growing interval as it always did. Either way it is
/// a cancelation point.
///
/// `null` while another task holds the wait for this child -- a `Reaper` --
/// and it has not published a term by the deadline: the child is not this
/// call's to reap, and it says the same thing it says about a child that is
/// still running.
pub fn waitTimeout(child: *Child, io: std.Io, timeout_ms: u32) WaitTimeoutError!?Term {
    const deadline: Deadline = .in(io, timeout_ms);
    if (child.settled()) |term| return term;
    if (!child.claimReap()) return child.settledWithin(io, deadline);
    defer child.releaseReap();
    return child.reapWithin(io, deadline);
}

/// A deadline, however this system counts to one. `Deadline` does not exist on
/// Windows, where nothing here needs to count.
const Deadline = if (is_windows) struct {
    at: std.Io.Clock.Timestamp,

    fn in(io: std.Io, milliseconds: u32) @This() {
        return .{ .at = .fromNow(io, .{
            .raw = .fromMilliseconds(milliseconds),
            .clock = .awake,
        }) };
    }

    fn remainingMs(deadline: @This(), io: std.Io) u32 {
        const left = deadline.at.durationFromNow(io).raw.toMilliseconds();
        if (left <= 0) return 0;
        return std.math.lossyCast(u32, left);
    }
} else wait_for.Deadline;

/// How long one wait on the child's process handle lasts before the caller is
/// given a chance to notice it has been cancelled. `wait.zig` keeps the same
/// number for the handles it opens, and is POSIX-only.
const windows_slice_ms: u32 = 5;

/// Reaps the child if it ends before `deadline`. The caller holds the reap.
///
/// This is the one place a bounded wait is written: `waitTimeout` is it with
/// the caller's timeout, and `killWait`'s grace is it with the grace. The two
/// used to be the same loop copied out twice.
fn reapWithin(child: *Child, io: std.Io, deadline: Deadline) WaitTimeoutError!?Term {
    if (try child.tryWaitClaimed()) |term| return term;

    if (is_windows) {
        // The child's own process handle is signalled the moment it ends, and
        // `WaitForSingleObject` takes the deadline directly. Asking again on a
        // sleeping interval instead cost a whole scheduler tick: the shortest
        // sleep Windows grants is about fifteen milliseconds, so a child that
        // ended in nine was not noticed until sixteen.
        while (true) {
            const left = deadline.remainingMs(io);
            if (left == 0) break;
            // A blocking wait on a handle is not a cancelation point, so it is
            // spent in slices and cancelation is asked about between them.
            switch (win32.WaitForSingleObject(child.id, @min(left, windows_slice_ms))) {
                win32.WAIT_TIMEOUT => {},
                // Ended, or a handle that cannot be waited on: either way the
                // reap below is what says so.
                else => break,
            }
            try std.Io.checkCancel(io);
        }
        return child.tryWaitClaimed();
    }

    if (!is_windows) {
        if (wait_for.Watch.open(child.id)) |watch| {
            defer watch.close();
            while (true) {
                const left = deadline.remainingMs(io);
                if (left == 0) break;
                // A blocking wait on a handle is not a cancelation point, so
                // it is spent in slices and cancelation is asked about
                // between them.
                if (watch.ended(@min(left, wait_for.slice_ms))) return child.reapEnded(io, deadline);
                try std.Io.checkCancel(io);
            }
            return child.tryWaitClaimed();
        }
    }

    // Nothing to wait on: ask again, on an interval that grows to a few
    // milliseconds so a child that ends promptly is noticed promptly and one
    // that does not is not asked about a thousand times a second.
    var interval_ms: u32 = 1;
    while (true) {
        const left = deadline.remainingMs(io);
        if (left == 0) return child.tryWaitClaimed();
        try std.Io.sleep(io, .fromMilliseconds(@min(interval_ms, left)), .awake);
        if (try child.tryWaitClaimed()) |term| return term;
        interval_ms = @min(interval_ms * 2, 4);
    }
}

/// Waits for whoever holds the reap to publish a term, until `deadline`.
///
/// The rare path, and the reason it asks again rather than waiting on a
/// handle: what it is waiting for is another task's publish, not the child's
/// end. The wait is asked for again each time round, because the task that had
/// it may have been cancelled before it reaped anything.
fn settledWithin(child: *Child, io: std.Io, deadline: Deadline) WaitTimeoutError!?Term {
    var interval_ms: u32 = 1;
    while (true) {
        if (child.settled()) |term| return term;
        if (child.claimReap()) {
            defer child.releaseReap();
            return child.reapWithin(io, deadline);
        }
        const left = deadline.remainingMs(io);
        if (left == 0) return null;
        try std.Io.sleep(io, .fromMilliseconds(@min(interval_ms, left)), .awake);
        interval_ms = @min(interval_ms * 2, 4);
    }
}

pub const TryWaitError = error{
    /// Something outside this package reaped the child, so there is no status
    /// left for anyone to report: a `SIGCHLD` handler of the program's own, or
    /// `SIGCHLD` set to `SIG_IGN`, which is the program telling the system to
    /// reap its children for it. POSIX only.
    ///
    /// This package has to be the one that reaps, and once it is not, the
    /// child is gone and how it ended cannot be recovered.
    ReapedElsewhere,
} || std.Io.UnexpectedError;

/// Reaps the child if it has already ended, and returns `null` if it has not.
///
/// Never blocks. Once this has returned a term, `wait` returns the same one.
///
/// `null` while a `Reaper` — or any other task — is inside the wait for this
/// child, whether or not the child has ended by then: the task that holds the
/// wait is the one that reaps, and this answers from the term it publishes as
/// soon as there is one. A `null` was always a snapshot; that is the one case
/// where it can be a moment out of date.
pub fn tryWait(child: *Child) TryWaitError!?Term {
    if (child.settled()) |term| return term;
    // Another task is inside the wait. The child is still running as far as
    // anything that has not been told otherwise is concerned, and taking the
    // status out from under the wait in flight is the one thing that must not
    // happen here.
    if (!child.claimReap()) return null;
    defer child.releaseReap();
    return child.tryWaitClaimed();
}

/// `tryWait` for a caller that already holds the reap.
fn tryWaitClaimed(child: *Child) TryWaitError!?Term {
    if (child.settled()) |term| return term;
    if (is_windows) return child.tryWaitWindows();

    var status: c_int = undefined;
    while (true) {
        const rc = c.waitpid(child.id, &status, c.W.NOHANG);
        if (rc == 0) return null;
        if (rc > 0) {
            const term = statusToTerm(@bitCast(status));
            child.publish(term);
            return term;
        }
        switch (c.errno(rc)) {
            .INTR => continue,
            .CHILD => return error.ReapedElsewhere,
            else => |err| return posix.unexpectedErrno(err),
        }
    }
}

/// Reap a child the watch has said is ending.
///
/// The note is posted as the process leaves and not as it becomes something
/// `waitpid` will hand over: on Darwin the two are a moment apart, and under
/// a busy process table the moment is long enough for `WNOHANG` to answer
/// "still running" once or twice. Taking that answer as a timeout reported a
/// child that had already ended as one that never did. So the reap is asked
/// for again, on a short interval, until the deadline the caller gave.
fn reapEnded(child: *Child, io: std.Io, deadline: Deadline) WaitTimeoutError!?Term {
    var tries: u32 = 0;
    while (true) {
        if (try child.tryWaitClaimed()) |term| return term;
        const left = deadline.remainingMs(io);
        if (left == 0) return null;
        // The first few asks give the kernel the scheduler tick it needs
        // without sleeping; after that, a millisecond at a time.
        if (tries < 8) std.Thread.yield() catch {} else try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        tries += 1;
        try std.Io.checkCancel(io);
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
    /// A console control event also needs a console: a Windows process that
    /// has none — a service, or a program run by a build or test harness —
    /// has nothing to address one to, and this reports success while reaching
    /// nobody. `.terminate` and `.kill` do not depend on a console.
    interrupt,
    /// Ask the child to stop, in a way it can catch and clean up after.
    /// POSIX: `SIGTERM`. Windows: `CTRL_BREAK_EVENT` to the child's process
    /// group when it has one — and, when it does not, `TerminateProcess`,
    /// which it cannot catch. Windows offers nothing else: there is no
    /// catchable request that reaches a process outside your console.
    ///
    /// A child that ends because of the console control event chooses its own
    /// exit code, and a child that does not handle the event gets the system's
    /// control-exit status. So `.terminate` on Windows is the one request here
    /// whose outcome this package does not decide; `Term` says what a byte of
    /// such a status looks like.
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
    /// POSIX: the descendant walk could not retain every stable process
    /// identity, so no partial tree signal was sent.
    OutOfMemory,
    /// This process may not signal the child.
    PermissionDenied,
    /// Windows: `.interrupt` was asked for and the child has no process group
    /// of its own, so there is nothing a console control event can be
    /// addressed to. Spawn with `detach` to get one.
    Unsupported,
} || std.Io.UnexpectedError;

/// Asks the child to stop, with `signal`.
///
/// **What it reaches.** On Windows every child is in a job object of its own,
/// and `.kill` ends the job, so it reaches the whole tree whether or not the
/// child was detached.
///
/// On POSIX there is no container for a tree, and this reaches three things:
/// the child, the child's process group when `detach` made one, and every
/// descendant the operating system will name — from one `/proc` process-table
/// pass on Linux and from `proc_listchildpids` on Darwin. The descendants are
/// signalled deepest first and before the child, because a process signalled
/// before the ones below it leaves them orphaned, and an orphan belongs to
/// `init` and is related to nothing.
///
/// So a descendant that gave itself a process group of its own with `setsid`
/// or `setpgid` is still reached, and — for `.kill`, which is the request that
/// promises to leave nothing behind — so is one that was started while the
/// first signal was being delivered: the group and the walk are asked again
/// until a pass names nothing. What is not reached on any system is a process
/// that has *both* left the group and been orphaned before anything looked,
/// and on the BSDs and illumos, which name a process's children only through
/// the whole process table, the process group is the whole of the reach.
///
/// `.terminate` and `.interrupt` ask once. They are requests a program is
/// meant to act on, and sending one twice to a program that is cleaning up is
/// not containment.
///
/// A child that has already ended is not signalled, because its name no longer
/// belongs to it; that case is not an error, and it may reap the child as a
/// side effect. On Windows that also means nothing else in its job is ended:
/// `killWait` on a child that exited on its own leaves what the child started
/// to `deinit`.
///
/// This does not wait. The child is still a process, and still needs reaping,
/// when this returns.
pub fn kill(child: *Child, signal: Signal) KillError!void {
    if (child.settled() != null) return;
    if (is_windows) return child.killWindows(signal);

    const sig = signal.toPosix();
    const target: posix.pid_t = if (child.pgid) |pgid| -pgid else child.id;

    // The descendants that the group does not cover, deepest first, and before
    // the child itself: a leader signalled before the processes below it
    // leaves them orphaned, and an orphan belongs to `init` and is named by no
    // walk. A descendant already in the group about to be signalled is left to
    // it, so the ordinary tree gets the one signal it always did.
    _ = try tree.signalDescendants(child.id, sig, child.pgid);

    const answer = child.signalTarget(target, sig);
    if (sig != .KILL) return answer;

    // `.kill` is the one that promises to leave nothing behind, and
    // `kill(-pgid)` is not atomic against a `fork` inside the group: a process
    // started while the signal was being delivered is in the group without
    // having been in it when the signal was sent. So it is asked again until a
    // pass names no descendant, which for a tree that is already dead is the
    // very next one.
    var pass: u8 = 0;
    while (pass < kill_passes) : (pass += 1) {
        const reached = try tree.signalDescendants(child.id, sig, null);
        _ = c.kill(target, sig);
        if (reached == 0) break;
    }
    return answer;
}

/// How many times after the first `.kill` will look again for something that
/// was started while it was working. Two is enough for a tree that forks once
/// more on its way out; a tree that forks faster than it can be killed is not
/// something a bound can fix.
const kill_passes: u8 = 2;

fn signalTarget(child: *Child, target: posix.pid_t, sig: posix.SIG) KillError!void {
    if (c.kill(target, sig) == 0) return;
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
/// **What the returned `Term` says differs by system, and by which of the two
/// requests did it.** On POSIX a child that does not catch `SIGTERM` reports
/// `.signal = .TERM`, and one that survives the grace reports `.signal =
/// .KILL`; either way the signal named is the one this package sent. On
/// Windows only the second is this package's to name: `.kill` is
/// `TerminateProcess` with an exit code of 1, so a child that had to be killed
/// reports `.exited = 1`. A child that obeys the `.terminate` before it ends
/// on its own terms and reports whatever status *it* chose — for one that does
/// not handle the control event, the system's control-exit status, which
/// reaches `Term` as its low byte. A caller that wants a number of its own on
/// that system should pass a `grace_ms` of zero; a caller that wants to know
/// whether the child ended well should ask `succeeded`.
///
/// The grace is `waitTimeout`, so a child that obeys the `.terminate` is
/// noticed the moment it does rather than at the end of an interval.
pub fn killWait(child: *Child, io: std.Io, grace_ms: u32) KillWaitError!Term {
    // A child that has already ended is reaped rather than signalled.
    if (try child.tryWait()) |term| return term;

    if (grace_ms > 0) {
        child.kill(.terminate) catch {};
        if (try child.waitTimeout(io, grace_ms)) |term| return term;
    }

    try child.kill(.kill);
    return child.wait(io);
}

pub const WaitTreeError = std.Io.Cancelable || std.Io.UnexpectedError;

/// Waits up to `timeout_ms` for everything the child started to end, and says
/// whether it did. **Windows only.**
///
/// `true` means the job object the child was put in holds no process any more:
/// not the child, and not a grandchild the child started and left behind. That
/// is a different question from `wait`, which is about the child alone, and it
/// is the question a program that is about to take down a subsystem has: a
/// child that exits having started a server is a tree that is still running.
/// `false` means the time ran out with something still in the job.
///
/// Ask it before `deinit`. The job and the port it reports on are closed
/// there, and closing the job is itself what ends what is left inside it — so
/// after `deinit` there is nothing to hear the answer on and this reports what
/// it heard while there was.
///
/// A zero `timeout_ms` asks and does not wait, which is how to poll. The
/// message the job posts is posted once and taking it off the port consumes
/// it, so this remembers: once it has answered `true` it answers `true`
/// thereafter.
///
/// **There is no POSIX counterpart, and naming one would be a lie.** A job
/// object is a container the operating system keeps and can report on; a
/// process group is an address to send signals to and nothing is accounted to
/// it. The nearest thing there — the descendant walk `kill` uses — cannot
/// answer this question: it walks down from the child, and a grandchild whose
/// parent has exited belongs to `init` and is related to the child by nothing
/// the system will tell you. A walk that named nothing would mean "the tree
/// has ended" and "the tree has been orphaned" indistinguishably, and on the
/// BSDs and illumos, which name a process's children only through the whole
/// process table, it would mean neither. So this is a compile error there
/// rather than an answer that is right on one system and wrong on three.
pub const waitTree = if (is_windows)
    waitTreeWindows
else
    @compileError(
        "Child.waitTree is Windows-only: a job object is a container the " ++
            "system accounts for, and POSIX has no such thing to ask. See " ++
            "Child.kill for what a signal reaches there.",
    );

/// How long one wait on the completion port lasts before the caller is given a
/// chance to notice it has been cancelled.
///
/// `GetQueuedCompletionStatus` is not a cancelation point, so the deadline is
/// spent in slices of this and cancelation is asked about between them. The
/// same five milliseconds `wait.slice_ms` spends on POSIX, for the same
/// reason.
const tree_slice_ms: u32 = 5;

fn waitTreeWindows(child: *Child, io: std.Io, timeout_ms: u32) WaitTreeError!bool {
    if (child.tree_ended) return true;
    const port = child.job_port orelse return false;
    const job = child.job orelse return false;
    const deadline: Deadline = .in(io, timeout_ms);

    while (true) {
        const left = deadline.remainingMs(io);
        var message: win32.DWORD = undefined;
        var key: windows.ULONG_PTR = undefined;
        var overlapped: ?*anyopaque = undefined;
        if (win32.GetQueuedCompletionStatus(
            port,
            &message,
            &key,
            &overlapped,
            @min(left, tree_slice_ms),
        ) != .FALSE) {
            // A job reports more than the one thing: a process started, a
            // process exited, a limit was reached. Only one of them is the
            // answer, and the rest are taken off the port and dropped.
            if (key == @intFromPtr(job) and message == win32.JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO) {
                child.tree_ended = true;
                return true;
            }
            continue;
        }
        switch (windows.GetLastError()) {
            // Nothing on the port within the slice, which is all this says.
            .WAIT_TIMEOUT => {},
            else => |err| return win32.unexpected(err),
        }
        if (left == 0) return false;
        try std.Io.checkCancel(io);
    }
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

/// An `Expect` over the child's streams, for a conversation: wait for what it
/// says, then answer.
///
/// The master for a child on a pseudo-terminal, and the two pipes for a child
/// on pipes. `null` when this process does not hold both directions — an
/// inherited stream, or a child given only one pipe — because half a
/// conversation is not one.
///
/// The result must be `start`ed and `deinit`ed, and must not move once it has
/// been started; `Expect` documents the rest.
pub fn expect(child: Child, buffer: []u8) ?Expect {
    const read = child.stdoutFile() orelse return null;
    const write = child.stdinFile() orelse return null;
    return .init(.{ .read = read, .write = write }, buffer);
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
    const deadline: ?Deadline = if (options.timeout_ms) |timeout_ms| .in(io, timeout_ms) else null;
    const term = term: while (true) {
        // A reader that cannot continue leaves a pipe the child may fill and
        // block on. Notice it while the child is still running, end the child,
        // and report the read failure after both tasks have joined.
        if (out.readFailed() or err.readFailed()) {
            break :term try child.killWait(io, 0);
        }

        const slice_ms = if (deadline) |until| slice: {
            const left = until.remainingMs(io);
            if (left == 0) {
                timed_out = true;
                break :term try child.killWait(io, options.grace_ms);
            }
            break :slice @min(left, output_wait_slice_ms);
        } else output_wait_slice_ms;
        if (try child.waitTimeout(io, slice_ms)) |finished| break :term finished;
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

    const out_failure = out.failure.load(.acquire);
    const err_failure = err.failure.load(.acquire);
    if (out_failure == .read_failed or err_failure == .read_failed) return error.ReadFailed;
    if (out_failure == .out_of_memory or err_failure == .out_of_memory) return error.OutOfMemory;
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
    failure: std.atomic.Value(Failure),
    done: std.atomic.Value(bool),

    const Failure = enum(u8) { none, read_failed, out_of_memory };

    const init: Collector = .{
        .list = .empty,
        .truncated = false,
        .failure = .init(.none),
        .done = .init(false),
    };

    fn readFailed(collector: *const Collector) bool {
        return collector.failure.load(.acquire) == .read_failed;
    }
};

/// How often an unbounded `output` wait gives its readers a chance to report
/// that one of them cannot keep draining. Each bounded wait still uses the
/// operating system's process handle rather than sleeping this interval.
const output_wait_slice_ms: u32 = 10;

fn collect(
    io: std.Io,
    allocator: Allocator,
    f: std.Io.File,
    max_bytes: usize,
    into: *Collector,
) std.Io.Cancelable!void {
    defer into.done.store(true, .release);
    var discard: [64 * 1024]u8 = undefined;
    while (true) {
        const room = max_bytes -| into.list.items.len;
        var keeping = into.failure.load(.acquire) != .out_of_memory and room != 0;
        const buffer = if (keeping) buffer: {
            if (into.list.capacity == into.list.items.len) {
                // Start large enough to drain an ordinary pipe in a handful
                // of reads, then grow geometrically. The read lands in the
                // allocation itself: no stack-buffer-to-list copy follows it,
                // and after a growth there is no allocation in the steady
                // state.
                const additional = @min(room, @max(@as(usize, 16 * 1024), into.list.items.len));
                into.list.ensureUnusedCapacity(allocator, additional) catch {
                    into.failure.store(.out_of_memory, .release);
                    into.truncated = true;
                    keeping = false;
                    break :buffer discard[0..];
                };
            }
            break :buffer into.list.unusedCapacitySlice()[0..@min(room, into.list.capacity - into.list.items.len)];
        } else discard[0..];

        const n = handles.readStreaming(f, io, &.{buffer}) catch |e| switch (e) {
            error.Canceled => return error.Canceled,
            else => {
                if (handles.finished(e)) return;
                into.failure.store(.read_failed, .release);
                return;
            },
        };
        if (!keeping) {
            // Allocation failed, but reading must continue until the child
            // exits or it can fill this pipe and make the wait deadlock.
            into.truncated = true;
            continue;
        }
        into.list.items.len += n;
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

/// Closes the job, which ends anything still in it. Idempotent.
fn closeJob(child: *Child) void {
    // The port goes after the job, because closing the job is what ends what
    // is left in it and the job posts that to the port. Nothing reads the
    // message by then; the order is so that the job is never reporting to a
    // handle that has gone.
    defer if (child.job_port) |port| {
        child.job_port = null;
        windows.CloseHandle(port);
    };
    const job = child.job orelse return;
    child.job = null;
    trace.print("child: closing the job", .{});
    windows.CloseHandle(job);
    trace.print("child: job closed", .{});
}

fn tryWaitWindows(child: *Child) TryWaitError!?Term {
    switch (win32.WaitForSingleObject(child.id, 0)) {
        win32.WAIT_OBJECT_0 => {},
        win32.WAIT_TIMEOUT => return null,
        else => return win32.unexpected(windows.GetLastError()),
    }
    var code: win32.DWORD = undefined;
    const term: Term = if (win32.GetExitCodeProcess(child.id, &code) != .FALSE)
        .{ .exited = @truncate(code) }
    else
        .{ .unknown = 0 };
    child.closeHandles();
    child.publish(term);
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
        else => |err| win32.unexpected(err),
    };
}

fn terminateWindows(child: *Child) KillError!void {
    // The job rather than the process, so what the child started goes with it.
    // `TerminateJobObject` is the same uncatchable end as `TerminateProcess`,
    // applied to the whole set, and the exit code is the same 1.
    if (child.job) |job| {
        trace.print("child: TerminateJobObject", .{});
        if (win32.TerminateJobObject(job, 1) != .FALSE) return;
    }
    if (win32.TerminateProcess(child.id, 1) != .FALSE) return;
    return switch (windows.GetLastError()) {
        .ACCESS_DENIED => {
            // Usually this means the process has already exited; the reap
            // below is what tells the two apart.
            if ((child.tryWait() catch null) != null) return;
            return error.PermissionDenied;
        },
        .INVALID_HANDLE => {},
        else => |err| win32.unexpected(err),
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
    _ = @import("command_line.zig");
    if (is_windows) {
        _ = @import("child_windows.zig");
    } else {
        _ = @import("child_posix.zig");
        _ = @import("tree.zig");
        _ = @import("wait.zig");
    }
}
