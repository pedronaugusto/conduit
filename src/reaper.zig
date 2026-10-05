//! Waits for a child on a background task, so the owner can ask whether it has
//! ended, wait for it to end, and have it stopped, none of them blocking on
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
//! * `stop` asks the child and what it started to end, and makes them if they
//!   have not by the end of a grace. It returns at once: the insisting is done
//!   on this `Reaper`'s own task, so a caller holding a lock can stop a child
//!   without waiting for it.
//! * `Options.end_tree` ends what the child leaves running when it ends by
//!   itself. See there for what that reaches on each system.
//!
//! Lifetime rules, all of them:
//!
//! * The `Child` must outlive the `Reaper`, and must not be destroyed while
//!   the `Reaper` is running.
//! * A `Reaper` must not be copied or moved once `start` has been called: the
//!   running task holds a pointer to it.
//! * `deinit` must be called before the `Reaper` goes out of scope, including
//!   on the path where the child never exits. It ends the task and waits for
//!   it to finish — and with it any insisting `stop` had still to do, so a
//!   program that wants a stopped child gone waits for it before `deinit`.
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
const spin = @import("spin.zig");
const State = @import("child/state.zig");
const posix = std.posix;
const c = std.c;
const Child = @import("child.zig").Child;

const is_windows = builtin.os.tag == .windows;
const win32 = if (is_windows) @import("win32.zig") else struct {};
const handles = @import("handles.zig");
const tree = if (is_windows) struct {} else @import("tree.zig");
const Orphans = @import("orphans.zig").Orphans;
const wait_for = if (is_windows) struct {} else @import("wait.zig");

const Term = Child.Term;
const Deadline = @import("deadline.zig").Deadline;

// Published before signalling, and retained until the held reap ends the tree.
// Only the small deadline snapshot is under this lock; no I/O is done in it.
const Stop = struct {
    mutex: std.atomic.Mutex = .unlocked,
    deadline: ?Deadline = null,

    fn lock(stop: *Stop) void {
        spin.lock(&stop.mutex);
    }

    fn request(stop: *Stop, io: std.Io, grace_ms: u32) bool {
        const deadline: Deadline = .in(io, grace_ms);
        stop.lock();
        defer stop.mutex.unlock();
        if (grace_ms != 0 and stop.deadline != null) return false;
        stop.deadline = deadline;
        return true;
    }

    fn remaining(stop: *Stop, io: std.Io) ?u32 {
        stop.lock();
        const deadline = stop.deadline;
        stop.mutex.unlock();
        return if (deadline) |at| at.remainingMs(io) else null;
    }
};

const Implementation = struct {
    /// The child being waited for. Borrowed.
    child: *Child,
    options: Reaper.Options,
    /// The task running the wait, and the one `stop` insists on.
    group: std.Io.Group,
    /// `running`, a term encoded by `encode`, or an error encoded by
    /// `encodeError`. Written once by the task and read by anyone.
    state: std.atomic.Value(u64),
    /// Set once `state` holds the answer, whatever it is.
    answered: std.Io.Event,
    /// The first stop deadline; force requests replace it with immediate expiry.
    stop: Stop,
    /// POSIX: a pipe whose reading end the task waits on beside the child, and
    /// which `deinit` writes to. The wait on the child is not a cancelation point
    /// and has no deadline, so this is what ends it early. `null` until `start`,
    /// and where a pipe could not be had.
    wake: if (is_windows) void else ?[2]posix.fd_t,

    /// The explicit process-wide adoption scope, owned until deinit.
    orphans: ?*Orphans,
    observation_failed: std.atomic.Value(bool),

    lifetime: std.atomic.Value(enum(u8) { ready, started, closed }),
};

pub const Reaper = enum(@Int(.unsigned, @sizeOf(Implementation) * 8)) {
    _,

    fn inner(reaper: *Reaper) *Implementation {
        return @ptrCast(@alignCast(reaper)); // safe: init writes this inline state; enum size and alignment hold the implementation.
    }

    fn innerConst(reaper: *const Reaper) *const Implementation {
        return @ptrCast(@alignCast(reaper)); // safe: borrows the same initialized inline state without copying it.
    }

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
        var reaper: Reaper = undefined;
        reaper.inner().* = .{
            .child = child,
            .options = options,
            .group = .init,
            .state = .init(running),
            .answered = .unset,
            .stop = .{},
            .wake = if (is_windows) {} else null,
            .orphans = null,
            .observation_failed = .init(false),
            .lifetime = .init(.ready),
        };
        return reaper;
    }

    /// Make this process a Linux child subreaper before spawning the child.
    /// One Reaper owns this process-wide scope. All adopted orphans belong to
    /// it, including those from other direct children; they have no remaining
    /// per-child attribution. Existing and conduit-spawned direct children keep
    /// their own waits. Until deinit, every new direct child must use conduit,
    /// and no outside waitpid(-1) or SIGCHLD reaper may consume their statuses.
    /// The Child address may be reserved before spawn; start needs it initialized.
    /// End and reap all direct children before deinit: a running direct child
    /// could create another orphan while the process setting is restored.
    /// Configure once, before start, from the owner's task. Unsupported off Linux.
    /// An independent task observes and reaps exited adoptees every 5 ms, even
    /// if another task owns the root wait. Scheduling and procfs access can
    /// extend that interval.
    pub fn enableSubreaper(reaper: *Reaper) Orphans.StartError!void {
        if (reaper.inner().lifetime.load(.acquire) != .ready or reaper.inner().orphans != null)
            return error.AlreadyStarted;
        const allocator = std.heap.page_allocator;
        const orphans = try allocator.create(Orphans);
        errdefer allocator.destroy(orphans);
        orphans.* = .init(allocator);
        try orphans.start();
        reaper.inner().orphans = orphans;
    }

    /// Copy identities owned by this explicit adoption scope. No record borrows
    /// the scope or confers signal authority. Empty without enableSubreaper.
    pub fn adoptionRecords(reaper: *Reaper, out: []Orphans.Record) Orphans.ListError![]Orphans.Record {
        const owner = reaper.inner().orphans orelse return out[0..0];
        return owner.list(out);
    }

    /// Notification of new scoped records, registered before start. Reset the
    /// event, compare adoptionCount, and take another snapshot if it changed.
    pub fn adoptionEvent(reaper: *Reaper, io: std.Io) ?*std.Io.Event {
        const owner = reaper.inner().orphans orelse return null;
        return owner.adoptionEvent(io);
    }

    pub fn adoptionCount(reaper: *const Reaper) u64 {
        const owner = reaper.innerConst().orphans orelse return 0;
        return owner.adoptionCount();
    }

    pub const StartError = std.Io.ConcurrentError || error{AlreadyStarted};

    /// Puts the wait in flight.
    ///
    /// The task must be able to run alongside the caller, so an `std.Io`
    /// implementation with no concurrency to offer fails here rather than
    /// deadlocking later. A successful start consumes this lifetime: another start,
    /// including after deinit, returns AlreadyStarted. A failed concurrency
    /// attempt releases its resources and may be retried before deinit.
    pub fn start(reaper: *Reaper, io: std.Io) StartError!void {
        if (reaper.inner().lifetime.cmpxchgStrong(.ready, .started, .acq_rel, .acquire) != null)
            return error.AlreadyStarted;
        errdefer reaper.inner().lifetime.store(.ready, .release);
        reaper.inner().observation_failed.store(false, .release);
        // Without a pipe the wait falls back to Child.wait, which is
        // a cancelation point of its own: the wake is how a better wait is ended,
        // not a condition of waiting at all.
        if (!is_windows) reaper.inner().wake = handles.pipe() catch null;
        errdefer reaper.closeWake();
        if (reaper.inner().orphans != null) {
            try reaper.inner().group.concurrent(io, observeAdoption, .{ reaper, io });
        }
        errdefer reaper.inner().group.cancel(io);
        return reaper.inner().group.concurrent(io, run, .{ reaper, io });
    }

    pub const ExitError = Child.WaitError;

    /// How the child ended, or `null` while the wait is still running.
    ///
    /// Never blocks. A `null` is a snapshot and may be stale by the time the caller
    /// acts on it; a term or error is final.
    pub fn exit(reaper: *const Reaper) ExitError!?Term {
        const state = reaper.innerConst().state.load(.acquire);
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
        try reaper.inner().answered.wait(io);
        return (try reaper.exit()).?;
    }

    pub const WaitTimeoutError = ExitError;

    /// `wait`, for at most `timeout_ms`: `null` if the child has not ended by
    /// then.
    pub fn waitTimeout(reaper: *Reaper, io: std.Io, timeout_ms: u32) WaitTimeoutError!?Term {
        const deadline: std.Io.Clock.Timestamp = .fromNow(io, .{
            .raw = .fromMilliseconds(timeout_ms),
            .clock = .awake,
        });
        while (true) {
            reaper.inner().answered.waitTimeout(io, .{ .deadline = deadline }) catch |err| switch (err) {
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
    pub fn stop(reaper: *Reaper, io: std.Io, grace_ms: u32) void {
        if (!reaper.inner().stop.request(io, grace_ms)) return;
        if (grace_ms == 0) {
            // ziglint-ignore: Z026 undelivered means ended or ending, as documented above; the term says how
            reaper.inner().child.kill(.kill) catch {};
            return;
        }
        // ziglint-ignore: Z026 undelivered means ended or ending, as documented above; the term says how
        reaper.inner().child.kill(.terminate) catch {};
        reaper.inner().group.concurrent(io, insist, .{ reaper, io, grace_ms }) catch {
            // No task to wait out the grace on: insisting now is the one answer
            // that still ends the child.
            reaper.stop(io, 0);
        };
    }

    fn insist(reaper: *Reaper, io: std.Io, grace_ms: u32) void {
        const term = reaper.waitTimeout(io, reaper.inner().stop.remaining(io) orelse grace_ms) catch |err| switch (err) {
            // `deinit`: the owner is done with this child.
            error.Canceled => return,
            // An answer, if an unhappy one: the child is no longer waited for.
            else => return,
        };
        if (term == null) reaper.stop(io, 0);
    }

    /// Stops waiting and releases the task.
    ///
    /// If the child has already ended this returns as soon as the task notices. If
    /// it has not, the task is told to go — and any insisting `stop` had yet to
    /// do goes with it — so a program that wants the child gone should see it
    /// gone first, with `stop` and `wait`.
    ///
    /// With enableSubreaper, call after all direct children ended and were reaped.
    /// It ends and reaps remaining adoptees, then restores the process setting.
    /// Cancellation, resource and restoration failures retain the scope for
    /// retry. DirectChildrenRemain means a direct child still owns a wait.
    /// Idempotent after successful completion.
    pub const DeinitError = Orphans.EndError || Orphans.DeinitError;

    pub fn deinit(reaper: *Reaper, io: std.Io) DeinitError!void {
        if (reaper.inner().lifetime.swap(.closed, .acq_rel) == .closed and reaper.inner().orphans == null) return;
        if (!is_windows) if (reaper.inner().wake) |ends| {
            _ = c.write(ends[1], "x", 1);
        };
        reaper.inner().group.cancel(io);
        reaper.closeWake();
        if (reaper.inner().orphans) |orphans| {
            // A process-wide owner cannot leave an adoptee without a future
            // wait. End before restoring the attribute and releasing pidfds.
            try orphans.end(io, 0);
            try orphans.deinit();
            std.heap.page_allocator.destroy(orphans);
            reaper.inner().orphans = null;
        }
    }

    /// A rejected start and a joined task release the same owned wake handles.
    fn closeWake(reaper: *Reaper) void {
        if (!is_windows) if (reaper.inner().wake) |ends| {
            reaper.inner().wake = null;
            _ = c.close(ends[0]);
            _ = c.close(ends[1]);
        };
    }

    /// Independent of root wait ownership: another task may hold that wait
    /// for the root's whole lifetime. This observer still reaps adopted exits.
    fn observeAdoption(reaper: *Reaper, io: std.Io) void {
        if (builtin.os.tag != .linux) return;
        while (reaper.inner().state.load(.acquire) == running) {
            reaper.lookOrphans() catch {
                reaper.inner().observation_failed.store(true, .release);
                return;
            };
            io.sleep(.fromMilliseconds(wait_for.slice_ms), .awake) catch return;
        }
    }

    fn run(reaper: *Reaper, io: std.Io) void {
        const result = reaper.reapOwned(io);
        reaper.inner().state.store(if (result) |term| encode(term) else |err| encodeError(err), .release);
        reaper.inner().answered.set(io);
    }

    /// Adoption is process-wide, so its one owner cleans it after every reap
    /// route, including a Child.wait that won the wait before this task.
    fn reapOwned(reaper: *Reaper, io: std.Io) ExitError!Term {
        const term = try reaper.reap(io);
        if (reaper.inner().orphans) |orphans| {
            if (reaper.inner().options.end_tree or reaper.inner().stop.remaining(io) != null or
                State.get(reaper.inner().child).descendants == .contain)
                orphans.end(io, reaper.inner().stop.remaining(io) orelse 0) catch |err| switch (err) {
                    error.Canceled => return error.Canceled,
                    else => return error.Unexpected,
                };
        }
        if (reaper.inner().observation_failed.load(.acquire)) return error.Unexpected;
        return term;
    }

    fn reap(reaper: *Reaper, io: std.Io) ExitError!Term {
        if (is_windows) {
            const term = try reaper.inner().child.wait(io);
            if (reaper.inner().options.end_tree or reaper.inner().stop.remaining(io) != null) if (State.get(reaper.inner().child).job) |job| {
                _ = win32.TerminateJobObject(job, 1);
            };
            return term;
        }
        const wake = reaper.inner().wake orelse return reaper.inner().child.wait(io);
        // Held from here to the reap, as any wait in flight holds it: so the child
        // ended is still the child's, unreaped, while its group is ended below.
        const held = reaper.inner().child.holdReap() orelse return reaper.inner().child.wait(io);
        defer held.release();
        // Read the published answer, including status loss, before watching an
        // identity that has been retired. Holding the reap does not conceal the
        // result: result reads it without asking the operating system to reap.
        if (try reaper.inner().child.result()) |term| return term;
        if (wait_for.Watch.open(State.get(reaper.inner().child).id)) |watch| {
            defer watch.close();
            while (true) switch (watch.endedOrWoken(wake[0], if (reaper.inner().orphans != null) wait_for.slice_ms else null)) {
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
            while (true) switch (wait_for.endedUnreaped(State.get(reaper.inner().child).id)) {
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
        const supervised = if (builtin.os.tag == .linux) State.get(reaper.inner().child).supervisor != null else false;
        if (!supervised and (reaper.inner().options.end_tree or reaper.inner().stop.remaining(io) != null)) {
            if (State.get(reaper.inner().child).cgroup.active()) {
                if (!reaper.endContained(io, wake[0])) return error.Canceled;
            } else if (State.get(reaper.inner().child).pgid) |pgid| {
                if (!reaper.endGroup(io, pgid, wake[0])) return error.Canceled;
            }
        }
        return held.wait(io);
    }

    /// Only an explicitly enabled scope pays this look. Linux provides no
    /// adoption fd; bounded waits also collect and reap adoptees while the root
    /// keeps running, so an idle root does not leave an exited orphan a zombie.
    fn lookOrphans(reaper: *Reaper) ExitError!void {
        if (reaper.inner().orphans) |orphans| _ = orphans.count() catch return error.Unexpected;
    }

    /// What the child left in its cgroup: asked, given the grace, then made.
    /// The child itself, ended and unreaped, is not counted as running there.
    /// False when the wake came first.
    fn endContained(reaper: *Reaper, io: std.Io, wake: posix.fd_t) bool {
        const contained = &State.get(reaper.inner().child).cgroup;
        switch (contained.populated()) {
            .none => return true,
            .others => {
                // ziglint-ignore: Z026 a member the request misses is still ended by the kill once the grace has passed
                _ = contained.signalMembers(.TERM, State.get(reaper.inner().child).id, null) catch {};
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
        if (State.get(reaper.inner().child).pgid) |pgid| return reaper.endGroup(io, pgid, wake);
        return true;
    }

    /// What the child left in its group: asked, given the grace, then made.
    /// False when the wake came first.
    fn endGroup(reaper: *Reaper, io: std.Io, pgid: posix.pid_t, wake: posix.fd_t) bool {
        const leader = State.get(reaper.inner().child).id;
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
        contained: *const @import("cgroup.zig").Cgroup,

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
        const deadline: @import("deadline.zig").Deadline = .in(io, reaper.inner().options.tree_grace_ms);
        var slice_ms: u32 = 1;
        while (true) {
            // A stop owns one grace, including cleanup after the root exits.
            // Re-read it each pass so a force request supersedes that grace.
            const left = reaper.inner().stop.remaining(io) orelse deadline.remainingMs(io);
            if (left == 0) return .elapsed;
            if (!pause(wake, @min(left, slice_ms))) return .woken;
            if (reach.empty(State.get(reaper.inner().child).id)) return .empty;
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
    var watchdog: @import("testing/support.zig").Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, testing.allocator, .{
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
    try testing.expect(reaper.endGroup(clock_io, State.get(&child).pgid.?, -1));
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
    var child = try Child.spawn(io, std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var reaper: Reaper = .init(&child, .{});
    defer reaper.deinit(io) catch unreachable;
    const Reject = struct {
        reaper: *Reaper,
        ends: ?[2]posix.fd_t = null,

        fn concurrent(userdata: ?*anyopaque, _: *std.Io.Group, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque) void) std.Io.ConcurrentError!void {
            const reject: *@This() = @ptrCast(@alignCast(userdata.?));
            reject.ends = reject.reaper.inner().wake;
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
    try std.testing.expectEqual(@as(?[2]posix.fd_t, null), reaper.inner().wake);
    try reaper.start(io);
    reaper.stop(io, 0);
    _ = (try reaper.waitTimeout(io, 5000)) orelse return error.TestChildDidNotExit;
}

test "Reaper deadlines keep spurious wakes on one answer event and spend the stop grace there" {
    if (is_windows) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var watchdog: @import("testing/support.zig").Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var reaper: Reaper = .init(&child, .{});
    defer reaper.deinit(io) catch unreachable;
    const Clock = struct {
        ms: u32 = 0,
        waits: usize = 0,
        sleeps: usize = 0,
        event: ?*const u32 = null,
        fn now(userdata: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            const clock: *@This() = @ptrCast(@alignCast(userdata.?));
            return .{ .nanoseconds = @as(i96, clock.ms) * std.time.ns_per_ms };
        }
        fn futexWait(userdata: ?*anyopaque, ptr: *const u32, _: u32, _: std.Io.Timeout) std.Io.Cancelable!void {
            const clock: *@This() = @ptrCast(@alignCast(userdata.?));
            if (clock.event) |event| std.debug.assert(event == ptr) else clock.event = ptr;
            clock.waits += 1;
            clock.ms += 10;
        }
        fn sleep(userdata: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {
            const clock: *@This() = @ptrCast(@alignCast(userdata.?));
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

test "a stop keeps its first deadline and a force expires the same grace" {
    const Clock = struct {
        var milliseconds: u32 = 100;
        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            return .{ .nanoseconds = @as(i96, milliseconds) * std.time.ns_per_ms };
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    const io: std.Io = .{ .vtable = &vtable, .userdata = std.testing.io.userdata };
    var stop: Stop = .{};
    Clock.milliseconds = 100;
    try std.testing.expect(stop.request(io, 100));
    Clock.milliseconds = 150;
    try std.testing.expect(!stop.request(io, 100));
    try std.testing.expectEqual(@as(?u32, 50), stop.remaining(io));
    try std.testing.expect(stop.request(io, 0));
    try std.testing.expectEqual(@as(?u32, 0), stop.remaining(io));
    Clock.milliseconds = 200;
    try std.testing.expect(!stop.request(io, 100));
    try std.testing.expectEqual(@as(?u32, 0), stop.remaining(io));
}

test "subreaping belongs to one Reaper and restores the process attribute" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const linux = std.os.linux;
    var before: c_int = 0;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prctl(@intFromEnum(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&before), 0, 0, 0)));
    var child: Child = @enumFromInt(0);
    var owner: Reaper = .init(&child, .{});
    try owner.enableSubreaper();
    defer owner.deinit(std.testing.io) catch unreachable;
    try std.testing.expectError(error.AlreadyStarted, owner.enableSubreaper());
    var other: Reaper = .init(&child, .{});
    defer other.deinit(std.testing.io) catch unreachable;
    try std.testing.expectError(error.AlreadyStarted, other.enableSubreaper());
    var during: c_int = 0;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prctl(@intFromEnum(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&during), 0, 0, 0)));
    try std.testing.expectEqual(@as(c_int, 1), during);
    owner.deinit(std.testing.io) catch unreachable;
    owner.deinit(std.testing.io) catch unreachable;
    try std.testing.expectError(error.AlreadyStarted, owner.enableSubreaper());
    var after: c_int = 0;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prctl(@intFromEnum(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&after), 0, 0, 0)));
    try std.testing.expectEqual(before, after);
    try other.enableSubreaper();
}

test "Reaper subreaping is unsupported off Linux" {
    if (builtin.os.tag == .linux) return error.SkipZigTest;
    var child: Child = @enumFromInt(0);
    var reaper: Reaper = .init(&child, .{});
    defer reaper.deinit(std.testing.io) catch unreachable;
    try std.testing.expectError(error.Unsupported, reaper.enableSubreaper());
}

test "a subreaper teardown retains ownership until every direct child is reaped" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const io = std.testing.io;
    var child: Child = @enumFromInt(0);
    var owner: Reaper = .init(&child, .{});
    try owner.enableSubreaper();
    defer owner.deinit(io) catch unreachable;
    var other = try Child.spawn(io, std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer other.release(io) catch unreachable;
    defer _ = other.killWait(io, 0) catch {};
    try std.testing.expectError(error.DirectChildrenRemain, owner.deinit(io));
    var during: c_int = 0;
    const linux = std.os.linux;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prctl(@intFromEnum(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&during), 0, 0, 0)));
    try std.testing.expectEqual(@as(c_int, 1), during);
}
