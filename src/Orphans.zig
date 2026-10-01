//! This process as the parent of every orphan below it. Linux, and opt-in.
//!
//! A process whose parent ends is given another. Ordinarily that is `init`,
//! or the nearest ancestor that asked to be given them, and from then on the
//! orphan is related to nothing this process can name: a daemon a child left
//! running, a grandchild that forked twice and called `setsid`. `start` makes
//! this process that ancestor (`PR_SET_CHILD_SUBREAPER`), so every such orphan
//! becomes a child of this one instead, and conduit takes care of it: it
//! reaps each one that has ended whenever conduit is doing something anyway,
//! and `end` ends them all, through a pidfd each, so no process given a
//! recycled pid is ever signalled.
//!
//! # Nothing runs while nothing happens
//!
//! There is no task and no timer. The kernel sends no notice when a process
//! is given to this one, and a clock to look for them would wake an idle
//! program for nothing. So conduit looks at this process's children — takes
//! in the new orphans, reaps the ones that have ended — at the moments it
//! already has in hand:
//!
//! * a child conduit started is reaped (`wait`, `tryWait`, `killWait`,
//!   `output`, a `Reaper`), which is also the moment the processes it left
//!   have become this one's;
//! * a spawn returns a child;
//! * `count` is asked;
//! * `end` runs.
//!
//! **The bound, as it is:** an orphan that ends while none of those happens
//! stays a zombie until the next of them, or until `end`. A program that
//! wants them gone sooner asks `count` when it likes. An orphan that is still
//! running costs nothing but its pidfd.
//!
//! # The contract: every child is started through conduit
//!
//! An orphan given to this process and a child this process started are the
//! same thing to the kernel, a child. Nothing in `/proc` or in a pidfd says
//! which parent a process had first. So conduit tells the two apart the only
//! way it can: it knows the children it started (`Child.spawn`,
//! `spawnShell`), and the children this process already had when `start` was
//! called, and takes every other child as adopted. A child started any other
//! way while this runs — `std.process.spawn`, a library that forks, a
//! `SIGCHLD` handler that reaps with `waitpid(-1)` — breaks that: conduit
//! would take the first for an orphan and reap it when it ends, and the wait
//! its owner makes afterwards would find nothing (the standard library's
//! treats that as a bug), and the last would take the status of a `Child`
//! from under it. **A program that starts `Orphans` starts every child
//! through conduit until `deinit`, and reaps only what conduit hands it.**
//!
//! A `Child`'s own status is never taken. A spawn holds a lock shared with
//! every other spawn from before its `fork` until the child is on the list of
//! conduit's own, and a look at this process's children holds it alone, so a
//! look never meets a child conduit started that is not on the list yet.
//!
//! # What a caller may observe
//!
//! * This process is a child subreaper from `start` to `deinit`, and
//!   `PR_GET_CHILD_SUBREAPER` says so. Its children are not: the setting is
//!   not inherited. `deinit` puts back what was there before.
//! * A process below this one whose parent ends reports this process as its
//!   parent (`getppid`, `/proc/<pid>/stat`), where it used to report `init` or
//!   whatever ancestor was a subreaper. This process receives a `SIGCHLD` for
//!   each adopted process that ends, as for any child of its own; the default
//!   action ignores it.
//! * A look reads `/proc/self/task/<tid>/children`, one small file per
//!   thread, and makes one `waitid` per running child conduit started and per
//!   adopted process, added to the reap or spawn that asked for it.
//! * While it runs, each child conduit starts costs one more descriptor, a
//!   pidfd, until the child has been reaped and a look has passed. A spawn
//!   that cannot have it ends the child it just started, reaps it, and fails
//!   with `error.ProcessFdQuotaExceeded` or its kin. Each adopted process
//!   holds a pidfd until it is reaped.
//! * Every spawn on Linux takes the shared side of that lock, running or not:
//!   one atomic operation when nothing is looking.
//!
//! # What reaches an adopted process
//!
//! `end`, and nothing on behalf of a single child. By the time an orphan is
//! this process's child it has no link left to the `Child` whose tree it came
//! from — its parent is gone, its group and session may be its own, and
//! nothing records the parent it had — so `Child.kill` and
//! `Reaper.Options.end_tree` cannot say it was that child's and do not guess.
//! Where the child has a cgroup of its own (owned by its Child) the cgroup still
//! says, and the child's `kill` ends it as before, adopted or not: the cgroup
//! is the per-child reach, and this is the floor beneath it and beneath the
//! walk.
//!
//! Lifetime rules: an `Orphans` must not move once `start` has been called,
//! and `deinit` must be called. One may run at a time in a process. POSIX
//! elsewhere has no such attribute, and there `start` is
//! `error.Unsupported`.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;
const Allocator = std.mem.Allocator;

const tree = if (Orphans.supported) @import("tree.zig") else struct {};
const wait_for = if (Orphans.supported) @import("wait.zig") else struct {};
const linux = std.os.linux;

const Implementation = struct {
    /// Every list here. Must be safe to use from more than one thread: spawns and
    /// reaps on any thread add to and look at them.
    allocator: Allocator,
    /// The children conduit started while this runs, and the ones this process
    /// had when `start` was called: not this one's to reap. Added to by spawns,
    /// which hold `gate` shared and `own_lock`; pruned by `look`, which holds
    /// `gate` alone.
    own: std.ArrayList(Orphans.Held),
    own_lock: Orphans.SpinLock,
    /// The children this process adopted, until each is reaped. Held under
    /// `lock`.
    adopted: std.ArrayList(Orphans.Held),
    lock: Orphans.SpinLock,
    /// Whether this process was a subreaper before `start`, so that `deinit`
    /// puts back what it found.
    was_subreaper: bool,
    running: bool,
    /// Adoption is announced without calling an owner's code while `lock` is
    /// held. A watcher compares `adoptions` after resetting this event so a
    /// concurrent adoption cannot be lost.
    adoptions: std.atomic.Value(u64),
    adoption_event: std.Io.Event,
    adoption_io: ?std.Io,
};

pub const Orphans = enum(@Int(.unsigned, @sizeOf(Implementation) * 8)) {
    _,

    /// Whether this system has what `start` needs. Linux: the subreaper attribute
    /// (3.4), `pidfd_open` (5.3), `waitid` on a pidfd (5.4), and the `children`
    /// files in `/proc`; `start` finds out whether the running kernel has them.
    pub const supported = builtin.os.tag == .linux;

    fn inner(orphans: *Orphans) *Implementation {
        return @ptrCast(@alignCast(orphans)); // safe: init writes inline state; the enum holds its size and alignment.
    }

    fn innerConst(orphans: *const Orphans) *const Implementation {
        return @ptrCast(@alignCast(orphans)); // safe: observes the same initialized inline state without copying it.
    }

    /// An `Orphans` that is not running. `start` makes it run.
    pub fn init(allocator: Allocator) Orphans {
        var orphans: Orphans = undefined;
        orphans.inner().* = .{
            .allocator = allocator,
            .own = .empty,
            .own_lock = .{},
            .adopted = .empty,
            .lock = .{},
            .was_subreaper = false,
            .running = false,
            .adoptions = .init(0),
            .adoption_event = .unset,
            .adoption_io = null,
        };
        return orphans;
    }

    /// Register one owner to be woken when a new orphan is held. The event is
    /// only a notification; call `list` to take the actual snapshot. Register
    /// before starting the owner's wait task.
    pub fn adoptionEvent(orphans: *Orphans, io: std.Io) *std.Io.Event {
        orphans.inner().lock.lock();
        defer orphans.inner().lock.unlock();
        orphans.inner().adoption_io = io;
        return &orphans.inner().adoption_event;
    }

    pub fn adoptionCount(orphans: *const Orphans) u64 {
        return orphans.innerConst().adoptions.load(.acquire);
    }

    pub const LookError = error{
        OutOfMemory,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        SystemResources,
    } || std.Io.UnexpectedError;

    pub const StartError = error{
        /// Not Linux, or a kernel without `waitid` on a pidfd (5.4) or without
        /// the `children` files in `/proc`.
        Unsupported,
        /// This `Orphans`, or another, is already running in this process.
        AlreadyStarted,
    } || LookError;

    /// Makes this process the parent of every orphan below it.
    ///
    /// The children this process has now are taken as its own, whoever started
    /// them, and are never reaped here. From here on, every child is started
    /// through conduit: that is the contract the file's documentation spells out.
    /// Starts nothing: no task, no timer.
    pub fn start(orphans: *Orphans) StartError!void {
        if (!supported) return error.Unsupported;
        if (orphans.inner().running) return error.AlreadyStarted;
        try probe();

        gate.lock();
        defer gate.unlock();
        if (current != null) return error.AlreadyStarted;

        orphans.inner().was_subreaper = subreaper();
        if (!orphans.inner().was_subreaper) try setSubreaper(true);
        errdefer if (!orphans.inner().was_subreaper) setSubreaper(false) catch {};

        // Whatever this process has now was started before the contract: it is
        // somebody's, and not an orphan's.
        errdefer {
            orphans.releaseAll();
            orphans.inner().own.deinit(orphans.inner().allocator);
            orphans.inner().own = .empty;
        }
        try forEachChild(orphans, claim);

        orphans.inner().running = true;
        current = orphans;
        active.store(true, .release);
    }

    pub const EndError = LookError || std.Io.Cancelable;

    /// Ends every process this one has adopted, reaps each, and returns once a
    /// look finds none left.
    ///
    /// Each adopted process and what it started are asked with `SIGTERM`, deepest
    /// first, given `grace_ms`, and then sent `SIGKILL`; a grace of zero is
    /// `SIGKILL` at once. An adopted process's own children are reached by the
    /// walk `Child.kill` uses, and whatever that misses is adopted when its parent
    /// ends and ended in its turn. Every signal to an adopted process goes
    /// through its pidfd.
    ///
    /// Children conduit started are not touched: they have their `Child`, and its
    /// `kill`. What is adopted while this runs is ended too, so a program that is
    /// still leaving orphans keeps this busy; it is the call for the end of a
    /// program. It waits by sleeping between looks, and is a cancelation point.
    pub fn end(orphans: *Orphans, io: std.Io, grace_ms: u32) EndError!void {
        if (!supported or !orphans.inner().running) return;
        const deadline: wait_for.Deadline = .in(io, grace_ms);
        var interval_ms: u32 = 1;
        // A `children` file read while a child is being reaped elsewhere may pass
        // over another child, so "nothing left" is believed after two looks.
        var empty_looks: u8 = 0;
        while (true) {
            const left = left: {
                gate.lock();
                orphans.inner().lock.lock();
                defer orphans.inner().lock.unlock();
                {
                    defer gate.unlock();
                    try orphans.look();
                }
                orphans.reapEnded();
                const insisting = grace_ms == 0 or deadline.remainingMs(io) == 0;
                for (orphans.inner().adopted.items) |*held| held.ask(if (insisting) .kill else .terminate);
                break :left orphans.inner().adopted.items.len;
            };
            if (left == 0) {
                empty_looks += 1;
                if (empty_looks == 2) return;
                continue;
            }
            empty_looks = 0;
            try std.Io.sleep(io, .fromMilliseconds(interval_ms), .awake);
            interval_ms = @min(interval_ms * 2, end_slice_ms);
        }
    }

    /// The longest `end` waits between two looks.
    const end_slice_ms: u32 = 5;

    /// Looks, reaps every adopted process that has ended, and says how many are
    /// left: still running, or ended in the moment since. Zero when this is not
    /// running. The call for a program that wants the zombies gone now rather
    /// than at conduit's next event.
    pub fn count(orphans: *Orphans) LookError!usize {
        if (!supported or !orphans.inner().running) return 0;
        gate.lock();
        orphans.inner().lock.lock();
        defer orphans.inner().lock.unlock();
        {
            defer gate.unlock();
            try orphans.look();
        }
        orphans.reapEnded();
        return orphans.inner().adopted.items.len;
    }

    /// A copied process identity. Retain both fields; the pid alone is not
    /// authority to signal. Save this boot's identity alongside persistent
    /// records, then use captureStarted or endRecorded within that boot.
    pub const Record = struct {
        pid: posix.pid_t,
        /// Linux clock ticks after boot, as returned by conduit.startTime.
        start: u64,
        /// Group and session observed in the same adoption snapshot as start.
        /// These are saved facts, not authority to signal a group later.
        group: posix.pid_t,
        session: posix.pid_t,
    };

    pub const ListError = LookError || error{IdentityUnavailable};

    /// Looks, reaps ended adoptees, and copies as many retained identities as
    /// fit in out. Start times are captured during adoption, while the pidfd
    /// and this owner's exclusive reap ownership still hold the process.
    /// A running process whose start time could not be read is
    /// IdentityUnavailable; its numeric pid is never returned alone.
    /// Empty when this is not running. Records own no handle and remain valid
    /// as saved facts after end or deinit; they do not promise liveness.
    pub fn list(orphans: *Orphans, out: []Record) ListError![]Record {
        if (!supported or !orphans.inner().running) return out[0..0];
        gate.lock();
        orphans.inner().lock.lock();
        defer orphans.inner().lock.unlock();
        {
            defer gate.unlock();
            try orphans.look();
        }
        orphans.reapEnded();
        const n = @min(out.len, orphans.inner().adopted.items.len);
        for (orphans.inner().adopted.items[0..n], out[0..n]) |held, *record| {
            record.* = held.record orelse return error.IdentityUnavailable;
        }
        return out[0..n];
    }

    /// Reaps what has ended, lets go of every pidfd, and puts this process's
    /// subreaper attribute back as `start` found it.
    ///
    /// It signals nothing. An adopted process still running stays this
    /// process's child, and with nothing left to reap it, it is a zombie from the
    /// moment it ends until this process ends: call `end` first. Orphans made
    /// after this go where they went before `start`.
    ///
    /// Idempotent.
    pub fn deinit(orphans: *Orphans) void {
        if (!supported or !orphans.inner().running) return;
        gate.lock();
        defer gate.unlock();
        orphans.inner().lock.lock();
        defer orphans.inner().lock.unlock();
        orphans.reapEnded();
        if (!orphans.inner().was_subreaper) setSubreaper(false) catch {};
        active.store(false, .release);
        current = null;
        orphans.inner().running = false;
        orphans.releaseAll();
        orphans.inner().own.deinit(orphans.inner().allocator);
        orphans.inner().adopted.deinit(orphans.inner().allocator);
        orphans.inner().own = .empty;
        orphans.inner().adopted = .empty;
    }

    //======================================================================
    // Conduit's events.
    //======================================================================

    /// Held shared by a spawn from before its `fork` until the child is on its
    /// `Orphans`' list of conduit's own, and alone by whatever looks at this
    /// process's children or turns adoption on or off. A lock of atomics and
    /// nothing else, because a reap has no `std.Io` to wait with.
    var gate: GateLock = .{};
    /// The `Orphans` running in this process, if one is. Read and written
    /// holding `gate`.
    var current: ?*Orphans = null;
    /// Whether one is running: the one load a reap pays when none is.
    var active: std.atomic.Value(bool) = .init(false);

    /// How many looks have run, in a test build: what lets a test say an idle
    /// process looked at nothing.
    pub var looks: std.atomic.Value(usize) = .init(0);

    /// Something of conduit's has happened — a child it started has been reaped,
    /// or a spawn has returned one — and, if an `Orphans` runs, a look goes with
    /// it: the processes that child left are this one's by now, and what has
    /// ended among the adopted is reaped. One atomic load when none runs.
    pub fn event() void {
        if (!supported or !active.load(.acquire)) return;
        gate.lock();
        defer gate.unlock();
        const orphans = current orelse return;
        orphans.inner().lock.lock();
        defer orphans.inner().lock.unlock();
        orphans.look() catch {};
        orphans.reapEnded();
    }

    pub const OwnError = error{
        OutOfMemory,
        ProcessFdQuotaExceeded,
        SystemFdQuotaExceeded,
        SystemResources,
    } || std.Io.UnexpectedError;

    /// A spawn, as far as adoption is concerned: `begin` before the `fork`,
    /// `started` with the child's pid after it, `finish` once that is done or
    /// there is no child. POSIX spawns go through this; outside Linux it is
    /// nothing.
    const SpawnState = struct {
        orphans: ?*Orphans,
        holding: bool,
        look_after: bool = false,
    };

    pub const Spawn = enum(@Int(.unsigned, @sizeOf(SpawnState) * 8)) {
        _,
        fn inner(spawn: *Spawn) *SpawnState {
            return @ptrCast(@alignCast(spawn)); // safe: begin initializes inline storage of this size and alignment.
        }
        fn init(orphans: ?*Orphans, holding: bool) Spawn {
            var spawn: Spawn = undefined;
            spawn.inner().* = .{ .orphans = orphans, .holding = holding };
            return spawn;
        }

        pub fn begin() Spawn {
            if (!supported) return Spawn.init(null, false);
            gate.lockShared();
            return Spawn.init(current, true);
        }

        /// Puts the child just started on the list of conduit's own. On an error
        /// the child is not on it, and the caller ends and reaps it: a child
        /// conduit cannot tell from an orphan is not one to hand back.
        pub fn started(spawn: *Spawn, pid: posix.pid_t) OwnError!void {
            if (!supported) return;
            const orphans = spawn.inner().orphans orelse return;
            const held = Held.open(pid) catch |err| switch (err) {
                // An unreaped child of this process has a pidfd to open.
                error.Gone => return error.Unexpected,
                else => |e| return e,
            };
            orphans.inner().own_lock.lock();
            defer orphans.inner().own_lock.unlock();
            orphans.inner().own.append(orphans.inner().allocator, held) catch {
                held.close();
                return error.OutOfMemory;
            };
            spawn.inner().look_after = true;
        }

        /// Lets a look happen again, and — after a spawn that started a child —
        /// has one: the spawn is an event of conduit's, and a moment to take in
        /// what is waiting. Idempotent.
        pub fn finish(spawn: *Spawn) void {
            if (!spawn.inner().holding) return;
            spawn.inner().holding = false;
            gate.unlockShared();
            if (spawn.inner().look_after) {
                spawn.inner().look_after = false;
                event();
            }
        }
    };

    //======================================================================
    // Locks of atomics.
    //======================================================================

    /// A mutex that spins, yielding. Every section it guards is a handful of
    /// system calls, but for `end`'s, which is the end of a program.
    const SpinLock = struct {
        held: std.atomic.Value(bool) = .init(false),

        fn lock(spin: *SpinLock) void {
            while (spin.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
                std.Thread.yield() catch {};
            }
        }

        fn unlock(spin: *SpinLock) void {
            spin.held.store(false, .release);
        }
    };

    /// Many spawns or one look. A look that is waiting keeps new spawns out, so
    /// a stream of spawns cannot hold a look off forever; the spawns in flight
    /// are each a `fork` long.
    const GateLock = struct {
        state: std.atomic.Value(u32) = .init(0),

        const writing: u32 = 1 << 31;
        const waiting: u32 = 1 << 30;
        const readers: u32 = waiting - 1;

        fn lockShared(gate_lock: *GateLock) void {
            while (true) {
                const state = gate_lock.state.load(.monotonic);
                if (state & (writing | waiting) == 0 and
                    gate_lock.state.cmpxchgWeak(state, state + 1, .acquire, .monotonic) == null) return;
                std.Thread.yield() catch {};
            }
        }

        fn unlockShared(gate_lock: *GateLock) void {
            _ = gate_lock.state.fetchSub(1, .release);
        }

        fn lock(gate_lock: *GateLock) void {
            while (true) {
                const state = gate_lock.state.load(.monotonic);
                if (state & writing == 0) {
                    if (state & readers == 0) {
                        // `waiting` is dropped with the taking; another look still
                        // waiting sets it again.
                        if (gate_lock.state.cmpxchgWeak(state, writing, .acquire, .monotonic) == null) return;
                        continue;
                    }
                    if (state & waiting == 0) {
                        _ = gate_lock.state.cmpxchgWeak(state, state | waiting, .monotonic, .monotonic);
                    }
                }
                std.Thread.yield() catch {};
            }
        }

        fn unlock(gate_lock: *GateLock) void {
            _ = gate_lock.state.fetchAnd(~writing, .release);
        }
    };

    //======================================================================
    // Looking and reaping. Linux.
    //======================================================================

    /// A process held by its pidfd, and what `end` has asked of it.
    const Held = struct {
        pid: posix.pid_t,
        pidfd: posix.fd_t,
        asked: Asked = .nothing,
        record: ?Record = null,

        const Asked = enum(u8) { nothing, terminate, kill };

        const OpenError = LookError || error{Gone};

        fn open(pid: posix.pid_t) OpenError!Held {
            const rc = linux.pidfd_open(pid, 0);
            return switch (linux.errno(rc)) {
                .SUCCESS => .{ .pid = pid, .pidfd = @intCast(rc) },
                // Reaped and gone, or a number that names a thread: nothing to
                // hold either way.
                .SRCH, .INVAL => error.Gone,
                .MFILE => error.ProcessFdQuotaExceeded,
                .NFILE => error.SystemFdQuotaExceeded,
                .NOMEM => error.SystemResources,
                else => |err| posix.unexpectedErrno(err),
            };
        }

        /// A new reap owner needs a positive kernel answer. The pidfd is
        /// released on both an unrelated identity and an unknown answer.
        fn openChild(pid: posix.pid_t) OpenError!Held {
            const held = try Held.open(pid);
            errdefer held.close();
            if (!try held.isChild()) return error.Gone;
            return held;
        }

        fn openAdopted(pid: posix.pid_t) OpenError!Held {
            return openAdoptedWith(pid, PidfdWait);
        }

        fn openAdoptedWith(pid: posix.pid_t, comptime System: type) OpenError!Held {
            var held = try System.open(pid);
            errdefer System.close(held.pidfd);
            if (!try held.isChildWith(System)) return error.Gone;
            held.record = System.record(pid);
            // A by-number lookup may have met a replacement if another
            // reaper broke the contract. The pidfd must still prove that
            // this owner holds the original identity after that lookup.
            if (!try held.isChildWith(System)) return error.Gone;
            return held;
        }

        fn close(held: Held) void {
            _ = c.close(held.pidfd);
        }

        /// Whether the process is a child of this one, reaped by nobody yet. Asked
        /// of the pidfd, so it is about this process and no other given its pid.
        fn isChild(held: Held) LookError!bool {
            return held.isChildWith(PidfdWait);
        }

        const PidfdWait = struct {
            fn open(pid: posix.pid_t) OpenError!Held {
                return Held.open(pid);
            }

            fn record(pid: posix.pid_t) ?Record {
                return tree.adoptionRecord(pid);
            }

            fn close(pidfd: posix.fd_t) void {
                _ = c.close(pidfd);
            }

            fn child(pidfd: posix.fd_t, info: *linux.siginfo_t) linux.E {
                return linux.errno(linux.waitid(.PIDFD, pidfd, info, wait_exited | wait_no_hang | wait_no_wait | wait_all, null));
            }
        };

        fn isChildWith(held: Held, comptime System: type) LookError!bool {
            var info = std.mem.zeroes(linux.siginfo_t);
            while (true) {
                switch (System.child(held.pidfd, &info)) {
                    .SUCCESS => return true,
                    .INTR => continue,
                    // Not a child of this process: its own parent's, or reaped.
                    .CHILD => return false,
                    // An unknown answer cannot authorize adoption or a reap.
                    else => return error.Unexpected,
                }
            }
        }

        const Reaped = enum { reaped, running, gone };

        /// Reaps the process if it has ended.
        fn reap(held: Held) Reaped {
            var info = std.mem.zeroes(linux.siginfo_t);
            while (true) {
                const rc = linux.waitid(.PIDFD, held.pidfd, &info, wait_exited | wait_no_hang | wait_all, null);
                switch (linux.errno(rc)) {
                    // With `WNOHANG` and nothing to report, the pid stays zero.
                    .SUCCESS => return if (info.fields.common.first.piduid.pid == 0) .running else .reaped,
                    .INTR => continue,
                    // Reaped by somebody else, which the contract forbids; there
                    // is nothing left to hold either way.
                    .CHILD => return .gone,
                    else => return .running,
                }
            }
        }

        /// Sends `what` to the process and what it started, deepest first, once:
        /// a request already made is not made again, and `.kill` follows
        /// `.terminate`.
        fn ask(held: *Held, what: Asked) void {
            if (@intFromEnum(held.asked) >= @intFromEnum(what)) return;
            held.asked = what;
            const sig: posix.SIG = if (what == .kill) .KILL else .TERM;
            // Its pid is its own: it is this process's child, and nobody but this
            // process reaps it. A walk that could not be made leaves its
            // descendants to be adopted when it ends, and asked then.
            _ = tree.signalDescendants(held.pid, sig, null) catch 0;
            _ = linux.pidfd_send_signal(held.pidfd, sig, null, 0);
        }
    };

    const wait_exited: u32 = linux.W.EXITED;
    const wait_no_hang: u32 = linux.W.NOHANG;
    const wait_no_wait: u32 = linux.W.NOWAIT;
    /// `__WALL`: a child whatever signal it reports its end with. An adopted
    /// process reports `SIGCHLD`, as the kernel resets it on the way; a child
    /// this process had at `start` may have been made with another.
    const wait_all: u32 = 0x40000000;

    /// Finds every child of this process that is neither conduit's own nor
    /// adopted already, and adopts it. The caller holds `gate` alone and `lock`.
    fn look(orphans: *Orphans) LookError!void {
        if (builtin.is_test) _ = looks.fetchAdd(1, .monotonic);
        // A child of conduit's own that its owner has reaped is no longer a child
        // at all, and its pid may be given to a process this one should adopt.
        var i: usize = 0;
        while (i < orphans.inner().own.items.len) {
            const held = orphans.inner().own.items[i];
            // Keep an existing hold until the kernel proves it was reaped.
            // Unknown ownership only refuses a new claim; it never releases
            // a pidfd that a later successful look may still need.
            if (held.isChild() catch true) {
                i += 1;
                continue;
            }
            held.close();
            _ = orphans.inner().own.swapRemove(i);
        }
        try forEachChild(orphans, consider);
    }

    fn consider(orphans: *Orphans, pid: posix.pid_t) LookError!void {
        for (orphans.inner().own.items) |held| if (held.pid == pid) return;
        for (orphans.inner().adopted.items) |held| if (held.pid == pid) return;
        const held = Held.openAdopted(pid) catch |err| switch (err) {
            error.Gone => return,
            else => |e| return e,
        };
        orphans.inner().adopted.append(orphans.inner().allocator, held) catch {
            held.close();
            return error.OutOfMemory;
        };
        _ = orphans.inner().adoptions.fetchAdd(1, .release);
        if (orphans.inner().adoption_io) |io| orphans.inner().adoption_event.set(io);
    }

    /// `start`'s look: every child there is is somebody's.
    fn claim(orphans: *Orphans, pid: posix.pid_t) LookError!void {
        const held = Held.openChild(pid) catch |err| switch (err) {
            error.Gone => return,
            else => |e| return e,
        };
        orphans.inner().own.append(orphans.inner().allocator, held) catch {
            held.close();
            return error.OutOfMemory;
        };
    }

    /// Reaps every adopted process that has ended. The caller holds `lock`.
    fn reapEnded(orphans: *Orphans) void {
        var i: usize = 0;
        while (i < orphans.inner().adopted.items.len) {
            const held = orphans.inner().adopted.items[i];
            switch (held.reap()) {
                .running => i += 1,
                .reaped, .gone => {
                    held.close();
                    _ = orphans.inner().adopted.swapRemove(i);
                },
            }
        }
    }

    fn releaseAll(orphans: *Orphans) void {
        for (orphans.inner().own.items) |held| held.close();
        for (orphans.inner().adopted.items) |held| held.close();
        orphans.inner().own.clearRetainingCapacity();
        orphans.inner().adopted.clearRetainingCapacity();
    }

    /// Whether the running kernel has what this needs, asked of this process.
    fn probe() StartError!void {
        const self = Held.open(linux.getpid()) catch return error.Unsupported;
        defer self.close();
        var info = std.mem.zeroes(linux.siginfo_t);
        const rc = linux.waitid(.PIDFD, self.pidfd, &info, wait_exited | wait_no_hang, null);
        // This process is not its own child: a kernel that can wait on a pidfd
        // says so, and one that cannot (before 5.4) calls the id type invalid.
        if (linux.errno(rc) != .CHILD) return error.Unsupported;
        var path_buffer: [64]u8 = undefined;
        const path = std.fmt.bufPrintZ(&path_buffer, "/proc/self/task/{d}/children", .{linux.gettid()}) catch return error.Unsupported;
        const children = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (children < 0) return error.Unsupported;
        _ = c.close(children);
    }

    fn subreaper() bool {
        var flag: c_int = 0;
        const rc = linux.prctl(@intFromEnum(linux.PR.GET_CHILD_SUBREAPER), @intFromPtr(&flag), 0, 0, 0); // safe: the address of a local the call writes one int to, alive across it
        return linux.errno(rc) == .SUCCESS and flag != 0;
    }

    fn setSubreaper(on: bool) std.Io.UnexpectedError!void {
        const rc = linux.prctl(@intFromEnum(linux.PR.SET_CHILD_SUBREAPER), @intFromBool(on), 0, 0, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            else => |err| return posix.unexpectedErrno(err),
        }
    }

    /// Calls `each` with every child of every thread of this process, from
    /// `/proc/self/task/<tid>/children`. A thread that ends while this reads is
    /// passed over, with its children: they are another thread's by then, or
    /// this process's next time round.
    fn forEachChild(
        orphans: *Orphans,
        comptime each: fn (*Orphans, posix.pid_t) LookError!void,
    ) LookError!void {
        const dir = c.open("/proc/self/task", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
        if (dir < 0) return switch (c.errno(@as(c_int, -1))) {
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .NOMEM => error.SystemResources,
            else => |err| posix.unexpectedErrno(err),
        };
        defer _ = c.close(dir);

        var entries: [1024]u8 align(@alignOf(linux.dirent64)) = undefined;
        while (true) {
            const rc = linux.getdents64(dir, &entries, entries.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => |err| return posix.unexpectedErrno(err),
            }
            if (rc == 0) return;
            var names: tree.Dirents = .{ .bytes = entries[0..rc] };
            while (names.next()) |name| {
                _ = std.fmt.parseInt(posix.pid_t, name, 10) catch continue;
                var file_buffer: [32]u8 = undefined;
                const file = std.fmt.bufPrintZ(&file_buffer, "{s}/children", .{name}) catch continue;
                const fd = c.openat(dir, file, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
                if (fd < 0) continue;
                defer _ = c.close(fd);
                try eachListed(orphans, fd, each);
            }
        }
    }

    /// The pids a `children` file lists, space-separated, each handed to `each`.
    fn eachListed(
        orphans: *Orphans,
        fd: posix.fd_t,
        comptime each: fn (*Orphans, posix.pid_t) LookError!void,
    ) LookError!void {
        var buffer: [4096]u8 = undefined;
        var number: posix.pid_t = 0;
        var digits: usize = 0;
        while (true) {
            const n = c.read(fd, &buffer, buffer.len);
            if (n < 0) {
                if (c.errno(@as(c_int, -1)) == .INTR) continue;
                break;
            }
            if (n == 0) break;
            for (buffer[0..@intCast(n)]) |byte| {
                if (byte >= '0' and byte <= '9') {
                    number = number *| 10 +| (byte - '0');
                    digits += 1;
                    continue;
                }
                if (digits > 0) try each(orphans, number);
                number = 0;
                digits = 0;
            }
        }
        if (digits > 0) try each(orphans, number);
    }

    test "Orphans exposes no writable adoption state" {
        try std.testing.expect(@typeInfo(Orphans) == .@"enum");
    }
};

test "orphan records retain a pid and its captured start time" {
    var storage: [1]Orphans.Record = undefined;
    var orphans: Orphans = .init(std.testing.allocator);
    defer orphans.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try orphans.list(&storage)).len);
}

test "an unknown pidfd wait does not prove reap ownership" {
    const Refused = struct {
        fn child(_: posix.fd_t, _: *linux.siginfo_t) linux.E {
            return .PERM;
        }
    };
    const held: Orphans.Held = .{ .pid = if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else 1, .pidfd = if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else -1 };
    try std.testing.expectError(error.Unexpected, held.isChildWith(Refused));
}

test "orphan identity capture refuses a pid recycled during its start-time lookup" {
    const Reuse = struct {
        var retired: bool = false;
        var closes: usize = 0;
        var checks: usize = 0;

        fn open(pid: posix.pid_t) Orphans.Held.OpenError!Orphans.Held {
            return .{ .pid = pid, .pidfd = if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else 7 };
        }

        fn child(_: posix.fd_t, _: *linux.siginfo_t) linux.E {
            checks += 1;
            // The pidfd remains bound to the original process after the
            // number has been reused. Only that process can be ours to reap.
            return if (retired) .CHILD else .SUCCESS;
        }

        fn record(pid: posix.pid_t) ?Orphans.Record {
            // Force another reaper to retire the held process and let a
            // replacement occupy its pid before the by-number lookup returns.
            retired = true;
            return .{ .pid = pid, .start = 900, .group = pid, .session = pid };
        }

        fn close(_: posix.fd_t) void {
            closes += 1;
        }
    };
    Reuse.retired = false;
    Reuse.closes = 0;
    Reuse.checks = 0;
    try std.testing.expectError(error.Gone, Orphans.Held.openAdoptedWith(if (builtin.os.tag == .windows) std.os.windows.INVALID_HANDLE_VALUE else 123, Reuse));
    try std.testing.expectEqual(@as(usize, 2), Reuse.checks);
    try std.testing.expectEqual(@as(usize, 1), Reuse.closes);
}

test "orphan records copy group and session from the held adoption" {
    try std.testing.expect(@hasField(Orphans.Record, "group"));
    try std.testing.expect(@hasField(Orphans.Record, "session"));
}

test "Orphans Spawn exposes no writable adoption gate ownership" {
    try std.testing.expect(@typeInfo(Orphans.Spawn) == .@"enum");
}
