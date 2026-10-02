//! Darwin's observed lineage, owned by one task from before the root runs.
//! A fork note gives no child id. Enumerate that parent's children promptly,
//! register each one before expanding it, and retain kernel unique identities.
//! A parent that forks and exits before enumeration can still hide its child;
//! neither process names nor init's children can repair that lost edge.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const posix = std.posix;
const tree = if (builtin.os.tag == .windows) struct {} else @import("tree.zig");

/// Test-only observer delay exposes the window without changing the fixture.
pub const testing_hook = struct {
    pub var fail_enumeration: std.atomic.Value(bool) = .init(false);
    pub var delay_ms: std.atomic.Value(u32) = .init(0);
};

pub const supported = if (builtin.os.tag == .windows) false else tree.Forks.supported;
pub const Tracker = if (supported) Darwin else struct {
    pub fn start(_: posix.pid_t) error{SystemResources}!*@This() {
        return error.SystemResources;
    }
    pub fn finish(_: *@This()) bool {
        return true;
    }
    pub fn failedTracking(_: *const @This()) bool {
        return false;
    }
    pub fn deinit(_: *@This()) void {}
};

const Darwin = struct {
    allocator: std.mem.Allocator,
    queue: posix.fd_t,
    wake: [2]posix.fd_t,
    thread: ?std.Thread = null,
    known: std.ArrayList(tree.DarwinProcess) = .empty,
    ending: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    /// Test handshake: registrations completed by this task, never a borrowed list.
    observed: if (builtin.is_test) std.atomic.Value(usize) else void = if (builtin.is_test) .init(0) else {},

    pub fn start(root: posix.pid_t) error{ OutOfMemory, SystemResources }!*Darwin {
        const allocator = std.heap.page_allocator;
        const tracker = try allocator.create(Darwin);
        errdefer allocator.destroy(tracker);
        const queue = c.kqueue();
        if (queue < 0) return error.SystemResources;
        errdefer _ = c.close(queue);
        const wake = @import("handles.zig").pipe() catch return error.SystemResources;
        errdefer {
            _ = c.close(wake[0]);
            _ = c.close(wake[1]);
        }
        tracker.* = .{ .allocator = allocator, .queue = queue, .wake = wake };
        errdefer tracker.known.deinit(allocator);
        try tracker.known.append(allocator, tree.DarwinProcess.capture(root) orelse return error.SystemResources);
        if (!tracker.register(root, c.EVFILT.PROC, c.NOTE.FORK | c.NOTE.EXEC | c.NOTE.EXIT, tracker.known.items[0].unique_id) or
            !tracker.register(wake[0], c.EVFILT.READ, 0, 0)) return error.SystemResources;
        if (builtin.is_test) tracker.observed.store(1, .release);
        tracker.thread = std.Thread.spawn(.{}, run, .{tracker}) catch return error.SystemResources;
        return tracker;
    }

    fn register(tracker: *Darwin, id: posix.pid_t, filter: i16, flags: u32, identity: u64) bool {
        var change = [_]c.kevent64_s{.{ .ident = @intCast(id), .filter = filter, .flags = c.EV.ADD | c.EV.ENABLE | c.EV.CLEAR, .fflags = flags, .data = 0, .udata = identity, .ext = .{ 0, 0 } }};
        var nothing: [0]c.kevent64_s = undefined;
        return c.kevent64(tracker.queue, &change, 1, &nothing, 0, .{ .IMMEDIATE = true }, null) == 0;
    }

    /// Request the final force; nonblocking even for Child.tryWait.
    pub fn finish(tracker: *Darwin) bool {
        if (!tracker.ending.swap(true, .acq_rel)) _ = c.write(tracker.wake[1], "x", 1);
        return tracker.done.load(.acquire);
    }

    pub fn failedTracking(tracker: *const Darwin) bool {
        return tracker.failed.load(.acquire);
    }

    fn discover(tracker: *Darwin, parent: tree.DarwinProcess) !void {
        if (builtin.is_test) {
            if (testing_hook.fail_enumeration.load(.acquire)) return error.SystemResources;
            const delay_ms = testing_hook.delay_ms.load(.acquire);
            if (delay_ms != 0) {
                const delay: c.timespec = .{ .sec = 0, .nsec = @intCast(@as(u64, delay_ms) * std.time.ns_per_ms) };
                _ = c.nanosleep(&delay, null);
            }
        }
        var children: std.ArrayList(posix.pid_t) = .empty;
        defer children.deinit(tracker.allocator);
        try tree.observedChildrenOfDarwin(parent.pid, &children, tracker.allocator);
        for (children.items) |pid| {
            const child = tree.DarwinProcess.capture(pid) orelse continue;
            if (!child.childOf(&parent)) continue;
            var found = false;
            for (tracker.known.items) |held| if (held.unique_id == child.unique_id) {
                found = true;
                break;
            };
            if (found) continue;
            try tracker.known.append(tracker.allocator, child);
            // If registration loses to exit, still expand its current children.
            // No delay between discovering an edge and watching the next fork.
            const watching = tracker.register(pid, c.EVFILT.PROC, c.NOTE.FORK | c.NOTE.EXEC | c.NOTE.EXIT, child.unique_id);
            if (!watching and child.alive()) return error.SystemResources;
            if (builtin.is_test and watching) _ = tracker.observed.fetchAdd(1, .release);
            try tracker.discover(child);
        }
    }

    fn run(tracker: *Darwin) void {
        defer tracker.done.store(true, .release);
        var events: [64]c.kevent64_s = undefined;
        var nothing: [0]c.kevent64_s = undefined;
        while (true) {
            const ending = tracker.ending.load(.acquire);
            if (ending) {
                // Expand before ending a parent, so cleanup itself does not
                // erase an edge that was still available to enumeration.
                var index: usize = 0;
                while (index < tracker.known.items.len) : (index += 1)
                    tracker.discover(tracker.known.items[index]) catch {
                        tracker.failed.store(true, .release);
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
            const timeout: c.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
            const ready = c.kevent64(tracker.queue, &nothing, 0, &events, events.len, .{}, if (ending) &timeout else null);
            if (ready < 0) {
                if (posix.errno(-1) == .INTR) continue;
                // Losing the observer must end its still-held root, so a
                // contained child cannot keep spawning unobserved descendants.
                tracker.failed.store(true, .release);
                _ = tracker.known.items[0].signal(.KILL);
                tracker.ending.store(true, .release);
                continue;
            }
            for (events[0..@intCast(ready)]) |event| {
                if (event.filter != c.EVFILT.PROC) continue;
                // No index or borrowed list pointer survives discover's growth.
                for (tracker.known.items) |parent| {
                    if (parent.pid != event.ident or parent.unique_id != event.udata) continue;
                    tracker.discover(parent) catch {
                        tracker.failed.store(true, .release);
                        _ = tracker.known.items[0].signal(.KILL);
                        tracker.ending.store(true, .release);
                    };
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

    pub fn deinit(tracker: *Darwin) void {
        _ = tracker.finish();
        if (tracker.thread) |thread| thread.join();
        _ = c.close(tracker.queue);
        _ = c.close(tracker.wake[0]);
        _ = c.close(tracker.wake[1]);
        const allocator = tracker.allocator;
        tracker.known.deinit(allocator);
        allocator.destroy(tracker);
    }
};

pub const test_access = if (@import("builtin").is_test) struct {
    pub const tree = fixture_tree;
    pub const Darwin = fixture_Darwin;
} else struct {};
const fixture_tree = tree;
const fixture_Darwin = Darwin;
