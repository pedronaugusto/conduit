const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const windows = std.os.windows;
const c = std.c;
const Allocator = std.mem.Allocator;
const Pty = @import("../pty.zig").Pty;
const is_windows = builtin.os.tag == .windows;
/// A numeric process id on either platform, never a Windows handle.
pub const Id = if (is_windows) windows.DWORD else posix.pid_t;

/// A process group. The process group id on POSIX; on Windows the id of the
/// group `CREATE_NEW_PROCESS_GROUP` made, which is the child's process id.
pub const ProcessGroupId = if (is_windows) windows.DWORD else posix.pid_t;

/// How a child process ended. Exit codes retain all 32 bits on Windows;
/// POSIX exit codes occupy the low byte. Signals are POSIX-only, and stopped
/// is never produced because these waits do not request stop notifications.
pub const Term = union(enum) {
    exited: u32,
    signal: posix.SIG,
    stopped: posix.SIG,
    unknown: u32,
};

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
    /// A pipe `spawn` creates and the `Child` owns, borrowed afterwards through
    /// `stdinFile`, `stdoutFile` or `stderrFile`.
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
    /// Whether descendants may outlive a normal, reaped exit. Independent
    /// of `detach`: `.contain` also makes a private group on POSIX.
    /// Timeout, output error and explicit termination still end the tree.
    descendants: Descendants = .survive,
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
    /// Files the child is given beyond its standard three, in order: the
    /// first is its descriptor 3, the next 4, and so on. A listening socket
    /// handed over the way a service manager hands one (`LISTEN_FDS`), or a
    /// pipe for a protocol of the caller's own (`--status-fd=3`), has no other
    /// way in. Go's `ExtraFiles`.
    ///
    /// Borrowed: `spawn` closes none of them, and they must stay open until it
    /// returns. The child gets each whatever its close-on-exec flag says here,
    /// and whatever number it has here, including one of the numbers it is
    /// placed at: a file at 4 given first and a file at 3 given second cross
    /// over correctly. `fd_policy = .close_all` closes what is above them.
    ///
    /// **Windows** numbers no descriptors; a child that inherits a handle has
    /// it at the same value. Each file goes to the child as a private
    /// inheritable duplicate named in the handle list, as the standard
    /// streams do, and in the table of inherited descriptors the Microsoft C
    /// runtime reads from the startup record (`lpReserved2`): a child on that
    /// runtime — `cmd.exe`, Python, Node, any C program — has them as its
    /// descriptors 3 and up, which is how libuv gives a Node child extra
    /// stdio. A child on no C runtime finds them with `GetStartupInfoW`.
    /// Together with `.pty` this is `error.Unsupported`: a pseudoconsole is
    /// attached through the attribute list, which Windows documents as
    /// incompatible with naming a child's handles, the reason `stderr_to` is
    /// refused there too. So is a list too long for the startup record's
    /// 16-bit size, more than 7,000 files.
    extra_fds: []const std.Io.File = &.{},
    /// What the child and everything it starts may use. Windows only:
    /// anything set here is `error.Unsupported` elsewhere.
    job_limits: JobLimits = .{},
    /// The signal the child is sent when its parent ends, however it ends:
    /// a crash or `SIGKILL` included, which no handler of the parent's sees.
    /// `.kill` is the usual choice, for a child that must not outlive the
    /// program that started it.
    ///
    /// **Linux only**: `PR_SET_PDEATHSIG`, set in the fork child, so a spawn
    /// with it never takes the `posix_spawn` path. If the parent has already
    /// gone by the time it is set, the child sends it to itself before it
    /// runs anything. The parent it watches is the *thread* that called
    /// `spawn`: in a program whose threads live as long as it does, as
    /// `std.Io.Threaded`'s workers do, that is the program; a thread that
    /// ends earlier takes its children with it. The setting survives
    /// `execve` except into a set-user-ID or set-group-ID program.
    /// A contained Linux root instead watches its private supervisor with
    /// SIGKILL. Loss of the caller's socket asks that supervisor to end and
    /// reap the whole scope, independently of this option.
    ///
    /// Anywhere else it is `error.Unsupported`: macOS has no such thing, and
    /// a program there that must not leave children behind a crash keeps
    /// their pids and start times (`conduit.startTime`) and ends them the
    /// next time it runs.
    parent_death_signal: ?Signal = null,
};

/// One policy for the descendants a child starts, on every platform.
pub const Descendants = enum {
    /// Normal exit and deinit leave descendants running. The default, for
    /// helpers that deliberately start a daemon. Reap before deinit.
    survive,
    /// End descendants on normal completion too. Windows ends the Job
    /// members and confirms zero active processes before publishing the
    /// root's status; POSIX ends the cgroup or private process
    /// group before the final reap releases its identity. Darwin also ends
    /// descendants whose lineage was observed from before exec. This is
    /// observation, without kernel enforcement: a fork followed by parent
    /// exit before enumeration or registration can escape. The measured
    /// window yielded 0/100 escapes with no added delay and 100/100 with
    /// a 20 ms observer delay in one run; counts depend on scheduling.
    /// Linux uses a private subreaper supervisor per contained child,
    /// with or without a writable cgroup. It reaps the root and every
    /// adoptee before completion, preserving the root's exact status.
    contain,
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
    /// whatever its flags say. The child gets its three standard streams,
    /// what `extra_fds` gives it, and nothing else.
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
    /// No search. `argv[0]` is used as the path supplied, resolved against
    /// the child's working directory when relative, including a bare name.
    none,
};

pub const SpawnError = error{
    OutOfMemory,
    /// `argv` was empty, or one of its elements holds a NUL, which would end
    /// it early — or, on Windows, its first element contains a double quote,
    /// which cannot be serialised into a command line without letting
    /// characters leak into the arguments after it.
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
    /// or `extra_fds` together with `.pty` on Windows, a `path_search` other than
    /// `.child_environ` there, `credentials` or `resource_limits` anywhere on
    /// Windows, `job_limits` anywhere else, or `parent_death_signal` anywhere
    /// but Linux. The option that cannot be honoured says so.
    Unsupported,
    /// Windows: `job_limits.cpu_rate` was outside its inclusive 1–10,000
    /// range. No child was started.
    InvalidJobLimit,
    /// The system answered in a way this package does not expect.
    Unexpected,
};

pub const ReleaseError = KillWaitError || WaitTreeError;

/// Containment facts for a survivor record, with no owned handles.
/// The cgroup path borrows the buffer passed to containment; everything else
/// is copied. Keep that buffer with the record, independently of this Child.
pub const SupervisorRecord = struct {
    pid: Id,
    start: u64,
    boot: [36]u8,
};

pub const Containment = struct {
    /// Linux: a private scope identity, independently of the root pid.
    supervisor: ?SupervisorRecord = null,
    group: ?ProcessGroupId,
    cgroup: ?struct {
        path: [:0]const u8,
        id: u64,
        boot: [36]u8,
    } = null,
};

pub const ContainmentError = error{ BufferTooSmall, IdentityUnavailable };

pub const WaitError = std.process.Child.WaitError || error{ReapedElsewhere};

pub const WaitTimeoutError = TryWaitError || std.Io.Cancelable;

pub const TryWaitError = error{
    /// Something outside this package reaped the child, so there is no status
    /// left for anyone to report: a `SIGCHLD` handler of the program's own, or
    /// `SIGCHLD` set to `SIG_IGN`, which is the program telling the system to
    /// reap its children for it. POSIX only.
    ///
    /// This package has to be the one that reaps, and once it is not, the
    /// child is gone and how it ended cannot be recovered.
    ReapedElsewhere,
    /// The system answered in a way this package does not expect.
    Unexpected,
};

/// A signal for `Child.kill`: the three requests to end that mean the same
/// thing on both systems, the POSIX signals programs are commonly sent for
/// other reasons, by name, and any other POSIX signal by its number.
///
/// Only `.interrupt`, `.terminate` and `.kill` ask the child to end, and only
/// they make the descendants part of that ending: a child that catches one
/// and exits normally still has its tree ended at the reap. Every other
/// signal is delivered to the same processes and changes nothing about how
/// the child's tree is treated afterwards, whatever its default action does
/// to the processes it reaches.
///
/// **Windows** has an equivalent for the first three only. Every other member
/// is `error.Unsupported` there, by name: no call sends a hang-up, a quit, a
/// user signal or a window change to a process, a pseudoconsole's window
/// change is `Pty.resize`, and the only way to stop and continue a process is
/// an undocumented call, or suspending its threads one at a time while it may
/// be starting another.
pub const Signal = union(enum) {
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
    /// whose outcome this package does not decide; `Term` preserves that status.
    terminate,
    /// End the child now. POSIX: `SIGKILL`. Windows: `TerminateProcess`.
    /// Neither can be caught.
    kill,
    /// `SIGHUP`: the terminal went away, or — for a daemon, which has none —
    /// read the configuration again. POSIX only.
    hangup,
    /// `SIGQUIT`: what Ctrl-\ sends; ends with a core dump by default, and
    /// some runtimes print their threads instead. POSIX only.
    quit,
    /// `SIGUSR1`, whatever the program says it means. POSIX only.
    user1,
    /// `SIGUSR2`, whatever the program says it means. POSIX only.
    user2,
    /// `SIGSTOP`: suspend, which cannot be caught or ignored. The child does
    /// not end, so no wait here returns for it; `.@"continue"` resumes it.
    /// POSIX only.
    stop,
    /// `SIGCONT`: resume a stopped child. POSIX only.
    @"continue",
    /// `SIGWINCH`: the window size changed. A child on a pair is sent this by
    /// the terminal itself when `Pty.resize` changes the size; this is for a
    /// child that should look again without one. POSIX only.
    window_change,
    /// Any other POSIX signal, by the system's own number: `.{ .posix = .ALRM }`.
    /// One the system does not have is `error.Unsupported`, as is this member
    /// on Windows, where nothing has a number to give it.
    posix: posix.SIG,

    /// The POSIX signal number this stands for. POSIX only: Windows has no
    /// `SIGKILL` to name.
    pub fn toPosix(signal: Signal) posix.SIG {
        if (is_windows) @compileError("Signal.toPosix is POSIX-only");
        return toPosixImpl(signal);
    }

    fn toPosixImpl(signal: Signal) posix.SIG {
        return switch (signal) {
            .interrupt => .INT,
            .terminate => .TERM,
            .kill => .KILL,
            .hangup => .HUP,
            .quit => .QUIT,
            .user1 => .USR1,
            .user2 => .USR2,
            .stop => .STOP,
            .@"continue" => .CONT,
            .window_change => .WINCH,
            .posix => |number| number,
        };
    }

    /// Whether this asks the child to end — `.interrupt`, `.terminate` or
    /// `.kill`, or the same three spelled by number — which is what makes
    /// the descendants part of the ending.
    pub fn ends(signal: Signal) bool {
        return switch (signal) {
            .interrupt, .terminate, .kill => true,
            .posix => |number| if (is_windows) false else switch (number) {
                .INT, .TERM, .KILL => true,
                else => false,
            },
            else => false,
        };
    }

    /// Whether this system has the signal at all: a number between one and
    /// the last signal it defines. Always true for the named members.
    pub fn valid(signal: Signal) bool {
        if (is_windows) return switch (signal) {
            .interrupt, .terminate, .kill => true,
            else => false,
        };
        const number = @intFromEnum(signal.toPosix());
        return number > 0 and number < signal_limit;
    }

    const signal_limit = if (is_windows) 0 else if (@hasDecl(c.SIG, "RTMAX")) @max(c.NSIG, c.SIG.RTMAX + 1) else c.NSIG;
};

pub const KillError = error{
    /// POSIX: the descendant walk could not hold the whole tree, so no
    /// descendant outside the child's group was signalled. The child, and its
    /// group if it has one, were signalled all the same.
    OutOfMemory,
    /// This process may not signal the child.
    PermissionDenied,
    /// The signal has no meaning here. Windows: `.interrupt` was asked for and
    /// the child has no process group of its own, so there is nothing a
    /// console control event can be addressed to (spawn with `detach` to get
    /// one), or a signal other than the three it has an equivalent for. POSIX:
    /// a `.posix` number this system does not define.
    Unsupported,
    /// The system answered in a way this package does not expect.
    Unexpected,
};

pub const KillWaitError = KillError || WaitError || TryWaitError || std.Io.Cancelable;

pub const WaitTreeError = error{
    /// Linux: the child was given no cgroup of its own, so there is no
    /// container to ask.
    Unsupported,
} || std.Io.Cancelable || std.Io.UnexpectedError;

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

/// What `Child.exchange` takes: `output`'s bounds, with one deadline over
/// everything.
pub const ExchangeOptions = struct {
    /// The most kept from each stream, as `OutputOptions.max_bytes`: bytes
    /// past it are read and dropped, and the stream is reported truncated.
    max_bytes: usize = 10 * 1024 * 1024,
    /// One budget for the whole exchange: writing the input, the child's run,
    /// its end and the reading after it. When it runs out the child is killed
    /// at once, with no grace, and `Output.timedOut` says so. `null` waits as
    /// long as it takes.
    timeout_ms: ?u32 = null,
    /// How long to keep reading after the child has ended, as
    /// `OutputOptions.drain_ms`, and never past the timeout.
    drain_ms: u32 = 1000,
};

pub const ExchangeError = OutputError || error{
    /// There is input to give and the child's standard input is not a pipe
    /// this `Child` holds.
    NoStdinPipe,
} || std.Io.File.Writer.Error;

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
