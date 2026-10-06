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
//! On POSIX this is `posix_spawn` when file actions and attributes can describe
//! the child — on Linux a detached child on a pseudo-terminal included — and
//! otherwise a fork and an exec, doing between the two the things there is no
//! other place to do: `setsid`, `TIOCSCTTY`, an empty signal mask and every
//! signal back at its default action.
//!
//! On Windows it is `CreateProcessW`. A child on a pseudo-terminal is attached
//! to the pseudoconsole through `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE` in a
//! `PROC_THREAD_ATTRIBUTE_LIST`, which is the ConPTY counterpart of the
//! controlling-terminal dance, and `detach` is `CREATE_NEW_PROCESS_GROUP`.
//! What the two systems do *not* share is spelled out on `SpawnOptions.detach`
//! and on `Signal`.

const State = @import("child/State.zig");

const builtin = @import("builtin");
const std = @import("std");
const spin = @import("spin.zig");
const posix = std.posix;
const c = std.c;
const windows = std.os.windows;
const Allocator = std.mem.Allocator;

const Expect = @import("expect.zig").Expect;
pub const InputWriter = input_writer.Writer(Child).InputWriter;
const Pty = @import("pty.zig").Pty;
const trace = @import("trace.zig");
const handles = @import("handles.zig");
const is_windows = builtin.os.tag == .windows;
const win32 = @import("win32.zig");
const tree = @import("tree.zig");
const cgroups = @import("cgroup.zig");
const wait_for = @import("wait.zig");
const orphans = @import("orphans.zig").Orphans;
const Deadline = @import("conduit.tty").Deadline;
const SerialAllocator = @import("serial_allocator.zig").SerialAllocator;
const input_writer = @import("input_writer.zig");
const completion = @import("child/windows/completion.zig");
const contract = @import("child/contract.zig");
const child_output = @import("child/output.zig");
const child_posix = @import("child/posix.zig");
const child_windows = @import("child/windows.zig");

/// Owns the lifecycle and created pipes. A handle: copies name the same
/// child, and exactly one of them is released or deinited.
pub const Child = struct {
    /// Private: the lifecycle, allocated by `spawn` and freed by `deinit`.
    state: *State,

    /// A numeric process id on either platform, never a Windows handle.
    pub const Id = contract.Id;

    /// A process group. The process group id on POSIX; on Windows the id of the
    /// group `CREATE_NEW_PROCESS_GROUP` made, which is the child's process id.
    pub const ProcessGroupId = contract.ProcessGroupId;

    /// How a child process ended. Exit codes retain all 32 bits on Windows;
    /// POSIX exit codes occupy the low byte. Signals are POSIX-only, and stopped
    /// is never produced because these waits do not request stop notifications.
    pub const Term = contract.Term;

    /// Whether the child ended the way a program that did its job ends: exited,
    /// with a status of zero.
    ///
    /// Every other end is false, and they are not the same as each other: a
    /// non-zero status is the program saying something went wrong, and a signal is
    /// the program not getting to say anything. `exitCode` and `signalName` are
    /// for telling them apart.
    ///
    pub fn succeeded(term: Term) bool {
        return switch (term) {
            .exited => |code| code == 0,
            else => false,
        };
    }

    /// The status the child exited with, or `null` if it did not exit -- which on
    /// POSIX means a signal ended it.
    pub fn exitCode(term: Term) ?u32 {
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
    /// Terms returned by Windows waits have no signal name: a terminated process
    /// there reports the exit code it was terminated with, and
    /// `killWait` uses 1. A portable program that wants to say why a child stopped
    /// has to accept that the Windows answer is a number.
    pub fn signalName(term: Term) ?[]const u8 {
        return switch (term) {
            .signal, .stopped => |signal| std.enums.tagName(posix.SIG, signal),
            else => null,
        };
    }

    /// The number of the signal that ended or stopped the child, or `null` if
    /// none did. Unlike `signalName`, a signal with no name has one: a
    /// real-time signal is its number. Never set by a Windows wait.
    pub fn signalNumber(term: Term) ?u8 {
        return switch (term) {
            .signal, .stopped => |signal| std.math.cast(u8, @intFromEnum(signal)),
            else => null,
        };
    }

    /// The child's end as a POSIX shell reports it in `$?`: the exit status
    /// in its low byte, or 128 and the number of the signal that ended or
    /// stopped it. An end that is neither is 255. A Windows exit code is
    /// truncated to its low byte, as a POSIX shell there reports one;
    /// `exitCode` keeps all 32 bits.
    pub fn shellStatus(term: Term) u8 {
        return switch (term) {
            .exited => |code| @truncate(code),
            .signal, .stopped => if (signalNumber(term)) |number| 128 +| number else 255,
            .unknown => 255,
        };
    }

    /// Which of the child's three standard streams get pipes.
    ///
    /// A stream that is not piped is inherited from the parent, on both systems.
    /// Piping only what is read avoids the deadlock of a full pipe nobody drains.
    pub const PipeOptions = contract.PipeOptions;

    /// What one of the child's three standard streams is connected to.
    ///
    /// The five are the standard library's — `std.process.SpawnOptions.StdIo` has
    /// the same ones under the same names — because a caller who already knows
    /// that vocabulary should not have to learn a second one here.
    pub const Stream = contract.Stream;

    /// The child's three standard streams, each named on its own.
    pub const Streams = contract.Streams;

    /// What the child's standard input, output and error are connected to.
    pub const Stdio = contract.Stdio;

    /// Everything `spawn` needs.
    pub const SpawnOptions = contract.SpawnOptions;

    /// One policy for the descendants a child starts, on every platform.
    pub const Descendants = contract.Descendants;

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
    pub const JobLimits = contract.JobLimits;

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
    pub const FdPolicy = contract.FdPolicy;

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
    pub const Credentials = contract.Credentials;

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
    pub const ResourceLimit = contract.ResourceLimit;

    /// Where the `PATH` that resolves a bare `argv[0]` comes from.
    ///
    /// On Windows the package resolves `.child_environ` before `CreateProcessW`,
    /// because that call otherwise searches the parent's PATH even when given a
    /// different environment. The other two remain `error.Unsupported` there.
    pub const PathSearch = contract.PathSearch;

    pub const SpawnError = contract.SpawnError;

    /// What an `execve` that failed means, as one of `SpawnError`.
    ///
    /// Both spawn paths on POSIX end here: the fork child reports the number it
    /// got back over its pipe, and `posix_spawn` returns it.
    pub const execError = contract.execError;

    /// Starts `options.argv` as a child process.
    ///
    /// `allocator` builds the arguments and environment and owns the lifecycle
    /// state until `deinit`. It must outlive the Child. `io` closes every handle
    /// the parent opened here and does not keep.
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
    pub fn spawn(allocator: Allocator, io: std.Io, options: SpawnOptions) SpawnError!Child {
        if (options.argv.len == 0) return error.InvalidArgv;
        // An argument is passed on as a string that ends at a NUL: the child
        // would receive less of it than was given, and on Windows none of the
        // arguments after it.
        for (options.argv) |argument| if (std.mem.findScalar(u8, argument, 0) != null) return error.InvalidArgv;
        if (options.parent_death_signal != null and builtin.os.tag != .linux) return error.Unsupported;
        var configured = options;
        // A private POSIX group belongs to the held child until the reap. It
        // must never be the caller's group, even when detach was not requested.
        if (!is_windows and options.descendants == .contain) configured.detach = true;
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.allocator = allocator;
        if (is_windows) return .{ .state = try child_windows.spawn(allocator, io, configured, state) };
        // A job object is what these bound, and POSIX has no such container.
        // `resource_limits` is the option that exists here.
        if (options.job_limits.any()) return error.Unsupported;
        return .{ .state = try child_posix.spawn(allocator, io, configured, state) };
    }

    pub const ReleaseError = contract.ReleaseError;

    /// Ends an unfinished contained scope, confirms completion, then does what
    /// `deinit` does. A failure keeps the Child and its scope whole, so the
    /// call can be made again; a success leaves the Child undefined, like
    /// `deinit`, so a Child is released or deinited, never both. A
    /// survival-policy child is simply deinited. Join every task borrowing
    /// this Child before releasing it.
    pub fn release(child: *Child, io: std.Io) ReleaseError!void {
        const state = child.state;
        if (state.descendants == .contain and !state.scope_complete) {
            _ = try child.killWait(io, 0);
        }
        child.deinit(io);
    }

    /// Closes owned streams and lifecycle resources; supplied streams stay
    /// open. The Child is undefined afterwards. A contained scope must
    /// already have confirmed completion: `release` ends an unfinished one
    /// and reports what its cleanup met. Join every task borrowing this Child
    /// first. A reaped survival-policy child leaves descendants alone. Linux
    /// cgroups with surviving members remain until empty and a later cleanup
    /// removes them.
    pub fn deinit(child: *Child, io: std.Io) void {
        const state = child.state;
        std.debug.assert(state.descendants != .contain or state.scope_complete);
        if (state.stdin) |f| f.close(io);
        if (state.stdout) |f| f.close(io);
        if (state.stderr) |f| f.close(io);
        if (is_windows) {
            if (state.handles_open) child.closeHandles();
            child.closeJob();
        } else {
            if (comptime builtin.os.tag == .linux) if (state.supervisor) |owner| owner.close();
            if (state.lineage) |tracker| tracker.destroy();
            state.forks.close();
            state.cgroup.release();
        }
        state.allocator.destroy(state);
        child.* = undefined;
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
        const state = child.state;
        const f = state.stdin orelse return;
        state.stdin = null;
        f.close(io);
    }

    /// Takes the stdin pipe and starts a bounded writer on its own task. Bytes
    /// queued through it never wait for the child to read. On success stdin is
    /// null: the InputWriter alone writes and closes it, independently of this
    /// Child's lifetime. On error this Child still owns the untouched pipe.
    /// Only a pipe can be transferred; a terminal is error.NoStdinPipe.
    pub fn inputWriter(child: *Child, allocator: Allocator, io: std.Io, options: InputWriter.Options) InputWriter.StartError!InputWriter {
        return InputWriter.init(allocator, io, child, options);
    }

    /// The live identity as a number, or null after retirement.
    /// This is a snapshot, not authority to signal: only kill holds the identity
    /// through delivery. A process that ended but is not reaped still has an id.
    pub fn processId(child: *const Child) ?Id {
        const state = child.state;
        spin.lock(&state.identity);
        defer state.identity.unlock();
        if (state.reaped.load(.acquire) or state.identity_retired) return null;
        return state.process_id;
    }

    /// Containment facts for a survivor record, with no owned handles.
    /// The cgroup path borrows the buffer passed to containment; everything else
    /// is copied. Keep that buffer with the record, independently of this Child.
    pub const SupervisorRecord = contract.SupervisorRecord;

    pub const Containment = contract.Containment;

    pub const ContainmentError = contract.ContainmentError;

    /// Copies the detached group and, on Linux, the cgroup path, directory inode
    /// boot id and private supervisor identity. Available through retirement, until transfer or deinit. No cgroup is null;
    /// a cgroup whose identity cannot be read is IdentityUnavailable, so a ledger
    /// never silently records incomplete containment. An undersized path buffer
    /// is BufferTooSmall; std.fs.max_path_bytes + 64 always holds our path.
    ///
    /// Save processId and this record before starting a Reaper. Retain the saved
    /// id as the ledger key through retirement; it is not permission to signal.
    pub fn containment(child: *const Child, buffer: []u8) ContainmentError!Containment {
        const state = child.state;
        var record: Containment = .{ .group = state.pgid };
        if (comptime builtin.os.tag == .linux) if (state.supervisor) |owner| {
            record.supervisor = owner.record;
        };
        if (comptime !is_windows) if (state.cgroup.active()) {
            const path = state.cgroup.path(buffer) orelse return error.BufferTooSmall;
            const id = state.cgroup.id() orelse return error.IdentityUnavailable;
            const boot = cgroups.bootIdentity() orelse return error.IdentityUnavailable;
            record.cgroup = .{ .path = path, .id = id, .boot = boot };
        };
        return record;
    }

    /// The published answer without asking the OS to reap. Safe alongside a wait
    /// or Reaper: null before publication, or ReapedElsewhere after status loss.
    pub fn result(child: *const Child) TryWaitError!?Term {
        const state = child.state;
        spin.lock(&state.identity);
        defer state.identity.unlock();
        if (child.settled()) |term| return term;
        if (state.identity_retired) return error.ReapedElsewhere;
        return null;
    }

    pub const WaitError = contract.WaitError;

    /// Blocks until the child ends, and returns how.
    ///
    /// Returns the same value on every later call: the child is reaped once. This
    /// waits on the same exit handles as `waitTimeout`, without reaping until
    /// signalling has let go of the identity. It is a cancelation point.
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
        return child.waitClaimed(io);
    }

    /// `wait` for a caller that already holds the reap.
    fn waitClaimed(child: *Child, io: std.Io) WaitError!Term {
        // One implementation owns final reaping for bounded and unbounded waits.
        // Renew the largest bounded wait until an answer arrives: a child may
        // run longer than one u32 millisecond span. Exit observation keeps the
        // zombie (or Windows handles) intact until tryWaitClaimed takes identity.
        while (true) {
            const term = try child.reapWithin(io, .in(io, std.math.maxInt(u32)));
            if (term) |ended| return ended;
        }
    }

    //======================================================================
    // One reap, whoever asks for it.
    //======================================================================

    /// The term, if whoever reaped the child has published it.
    ///
    /// The acquire load pairs with the release store in `publish`, so a caller
    /// that sees a term sees every field the reaper wrote before it.
    fn settled(child: *const Child) ?Term {
        if (!child.state.reaped.load(.acquire)) return null;
        // Published only after it was written.
        std.debug.assert(child.state.term != null);
        return child.state.term;
    }

    /// Records how the child ended and lets everyone else read it.
    fn publish(child: *Child, term: Term) void {
        // One reap, so one term: whoever publishes holds the identity, and a
        // second reap would be of a process this child no longer names.
        std.debug.assert(!child.state.reaped.load(.monotonic));
        std.debug.assert(child.state.term == null);
        child.state.term = term;
        child.state.reaped.store(true, .release);
    }

    /// Takes the right to be inside the operating system's wait for this child.
    fn claimReap(child: *Child) bool {
        return child.state.reaping.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }

    fn releaseReap(child: *Child) void {
        // Only the task that claimed the reap gives it back.
        std.debug.assert(child.state.reaping.load(.monotonic));
        child.state.reaping.store(false, .release);
    }

    /// Takes the right to reap the child, for a caller that waits for the child's
    /// end in a way of its own and reaps it afterwards: `Reaper`, which waits on
    /// a handle it can also be woken from, and does something between the end and
    /// the reap. `null` while another task holds it.
    ///
    /// While it is held the rest of the handshake behaves as it does for any wait
    /// in flight: `tryWait` says the child is still running, and `wait` waits for
    /// the term the holder publishes.
    pub fn holdReap(child: *Child) ?HeldReap {
        if (!child.claimReap()) return null;
        return .{ .child = child.* };
    }

    /// The right to reap a child, held until `release`, including after `wait`.
    pub const HeldReap = ReapHold;

    pub const WaitTimeoutError = contract.WaitTimeoutError;

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
                switch (win32.WaitForSingleObject(child.state.id, @min(left, windows_slice_ms))) {
                    win32.wait_timeout => {},
                    win32.wait_object_0 => return child.reapEnded(io, deadline),
                    // Ended, or a handle that cannot be waited on: either way the
                    // reap below is what says so.
                    else => break,
                }
                try std.Io.checkCancel(io);
            }
            return child.tryWaitClaimed();
        }

        if (!is_windows) {
            if (builtin.is_test) if (before_exit_watch) |hook| hook(child);
            if (comptime tree.Forks.supported) {
                while (true) {
                    const left = deadline.remainingMs(io);
                    if (left == 0) return child.tryWaitClaimed();
                    const ended = child.state.forks.ended(@min(left, wait_for.slice_ms)) orelse break;
                    if (ended) return child.reapEnded(io, deadline);
                    try std.Io.checkCancel(io);
                }
            }
            if (wait_for.Watch.open(child.state.id)) |watch| {
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

        // Darwin refuses a watch once exit has begun. The child may have
        // ended between the first reap attempt and registration; ask again
        // before treating a missing watch as a reason to sleep.
        if (try child.tryWaitClaimed()) |term| return term;

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

    var before_exit_watch: if (builtin.is_test) ?*const fn (*Child) void else void = if (builtin.is_test) null else {};

    test "an exit before watch registration is reaped without a fallback sleep" {
        if (is_windows) return error.SkipZigTest;
        if (!tree.Forks.supported) return error.SkipZigTest;
        const testing = std.testing;
        const io = testing.io;
        var child = try Child.spawn(testing.allocator, io, .{
            .argv = &.{ "/bin/sh", "-c", "read x" },
            .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
            .detach = true,
        });
        defer child.deinit(io);
        defer _ = child.killWait(io, 0) catch {};
        const Exit = struct {
            fn beforeWatch(owner: *Child) void {
                owner.closeStdin(testing.io);
                const until: Deadline = .in(testing.io, 5000);
                while (wait_for.endedUnreaped(owner.state.id) == .running) {
                    if (until.remainingMs(testing.io) == 0) @panic("fixture did not exit");
                    spin.yield();
                }
                // A fork check may consume NOTE_EXIT before the waiter runs.
                _ = owner.state.forks.any();
            }
            fn sleep(_: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
                return error.Canceled;
            }
        };
        var vtable = io.vtable.*;
        vtable.sleep = Exit.sleep;
        const no_sleep: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
        before_exit_watch = Exit.beforeWatch;
        defer before_exit_watch = null;
        // A termination request still owns the final group force before reap.
        child.state.end_descendants = true;
        _ = try child.wait(no_sleep);
        try testing.expect(child.state.scope_complete);
    }

    test "a child that never forked needs no final group enumeration" {
        if (is_windows) return error.SkipZigTest;
        if (!tree.Forks.supported) return error.SkipZigTest;
        const io = std.testing.io;
        var child = try Child.spawn(std.testing.allocator, io, .{
            .argv = &.{ "/bin/sleep", "30" },
            .stdio = .ignore,
            .detach = true,
        });
        defer child.deinit(io);
        defer _ = child.killWait(io, 0) catch {};
        const before = tree.testing_hook.group_forces.load(.acquire);
        try child.kill(.kill);
        _ = try child.wait(io);
        try std.testing.expectEqual(before, tree.testing_hook.group_forces.load(.acquire));
        try std.testing.expect(child.state.scope_complete);
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

    pub const TryWaitError = contract.TryWaitError;

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
        // tryWait must stay nonblocking even while a signaller walks a tree.
        if (!child.state.identity.tryLock()) return null;
        var published = false;
        defer {
            child.state.identity.unlock();
            // Adoption belongs to Orphans, after retirement has let go of the
            // identity. Its process-table look must not hold off signalling.
            if (builtin.os.tag == .linux and published) orphans.event();
        }
        if (child.settled()) |term| return term;
        if (child.state.identity_retired) return error.ReapedElsewhere;
        if (is_windows) {
            const term = try child.tryWaitWindows();
            published = term != null;
            return term;
        }

        const supervised = if (builtin.os.tag == .linux) child.state.supervisor != null else false;
        if (!supervised and (child.state.force_tree or child.state.end_descendants or child.state.descendants == .contain)) {
            // Normal containment and every termination request share this
            // final force. Once waitid observes the root ended, its last fork
            // has finished and its group id is still ours until waitpid.
            switch (wait_for.endedUnreaped(child.state.id)) {
                .running => return null,
                .ended => {
                    if (child.state.lineage) |tracker| if (!tracker.finish()) return null;
                    const contained = &child.state.cgroup;
                    if (!contained.active() or !contained.kill()) {
                        // Once this root has ended, a watch that saw no fork
                        // proves its private session never had another member.
                        const could_have_members = if (tree.Forks.supported) child.state.forks.any() else true;
                        if (could_have_members) if (child.state.pgid) |pgid| tree.forceHeldGroup(pgid, child.state.id);
                    }
                    child.state.force_tree = false;
                },
                .unknown => {},
            }
        }
        var status: c_int = undefined;
        while (true) {
            const rc = c.waitpid(child.state.id, &status, c.W.NOHANG);
            if (rc == 0) return null;
            if (rc > 0) {
                const root_status = if (builtin.os.tag == .linux) if (child.state.supervisor) |owner| owner.result() catch |err| {
                    child.state.identity_retired = true;
                    return err;
                } else @as(u32, @bitCast(status)) else @as(u32, @bitCast(status));
                child.state.scope_complete = true;
                const term = statusToTerm(root_status);
                if (child.state.lineage) |tracker| if (tracker.failedTracking()) {
                    child.state.identity_retired = true;
                    published = true;
                    return error.Unexpected;
                };
                child.publish(term);
                published = true;
                return term;
            }
            switch (c.errno(rc)) {
                .INTR => continue,
                .CHILD => {
                    child.state.identity_retired = true;
                    return error.ReapedElsewhere;
                },
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
            if (tries < 8) spin.yield() else try std.Io.sleep(io, .fromMilliseconds(1), .awake);
            tries += 1;
            try std.Io.checkCancel(io);
        }
    }

    /// What `kill` sends: the three requests to end that mean the same thing on
    /// both systems, the common POSIX signals by name, and any POSIX signal by
    /// number. `child/contract.zig` says what each is on each system.
    pub const Signal = contract.Signal;

    pub const KillError = contract.KillError;

    /// Sends `signal` to the child and what it started: asks it to stop, or —
    /// with a signal that is not one of the three requests to end — to reload,
    /// pause, resume or whatever else the program makes of it. Every signal is
    /// aimed the same way; only `.kill` is sent more than once, and only
    /// `.interrupt`, `.terminate` and `.kill` make the tree part of the child's
    /// ending (`Signal.ends`).
    ///
    /// **What it reaches.** On Windows every child is in a job object of its own,
    /// and `.kill` ends the job, so it reaches the whole tree whether or not the
    /// child was detached.
    ///
    /// On Linux, where this process may make a cgroup below its own, every child
    /// is put in one of its own before it runs (held in its lifecycle; `cgroup.zig`
    /// says how that is found out), and the cgroup is the reach: `.kill` writes
    /// `cgroup.kill`, which ends everything in it at once and is safe against a
    /// fork while it is delivered, and the other two signal each member. A
    /// descendant that changed its group or session, or was orphaned, is still
    /// in it. What leaves it is a process that moves itself to another cgroup it
    /// may write to. Where no cgroup could be made — a read-only cgroup mount, as
    /// in a default container, a cgroup owned by another user, a kernel before
    /// 5.14 — a child is reached as on the other POSIX systems, below.
    ///
    /// A contained Linux child has a private supervisor. Signals go through
    /// its command socket, so the caller cannot signal a recycled root pid.
    /// Its root group and adoptees receive requests, with other cgroup members
    /// reached where available. A force recursively ends and reaps the whole
    /// adoption scope; completion retains the root's own exit status.
    ///
    /// Where `Orphans` runs, a descendant whose parent ended before the signal is
    /// this process's child by then, adopted, and is reached here only through
    /// the child's cgroup: nothing else says which child it came from, and this
    /// does not guess. `Orphans.killAll` ends every adopted process.
    ///
    /// Otherwise POSIX has no container for a tree, and this reaches three things:
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
    /// **A child with nothing below it is signalled alone.** It has no
    /// descendants, so there is nothing for the walk to name, and the walk is the
    /// cost of this call: on Darwin `proc_listchildpids` passes over the whole
    /// process table each time it is asked, and on Linux the pass reads every
    /// process's `/proc` record. On Darwin `spawn` watches the child's forks
    /// from before it runs (`tree.Forks`), and this sends the signal with no walk
    /// while the watch has seen none. On Linux it reads the child's own
    /// `children` files first, one per thread, and sends the signal with no walk
    /// while they name nobody. Either way, for `.kill` it looks once more after
    /// the signal, so that a first child made while it was being sent still gets
    /// the passes above. A child that has a child is walked as described.
    ///
    /// A child that has already been reaped is not signalled, because its name no
    /// longer belongs to it; that case is not an error. A child already reaped
    /// on its own leaves descendants to the chosen lifecycle policy.
    ///
    /// This does not wait for the child to exit. It shares an identity claim with
    /// final reaping: no wait can release the pid or close the Windows handles
    /// during the descendant walk or signal delivery. The child still needs
    /// reaping when this returns, unless another task has already done it.
    pub fn kill(child: *Child, signal: Signal) KillError!void {
        // Never wait for an exit here. Whoever holds identity is only delivering
        // a signal or doing the final nonblocking reap, not waiting on the child.
        spin.lock(&child.state.identity);
        defer child.state.identity.unlock();
        if (child.settled() != null or child.state.identity_retired) return;
        if (!signal.valid()) return error.Unsupported;
        if (signal.ends()) child.state.end_descendants = true;
        if (builtin.is_test) if (signal_probe) |probe| probe.beforeSignal(child);
        if (is_windows) return child.killWindows(signal);
        const sig = signal.toPosix();

        if (comptime builtin.os.tag == .linux) if (child.state.supervisor) |owner| {
            if (sig == .KILL and child.state.cgroup.active()) _ = child.state.cgroup.kill();
            var cgroup_signalled = false;
            if (sig != .KILL and child.state.cgroup.active())
                cgroup_signalled = (try child.state.cgroup.signalMembers(sig, child.state.process_id, child.state.pgid)) != null;
            return owner.request(sig, cgroup_signalled);
        };
        if (sig == .KILL) child.state.force_tree = true;
        const target: posix.pid_t = if (child.state.pgid) |pgid| -pgid else child.state.id;

        // A child in a cgroup of its own: the cgroup is the tree, whatever the
        // processes in it have done with their groups, sessions and parents.
        // `.kill` ends it in one write, safe against a fork during delivery;
        // anything else goes to each member not in the group, then to the group
        // or the child, so none of them is asked twice. A cgroup the kernel will
        // not act on leaves the child to the walk below.
        if (child.state.cgroup.active()) contained: {
            if (sig == .KILL) {
                if (!child.state.cgroup.kill()) break :contained;
            } else {
                _ = (try child.state.cgroup.signalMembers(sig, child.state.id, child.state.pgid)) orelse break :contained;
            }
            return child.signalTarget(target, sig);
        }

        // A child with nothing below it has no descendants for a walk to name,
        // and its stop is the signal alone. `mayHaveDescendants` says how that is
        // known on each system.
        if (!child.mayHaveDescendants()) {
            const answer = child.signalTarget(target, sig);
            // A first child made while the signal was being sent is seen by the
            // second look; then the passes below, as for any tree.
            if (sig != .KILL or !child.mayHaveDescendants()) return answer;
            try child.killPasses(target, sig);
            return answer;
        }

        // The descendants that the group does not cover, deepest first, and before
        // the child itself: a leader signalled before the processes below it
        // leaves them orphaned, and an orphan belongs to `init` and is named by no
        // walk. A descendant already in the group about to be signalled is left to
        // it, so the ordinary tree gets the one signal it always did.
        // A walk that cannot hold the tree still leaves the child and its group
        // to be signalled; the incomplete pass is reported after that.
        const walked = tree.signalDescendants(child.state.id, sig, child.state.pgid);

        const answer = child.signalTarget(target, sig);
        const passes = if (sig == .KILL) child.killPasses(target, sig) else {};
        try answer;
        _ = try walked;
        return passes;
    }

    /// Whether a walk could name anything below the child, asked without one.
    ///
    /// **Darwin**: the watch on the child's forks, registered before it ran
    /// (`tree.Forks`), has seen none: a child that has never forked has no
    /// descendants. A fork made in the kernel is noted before the process it
    /// started can run.
    ///
    /// **Linux**: no thread of the child has a child now (`tree.hasChildren`),
    /// one small read per thread where the walk reads every process on the
    /// system. A child made while this is asked is seen by the look `kill` takes
    /// after a `.kill` has been sent, as long as its parent has not yet gone.
    ///
    /// **Elsewhere** it cannot be said, and the answer is the walk.
    fn mayHaveDescendants(child: *Child) bool {
        if (builtin.os.tag == .linux) return tree.hasChildren(child.state.id);
        return child.state.forks.any();
    }

    /// `.kill` is the one that promises to leave nothing behind, and
    /// `kill(-pgid)` is not atomic against a `fork` inside the group: a process
    /// started while the signal was being delivered is in the group without having
    /// been in it when the signal was sent. So it is asked again until a pass names
    /// no descendant, which for a tree that is already dead is the very next one.
    fn killPasses(child: *Child, target: posix.pid_t, sig: posix.SIG) KillError!void {
        var pass: u8 = 0;
        while (pass < kill_passes) : (pass += 1) {
            const reached = tree.signalDescendants(child.state.id, sig, null);
            _ = c.kill(target, sig);
            if (try reached == 0) break;
        }
    }

    /// How many times after the first `.kill` will look again for something that
    /// was started while it was working. Two is enough for a tree that forks once
    /// more on its way out; a tree that forks faster than it can be killed is not
    /// something a bound can fix.
    const kill_passes: u8 = 2;

    fn signalTarget(child: *Child, target: posix.pid_t, sig: posix.SIG) KillError!void {
        return signalOwnedTarget(PosixSignals, child.state.id, target, sig);
    }

    const PosixSignals = struct {
        fn send(target: posix.pid_t, sig: posix.SIG) ?posix.E {
            if (c.kill(target, sig) == 0) return null;
            return c.errno(@as(c_int, -1));
        }

        fn ended(pid: posix.pid_t) wait_for.Ended {
            return wait_for.endedUnreaped(pid);
        }
    };

    fn signalOwnedTarget(comptime System: type, pid: posix.pid_t, target: posix.pid_t, sig: posix.SIG) KillError!void {
        switch (System.send(target, sig) orelse return) {
            .PERM => {
                // Darwin refuses a signal addressed to a process group whose only
                // remaining member has exited and not yet been reaped. That is not
                // a permission problem in any sense the caller can act on, so it is
                // reported as what it is: the child is already gone.
                if (System.ended(pid) == .ended) return;
                // A Darwin group walk can exclude an exiting root before waitid
                // can observe it. Address the held root directly: this also
                // distinguishes a denied live child's actual permissions from
                // the group's empty delivery set. Identity is still held.
                if (target < 0) return signalOwnedTarget(System, pid, pid, sig);
                return error.PermissionDenied;
            },
            // No such process: the child ended between the check above and here.
            .SRCH => return,
            // `kill` checked the number against the system's range; a number
            // inside it the system still refuses is one it does not have.
            .INVAL => return error.Unsupported,
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    test "a group leaving before its exit is waitable still receives a child signal" {
        if (is_windows) return error.SkipZigTest;
        const Leaving = struct {
            var root_signalled: bool = false;

            fn send(target: posix.pid_t, _: posix.SIG) ?posix.E {
                if (target < 0) return .PERM;
                root_signalled = true;
                return null;
            }

            fn ended(_: posix.pid_t) wait_for.Ended {
                return .running;
            }
        };
        Leaving.root_signalled = false;
        try signalOwnedTarget(Leaving, 123, -123, .TERM);
        try std.testing.expect(Leaving.root_signalled);
    }

    test "a refused group still reports the held child's actual permission denial" {
        if (is_windows) return error.SkipZigTest;
        const Denied = struct {
            fn send(_: posix.pid_t, _: posix.SIG) ?posix.E {
                return .PERM;
            }

            fn ended(_: posix.pid_t) wait_for.Ended {
                return .running;
            }
        };
        try std.testing.expectError(error.PermissionDenied, signalOwnedTarget(Denied, 123, -123, .TERM));
    }

    pub const KillWaitError = contract.KillWaitError;

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
    /// reaches `Term` in full. A caller that wants a number of its own on
    /// that system should pass a `grace_ms` of zero; a caller that wants to know
    /// whether the child ended well should ask `succeeded`.
    ///
    /// The grace is `waitTimeout`, so a child that obeys the `.terminate` is
    /// noticed the moment it does rather than at the end of an interval.
    ///
    /// `error.OutOfMemory` is `kill`'s: the walk could not hold the child's
    /// tree. The child itself was killed and has been reaped when it returns.
    pub fn killWait(child: *Child, io: std.Io, grace_ms: u32) KillWaitError!Term {
        // A child that has already ended is reaped rather than signalled.
        if (try child.tryWait()) |term| return term;

        if (grace_ms > 0) {
            // ziglint-ignore: Z026 a `.terminate` that cannot be sent leaves the grace to run out, and the `.kill` after it reports
            child.kill(.terminate) catch {};
            if (try child.waitTimeout(io, grace_ms)) |term| return term;
        }

        // A walk too large to hold still killed the child itself, so it is
        // reaped before the incomplete walk is reported.
        child.kill(.kill) catch |err| switch (err) {
            error.OutOfMemory => {
                _ = try child.wait(io);
                return err;
            },
            else => return err,
        };
        return child.wait(io);
    }

    pub const WaitTreeError = contract.WaitTreeError;

    /// Waits up to `timeout_ms` for everything the child started to end, and says
    /// whether it did. **Windows, and Linux for a child in a cgroup of its own.**
    ///
    /// `true` means the container the child was put in holds no process any
    /// more: not the child, and not a grandchild the child started and left
    /// behind, whatever that grandchild did with its group, its session or its
    /// parent. That is also confirmed by a contained `wait`. With the survival
    /// policy it is the question a program that is about to take down a
    /// subsystem has: a child that exits having started a server is a tree that
    /// is still running. `false` means the time ran out with something still in
    /// it.
    ///
    /// On Windows the container is the job object, which reports to a
    /// completion port; on Linux it is the child's cgroup, whose `cgroup.events`
    /// wakes a `poll` when its `populated` line changes, so the wait is woken by
    /// the change rather than by asking again. A process that has ended and not
    /// been reaped is not in it. Either way the deadline is spent in five
    /// millisecond slices, between which cancelation is asked about, as every
    /// wait here is.
    ///
    /// Ask it before `deinit`, which releases the job and its port, or the
    /// cgroup, under the chosen descendant policy.
    ///
    /// A zero `timeout_ms` asks and does not wait, which is how to poll. On
    /// Windows the job's message is posted once and taking it off the port
    /// consumes it, so this remembers: once it has answered `true` it answers
    /// `true` thereafter. A Linux cgroup is asked again each time.
    ///
    /// A Linux child that was given no cgroup — this process may not make one
    /// below its own, which `kill` describes — is `error.Unsupported`: what
    /// remains is a walk down from the child, which cannot tell a tree that has
    /// ended from one that has been orphaned.
    ///
    /// **Elsewhere on POSIX there is no counterpart, and naming one would be a
    /// lie.** A process group is an address to send signals to and nothing is
    /// accounted to it. The nearest thing there — the descendant walk `kill` uses
    /// — cannot answer this question: it walks down from the child, and a
    /// grandchild whose parent has exited belongs to `init` and is related to the
    /// child by nothing the system will tell you. A walk that named nothing would
    /// mean "the tree has ended" and "the tree has been orphaned"
    /// indistinguishably, and on the BSDs and illumos, which name a process's
    /// children only through the whole process table, it would mean neither. So
    /// this is a compile error there rather than an answer that is right on one
    /// system and wrong on three.
    pub fn waitTree(child: *Child, io: std.Io, timeout_ms: u32) WaitTreeError!bool {
        if (is_windows) return child.waitTreeWindows(io, timeout_ms);
        if (builtin.os.tag != .linux) @compileError(
            "Child.waitTree is Windows and Linux only: a job object and a cgroup " ++
                "are containers the system accounts for, and this system has no " ++
                "such thing to ask. See Child.kill for what a signal reaches there.",
        );
        return child.waitTreeLinux(io, timeout_ms);
    }

    fn waitTreeLinux(child: *Child, io: std.Io, timeout_ms: u32) WaitTreeError!bool {
        const contained = &child.state.cgroup;
        if (!contained.active()) return error.Unsupported;
        return contained.waitEmpty(io, timeout_ms);
    }

    /// How long one wait on the completion port lasts before the caller is given a
    /// chance to notice it has been cancelled.
    ///
    /// `GetQueuedCompletionStatus` is not a cancelation point, so the deadline is
    /// spent in slices of this and cancelation is asked about between them. The
    /// same five milliseconds `wait.slice_ms` spends on POSIX, for the same
    /// reason.
    const tree_slice_ms: u32 = 5;

    fn waitTreeWindows(child: *Child, io: std.Io, timeout_ms: u32) WaitTreeError!bool {
        if (child.state.tree_ended) return true;
        const port = child.state.job_port orelse return false;
        const job = child.state.job orelse return false;
        const deadline: Deadline = .in(io, timeout_ms);

        while (true) {
            const left = deadline.remainingMs(io);
            var message: windows.DWORD = undefined;
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
                if (key == @intFromPtr(job) and message == win32.job_object_msg_active_process_zero) { // safe: the completion key against the job handle's value, nothing dereferenced
                    child.state.tree_ended = true;
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
        const state = child.state;
        if (state.stdin) |f| return f;
        if (child.state.pty) |m| return m.write;
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
        const state = child.state;
        if (state.stdout) |f| return f;
        if (child.state.pty) |m| return m.read;
        return null;
    }

    /// The separate standard-error pipe, borrowed until closure or deinit.
    pub fn stderrFile(child: Child) ?std.Io.File {
        const state = child.state;
        return state.stderr;
    }

    /// The borrowed terminal streams, when spawned on a pair.
    pub fn terminalMaster(child: Child) ?Pty.Master {
        const state = child.state;
        return state.pty;
    }

    /// Transfers the stdin pipe to the caller, who must close it. Terminal streams stay borrowed.
    pub fn takeStdin(child: *Child) ?std.Io.File {
        const state = child.state;
        const taken = state.stdin;
        state.stdin = null;
        return taken;
    }

    /// Transfers the stdout pipe to the caller, who must close it. Terminal streams stay borrowed.
    pub fn takeStdout(child: *Child) ?std.Io.File {
        const state = child.state;
        const taken = state.stdout;
        state.stdout = null;
        return taken;
    }

    /// Transfers the stderr pipe to the caller, who must close it. Terminal streams stay borrowed.
    pub fn takeStderr(child: *Child) ?std.Io.File {
        const state = child.state;
        const taken = state.stderr;
        state.stderr = null;
        return taken;
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

    /// Owns collected bytes; move before sharing and never copy an owner.
    pub const Output = child_output.Output;

    pub const OutputOptions = contract.OutputOptions;

    pub const OutputError = contract.OutputError;

    /// Runs the child to the end and collects what it wrote.
    ///
    /// Both streams are read as either has bytes, because a child that fills
    /// one pipe while the parent is reading the other deadlocks, and because a
    /// timeout that a blocked read can defeat is not a timeout: from one task
    /// that polls the pipes and the child's exit together where the system has
    /// a handle for the exit, and on reader tasks elsewhere (Windows).
    ///
    /// `allocator` need not be safe to use from several threads: where the
    /// streams are read on tasks, their allocations are serialized. The
    /// returned `Output` is freed with `allocator`.
    ///
    /// The child is reaped when this returns, whether it ended on its own or was
    /// killed, so `wait` afterwards answers from the same term. That holds for a
    /// call that returns an error too, a cancelation included: a run abandoned
    /// is a run ended, so the child and what it started are killed and reaped
    /// before the error comes back, and no caller is left holding a process it
    /// can no longer wait for. `deinit` is still the caller's to make.
    pub fn output(
        child: *Child,
        allocator: Allocator,
        io: std.Io,
        options: OutputOptions,
    ) OutputError!Output {
        return child.outputUntil(allocator, io, options, null);
    }

    /// `output`, with `until` a deadline over the whole of it: the run's own
    /// timeout and every drain end by it at the latest.
    fn outputUntil(
        child: *Child,
        allocator: Allocator,
        io: std.Io,
        options: OutputOptions,
        until: ?Deadline,
    ) OutputError!Output {
        errdefer child.abandon(io);
        // On a system with a handle that becomes readable when the child ends,
        // the two pipes and that handle are watched together from this task, so
        // no task is started and no thread is woken to read a pipe. Windows, and
        // a system with nothing to watch, keep the readers on tasks.
        const published = try child.result();
        if (!is_windows) {
            // A published term needs only stream draining. Never register an OS
            // watch on the retired number, which may already name a stranger.
            if (published != null) return child.outputPolled(allocator, io, options, until, null, published, false);
            if (comptime tree.Forks.supported) {
                if (child.state.forks.queue) |queue|
                    return child.outputPolled(allocator, io, options, until, .{ .handle = queue }, null, true);
            }
            if (wait_for.Watch.open(child.state.id)) |watch| return child.outputPolled(allocator, io, options, until, watch, null, false);
        }
        // The readers grow the collected streams on tasks of their own; their
        // allocations are made one at a time, so the caller's allocator need
        // not be safe to share.
        var serial: SerialAllocator = .{ .parent = allocator, .io = io };
        return child.outputOnTasks(serial.allocator(), io, options, until);
    }

    pub const ExchangeOptions = contract.ExchangeOptions;

    pub const ExchangeError = contract.ExchangeError;

    /// Runs the child to the end with `input` on its standard input, which
    /// then closes, and collects what it wrote: `output` with the input
    /// written alongside, so neither side waits on a full pipe, under one
    /// deadline.
    ///
    /// `input` is borrowed for the call and written from one task as it is,
    /// never copied. Input the child does not read is not an error: a program
    /// may end, or close its input, without taking all of it. Any other write
    /// failure is returned once the child has ended. With no input, standard
    /// input is closed at once; input for a child whose standard input is not
    /// a pipe this `Child` holds is `error.NoStdinPipe`.
    ///
    /// `ExchangeOptions.timeout_ms` bounds the whole call: the input, the run,
    /// the reap and the drain after it. A child still running then is killed
    /// with no grace and `Output.timedOut` is true; a write still blocked —
    /// on something the child started that holds its input and never reads —
    /// is interrupted. The call returns by the deadline, give or take the
    /// moment a kill takes.
    ///
    /// `allocator` need not be safe to use from several threads: every
    /// allocation of the call is serialized, and grows only the two collected
    /// streams, each bounded by `max_bytes`. The returned `Output` is freed
    /// with `allocator`. As with `output`, the child is reaped when this
    /// returns, an error included — except `error.NoStdinPipe`, which refuses
    /// the call before it starts and leaves the child running.
    pub fn exchange(
        child: *Child,
        allocator: Allocator,
        io: std.Io,
        input: []const u8,
        options: ExchangeOptions,
    ) ExchangeError!Output {
        // A call refused for how it was made leaves the child as it was.
        const state = child.state;
        if (input.len != 0 and state.stdin == null) return error.NoStdinPipe;
        errdefer child.abandon(io);
        const until: ?Deadline = if (options.timeout_ms) |timeout_ms| .in(io, timeout_ms) else null;
        var feed: Feed = .{};
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        if (input.len == 0) {
            child.closeStdin(io);
        } else {
            const stdin = state.stdin.?;
            try group.concurrent(io, Feed.run, .{ io, &feed, stdin, input });
            // The task closes it once written.
            state.stdin = null;
        }
        var collected = try child.outputUntil(allocator, io, .{
            .max_bytes = options.max_bytes,
            .grace_ms = 0,
            .drain_ms = options.drain_ms,
        }, until);
        errdefer collected.deinit(allocator);
        // The child has ended. What still holds its input is not the child,
        // and a write to it is not waited for.
        group.cancel(io);
        if (feed.failure) |err| return err;
        return collected;
    }

    /// The input of an `exchange`, written on a task of its own.
    const Feed = struct {
        failure: ?std.Io.File.Writer.Error = null,

        fn run(io: std.Io, feed: *Feed, file: std.Io.File, bytes: []const u8) std.Io.Cancelable!void {
            // Only this task uses or closes the pipe once it has started.
            defer file.close(io);
            handles.writeStreamingAll(io, file, bytes) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                // The child ended, or closed its input, before taking all of it.
                error.BrokenPipe => {},
                else => feed.failure = err,
            };
        }
    };

    /// The end of a run nobody will finish: `.kill` and the reap, with
    /// cancelation held off, since the cancelation is usually why.
    fn abandon(child: *Child, io: std.Io) void {
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        // The run may have failed while draining after normal publication.
        // The job or cgroup still belongs to us even then; a retired process
        // or group number never becomes signalling authority again.
        const state = child.state;
        if (is_windows) {
            if (state.job) |job| _ = win32.TerminateJobObject(job, 1);
        } else if (state.cgroup.active()) _ = state.cgroup.kill();
        // ziglint-ignore: Z026 the run's own error is the one returned; a child that cannot be killed or reaped here has nowhere else to report
        _ = child.killWait(io, 0) catch {};
    }

    fn outputOnTasks(
        child: *Child,
        allocator: Allocator,
        io: std.Io,
        options: OutputOptions,
        until: ?Deadline,
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
            try group.concurrent(io, collect, .{ allocator, io, f, options.max_bytes, &out });
        } else out.done.store(true, .release);
        if (child.state.stderr) |f| {
            try group.concurrent(io, collect, .{ allocator, io, f, options.max_bytes, &err });
        } else err.done.store(true, .release);

        var timed_out = false;
        const deadline = runDeadline(io, options, until);
        const term = term: while (true) {
            // A reader that cannot continue leaves a pipe the child may fill and
            // block on. Notice it while the child is still running, end the child,
            // and report the read failure after both tasks have joined.
            if (out.readFailed() or err.readFailed()) {
                break :term try child.killWait(io, 0);
            }

            const slice_ms = if (deadline) |run_end| slice: {
                const left = run_end.remainingMs(io);
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
        const drain = drainDeadline(io, options, until);
        while (true) {
            if (out.done.load(.acquire) and err.done.load(.acquire)) break;
            const left = drain.remainingMs(io);
            if (left == 0) break;
            try std.Io.sleep(io, .fromMilliseconds(@min(left, 2)), .awake);
        }
        // Joins the tasks, so the lists below are this task's alone again.
        group.cancel(io);

        return Collector.output(allocator, &out, &err, term, timed_out);
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

        /// What the two collectors hold, as the `Output` of a run that ended
        /// with `term`: theirs no longer, and the first failure either met.
        fn output(allocator: Allocator, out: *Collector, err: *Collector, term: Term, timed_out: bool) OutputError!Output {
            const out_failure = out.failure.load(.acquire);
            const err_failure = err.failure.load(.acquire);
            if (out_failure == .read_failed or err_failure == .read_failed) return error.ReadFailed;
            if (out_failure == .out_of_memory or err_failure == .out_of_memory) return error.OutOfMemory;
            const stdout_bytes = try out.list.toOwnedSlice(allocator);
            errdefer allocator.free(stdout_bytes);
            const stderr_bytes = try err.list.toOwnedSlice(allocator);
            return Output.init(.{
                .stdout = stdout_bytes,
                .stderr = stderr_bytes,
                .stdout_truncated = out.truncated or !out.done.load(.acquire),
                .stderr_truncated = err.truncated or !err.done.load(.acquire),
                .term = term,
                .timed_out = timed_out,
            });
        }
    };

    /// What one round of `outputPolled` waits on: each stream still open, and
    /// the child's exit while it is still to come. `which` says what each
    /// descriptor is, 0 and 1 for the streams and 2 for the exit.
    const PollSet = struct {
        fds: [3]posix.pollfd,
        which: [3]u8,
        count: usize,

        /// A stream whose descriptor is not one is not something `poll`
        /// reports on: it is read here, directly, so that the read says what
        /// is wrong.
        fn init(
            allocator: Allocator,
            io: std.Io,
            streams: [2]?std.Io.File,
            collectors: [2]*Collector,
            max_bytes: usize,
            exit: ?posix.fd_t,
        ) OutputError!PollSet {
            var set: PollSet = .{ .fds = undefined, .which = undefined, .count = 0 };
            for (streams, collectors, 0..) |stream, collector, i| {
                if (collector.done.load(.acquire)) continue;
                if (stream.?.handle < 0) {
                    _ = try collectOnce(allocator, io, stream.?, max_bytes, collector);
                    continue;
                }
                set.add(stream.?.handle, @intCast(i));
            }
            if (exit) |fd| set.add(fd, 2);
            return set;
        }

        fn add(set: *PollSet, fd: posix.fd_t, what: u8) void {
            std.debug.assert(set.count < set.fds.len);
            set.fds[set.count] = .{ .fd = fd, .events = posix.POLL.IN, .revents = 0 };
            set.which[set.count] = what;
            set.count += 1;
        }
    };

    /// When a run collecting output is ended: its own timeout, or `until`,
    /// whichever comes first.
    fn runDeadline(io: std.Io, options: OutputOptions, until: ?Deadline) ?Deadline {
        const own: ?Deadline = if (options.timeout_ms) |timeout_ms| .in(io, timeout_ms) else null;
        return earlier(io, own, until);
    }

    /// When reading stops after the child has ended: `drain_ms` from now, or
    /// `until`, whichever comes first.
    fn drainDeadline(io: std.Io, options: OutputOptions, until: ?Deadline) Deadline {
        return earlier(io, Deadline.in(io, options.drain_ms), until).?;
    }

    fn earlier(io: std.Io, a: ?Deadline, b: ?Deadline) ?Deadline {
        const first = a orelse return b;
        const second = b orelse return first;
        return if (second.remainingMs(io) < first.remainingMs(io)) second else first;
    }

    /// How often an unbounded `output` wait gives its readers a chance to report
    /// that one of them cannot keep draining. Each bounded wait still uses the
    /// operating system's process handle rather than sleeping this interval.
    const output_wait_slice_ms: u32 = 10;

    fn collect(
        allocator: Allocator,
        io: std.Io,
        f: std.Io.File,
        max_bytes: usize,
        into: *Collector,
    ) std.Io.Cancelable!void {
        while (!try collectOnce(allocator, io, f, max_bytes, into)) {}
    }

    /// One read of a stream into its collector. True once the stream is finished,
    /// by its end or by a failure the collector now records; `done` is set then.
    fn collectOnce(
        allocator: Allocator,
        io: std.Io,
        f: std.Io.File,
        max_bytes: usize,
        into: *Collector,
    ) std.Io.Cancelable!bool {
        var discard: [64 * 1024]u8 = undefined;
        {
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

            const n = handles.readStreaming(io, f, &.{buffer}) catch |e| switch (e) {
                error.Canceled => return error.Canceled,
                else => {
                    if (!handles.finished(e)) into.failure.store(.read_failed, .release);
                    into.done.store(true, .release);
                    return true;
                },
            };
            if (!keeping) {
                // Allocation failed, but reading must continue until the child
                // exits or it can fill this pipe and make the wait deadlock.
                into.truncated = true;
                return false;
            }
            into.list.items.len += n;
            return false;
        }
    }

    /// `output` on one task: the pipes and the child's end are polled together.
    ///
    /// The promises are the same as the task-based path's. Two streams are read
    /// as either has bytes, so a child that fills one while the other is being
    /// read is never blocked; a timeout is a bound on the poll and not on a read
    /// that may never return; after the child ends the streams are drained for
    /// `drain_ms` and no longer, because whatever still holds them open is not
    /// the child.
    fn outputPolled(
        child: *Child,
        allocator: Allocator,
        io: std.Io,
        options: OutputOptions,
        until: ?Deadline,
        watch: ?wait_for.Watch,
        published: ?Term,
        borrowed_exit: bool,
    ) OutputError!Output {
        defer if (!borrowed_exit) if (watch) |opened| opened.close();
        var out: Collector = .init;
        var err: Collector = .init;
        errdefer out.list.deinit(allocator);
        errdefer err.list.deinit(allocator);

        const streams = [2]?std.Io.File{ child.stdoutFile(), child.state.stderr };
        const collectors = [2]*Collector{ &out, &err };
        // A stream this process does not hold is finished before it starts.
        for (streams, collectors) |stream, collector| {
            if (stream == null) collector.done.store(true, .release);
        }

        var timed_out = false;
        const deadline = runDeadline(io, options, until);
        var term = published;
        var drain: ?Deadline = if (published != null) drainDeadline(io, options, until) else null;
        var ended = false;
        while (true) {
            try std.Io.checkCancel(io);
            // A fork check or waiter may have consumed the shared exit note.
            if (comptime tree.Forks.supported) if (borrowed_exit and child.state.forks.exited.load(.acquire)) {
                ended = true;
            };
            const out_done = out.done.load(.acquire);
            const err_done = err.done.load(.acquire);
            if (term == null) {
                // A reader that cannot continue leaves a pipe the child may fill
                // and block on: end the child now and report the failure once
                // the other stream is drained.
                if (out.readFailed() or err.readFailed()) {
                    term = try child.killWait(io, 0);
                } else if (deadline != null and deadline.?.remainingMs(io) == 0) {
                    timed_out = true;
                    term = try child.killWait(io, options.grace_ms);
                } else if (ended) {
                    // Through the reap claim: a task holding it (a `Reaper`,
                    // or a `HeldReap`) reaps, and this reads what it publishes.
                    term = try child.tryWait();
                }
                if (term != null) drain = drainDeadline(io, options, until);
            }
            if (term != null and (out_done and err_done or drain.?.remainingMs(io) == 0)) break;

            var set = try PollSet.init(allocator, io, streams, collectors, options.max_bytes, if (term == null and !ended) watch.?.handle else null);
            const fds = set.fds[0..set.count];
            const which = set.which[0..set.count];
            const count = set.count;
            var slice: u32 = output_wait_slice_ms;
            if (term == null) {
                if (deadline) |run_end| slice = @min(slice, run_end.remainingMs(io));
            } else slice = @min(slice, drain.?.remainingMs(io));
            if (count == 0) {
                // The streams are finished and the child has been told to end;
                // it is only its own exit that is waited for now.
                if (try child.waitTimeout(io, slice)) |finished| {
                    term = finished;
                    drain = drainDeadline(io, options, until);
                }
                continue;
            }
            // A poll that cannot be made is a stream that cannot be read.
            const ready = posix.poll(fds, @intCast(slice)) catch return error.ReadFailed;
            if (ready == 0) continue;
            for (fds, which) |fd, i| {
                if (fd.revents == 0) continue;
                if (i == 2) {
                    // The child has ended, or is a moment from being waitable:
                    // the reap is asked for on the next round, and again until
                    // it answers.
                    if (comptime tree.Forks.supported) {
                        if (borrowed_exit) {
                            ended = child.state.forks.ended(0) orelse false;
                            continue;
                        }
                    }
                    ended = true;
                    continue;
                }
                _ = try collectOnce(allocator, io, streams[i].?, options.max_bytes, collectors[i]);
            }
        }

        return Collector.output(allocator, &out, &err, term.?, timed_out);
    }

    //======================================================================
    // Windows.
    //======================================================================

    fn closeHandles(child: *Child) void {
        windows.CloseHandle(child.state.id);
        windows.CloseHandle(child.state.thread);
        child.state.handles_open = false;
    }

    /// Closes the job under the selected lifecycle policy. Idempotent.
    fn closeJob(child: *Child) void {
        // The port goes after the job. A contained job ends its members here
        // and posts that to the port; the job must not report to a handle that
        // has gone, even though nothing reads the final message.
        defer if (child.state.job_port) |port| {
            child.state.job_port = null;
            windows.CloseHandle(port);
        };
        const job = child.state.job orelse return;
        child.state.job = null;
        trace.print("child: closing the job", .{});
        windows.CloseHandle(job);
        trace.print("child: job closed", .{});
    }

    fn tryWaitWindows(child: *Child) TryWaitError!?Term {
        switch (win32.WaitForSingleObject(child.state.id, 0)) {
            win32.wait_object_0 => {},
            win32.wait_timeout => return null,
            else => return win32.unexpected(windows.GetLastError()),
        }
        var code: windows.DWORD = undefined;
        const term: Term = if (win32.GetExitCodeProcess(child.state.id, &code) != .FALSE)
            .{ .exited = code }
        else
            .{ .unknown = 0 };
        const completed = try completion.poll(WindowsCompletion, child, term, child.state.descendants, child.state.end_descendants);
        if (completed == null) return null;
        if (child.state.descendants == .contain or child.state.end_descendants)
            child.state.scope_complete = true;
        child.closeHandles();
        child.publish(term);
        return term;
    }

    const WindowsCompletion = struct {
        pub fn releaseSurvivors(child: *Child) Child.TryWaitError!void {
            try child.releaseJobSurvivors();
        }
        pub fn end(child: *Child) Child.TryWaitError!void {
            const job = child.state.job orelse return error.Unexpected;
            if (win32.TerminateJobObject(job, 1) == .FALSE)
                return win32.unexpected(windows.GetLastError());
        }
        pub fn empty(child: *Child) Child.TryWaitError!bool {
            const job = child.state.job orelse return error.Unexpected;
            var counts: win32.JobObjectBasicAccountingInformation = undefined;
            if (win32.QueryInformationJobObject(job, win32.job_object_basic_accounting_information, &counts, @sizeOf(@TypeOf(counts)), null) == .FALSE)
                return win32.unexpected(windows.GetLastError());
            return counts.ActiveProcesses == 0;
        }
        pub fn ended(child: *Child) Child.TryWaitError!bool {
            if (child.state.tree_ended) return true;
            const job = child.state.job orelse return error.Unexpected;
            const port = child.state.job_port orelse return error.Unexpected;
            while (true) {
                var message: windows.DWORD = undefined;
                var key: windows.ULONG_PTR = undefined;
                var overlapped: ?*anyopaque = undefined;
                if (win32.GetQueuedCompletionStatus(port, &message, &key, &overlapped, 0) == .FALSE)
                    return switch (windows.GetLastError()) {
                        .WAIT_TIMEOUT => false,
                        else => |err| win32.unexpected(err),
                    };
                if (key == @intFromPtr(job) and message == win32.job_object_msg_active_process_zero) { // safe: the completion key is compared with the job handle, never dereferenced.
                    child.state.tree_ended = true;
                    return true;
                }
            }
        }
    };

    /// Release only kill-on-close, retaining every resource limit the caller
    /// chose. Failure leaves the process handles and status available to retry.
    fn releaseJobSurvivors(child: *Child) TryWaitError!void {
        const job = child.state.job orelse return;
        var limits: win32.JobObjectExtendedLimitInformation = undefined;
        if (win32.QueryInformationJobObject(job, win32.job_object_extended_limit_information, &limits, @sizeOf(@TypeOf(limits)), null) == .FALSE)
            return win32.unexpected(windows.GetLastError());
        limits.BasicLimitInformation.LimitFlags &= ~win32.job_object_limit_kill_on_job_close;
        if (win32.SetInformationJobObject(job, win32.job_object_extended_limit_information, &limits, @sizeOf(@TypeOf(limits))) == .FALSE)
            return win32.unexpected(windows.GetLastError());
    }

    fn killWindows(child: *Child, signal: Signal) KillError!void {
        const event: windows.DWORD = switch (signal) {
            .interrupt => win32.ctrl_c_event,
            .terminate => win32.ctrl_break_event,
            .kill => return child.terminateWindows(),
            // `Signal` names each of these and why Windows has nothing for it.
            else => return error.Unsupported,
        };
        const group = child.state.pgid orelse switch (signal) {
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
        if (child.state.job) |job| {
            trace.print("child: TerminateJobObject", .{});
            if (win32.TerminateJobObject(job, 1) != .FALSE) return;
        }
        if (win32.TerminateProcess(child.state.id, 1) != .FALSE) return;
        return switch (windows.GetLastError()) {
            .ACCESS_DENIED => {
                // Usually this means the process has already exited. Observe it
                // without reaping while signal delivery owns the identity.
                if (win32.WaitForSingleObject(child.state.id, 0) == win32.wait_object_0) return;
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
    ///
    /// The word is sixteen bits wide, and those are what is decoded. Nothing
    /// `waitpid` returns here sets the bits above them, and Darwin's
    /// `EXITSTATUS` in the standard library narrows everything above the low
    /// byte into a `u8` -- a panic, not an answer, for a word that did.
    fn statusToTerm(status: u32) Term {
        const word = status & 0xffff;
        return if (c.W.IFEXITED(word))
            .{ .exited = c.W.EXITSTATUS(word) }
        else if (c.W.IFSIGNALED(word))
            .{ .signal = c.W.TERMSIG(word) }
        else if (c.W.IFSTOPPED(word))
            .{ .stopped = c.W.STOPSIG(word) }
        else
            .{ .unknown = status };
    }

    /// Any status word decodes to a `Term`, and the `$?` a shell would give it
    /// is the one its bits say: the exit status in the second byte, or 128 and
    /// a signal's number -- whatever the bits above them hold.
    fn statusDecodes(_: void, smith: *std.testing.Smith) anyerror!void {
        @disableInstrumentation();
        if (is_windows) return error.SkipZigTest;
        try checkStatus(smith.value(u32));
    }

    fn checkStatus(status: u32) !void {
        const term = statusToTerm(status);
        // The two shapes every system's kernel writes, in the low sixteen
        // bits: an exit with its status in the second byte, and a signal's
        // number alone in the low seven. Any other word decodes to whatever
        // that system's macros make of it, and never to a panic.
        const word = status & 0xffff;
        if (word & 0xff == 0) {
            try std.testing.expectEqual(word >> 8, term.exited);
            try std.testing.expectEqual(@as(u8, @intCast(word >> 8)), shellStatus(term));
        } else if (word >> 8 == 0 and word & 0x7f != 0x7f) {
            try std.testing.expectEqual(word & 0x7f, @intFromEnum(term.signal));
            try std.testing.expectEqual(@as(u8, @intCast(128 + (word & 0x7f))), shellStatus(term));
        }
        _ = shellStatus(term);
        _ = signalName(term);
        _ = signalNumber(term);
    }

    test "a wait status word decodes to the end a shell reports" {
        try std.testing.fuzz({}, statusDecodes, .{});
    }

    test "a wait status word decodes whatever its upper bits hold" {
        if (is_windows) return error.SkipZigTest;
        for ([_]u32{ 0, 0x0100, 0xff00, 0x10000, 0x1ff00, 0xffff_0000, 0xffff_ffff, 0x0109, 0x1_0009, 0x137f, 0x1_137f }) |status| {
            try checkStatus(status);
        }
    }

    // A test can stop delivery at the boundary between taking the child's name
    // and using it. No hook or storage reaches a consumer build.
    var signal_probe: if (builtin.is_test) ?*SignalProbe else void = if (builtin.is_test) null else {};

    const SignalProbe = if (builtin.is_test) struct {
        context: *anyopaque,
        observe: *const fn (*anyopaque, *Child) void,
        fn beforeSignal(probe: *SignalProbe, child: *Child) void {
            probe.observe(probe.context, child);
        }
    } else struct {};

    test "output of an exited Darwin child needs no reader task" {
        if (is_windows) return error.SkipZigTest;
        if (!tree.Forks.supported) return error.SkipZigTest;
        const testing = std.testing;
        const io = testing.io;
        var child = try Child.spawn(testing.allocator, io, .{
            .argv = &.{ "/bin/echo", "retained" },
            .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
        });
        defer child.deinit(io);
        defer _ = child.killWait(io, 0) catch {};
        const until: Deadline = .in(io, 5000);
        while (wait_for.endedUnreaped(child.state.id) == .running) {
            if (until.remainingMs(io) == 0) return error.TestChildDidNotExit;
            try std.Io.sleep(io, .fromMilliseconds(1), .awake);
        }
        // Another fork check can consume the queued exit without reaping.
        _ = child.state.forks.any();
        const Refuse = struct {
            fn concurrent(_: ?*anyopaque, _: *std.Io.Group, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
                return error.ConcurrencyUnavailable;
            }
        };
        var vtable = io.vtable.*;
        vtable.groupConcurrent = Refuse.concurrent;
        const no_tasks: std.Io = .{ .userdata = io.userdata, .vtable = &vtable };
        var collected = try child.output(testing.allocator, no_tasks, .{});
        defer collected.deinit(testing.allocator);
        try testing.expectEqualStrings("retained\n", collected.stdout());
        try testing.expect(succeeded(collected.term()));
    }

    test "output on tasks bounds draining by elapsed time after a delayed sleep" {
        const testing = std.testing;
        const io = testing.io;
        const argv: []const []const u8 = if (is_windows) &.{ "cmd.exe", "/c", "set /p line=& exit 0" } else &.{ "/bin/sh", "-c", "read x" };
        var child = try spawn(testing.allocator, io, .{
            .argv = argv,
            .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
        });
        defer child.release(io) catch unreachable;
        defer _ = child.killWait(io, 0) catch {};
        child.closeStdin(io);
        _ = (try child.waitTimeout(io, 5000)) orelse return error.TestChildDidNotExit;

        // A live writer keeps the output open after the child has ended, as an
        // inherited pipe in a grandchild would, without leaving an orphan behind.
        var writer = try spawn(testing.allocator, io, .{
            .argv = argv,
            .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
        });
        defer writer.deinit(io);
        defer _ = writer.killWait(io, 0) catch {};
        child.state.stdout = writer.state.stdout;
        writer.state.stdout = null;

        const Clock = struct {
            var elapsed: std.atomic.Value(u32) = .init(0);

            fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
                return .{ .nanoseconds = @as(i96, elapsed.load(.acquire)) * std.time.ns_per_ms };
            }

            fn sleep(_: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
                // A two millisecond sleep that resumed after ten. Only the
                // caller's clock says how much of the drain budget was spent.
                _ = elapsed.fetchAdd(10, .release);
                try std.Io.checkCancel(std.testing.io);
            }
        };
        Clock.elapsed.store(0, .release);
        var vtable = io.vtable.*;
        vtable.now = Clock.now;
        vtable.sleep = Clock.sleep;
        const delayed_io: std.Io = .{ .vtable = &vtable, .userdata = io.userdata };
        var collected = try child.outputOnTasks(testing.allocator, delayed_io, .{ .drain_ms = 20 }, null);
        defer collected.deinit(testing.allocator);
        try testing.expect(collected.stdoutTruncated());
        try testing.expectEqual(@as(u32, 20), Clock.elapsed.load(.acquire));
    }

    test "a reap reported elsewhere retires the identity before kill can use its number" {
        if (is_windows) return error.SkipZigTest;
        const testing = std.testing;
        const io = testing.io;

        var child = try spawn(testing.allocator, io, .{
            .argv = &.{ "/bin/sh", "-c", "exit 7" },
            .stdio = .ignore,
        });
        defer child.release(io) catch unreachable;
        var status: c_int = undefined;
        while (c.waitpid(child.state.id, &status, 0) < 0) {
            if (c.errno(@as(c_int, -1)) != .INTR) return error.TestWaitFailed;
        }
        try testing.expectError(error.ReapedElsewhere, child.tryWait());
        try testing.expectError(error.ReapedElsewhere, child.result());
        try testing.expectEqual(@as(?Id, null), child.processId());

        var witness = try spawn(testing.allocator, io, .{
            .argv = &.{ "/bin/sh", "-c", "read x" },
            .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
        });
        defer witness.release(io) catch unreachable;
        defer _ = witness.killWait(io, 0) catch {};
        // Substitute an unrelated live process's number for the retired label:
        // exercise PID reuse without relying on the kernel to recycle a pid.
        child.state.id = witness.state.id;
        try child.kill(.kill);
        try testing.expectEqual(@as(?Term, null), try witness.waitTimeout(io, 20));
    }

    test {
        _ = @import("child/command_line.zig");
        if (is_windows) {
            _ = @import("child/windows.zig");
        } else {
            _ = @import("child/posix.zig");
            _ = @import("cgroup.zig");
            _ = @import("tree.zig");
            _ = @import("wait.zig");
        }
    }

    test "Term can carry every Windows exit code on every platform" {
        const term: Term = .{ .exited = 255 };
        try std.testing.expectEqual(@as(u16, 32), @bitSizeOf(@TypeOf(term.exited)));
    }

    test "Child lifecycle cannot be read or rewritten through public fields" {
        inline for (.{ "id", "thread", "handles_open", "job", "job_port", "tree_ended", "pgid", "forks", "cgroup", "term", "reaped", "reaping", "identity", "identity_retired" }) |name| {
            try std.testing.expect(!@hasField(Child, name));
        }
    }
};

/// `Child.HeldReap`: the right to reap a child, held until `release`,
/// including after `wait`. Release exactly once. The child must not be
/// deinited while it is held. Declared here rather than in `Child` only so
/// that its methods can read as methods; `Child.HeldReap` is its name.
pub const ReapHold = struct {
    /// Private: the child whose reap is held.
    child: Child,

    /// Blocks until the child ends, reaps it and publishes the term — or
    /// answers from the one already published.
    pub fn wait(held: ReapHold, io: std.Io) contract.WaitError!contract.Term {
        var child = held.child;
        return child.waitClaimed(io);
    }

    /// Gives the right back, whether or not the child was reaped.
    pub fn release(held: ReapHold) void {
        var child = held.child;
        child.releaseReap();
    }
};

pub const test_access = if (builtin.is_test) struct {
    pub const SignalProbe = Child.SignalProbe;
    pub fn probe(value: ?*Child.SignalProbe) void {
        Child.signal_probe = value;
    }
} else struct {};
