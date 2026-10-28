//! Darwin's observed lineage, owned by one task from before the root runs.
//! A fork note gives no child id. Enumerate that parent's children promptly,
//! register each one before expanding it, and retain kernel unique identities.
//! A parent that forks and exits before enumeration can still hide its child;
//! neither process names nor init's children can repair that lost edge.
//!
//! The notes arrive on a kqueue of the tracker's own, which its task waits
//! on through reactor (the queue is readable while it holds events) beside
//! a `Wake` that asks it to end. Ending kills every known descendant and
//! waits for their exit notes, expanding any fork they make first, until
//! none is left.
const std = @import("std");
const aegis = @import("aegis");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const tree = @import("tree.zig");
const reactor = @import("reactor");

/// Test-only observer delay exposes the window without changing the fixture.
pub const testing_hook = struct {
    pub var enumeration: aegis.Atomic(Enumeration) = .init(.normal);
    pub var delay: aegis.Atomic(aegis.units.Duration(.millisecond, u32)) = .init(.fromRaw(0));
    pub const Enumeration = enum(u8) { normal, fail };
};

/// Whether a tracker has been asked to end, whether its task has finished
/// watching, and whether a look failed.
const Ending = enum(u8) { running, ending };
const Watching = enum(u8) { watching, done };
const Outcome = enum(u8) { ok, failed };

pub const supported = if (builtin.target.os.tag == .windows) false else tree.Forks.supported;
pub const Tracker = if (supported) Darwin else NoTracker;

/// Where there is no fork note to observe: no tracker ever starts.
const NoTracker = struct {
    pub fn start(_: std.mem.Allocator, _: std.Io, _: posix.pid_t) error{SystemResources}!*NoTracker {
        return error.SystemResources;
    }
    pub fn finish(_: *NoTracker) bool {
        return true;
    }
    pub fn waitFinished(_: *NoTracker, _: std.Io, _: std.Io.Timeout) std.Io.Cancelable!bool {
        return true;
    }
    pub fn failedTracking(_: *const NoTracker) bool {
        return false;
    }
    pub fn destroy(tracker: *NoTracker, _: std.Io) void {
        tracker.* = undefined;
    }
};

const Darwin = struct {
    gpa: std.mem.Allocator,
    queue: posix.fd_t,
    /// Signaled once `ending` is set, for the task that waits on the queue.
    end: reactor.Wake,
    task: std.Io.Future(void) = undefined,
    known: std.ArrayList(tree.DarwinProcess) = .empty,
    ending: aegis.Atomic(Ending) = .init(.running),
    done: aegis.Atomic(Watching) = .init(.watching),
    /// Signaled once `done` is set, for a reap that waits on it.
    finished: reactor.Wake,
    failed: aegis.Atomic(Outcome) = .init(.ok),
    /// Test handshake: registrations completed by this task, never a borrowed list.
    observed: if (builtin.is_test) std.atomic.Value(usize) else void = if (builtin.is_test) .init(0) else {},

    pub fn start(gpa: std.mem.Allocator, io: std.Io, root: posix.pid_t) error{ OutOfMemory, SystemResources }!*Darwin {
        const tracker = try gpa.create(Darwin);
        errdefer gpa.destroy(tracker);
        const queue = c.kqueue();
        if (queue < 0) return error.SystemResources;
        errdefer _ = c.close(queue);
        var end = reactor.Wake.init(io) catch return error.SystemResources;
        errdefer end.deinit(io);
        var finished = reactor.Wake.init(io) catch return error.SystemResources;
        errdefer finished.deinit(io);
        tracker.* = .{ .gpa = gpa, .queue = queue, .end = end, .finished = finished };
        errdefer tracker.known.deinit(gpa);
        try tracker.known.append(gpa, tree.DarwinProcess.capture(root) orelse return error.SystemResources);
        if (!tracker.register(root, c.EVFILT.PROC, c.NOTE.FORK | c.NOTE.EXEC | c.NOTE.EXIT, tracker.known.items[0].unique_id)) return error.SystemResources;
        if (builtin.is_test) tracker.observed.store(1, .release);
        tracker.task = io.concurrent(run, .{ tracker, io }) catch return error.SystemResources;
        return tracker;
    }

    fn register(tracker: *Darwin, id: posix.pid_t, filter: i16, flags: u32, identity: u64) bool {
        var change = [_]c.kevent64_s{.{ .ident = @intCast(id), .filter = filter, .flags = c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR, .fflags = flags, .data = 0, .udata = identity, .ext = .{ 0, 0 } }};
        var nothing: [0]c.kevent64_s = undefined;
        return c.kevent64(tracker.queue, &change, 1, &nothing, 0, .{ .IMMEDIATE = true }, null) == 0;
    }

    /// Request the final force; nonblocking even for Child.tryWait.
    pub fn finish(tracker: *Darwin) bool {
        if (tracker.ending.swap(.ending, .acq_rel) != .ending) tracker.end.signal();
        return tracker.done.load(.acquire) == .done;
    }

    /// Asks for the final force, and waits until it is done or `timeout`
    /// passes: true once done.
    pub fn waitFinished(tracker: *Darwin, io: std.Io, timeout: std.Io.Timeout) std.Io.Cancelable!bool {
        while (!tracker.finish()) tracker.finished.wait(io, timeout) catch |err| switch (err) {
            error.Timeout => return tracker.done.load(.acquire) == .done,
            error.Canceled => return error.Canceled,
        };
        return true;
    }

    pub fn failedTracking(tracker: *const Darwin) bool {
        return tracker.failed.load(.acquire) == .failed;
    }

    fn discover(tracker: *Darwin, parent: tree.DarwinProcess) !void {
        if (builtin.is_test) {
            if (testing_hook.enumeration.load(.acquire) == .fail) return error.SystemResources;
            const hold = testing_hook.delay.load(.acquire);
            if (hold.compare(.fromRaw(0)) == .gt) {
                const delay: c.timespec = .{ .sec = 0, .nsec = @intCast(hold.convert(.nanosecond, u64, .exact).raw()) }; // aegis: boundary: nanosleep takes the nanoseconds as a C integer
                _ = c.nanosleep(&delay, null);
            }
        }
        var children: std.ArrayList(posix.pid_t) = .empty;
        defer children.deinit(tracker.gpa);
        try tree.observedChildrenOfDarwin(tracker.gpa, parent.pid, &children);
        for (children.items) |pid| {
            const child = tree.DarwinProcess.capture(pid) orelse continue;
            if (!child.childOf(&parent)) continue;
            var found = false;
            for (tracker.known.items) |held| if (held.unique_id == child.unique_id) {
                found = true;
                break;
            };
            if (found) continue;
            try tracker.known.append(tracker.gpa, child);
            // If registration loses to exit, still expand its current children.
            // No delay between discovering an edge and watching the next fork.
            const watching = tracker.register(pid, c.EVFILT.PROC, c.NOTE.FORK | c.NOTE.EXEC | c.NOTE.EXIT, child.unique_id);
            if (!watching and child.alive()) return error.SystemResources;
            if (builtin.is_test and watching) _ = tracker.observed.fetchAdd(1, .release);
            try tracker.discover(child);
        }
    }

    fn run(tracker: *Darwin, io: std.Io) void {
        defer {
            tracker.done.store(.done, .release);
            tracker.finished.signal();
        }
        var events: [64]c.kevent64_s = undefined;
        var nothing: [0]c.kevent64_s = undefined;
        while (true) {
            const ending = tracker.ending.load(.acquire) == .ending;
            if (ending) {
                // Expand before ending a parent, so cleanup itself does not
                // erase an edge that was still available to enumeration.
                var index: usize = 0;
                while (index < tracker.known.items.len) : (index += 1)
                    tracker.discover(tracker.known.items[index]) catch {
                        tracker.failed.store(.failed, .release);
                    };
                var alive = false;
                var reverse = tracker.known.items.len;
                while (reverse > 1) {
                    reverse -= 1;
                    const process = &tracker.known.items[reverse];
                    if (process.alive()) {
                        alive = true;
                        _ = process.signal(.KILL);
                    }
                }
                if (!alive) return;
            }
            // The queue's notes, and until ending a request to end. Each one
            // killed above posts its exit note, and a fork first its own.
            const members = [_]reactor.Waitable{ .{ .readable = tracker.queue }, .{ .wake = &tracker.end } };
            _ = reactor.waitAny(io, members[0 .. @as(usize, 1) + @intFromBool(!ending)], .none) catch |err| switch (err) {
                // Nobody cancels the task but its own end: taken as one.
                error.Canceled => {
                    tracker.ending.store(.ending, .release);
                    continue;
                },
                error.Timeout => unreachable, // unreachable: the wait has no timeout
                error.Unsupported, error.Unexpected => {
                    tracker.lost();
                    continue;
                },
            };
            const ready = c.kevent64(tracker.queue, &nothing, 0, &events, events.len, .{ .IMMEDIATE = true }, null);
            if (ready < 0) {
                if (posix.errno(-1) == .INTR) continue;
                tracker.lost();
                continue;
            }
            for (events[0..@intCast(ready)]) |event| {
                if (event.filter != c.EVFILT.PROC) continue;
                // No index or borrowed list pointer survives discover's growth.
                for (tracker.known.items) |parent| {
                    if (parent.pid != event.ident or parent.unique_id != event.udata) continue;
                    tracker.discover(parent) catch tracker.lost();
                    if (event.fflags & c.NOTE.EXIT != 0 and parent.unique_id != tracker.known.items[0].unique_id) {
                        for (tracker.known.items, 0..) |held, index| {
                            if (held.unique_id == parent.unique_id) {
                                _ = tracker.known.orderedRemove(index);
                                break;
                            }
                        }
                    }
                    break;
                }
            }
        }
    }

    /// Losing the observer must end its still-held root, so a contained
    /// child cannot keep spawning unobserved descendants.
    fn lost(tracker: *Darwin) void {
        tracker.failed.store(.failed, .release);
        _ = tracker.known.items[0].signal(.KILL);
        tracker.ending.store(.ending, .release);
    }

    /// Stops the task, closes the queue and frees the tracker: `tracker` is
    /// gone when this returns.
    pub fn destroy(tracker: *Darwin, io: std.Io) void {
        _ = tracker.finish();
        tracker.task.await(io);
        tracker.finished.deinit(io);
        tracker.end.deinit(io);
        _ = c.close(tracker.queue);
        const gpa = tracker.gpa;
        tracker.known.deinit(gpa);
        gpa.destroy(tracker);
    }
};
