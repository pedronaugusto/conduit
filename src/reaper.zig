//! Waits for a child on a background task, so the owner can ask whether it has
//! ended, wait for it to end, and have it killed, none of them blocking on
//! anything but what it asked for.
//!
//! A `wait` is the only way to learn how a process ended, and it blocks. Where
//! a program is doing something else in the meantime — drawing a frame,
//! serving a request, waiting on a socket — the wait belongs on a task of its
//! own, and the result has to reach the other task safely. That is what this
//! is: one `std.Io.Group` task waiting for the child, one atomic the result is
//! published through, and one event that is set when it has been, so that
//! `wait` and `waitTimeout` wait on the answer rather than asking for it again
//! and again.
//!
//! Two things more, both of them about ending:
//!
//! * `kill` asks the child and what it started to end, and makes them if they
//!   have not by the end of a grace. It returns at once: the insisting is done
//!   on this `Reaper`'s own task, so a caller holding a lock can kill a child
//!   without waiting for it.
//! * `Options.end_tree` ends what the child leaves running when it ends by
//!   itself. See there for what that reaches on each system.
//!
//! Lifetime rules, all of them:
//!
//! * The `Child` must outlive the `Reaper`, and must not be deinited while
//!   the `Reaper` is running. `start` copies the `Child` handle, so the
//!   caller's own copy may move after it.
//! * A `Reaper` must not be copied or moved once `start` has been called: the
//!   running task holds a pointer to it. Safe builds assert it on each call.
//! * `deinit` (or `stop`, then `deinit`) must be called before the `Reaper`
//!   goes out of scope, including on the path where the child never exits.
//!   Either ends the task and waits for it to finish — and with it any
//!   insisting `kill` had still to do, so a program that wants a killed
//!   child gone waits for it first. With `enableSubreaper`, `stop` is the
//!   call that can fail, and `deinit` follows its success.
//! * After `exit` returns a non-null term, the child has been reaped.
//!   `Child.wait` and `Child.tryWait` keep returning the same term, and
//!   `Child.kill` does nothing. A wait failure is returned instead and is
//!   likewise final.
//!
//! The owner may go on calling `Child.kill`, `Child.killWait`, `Child.wait`
//! and `Child.tryWait` while this runs, which is the sequence the whole thing
//! exists for: ask `exit`, get `null`, and decide the child has had long
//! enough. Only one of them is inside the operating system's wait at a time,
//! and the one that is publishes the term to the rest — so `tryWait` answers
//! `null` while this holds the wait, and `killWait` returns the term this
//! task reaped rather than asking for a second one. `Child.result` documents
//! the handshake.

const builtin = @import("builtin");
const std = @import("std");
const Pin = @import("pin.zig").Pin;
const spin = @import("spin.zig");
const posix = std.posix;
const c = std.c;
const Child = @import("child.zig").Child;

const is_windows = builtin.os.tag == .windows;
const win32 = @import("win32.zig");
const tty = @import("conduit.tty");
const tree = @import("tree.zig");
const Orphans = @import("orphans.zig").Orphans;
const wait_for = @import("wait.zig");

const Term = Child.Term;
const Deadline = tty.Deadline;
const Cgroup = @import("cgroup.zig").Cgroup;
const Watchdog = @import("testing/support.zig").Watchdog;

// Published before signalling, and retained until the held reap ends the tree.
// Only the small deadline snapshot is under this lock; no I/O is done in it.
const Kill = struct {
    mutex: std.atomic.Mutex = .unlocked,
    deadline: ?Deadline = null,

    fn lock(kill: *Kill) void {
        spin.lock(&kill.mutex);
    }

    fn request(kill: *Kill, io: std.Io, grace_ms: u32) bool {
        const deadline: Deadline = .in(io, grace_ms);
        kill.lock();
        defer kill.mutex.unlock();
        if (grace_ms != 0 and kill.deadline != null) return false;
        kill.deadline = deadline;
        return true;
    }

    fn remaining(kill: *Kill, io: std.Io) ?u32 {
        kill.lock();
        const deadline = kill.deadline;
        kill.mutex.unlock();
        return if (deadline) |at| at.remainingMs(io) else null;
    }
};

pub const Reaper = struct {
    // Fields are private: read and change them only through the methods.
    /// The caller's handle, read by `start`: a subreaper's `Child` is
    /// spawned after `init`.
    source: *Child,
    /// The child being waited for, copied from `source` again by `start`. The
    /// child must not be deinited while this runs; the caller's handle may
    /// move.
    child: Child,
    options: Reaper.Options,
    /// The task running the wait, and the one `kill` insists on.
    group: std.Io.Group,
    /// `running`, a term encoded by `encode`, or an error encoded by
    /// `encodeError`. Written once by the task and read by anyone.
    state: std.atomic.Value(u64),
    /// Set once `state` holds the answer, whatever it is.
    answered: std.Io.Event,
    /// The first kill deadline; force requests replace it with immediate expiry.
    killing: Kill,
    /// POSIX: a pipe whose reading end the task waits on beside the child, and
    /// which `stop` and `deinit` write to. The wait on the child is not a cancelation point
    /// and has no deadline, so this is what ends it early. `null` until `start`,
    /// and where a pipe could not be had.
    wake: if (is_windows) void else ?[2]posix.fd_t,

    /// The explicit process-wide adoption scope, owned until stop.
    orphans: ?*Orphans,
    observation_failed: std.atomic.Value(bool),

    lifetime: std.atomic.Value(enum(u8) { ready, started, closed }),
    /// Safe builds: where this was when `start` began to hold a pointer to it.
    pin: Pin = .{},

    pub const Options = struct {
        /// End what the child leaves running when it ends, and reap the child only
        /// once that is done.
        ///
        /// **Linux, for a child in a cgroup of its own** (detached
        /// or not): once the child has ended, and before it is reaped, whatever
        /// is still running in the cgroup is asked to end with `SIGTERM`, given
        /// `tree_grace_ms`, and ended with `cgroup.kill` if it has not — however
        /// it had changed its group or session, and orphaned or not.
        ///
        /// **POSIX otherwise**, for a child spawned with `detach`: once the child has
        /// ended, and before it is reaped, what is left in its process group is
        /// asked to end with `SIGTERM`, given `tree_grace_ms` to do so, and sent
        /// `SIGKILL` if it has not. The child, ended but not reaped, still holds
        /// the group's id, so the signal cannot reach a group that has since been
        /// given the same number. A descendant that left the group before the
        /// child ended is related to nothing any more and is not reached, which is
        /// the limit `Child.kill` states too; Linux and Darwin are asked whether
        /// the group is empty, and elsewhere what is left is sent `SIGKILL` at
        /// once. A child that was not detached has no group of its own, and
        /// nothing is signalled for it. The wait needs a handle on the child's
        /// end (`waitTimeout` says which), and without one the child is reaped
        /// as it would have been and nothing is signalled.
        ///
        /// **Windows**: the job the child was put in is ended as soon as the
        /// child is reaped. There is no request there a process outside the
        /// child's console group can catch, so there is no grace to give.
        ///
        /// The term published is the child's own, however long its tree took.
        end_tree: bool = false,
        /// With `end_tree`, how long what the child left gets between being asked
        /// to end and being made to.
        tree_grace_ms: u32 = 1000,
    };

    /// A `Reaper` that is not waiting for anything yet. Call `start` to put the
    /// wait in flight.
    pub fn init(child: *Child, options: Options) Reaper {
        return .{
            .source = child,
            .child = child.*,
            .options = options,
            .group = .init,
            .state = .init(running),
            .answered = .unset,
            .killing = .{},
            .wake = if (is_windows) {} else null,
            .orphans = null,
            .observation_failed = .init(false),
            .lifetime = .init(.ready),
        };
    }

    /// Make this process a Linux child subreaper before spawning the child.
    /// One Reaper owns this process-wide scope. All adopted orphans belong to
    /// it, including those from other direct children; they have no remaining
    /// per-child attribution. Existing and conduit-spawned direct children keep
    /// their own waits. Until stop, every new direct child must use conduit,
    /// and no outside waitpid(-1) or SIGCHLD reaper may consume their statuses.
    /// The Child address may be reserved before spawn; start needs it initialized.
    /// End and reap all direct children before stop: a running direct child
    /// could create another orphan while the process setting is restored.
    /// Configure once, before start, from the owner's task. Unsupported off Linux.
    /// An independent task observes and reaps exited adoptees every 5 ms, even
    /// if another task owns the root wait. Scheduling and procfs access can
    /// extend that interval.
    pub fn enableSubreaper(reaper: *Reaper) Orphans.StartError!void {
        if (reaper.lifetime.load(.acquire) != .ready or reaper.orphans != null)
            return error.AlreadyStarted;
        const allocator = std.heap.page_allocator;
        const orphans = try allocator.create(Orphans);
        errdefer allocator.destroy(orphans);
        orphans.* = .init(allocator);
        try orphans.start();
        reaper.orphans = orphans;
    }

    /// Copy identities owned by this explicit adoption scope. No record borrows
    /// the scope or confers signal authority. Empty without enableSubreaper.
    pub fn adoptionRecords(reaper: *Reaper, out: []Orphans.Record) Orphans.ListError![]Orphans.Record {
        reaper.pin.check(reaper);
        const owner = reaper.orphans orelse return out[0..0];
        return owner.list(out);
    }

    /// Notification of new scoped records, registered before start. Reset the
    /// event, compare adoptionCount, and take another snapshot if it changed.
    pub fn adoptionEvent(reaper: *Reaper, io: std.Io) ?*std.Io.Event {
        reaper.pin.check(reaper);
        const owner = reaper.orphans orelse return null;
        return owner.adoptionEvent(io);
    }

    pub fn adoptionCount(reaper: *const Reaper) u64 {
        reaper.pin.check(reaper);
        const owner = reaper.orphans orelse return 0;
        return owner.adoptionCount();
    }

    pub const StartError = std.Io.ConcurrentError || error{AlreadyStarted};

    /// Puts the wait in flight.
    ///
    /// The task must be able to run alongside the caller, so an `std.Io`
    /// implementation with no concurrency to offer fails here rather than
    /// deadlocking later. A successful start consumes this lifetime: another start,
    /// including after stop, returns AlreadyStarted. A failed concurrency
    /// attempt releases its resources and may be retried before stop.
    pub fn start(reaper: *Reaper, io: std.Io) StartError!void {
        if (reaper.lifetime.cmpxchgStrong(.ready, .started, .acq_rel, .acquire) != null)
            return error.AlreadyStarted;
        errdefer reaper.lifetime.store(.ready, .release);
        reaper.child = reaper.source.*;
        reaper.pin.set(reaper);
        reaper.observation_failed.store(false, .release);
        // Without a pipe the wait falls back to Child.wait, which is
        // a cancelation point of its own: the wake is how a better wait is ended,
        // not a condition of waiting at all.
        if (!is_windows) reaper.wake = tty.pipe(.{}) catch null;
        errdefer reaper.closeWake();
        if (reaper.orphans != null) {
            try reaper.group.concurrent(io, observeAdoption, .{ reaper, io });
        }
        errdefer reaper.group.cancel(io);
        return reaper.group.concurrent(io, run, .{ reaper, io });
    }

    pub const ExitError = Child.WaitError;

    /// How the child ended, or `null` while the wait is still running.
    ///
    /// Never blocks. A `null` is a snapshot and may be stale by the time the caller
    /// acts on it; a term or error is final.
    pub fn exit(reaper: *const Reaper) ExitError!?Term {
        reaper.pin.check(reaper);
        const state = reaper.state.load(.acquire);
        if (state == running) return null;
        return @as(?Term, try decode(state));
    }

    /// How the child ended, once it has: blocks until the task has the answer.
    ///
    /// This waits on the answer rather than on the child, so any number of tasks
    /// may call it at once, and none of them asks the operating system anything.
    /// It is a cancelation point. A `Reaper` that was never started never
    /// answers.
    pub fn wait(reaper: *Reaper, io: std.Io) ExitError!Term {
        reaper.pin.check(reaper);
        try reaper.answered.wait(io);
        return (try reaper.exit()).?;
    }

    pub const WaitTimeoutError = ExitError;

    /// `wait`, for at most `timeout_ms`: `null` if the child has not ended by
    /// then.
    pub fn waitTimeout(reaper: *Reaper, io: std.Io, timeout_ms: u32) WaitTimeoutError!?Term {
        reaper.pin.check(reaper);
        const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{
            .raw = .fromMilliseconds(timeout_ms),
            .clock = .awake,
        });
        while (true) {
            reaper.answered.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
                // A wakeup before the deadline is spurious; one after it is the
                // answer that there is none yet.
                error.Timeout => if (deadline.durationFromNow(io).raw.nanoseconds > 0) continue else return reaper.exit(),
                error.Canceled => return error.Canceled,
            };
            return reaper.exit();
        }
    }

    /// Asks the child to end, and makes it if it has not within `grace_ms`.
    ///
    /// `.terminate` now and `.kill` once the grace has passed, each of them
    /// `Child.kill`'s and reaching what `Child.kill` reaches. A held reap also
    /// ends anything left in the owned group or cgroup before releasing its
    /// identity, using the remainder of the same grace. A `grace_ms` of zero
    /// is `.kill` now. It never blocks: the grace is waited out on this
    /// `Reaper`'s task, and ends early once the child and its owned tree end.
    ///
    /// Only the first request with a grace counts. A second one would either
    /// wait longer than the first, which it cannot, or less, which is a request
    /// with a grace of zero — and that one is always sent. A signal that cannot
    /// be delivered is not reported: the child has ended, or is ending, and the
    /// term says how.
    pub fn kill(reaper: *Reaper, io: std.Io, grace_ms: u32) void {
        reaper.pin.check(reaper);
        if (!reaper.killing.request(io, grace_ms)) return;
        if (grace_ms == 0) {
            // ziglint-ignore: Z026 undelivered means ended or ending, as documented above; the term says how
            reaper.target().kill(.kill) catch {};
            return;
        }
        // ziglint-ignore: Z026 undelivered means ended or ending, as documented above; the term says how
        reaper.target().kill(.terminate) catch {};
        reaper.group.concurrent(io, insist, .{ reaper, io, grace_ms }) catch {
            // No task to wait out the grace on: insisting now is the one answer
            // that still ends the child.
            reaper.kill(io, 0);
        };
    }

    /// The child as the caller holds it before `start`, and as this holds it
    /// after.
    fn target(reaper: *Reaper) *Child {
        return if (reaper.lifetime.load(.acquire) == .ready) reaper.source else &reaper.child;
    }

    fn insist(reaper: *Reaper, io: std.Io, grace_ms: u32) void {
        const term = reaper.waitTimeout(io, reaper.killing.remaining(io) orelse grace_ms) catch |err| switch (err) {
            // `stop` or `deinit`: the owner is done with this child.
            error.Canceled => return,
            // An answer, if an unhappy one: the child is no longer waited for.
            else => return,
        };
        if (term == null) reaper.kill(io, 0);
    }

    /// Stops waiting, releases the task and ends the adoption scope.
    ///
    /// If the child has already ended this returns as soon as the task notices. If
    /// it has not, the task is told to go — and any insisting `kill` had yet to
    /// do goes with it — so a program that wants the child gone should see it
    /// gone first, with `kill` and `wait`.
    ///
    /// With enableSubreaper, call after all direct children ended and were reaped.
    /// It ends and reaps remaining adoptees, then restores the process setting.
    /// Cancellation, resource and restoration failures retain the scope, and
    /// the call can be made again. DirectChildrenRemain means a direct child
    /// still owns a wait. Once it has succeeded another call does nothing, and
    /// a later `start` or `enableSubreaper` is AlreadyStarted.
    pub const StopError = Orphans.KillError || Orphans.StopError;

    pub fn stop(reaper: *Reaper, io: std.Io) StopError!void {
        reaper.pin.check(reaper);
        reaper.joinTask(io);
        if (reaper.orphans) |orphans| {
            // A process-wide owner cannot leave an adoptee without a future
            // wait. End before restoring the attribute and releasing pidfds.
            try orphans.killAll(io, 0);
            try orphans.stop();
            orphans.deinit();
            std.heap.page_allocator.destroy(orphans);
            reaper.orphans = null;
        }
    }

    /// Stops waiting and releases the task, as `stop` does, and leaves the
    /// `Reaper` undefined. With enableSubreaper, `stop` must have succeeded
    /// first: the adoption scope is process-wide, and only `stop` can report
    /// what keeps it from ending.
    pub fn deinit(reaper: *Reaper, io: std.Io) void {
        reaper.pin.check(reaper);
        reaper.joinTask(io);
        std.debug.assert(reaper.orphans == null);
        reaper.* = undefined;
    }

    /// Closes the lifetime and joins the task. Calling it again joins nothing.
    fn joinTask(reaper: *Reaper, io: std.Io) void {
        reaper.lifetime.store(.closed, .release);
        if (!is_windows) if (reaper.wake) |ends| {
            _ = c.write(ends[1], "x", 1);
        };
        reaper.group.cancel(io);
        reaper.closeWake();
    }

    /// A rejected start and a joined task release the same owned wake handles.
    fn closeWake(reaper: *Reaper) void {
        if (!is_windows) if (reaper.wake) |ends| {
            reaper.wake = null;
            _ = c.close(ends[0]);
            _ = c.close(ends[1]);
        };
    }

    /// Independent of root wait ownership: another task may hold that wait
    /// for the root's whole lifetime. This observer still reaps adopted exits.
    fn observeAdoption(reaper: *Reaper, io: std.Io) void {
        if (builtin.os.tag != .linux) return;
        while (reaper.state.load(.acquire) == running) {
            reaper.lookOrphans() catch {
                reaper.observation_failed.store(true, .release);
                return;
            };
            io.sleep(.fromMilliseconds(wait_for.slice_ms), .awake) catch return;
        }
    }

    fn run(reaper: *Reaper, io: std.Io) void {
        const result = reaper.reapOwned(io);
        reaper.state.store(if (result) |term| encode(term) else |err| encodeError(err), .release);
        reaper.answered.set(io);
    }

    /// Adoption is process-wide, so its one owner cleans it after every reap
    /// route, including a Child.wait that won the wait before this task.
    fn reapOwned(reaper: *Reaper, io: std.Io) ExitError!Term {
        const term = try reaper.reap(io);
        if (reaper.orphans) |orphans| {
            if (reaper.options.end_tree or reaper.killing.remaining(io) != null or
                reaper.child.state.descendants == .contain)
                orphans.killAll(io, reaper.killing.remaining(io) orelse 0) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return error.Unexpected,
                };
        }
        if (reaper.observation_failed.load(.acquire)) return error.Unexpected;
        return term;
    }

    fn reap(reaper: *Reaper, io: std.Io) ExitError!Term {
        if (is_windows) {
            const term = try reaper.child.wait(io);
            if (reaper.options.end_tree or reaper.killing.remaining(io) != null) if (reaper.child.state.job) |job| {
                _ = win32.TerminateJobObject(job, 1);
            };
            return term;
        }
        const wake = reaper.wake orelse return reaper.child.wait(io);
        // Held from here to the reap, as any wait in flight holds it: so the child
        // ended is still the child's, unreaped, while its group is ended below.
        const held = reaper.child.holdReap() orelse return reaper.child.wait(io);
        defer held.release();
        // Read the published answer, including status loss, before watching an
        // identity that has been retired. Holding the reap does not conceal the
        // result: result reads it without asking the operating system to reap.
        if (try reaper.child.result()) |term| return term;
        if (wait_for.Watch.open(reaper.child.state.id)) |watch| {
            defer watch.close();
            while (true) switch (watch.endedOrWoken(wake[0], if (reaper.orphans != null) wait_for.slice_ms else null)) {
                .ended => break,
                .woken => return error.Canceled,
                // a signal, not the end: ask again
                .timed_out => try reaper.lookOrphans(),
            };
        } else {
            // No watch. Darwin refuses one on a child that has already ended --
            // one that ended before this task first ran -- and some systems have
            // none at all. Either way the end is asked for without reaping, so
            // that what the child left in its group can still be ended by the id
            // the child holds. Where even that cannot be asked, the wait is the
            // Child.wait, and the group is left as it is.
            while (true) switch (wait_for.endedUnreaped(reaper.child.state.id)) {
                .ended => break,
                .running => {
                    try reaper.lookOrphans();
                    if (!pause(wake[0], wait_for.slice_ms)) return error.Canceled;
                },
                .unknown => return held.wait(io),
            };
        }
        // Ended, and not yet reaped: the group's id is still the child's, and
        // what is left in the group can be addressed by it. A child in a cgroup
        // of its own has what it left in there, wherever its group went.
        const supervised = if (builtin.os.tag == .linux) reaper.child.state.supervisor != null else false;
        if (!supervised and (reaper.options.end_tree or reaper.killing.remaining(io) != null)) {
            if (reaper.child.state.cgroup.active()) {
                if (!reaper.endContained(io, wake[0])) return error.Canceled;
            } else if (reaper.child.state.pgid) |pgid| {
                if (!reaper.endGroup(io, pgid, wake[0])) return error.Canceled;
            }
        }
        return held.wait(io);
    }

    /// Only an explicitly enabled scope pays this look. Linux provides no
    /// adoption fd; bounded waits also collect and reap adoptees while the root
    /// keeps running, so an idle root does not leave an exited orphan a zombie.
    fn lookOrphans(reaper: *Reaper) ExitError!void {
        if (reaper.orphans) |orphans| _ = orphans.count() catch return error.Unexpected;
    }

    /// What the child left in its cgroup: asked, given the grace, then made.
    /// The child itself, ended and unreaped, is not counted as running there.
    /// False when the wake came first.
    fn endContained(reaper: *Reaper, io: std.Io, wake: posix.fd_t) bool {
        const contained = &reaper.child.state.cgroup;
        switch (contained.populated()) {
            .none => return true,
            .others => {
                // ziglint-ignore: Z026 a member the request misses is still ended by the kill once the grace has passed
                _ = contained.signalMembers(.TERM, reaper.child.state.id, null) catch {};
                switch (reaper.treeGrace(io, wake, .{ .contained = contained })) {
                    .empty => return true,
                    .woken => return false,
                    .elapsed => {},
                }
            },
            .unknown => {},
        }
        // One write, and safe against a fork while it is delivered. A cgroup the
        // kernel will not end leaves the group to be ended as before.
        if (contained.kill()) return true;
        if (reaper.child.state.pgid) |pgid| return reaper.endGroup(io, pgid, wake);
        return true;
    }

    /// What the child left in its group: asked, given the grace, then made.
    /// False when the wake came first.
    fn endGroup(reaper: *Reaper, io: std.Io, pgid: posix.pid_t, wake: posix.fd_t) bool {
        const leader = reaper.child.state.id;
        // A group holding nothing but the child is the usual case, and is the
        // one that sends nothing.
        switch (tree.members(pgid, leader)) {
            .none => return true,
            .others => {
                _ = c.kill(-pgid, .TERM);
                switch (reaper.treeGrace(io, wake, .{ .group = pgid })) {
                    .empty => return true,
                    .woken => return false,
                    .elapsed => {},
                }
            },
            .unknown => {},
        }
        // `kill(-pgid)` is not atomic against a `fork` inside the group, so it is
        // sent again while the group still answers, as `Child.kill` does.
        tree.forceHeldGroup(pgid, leader);
        return true;
    }

    const TreeReach = union(enum) {
        group: posix.pid_t,
        contained: *const Cgroup,

        fn empty(reach: TreeReach, leader: posix.pid_t) bool {
            return switch (reach) {
                .group => |pgid| tree.members(pgid, leader) == .none,
                .contained => |contained| contained.populated() == .none,
            };
        }
    };

    /// One grace for either tree reach, measured by the caller's clock. An
    /// interrupted poll spends only the time it actually took, and a delayed
    /// wake spends all of it. Neither changes the deadline.
    fn treeGrace(reaper: *Reaper, io: std.Io, wake: posix.fd_t, reach: TreeReach) enum { empty, elapsed, woken } {
        const deadline: Deadline = .in(io, reaper.options.tree_grace_ms);
        var slice_ms: u32 = 1;
        while (true) {
            // A kill owns one grace, including cleanup after the root exits.
            // Re-read it each pass so a force request supersedes that grace.
            const left = reaper.killing.remaining(io) orelse deadline.remainingMs(io);
            if (left == 0) return .elapsed;
            if (!pause(wake, @min(left, slice_ms))) return .woken;
            if (reach.empty(reaper.child.state.id)) return .empty;
            slice_ms = @min(slice_ms * 2, tree_slice_ms);
        }
    }

    /// The longest the group is left between two looks while its grace runs.
    /// Only a group with something left in it is looked at at all.
    const tree_slice_ms: u32 = 20;

    /// Sleeps `ms` unless the wake comes first. False when it did.
    fn pause(wake: posix.fd_t, ms: u32) bool {
        if (builtin.is_test) if (pause_elapsed) |elapsed| {
            // A poll interrupted after two milliseconds, before its requested
            // slice elapsed. The test's clock advances by the time actually spent.
            elapsed.* += 2;
            return true;
        };
        var fds = [_]c.pollfd{.{ .fd = wake, .events = c.POLL.IN, .revents = 0 }};
        return c.poll(&fds, 1, @intCast(ms)) <= 0 or fds[0].revents == 0;
    }

    /// No term can encode to this: the tag byte is out of range.
    const running: u64 = std.math.maxInt(u64);

    fn encode(term: Term) u64 {
        const tag: u64, const payload: u32 = switch (term) {
            .exited => |code| .{ 0, code },
            .signal => |signal| .{ 1, @intCast(@intFromEnum(signal)) },
            .stopped => |signal| .{ 2, @intCast(@intFromEnum(signal)) },
            .unknown => |value| .{ 3, value },
        };
        return (tag << 32) | payload;
    }

    fn encodeError(err: ExitError) u64 {
        return (@as(u64, 4) << 32) | @intFromError(err);
    }

    fn decode(state: u64) ExitError!Term {
        const payload: u32 = @truncate(state);
        return switch (state >> 32) {
            0 => .{ .exited = @intCast(payload) },
            1 => .{ .signal = @enumFromInt(payload) },
            2 => .{ .stopped = @enumFromInt(payload) },
            3 => .{ .unknown = payload },
            4 => @as(ExitError, @errorCast(@errorFromInt(@as(u16, @truncate(payload))))),
            else => unreachable,
        };
    }
};

var pause_elapsed: if (builtin.is_test) ?*u32 else void = if (builtin.is_test) null else {};

test "a Reaper tree grace counts elapsed time when polls are interrupted" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(testing.allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", "trap '' TERM; sleep 30 & echo ready; read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
        .detach = true,
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var buffer: [32]u8 = undefined;
    var reader = child.stdoutFile().?.reader(io, &buffer);
    try testing.expectEqualStrings("ready", (try reader.interface.takeDelimiter('\n')).?);

    const Clock = struct {
        fn now(userdata: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const elapsed: *u32 = @ptrCast(@alignCast(userdata.?));
            return .{ .nanoseconds = @as(i96, elapsed.*) * std.time.ns_per_ms };
        }
    };
    var elapsed: u32 = 0;
    var vtable = io.vtable.*;
    vtable.now = Clock.now;
    const clock_io: std.Io = .{ .vtable = &vtable, .userdata = &elapsed };
    var reaper: Reaper = .init(&child, .{ .tree_grace_ms = 100 });
    pause_elapsed = &elapsed;
    defer pause_elapsed = null;
    try testing.expect(reaper.endGroup(clock_io, child.state.pgid.?, -1));
    try testing.expect(elapsed >= 100);
}

test "every term survives the round trip through the atomic" {
    const cases = [_]Term{
        .{ .exited = 0 },
        .{ .exited = 255 },
        .{ .exited = 0xc000013a },
        .{ .exited = 0xffffffff },
        .{ .signal = .TERM },
        .{ .stopped = .INT },
        .{ .unknown = 0xdeadbeef },
    };
    for (cases) |term| {
        try std.testing.expectEqual(term, try Reaper.decode(Reaper.encode(term)));
        try std.testing.expect(Reaper.encode(term) != Reaper.running);
    }
}

test "every wait error survives the round trip through the atomic" {
    const cases = [_]Reaper.ExitError{
        error.AccessDenied,
        error.Canceled,
        error.Unexpected,
        error.ReapedElsewhere,
    };
    for (cases) |err| {
        try std.testing.expectError(err, Reaper.decode(Reaper.encodeError(err)));
        try std.testing.expect(Reaper.encodeError(err) != Reaper.running);
    }
}

test "a rejected Reaper start releases its wake pipe before returning" {
    if (is_windows) return error.SkipZigTest;
    const io = std.testing.io;
    var child = try Child.spawn(std.testing.allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var reaper: Reaper = .init(&child, .{});
    defer reaper.deinit(io);
    const Reject = struct {
        const Self = @This();
        reaper: *Reaper,
        ends: ?[2]posix.fd_t = null,

        fn concurrent(userdata: ?*anyopaque, _: *std.Io.Group, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
            const reject: *Self = @ptrCast(@alignCast(userdata.?));
            reject.ends = reject.reaper.wake;
            return error.ConcurrencyUnavailable;
        }
    };
    var reject: Reject = .{ .reaper = &reaper };
    var vtable = io.vtable.*;
    vtable.groupConcurrent = Reject.concurrent;
    const rejected_io: std.Io = .{ .userdata = &reject, .vtable = &vtable };
    try std.testing.expectError(error.ConcurrencyUnavailable, reaper.start(rejected_io));
    for (reject.ends.?) |fd| {
        try std.testing.expectEqual(@as(c_int, -1), c.fcntl(fd, c.F.GETFD));
        try std.testing.expectEqual(std.c.E.BADF, c.errno(@as(c_int, -1)));
    }
    try std.testing.expectEqual(@as(?[2]posix.fd_t, null), reaper.wake);
    try reaper.start(io);
    reaper.kill(io, 0);
    _ = (try reaper.waitTimeout(io, 5000)) orelse return error.TestChildDidNotExit;
}

test "Reaper deadlines keep spurious wakes on one answer event and spend the kill grace there" {
    if (is_windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(testing.allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var reaper: Reaper = .init(&child, .{});
    defer reaper.deinit(io);
    const Clock = struct {
        const Self = @This();
        ms: u32 = 0,
        waits: usize = 0,
        sleeps: usize = 0,
        event: ?*const u32 = null,
        fn now(userdata: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const clock: *Self = @ptrCast(@alignCast(userdata.?));
            return .{ .nanoseconds = @as(i96, clock.ms) * std.time.ns_per_ms };
        }
        fn futexWait(userdata: ?*anyopaque, ptr: *const u32, _: u32, _: std.Io.Timeout) std.Io.Cancelable!void {
            const clock: *Self = @ptrCast(@alignCast(userdata.?));
            if (clock.event) |event| std.debug.assert(event == ptr) else clock.event = ptr;
            clock.waits += 1;
            clock.ms += 10;
        }
        fn sleep(userdata: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
            const clock: *Self = @ptrCast(@alignCast(userdata.?));
            clock.sleeps += 1;
            return error.Canceled;
        }
    };
    var clock: Clock = .{};
    var vtable = io.vtable.*;
    vtable.now = Clock.now;
    vtable.futexWait = Clock.futexWait;
    vtable.sleep = Clock.sleep;
    const clock_io: std.Io = .{ .userdata = &clock, .vtable = &vtable };
    try testing.expectEqual(@as(?Term, null), try reaper.waitTimeout(clock_io, 30));
    try testing.expectEqual(@as(usize, 3), clock.waits);
    try testing.expectEqual(@as(usize, 0), clock.sleeps);
    try testing.expectEqual(@as(u32, 30), clock.ms);
    try testing.expectEqual(@as(?Term, null), try child.tryWait());
    clock = .{};
    reaper.insist(clock_io, 40);
    try testing.expectEqual(@as(usize, 4), clock.waits);
    try testing.expectEqual(@as(usize, 0), clock.sleeps);
    try testing.expectEqual(@as(u32, 40), clock.ms);
    try testing.expectEqual(Term{ .signal = .KILL }, try child.wait(io));
}

test "a kill keeps its first deadline and a force expires the same grace" {
    const Clock = struct {
        var milliseconds: u32 = 100;
        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            return .{ .nanoseconds = @as(i96, milliseconds) * std.time.ns_per_ms };
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    const io: std.Io = .{ .vtable = &vtable, .userdata = std.testing.io.userdata };
    var kill: Kill = .{};
    Clock.milliseconds = 100;
    try std.testing.expect(kill.request(io, 100));
    Clock.milliseconds = 150;
    try std.testing.expect(!kill.request(io, 100));
    try std.testing.expectEqual(@as(?u32, 50), kill.remaining(io));
    try std.testing.expect(kill.request(io, 0));
    try std.testing.expectEqual(@as(?u32, 0), kill.remaining(io));
    Clock.milliseconds = 200;
    try std.testing.expect(!kill.request(io, 100));
    try std.testing.expectEqual(@as(?u32, 0), kill.remaining(io));
}

test "subreaping belongs to one Reaper and restores the process attribute" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    var before: c_int = 0;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prctl(@intFromEnum(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&before), 0, 0, 0)));
    // The address a subreaper's child is spawned into, after init.
    var child: Child = undefined;
    var owner: Reaper = .init(&child, .{});
    try owner.enableSubreaper();
    defer {
        owner.stop(std.testing.io) catch unreachable;
        owner.deinit(std.testing.io);
    }
    try std.testing.expectError(error.AlreadyStarted, owner.enableSubreaper());
    var other: Reaper = .init(&child, .{});
    defer {
        other.stop(std.testing.io) catch unreachable;
        other.deinit(std.testing.io);
    }
    try std.testing.expectError(error.AlreadyStarted, other.enableSubreaper());
    var during: c_int = 0;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prctl(@intFromEnum(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&during), 0, 0, 0)));
    try std.testing.expectEqual(@as(c_int, 1), during);
    try owner.stop(std.testing.io);
    try owner.stop(std.testing.io);
    try std.testing.expectError(error.AlreadyStarted, owner.enableSubreaper());
    var after: c_int = 0;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prctl(@intFromEnum(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&after), 0, 0, 0)));
    try std.testing.expectEqual(before, after);
    try other.enableSubreaper();
}

test "Reaper subreaping is unsupported off Linux" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    // The address a subreaper's child is spawned into, after init.
    var child: Child = undefined;
    var reaper: Reaper = .init(&child, .{});
    defer reaper.deinit(std.testing.io);
    try std.testing.expectError(error.Unsupported, reaper.enableSubreaper());
}

test "a subreaper teardown retains ownership until every direct child is reaped" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    // The address a subreaper's child is spawned into, after init.
    var child: Child = undefined;
    var owner: Reaper = .init(&child, .{});
    try owner.enableSubreaper();
    defer {
        owner.stop(io) catch unreachable;
        owner.deinit(io);
    }
    var other = try Child.spawn(std.testing.allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer other.release(io) catch unreachable;
    defer _ = other.killWait(io, 0) catch {};
    try std.testing.expectError(error.DirectChildrenRemain, owner.stop(io));
    var during: c_int = 0;
    const linux = std.os.linux;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prctl(@intFromEnum(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&during), 0, 0, 0)));
    try std.testing.expectEqual(@as(c_int, 1), during);
}
