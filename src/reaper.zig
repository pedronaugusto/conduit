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
const aegis = @import("aegis");
const Pin = @import("pin.zig").Pin;
const posix = std.posix;
const c = std.c;
const Child = @import("child.zig").Child;

const is_windows = builtin.target.os.tag == .windows;
const win32 = @import("win32.zig");
const tty = @import("conduit.tty");
const tree = @import("tree.zig");
const Orphans = @import("orphans.zig").Orphans;
const child_exit = @import("exit.zig");
const reactor = @import("reactor");

const Term = Child.Term;
const Deadline = tty.Deadline;
const Cgroup = @import("cgroup.zig").Cgroup;

// Published before signalling, and retained until the held reap ends the tree.
// Only the small deadline snapshot is behind the guard; no I/O is done under it.
const Kill = struct {
    deadline: aegis.Guarded(?Deadline) = .init(null),

    fn request(kill: *Kill, io: std.Io, grace: std.Io.Duration) bool {
        const deadline: Deadline = .in(io, grace);
        var held = kill.deadline.acquire();
        defer held.deinit();
        const slot = held.value();
        if (grace.nanoseconds > 0 and slot.* != null) return false;
        slot.* = deadline;
        return true;
    }

    /// The deadline of the kill requested, if one was.
    fn current(kill: *Kill) ?Deadline {
        var held = kill.deadline.acquire();
        defer held.deinit();
        return held.value().*;
    }

    /// What is left of the kill's grace, if one was requested.
    fn remaining(kill: *Kill, io: std.Io) ?std.Io.Duration {
        return if (kill.current()) |deadline| deadline.remaining(io) else null;
    }
};

pub const Reaper = struct {
    /// Private: the caller's handle, read by `start`: a subreaper's `Child` is
    /// spawned after `init`.
    source: *Child,
    /// Private: the child being waited for, copied from `source` again by `start`. The
    /// child must not be deinited while this runs; the caller's handle may
    /// move.
    child: Child,
    /// Private: what `init` was given.
    options: Reaper.Options,
    /// Private: the task running the wait, and the one `kill` insists on.
    group: std.Io.Group,
    /// Private: `running`, a term encoded by `encode`, or an error encoded by
    /// `encodeError`. Written once by the task and read by anyone.
    state: std.atomic.Value(u64),
    /// Private: set once `state` holds the answer, whatever it is.
    answered: std.Io.Event,
    /// Private: the first kill deadline; force requests replace it with immediate expiry.
    killing: Kill,
    /// Private: on POSIX, what `stop` and `deinit` signal to end the wait on the child at
    /// once. Cancelling the task ends it too, but a wait on a thread that is
    /// not a reactor runtime's looks for a cancel only between short waits.
    /// `null` until `start`, and where none could be had.
    wake: if (is_windows) void else ?reactor.Wake,

    /// Private: the explicit process-wide adoption scope, owned until stop.
    orphans: ?*Orphans,
    /// Private: a look at the adoption scope failed while the task waited.
    observation_failed: std.atomic.Value(bool),

    /// Private: one claim for start and stop.
    lifetime: std.atomic.Value(enum(u8) { ready, started, closed }),
    /// Private: in safe builds, where this was when `start` began to hold a pointer to it.
    pin: Pin = .{},

    pub const Options = struct {
        /// End what the child leaves running when it ends, and reap the child only
        /// once that is done.
        ///
        /// **Linux, for a child in a cgroup of its own** (detached
        /// or not): once the child has ended, and before it is reaped, whatever
        /// is still running in the cgroup is asked to end with `SIGTERM`, given
        /// `tree_grace`, and ended with `cgroup.kill` if it has not — however
        /// it had changed its group or session, and orphaned or not.
        ///
        /// **POSIX otherwise**, for a child spawned with `detach`: once the child has
        /// ended, and before it is reaped, what is left in its process group is
        /// asked to end with `SIGTERM`, given `tree_grace` to do so, and sent
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
        tree_grace: std.Io.Duration = .fromSeconds(1),
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
        const gpa = std.heap.page_allocator;
        const orphans = try gpa.create(Orphans);
        errdefer gpa.destroy(orphans);
        orphans.* = .init(gpa);
        try orphans.start();
        reaper.orphans = orphans;
    }

    /// Copy identities owned by this explicit adoption scope. No record borrows
    /// the scope or confers signal authority. Empty without enableSubreaper.
    pub fn adoptionRecords(reaper: *Reaper, io: std.Io, out: []Orphans.Record) Orphans.ListError![]Orphans.Record {
        reaper.pin.check(reaper);
        const owner = reaper.orphans orelse return out[0..0];
        return owner.list(io, out);
    }

    /// Notification of new scoped records. Reset the event, compare
    /// adoptionCount, and take another snapshot if it changed.
    pub fn adoptionEvent(reaper: *Reaper) ?*std.Io.Event {
        reaper.pin.check(reaper);
        const owner = reaper.orphans orelse return null;
        return owner.adoptionEvent();
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
        // Without a wake the wait ends at the cancel, which is only later: it
        // is how a wait is ended early, not a condition of waiting at all.
        if (!is_windows) reaper.wake = reactor.Wake.init(io) catch null;
        errdefer reaper.closeWake(io);
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

    /// `wait`, for at most `timeout`: `null` if the child has not ended by
    /// then.
    pub fn waitTimeout(reaper: *Reaper, io: std.Io, timeout: std.Io.Timeout) WaitTimeoutError!?Term {
        reaper.pin.check(reaper);
        return reaper.waitWithin(io, .of(io, timeout));
    }

    /// `waitTimeout` to a deadline.
    fn waitWithin(reaper: *Reaper, io: std.Io, deadline: Deadline) WaitTimeoutError!?Term {
        while (true) {
            reaper.answered.waitTimeout(io, deadline.toTimeout()) catch |err| switch (err) {
                // A wakeup before the deadline is spurious; one after it is the
                // answer that there is none yet.
                error.Timeout => if (deadline.remainingMs(io) > 0) continue else return reaper.exit(),
                error.Canceled => return error.Canceled,
            };
            return reaper.exit();
        }
    }

    /// Asks the child to end, and makes it if it has not within `grace`.
    ///
    /// `.terminate` now and `.kill` once the grace has passed, each of them
    /// `Child.kill`'s and reaching what `Child.kill` reaches. A held reap also
    /// ends anything left in the owned group or cgroup before releasing its
    /// identity, using the remainder of the same grace. A zero grace
    /// is `.kill` now. It never blocks: the grace is waited out on this
    /// `Reaper`'s task, and ends early once the child and its owned tree end.
    ///
    /// Only the first request with a grace counts. A second one would either
    /// wait longer than the first, which it cannot, or less, which is a request
    /// with a grace of zero — and that one is always sent. A signal that cannot
    /// be delivered is not reported: the child has ended, or is ending, and the
    /// term says how.
    pub fn kill(reaper: *Reaper, io: std.Io, grace: std.Io.Duration) void {
        reaper.pin.check(reaper);
        if (!reaper.killing.request(io, grace)) return;
        if (grace.nanoseconds <= 0) {
            // glint-ignore: Z026 -- undelivered means ended or ending, as documented above; the term says how
            reaper.target().kill(.kill) catch {};
            return;
        }
        // glint-ignore: Z026 -- undelivered means ended or ending, as documented above; the term says how
        reaper.target().kill(.terminate) catch {};
        reaper.group.concurrent(io, insist, .{ reaper, io, grace }) catch {
            // No task to wait out the grace on: insisting now is the one answer
            // that still ends the child.
            reaper.kill(io, .zero);
        };
    }

    /// The child as the caller holds it before `start`, and as this holds it
    /// after.
    fn target(reaper: *Reaper) *Child {
        return if (reaper.lifetime.load(.acquire) == .ready) reaper.source else &reaper.child;
    }

    fn insist(reaper: *Reaper, io: std.Io, grace: std.Io.Duration) void {
        const term = reaper.waitWithin(io, reaper.killing.current() orelse .in(io, grace)) catch |err| switch (err) {
            // `stop` or `deinit`: the owner is done with this child.
            error.Canceled => return,
            // An answer, if an unhappy one: the child is no longer waited for.
            else => return,
        };
        if (term == null) reaper.kill(io, .zero);
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
            try orphans.killAll(io, .zero);
            try orphans.stop(io);
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
        if (!is_windows) if (reaper.wake) |*wake| wake.signal();
        reaper.group.cancel(io);
        reaper.closeWake(io);
    }

    /// A rejected start and a joined task release the same wake.
    fn closeWake(reaper: *Reaper, io: std.Io) void {
        if (!is_windows) if (reaper.wake) |*wake| {
            wake.deinit(io);
            reaper.wake = null;
        };
    }

    /// Independent of root wait ownership: another task may hold that wait
    /// for the root's whole lifetime. This observer still reaps adopted exits.
    fn observeAdoption(reaper: *Reaper, io: std.Io) void {
        if (builtin.target.os.tag != .linux) return;
        while (reaper.state.load(.acquire) == running) {
            reaper.lookOrphans(io) catch {
                reaper.observation_failed.store(true, .release);
                return;
            };
            io.sleep(adoption_interval, .awake) catch return;
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
                orphans.killAll(io, reaper.killing.remaining(io) orelse .zero) catch |err| switch (err) {
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
        // Held from here to the reap, as any wait in flight holds it: so the child
        // ended is still the child's, unreaped, while its group is ended below.
        const held = reaper.child.holdReap() orelse return reaper.child.wait(io);
        defer held.release();
        // Read the published answer, including status loss, before watching an
        // identity that has been retired. Holding the reap does not conceal the
        // result: result reads it without asking the operating system to reap.
        if (try reaper.child.result()) |term| return term;
        // With an adoption scope to look at, the wait is cut into the intervals
        // the looks are made at; without one it lasts as long as the child does.
        const interval: std.Io.Timeout = if (reaper.orphans != null) .{ .duration = .{ .raw = adoption_interval, .clock = .awake } } else .none;
        const watch: ?*const reactor.Process = if (reaper.child.state.exit_watch) |*existing| existing else null;
        const wake: ?*reactor.Wake = if (reaper.wake) |*existing| existing else null;
        while (true) switch (try child_exit.wait(io, reaper.child.state.id, watch, wake, interval)) {
            .ended => break,
            // `stop` or `deinit`: the owner is done with this child.
            .woken => return error.Canceled,
            .timeout => try reaper.lookOrphans(io),
            // Where even the end cannot be asked, the wait is the Child.wait, and
            // the group is left as it is.
            .unavailable => return held.wait(io),
        };
        // Ended, and not yet reaped: the group's id is still the child's, and
        // what is left in the group can be addressed by it. A child in a cgroup
        // of its own has what it left in there, wherever its group went.
        const supervised = if (builtin.target.os.tag == .linux) reaper.child.state.supervisor != null else false;
        if (!supervised and (reaper.options.end_tree or reaper.killing.remaining(io) != null)) {
            if (reaper.child.state.cgroup.active()) {
                try reaper.endContained(io);
            } else if (reaper.child.state.pgid) |pgid| {
                try reaper.endGroup(io, pgid);
            }
        }
        return held.wait(io);
    }

    /// How often the adoption scope is looked at while the root runs, on
    /// Linux, which provides no descriptor that says an orphan was adopted.
    const adoption_interval: std.Io.Duration = .fromMilliseconds(5);

    /// Only an explicitly enabled scope pays this look. Linux provides no
    /// adoption fd; bounded waits also collect and reap adoptees while the root
    /// keeps running, so an idle root does not leave an exited orphan a zombie.
    fn lookOrphans(reaper: *Reaper, io: std.Io) ExitError!void {
        if (reaper.orphans) |orphans| _ = orphans.count(io) catch return error.Unexpected;
    }

    /// What the child left in its cgroup: asked, given the grace, then made.
    /// The child itself, ended and unreaped, is not counted as running there.
    /// A cancel ends the grace and is returned.
    fn endContained(reaper: *Reaper, io: std.Io) std.Io.Cancelable!void {
        const contained = &reaper.child.state.cgroup;
        switch (contained.populated()) {
            .none => return,
            .others => {
                // glint-ignore: Z026 -- a member the request misses is still ended by the kill once the grace has passed
                _ = contained.signalMembers(.TERM, reaper.child.state.id, null) catch {};
                switch (try reaper.treeGrace(io, .{ .contained = contained })) {
                    .empty => return,
                    .elapsed => {},
                }
            },
            .unknown => {},
        }
        // One write, and safe against a fork while it is delivered. A cgroup the
        // kernel will not end leaves the group to be ended as before.
        if (contained.kill()) return;
        if (reaper.child.state.pgid) |pgid| return reaper.endGroup(io, pgid);
    }

    /// What the child left in its group: asked, given the grace, then made.
    /// A cancel ends the grace and is returned.
    fn endGroup(reaper: *Reaper, io: std.Io, pgid: posix.pid_t) std.Io.Cancelable!void {
        const leader = reaper.child.state.id;
        // A group holding nothing but the child is the usual case, and is the
        // one that sends nothing.
        switch (tree.members(pgid, leader)) {
            .none => return,
            .others => {
                _ = c.kill(-pgid, .TERM);
                switch (try reaper.treeGrace(io, .{ .group = pgid })) {
                    .empty => return,
                    .elapsed => {},
                }
            },
            .unknown => {},
        }
        // `kill(-pgid)` is not atomic against a `fork` inside the group, so it is
        // sent again while the group still answers, as `Child.kill` does.
        tree.forceHeldGroup(pgid, leader);
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

    /// One grace for either tree reach, measured by the caller's clock: a sleep
    /// that resumes late spends the time it took, and neither changes the
    /// deadline. Nothing announces that a group or a cgroup is empty, so it is
    /// looked at between sleeps.
    fn treeGrace(reaper: *Reaper, io: std.Io, reach: TreeReach) std.Io.Cancelable!enum { empty, elapsed } {
        const deadline: Deadline = .in(io, reaper.options.tree_grace);
        var slice_ms: u32 = 1;
        while (true) {
            // A kill owns one grace, including cleanup after the root exits.
            // Re-read it each pass so a force request supersedes that grace.
            const left = (reaper.killing.current() orelse deadline).remainingMs(io);
            if (left == 0) return .elapsed;
            try io.sleep(.fromMilliseconds(@min(left, slice_ms)), .awake);
            if (reach.empty(reaper.child.state.id)) return .empty;
            slice_ms = @min(slice_ms * 2, tree_slice_ms);
        }
    }

    /// The longest the group is left between two looks while its grace runs.
    /// Only a group with something left in it is looked at at all.
    const tree_slice_ms: u32 = 20;

    /// No term can encode to this: the tag byte is out of range.
    const running: u64 = std.math.maxInt(u64);

    fn encode(term: Term) u64 {
        const tag: u64, const payload: u32 = switch (term) {
            .exited => |code| .{ 0, code },
            .signal => |signal| .{ 1, @intCast(@backingInt(signal)) },
            .stopped => |signal| .{ 2, @intCast(@backingInt(signal)) },
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
            1 => .{ .signal = @fromBackingInt(@intCast(payload)) },
            2 => .{ .stopped = @fromBackingInt(@intCast(payload)) },
            3 => .{ .unknown = payload },
            4 => @as(ExitError, @errorCast(@errorFromInt(@as(u16, @truncate(payload))))),
            else => unreachable,
        };
    }
};

/// Tests only: the clocks and fault plans of the tests below.
const shakedown = @import("shakedown");

test "a Reaper tree grace counts elapsed time when its sleeps resume late" {
    if (builtin.target.os.tag != .linux and builtin.target.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var child = try Child.spawn(testing.allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", "trap '' TERM; sleep 30 & echo ready; read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
        .detach = true,
    });
    defer child.deinit(io);
    defer @import("testing/support.zig").reap(&child, io);
    var buffer: [32]u8 = undefined;
    var reader = child.stdoutFile().?.reader(io, &buffer);
    try testing.expectEqualStrings("ready", (try reader.interface.takeDelimiter('\n')).?);

    // Each sleep resumes two milliseconds late, on the test's clock.
    var clock: shakedown.Clock = .init(io, .{ .advance = .{ .auto = .{ .late = .fromMilliseconds(2) } } });
    const start = clock.read(.awake);
    var reaper: Reaper = .init(&child, .{ .tree_grace = .fromMilliseconds(100) });
    try reaper.endGroup(clock.io(), child.state.pgid.?);
    try testing.expect(start.durationTo(clock.read(.awake)).nanoseconds >= 100 * std.time.ns_per_ms);
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

test "a rejected Reaper start may be retried" {
    if (is_windows) return error.SkipZigTest;
    const io = std.testing.io;
    var child = try Child.spawn(std.testing.allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.deinit(io);
    defer @import("testing/support.zig").reap(&child, io);
    var reaper: Reaper = .init(&child, .{});
    defer reaper.deinit(io);
    const refused = try shakedown.FaultIo.init(std.testing.allocator, io, .{ .plan = &.{.{
        .at = .{ .nth = .{ .call = .groupConcurrent, .n = 1 } },
        .fault = .{ .fail = error.ConcurrencyUnavailable },
    }} });
    defer refused.deinit();
    try std.testing.expectError(error.ConcurrencyUnavailable, reaper.start(refused.io()));
    try reaper.start(io);
    reaper.kill(io, .zero);
    _ = (try reaper.waitTimeout(io, Deadline.within(.fromMilliseconds(5000)))) orelse return error.TestChildDidNotExit;
}

test "Reaper deadlines keep spurious wakes on one answer event and spend the kill grace there" {
    if (is_windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var child = try Child.spawn(testing.allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.deinit(io);
    defer @import("testing/support.zig").reap(&child, io);
    var reaper: Reaper = .init(&child, .{});
    defer reaper.deinit(io);
    // Every futex wait wakes spuriously ten milliseconds of the clock later.
    const Advance = struct {
        fn spend(_: std.Io, context: *anyopaque) void {
            const clock: *shakedown.Clock = @ptrCast(@alignCast(context)); // safe: the plan hands this test's Clock as the context
            clock.advance(.fromMilliseconds(10));
        }
    };
    var clock: shakedown.Clock = .init(io, .{});
    const counted = try shakedown.FaultIo.init(testing.allocator, clock.io(), .{
        .plan = &.{
            .{
                .at = .{ .nth = .{ .call = .futexWait, .n = 1 } },
                .fault = .{ .call = .{ .ctx = &clock, .f = Advance.spend, .then = &.spurious_wake } },
                .times = 0,
            },
            // No interval sleeps: any one would fail the wait.
            .{ .at = .{ .nth = .{ .call = .sleep, .n = 1 } }, .fault = .cancel, .times = 0 },
        },
    });
    defer counted.deinit();
    // FaultIo does not expose futex addresses. This observer only checks
    // the word and forwards the wait; the plan supplies all fault behavior.
    const Observed = struct {
        const Observer = shakedown.Layer(@This(), .{ .futexWait = wait });
        event: ?*const u32 = null,

        fn wait(userdata: ?*anyopaque, ptr: *const u32, expected: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
            const observer = Observer.of(userdata);
            if (observer.state.event) |word| std.debug.assert(word == ptr) else observer.state.event = ptr;
            return std.Io.futexWaitTimeout(observer.base, u32, ptr, expected, timeout);
        }
    };
    var observed: Observed.Observer = .init(counted.io(), .{});
    const clock_io = observed.io();
    var start = clock.read(.awake);
    try testing.expectEqual(@as(?Term, null), try reaper.waitTimeout(clock_io, Deadline.within(.fromMilliseconds(30))));
    try testing.expectEqual(@as(u64, 3), counted.count(.futexWait));
    try testing.expectEqual(@as(u64, 0), counted.count(.sleep));
    try testing.expectEqual(std.Io.Duration.fromMilliseconds(30), start.durationTo(clock.read(.awake)));
    try testing.expectEqual(@as(?Term, null), try child.tryWait(io));
    counted.reset();
    observed.state.event = null;
    start = clock.read(.awake);
    reaper.insist(clock_io, .fromMilliseconds(40));
    try testing.expectEqual(@as(u64, 4), counted.count(.futexWait));
    try testing.expectEqual(@as(u64, 0), counted.count(.sleep));
    try testing.expectEqual(std.Io.Duration.fromMilliseconds(40), start.durationTo(clock.read(.awake)));
    try testing.expectEqual(Term{ .signal = .KILL }, try child.wait(io));
}

test "a kill keeps its first deadline and a force expires the same grace" {
    var clock: shakedown.Clock = .init(std.testing.io, .{});
    const io = clock.io();
    var kill: Kill = .{};
    try std.testing.expect(kill.request(io, .fromMilliseconds(100)));
    clock.advance(.fromMilliseconds(50));
    try std.testing.expect(!kill.request(io, .fromMilliseconds(100)));
    try std.testing.expectEqual(@as(?u32, 50), kill.current().?.remainingMs(io));
    try std.testing.expect(kill.request(io, .zero));
    try std.testing.expectEqual(@as(?u32, 0), kill.current().?.remainingMs(io));
    clock.advance(.fromMilliseconds(50));
    try std.testing.expect(!kill.request(io, .fromMilliseconds(100)));
    try std.testing.expectEqual(@as(?u32, 0), kill.current().?.remainingMs(io));
}

test "subreaping belongs to one Reaper and restores the process attribute" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    var before: c_int = 0;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prctl(@backingInt(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&before), 0, 0, 0)));
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
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prctl(@backingInt(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&during), 0, 0, 0)));
    try std.testing.expectEqual(@as(c_int, 1), during);
    try owner.stop(std.testing.io);
    try owner.stop(std.testing.io);
    try std.testing.expectError(error.AlreadyStarted, owner.enableSubreaper());
    var after: c_int = 0;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prctl(@backingInt(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&after), 0, 0, 0)));
    try std.testing.expectEqual(before, after);
    try other.enableSubreaper();
}

test "Reaper subreaping is unsupported off Linux" {
    if (builtin.target.os.tag == .linux) return error.SkipZigTest;
    // The address a subreaper's child is spawned into, after init.
    var child: Child = undefined;
    var reaper: Reaper = .init(&child, .{});
    defer reaper.deinit(std.testing.io);
    try std.testing.expectError(error.Unsupported, reaper.enableSubreaper());
}

test "a subreaper teardown retains ownership until every direct child is reaped" {
    if (builtin.target.os.tag != .linux) return error.SkipZigTest;
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
    defer other.deinit(io);
    defer @import("testing/support.zig").reap(&other, io);
    try std.testing.expectError(error.DirectChildrenRemain, owner.stop(io));
    var during: c_int = 0;
    const linux = std.os.linux;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prctl(@backingInt(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&during), 0, 0, 0)));
    try std.testing.expectEqual(@as(c_int, 1), during);
}
