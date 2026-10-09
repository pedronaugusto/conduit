//! Bounded, ordered input for a child on a pipe.
//!
//! `Child.inputWriter` takes the child's stdin pipe and starts its one writing
//! task. `queue` copies bytes and never waits for the child to read; `close`
//! closes the pipe after those bytes, and `wait` reports delivery or the first
//! failure. Delivery means written to the pipe, not consumed by the child.
//!
//! The writer owns its pipe independently of the Child. It may move before
//! being shared, but must not be copied. `queue`, `close` and `wait` may run on
//! several tasks; `cancel` has one caller at a time. Stop all callers before
//! `deinit`, which cancels and joins the writing task before freeing anything.
//! The allocator and Io used to create it must outlive it. Its own allocator
//! calls are serialized; a shared allocator must support its other users.

const std = @import("std");
const aegis = @import("aegis");
const handles = @import("handles.zig");

pub fn Writer(comptime Child: type) type {
    return struct {
        pub const InputWriter = struct {
            /// Private: the queue and its task, allocated by `init` and freed by
            /// `deinit`.
            state: *State,

            pub const Options = struct {
                /// Bytes accepted but not yet written, queued and in flight together.
                /// A batch stays charged until its whole write completes. Zero accepts
                /// only empty writes. The queue's allocation metadata is additional.
                max_backlog: aegis.units.Bytes(usize),
            };

            pub const StartError = std.mem.Allocator.Error || std.Io.ConcurrentError || error{NoStdinPipe};
            pub const WriteError = std.Io.File.Writer.Error;
            pub const QueueError = WriteError || std.mem.Allocator.Error || error{ BacklogFull, InputClosed };

            /// Starts a writer and transfers the stdin pipe to it. `Child.inputWriter` is
            /// the same operation. On error the pipe remains the child's, untouched.
            /// A terminal has no separate input to close and is `error.NoStdinPipe`.
            /// Do not use an earlier copy of the pipe after this succeeds.
            pub fn init(gpa: std.mem.Allocator, io: std.Io, child: *Child, options: Options) StartError!InputWriter {
                const child_state = child.state;
                const file = child_state.stdin orelse return error.NoStdinPipe;
                const state = try gpa.create(State);
                errdefer gpa.destroy(state);
                state.* = .init(gpa, file, options.max_backlog);
                try state.group.concurrent(io, State.run, .{ state, io });
                child.state.stdin = null;
                return .{ .state = state };
            }

            /// Whether input is still accepted, regardless of available backlog space.
            /// An uncancelable snapshot; end, cancellation or failure makes it false.
            /// A later queue call still checks its own acceptance and may fail.
            pub fn isOpen(writer: *const InputWriter, io: std.Io) bool {
                const state = writer.state;
                var held = state.queue.acquireUncancelable(io);
                defer held.deinit(io);
                const inbox = held.value();
                return !inbox.ending and inbox.failed == null;
            }

            /// Copies all of `bytes` into the queue, or accepts none of it. Concurrent
            /// calls are ordered by acquisition of the queue mutex; bytes within a call
            /// stay together. That mutex is held for allocation and copying, never for a
            /// pipe write. `BacklogFull` is a refusal, not a wait or a partial enqueue.
            /// After a write failure, every call returns that same error.
            pub fn queue(writer: *InputWriter, io: std.Io, bytes: []const u8) QueueError!void {
                const state = writer.state;
                var held = try state.queue.acquire(io);
                defer held.deinit(io);
                const inbox = held.value();
                if (inbox.failed) |err| return err;
                if (inbox.ending) return error.InputClosed;
                if (bytes.len == 0) return;
                // Charged before anything is allocated, and released with the
                // batch it admitted: by the write that completes it, or by the
                // end of the writer, never by the caller giving up.
                var charge = inbox.backlog.reserve(bytes.len) catch return error.BacklogFull;
                errdefer charge.release();
                const node = try state.gpa.create(Node);
                errdefer state.gpa.destroy(node);
                const copy = try state.gpa.dupe(u8, bytes);
                node.* = .{ .batch = .init(.{ .gpa = state.gpa, .bytes = copy, .charge = undefined }) };
                charge.moveInto(&node.batch.borrowMut().charge);
                if (inbox.tail) |tail| tail.next = node else inbox.head = node;
                inbox.tail = node;
                state.more.signal(io);
            }

            /// Refuses further input and asks the task to close the pipe after everything
            /// already queued. Returns at once, and is idempotent. A retained failure is
            /// returned instead. `wait` observes the eventual closure or failure.
            pub fn close(writer: *InputWriter, io: std.Io) WriteError!void {
                const state = writer.state;
                var held = state.queue.acquireUncancelable(io);
                defer held.deinit(io);
                const inbox = held.value();
                if (inbox.failed) |err| return err;
                inbox.ending = true;
                state.more.signal(io);
            }

            /// Waits until the pipe is closed, returning the first write failure or
            /// `Canceled` if delivery was abandoned. It does not ask for the close itself.
            /// Canceling a waiting caller leaves delivery running for the other callers.
            pub fn wait(writer: *InputWriter, io: std.Io) WriteError!void {
                const state = writer.state;
                try state.closed.wait(io);
                var held = state.queue.acquireUncancelable(io);
                defer held.deinit(io);
                if (held.value().failed) |err| return err;
            }

            /// Abandons pending input, interrupts a blocked write and joins the task.
            /// No descriptor is closed under a write. Later calls report `Canceled`;
            /// an earlier write failure, or successful closure, stays final. Idempotent.
            /// Only one caller may cancel at a time; queue, close and wait may run alongside.
            pub fn cancel(writer: *InputWriter, io: std.Io) void {
                const state = writer.state;
                {
                    var held = state.queue.acquireUncancelable(io);
                    defer held.deinit(io);
                    const inbox = held.value();
                    if (!inbox.finished and inbox.failed == null) inbox.failed = error.Canceled;
                }
                state.group.cancel(io);
            }

            /// Cancels and joins the task, then frees the queue and state. Call after
            /// other users have stopped. The InputWriter is undefined afterwards;
            /// `cancel` is the call that can be made more than once.
            pub fn deinit(writer: *InputWriter, io: std.Io) void {
                writer.cancel(io);
                const state = writer.state;
                state.gpa.destroy(state);
                writer.* = undefined;
            }
        };
    };
}

/// One batch of queued bytes, and what it is charged against the backlog.
const Batch = struct {
    gpa: std.mem.Allocator,
    bytes: []u8,
    charge: aegis.bounded.Budget(usize).Reservation,

    /// Gives back the bytes and the charge, together: the one place either is
    /// released.
    fn release(batch: *Batch) void {
        batch.charge.release();
        batch.gpa.free(batch.bytes);
    }
};

/// A queued batch, in the order it was accepted.
const Node = struct {
    next: ?*Node = null,
    batch: aegis.own.Owned(Batch, Batch.release),
};

/// What the queue's callers and the writing task share, behind `State.queue`.
const Queue = struct {
    /// Bytes accepted and not yet written. Its ceiling is `max_backlog`.
    backlog: aegis.bounded.Budget(usize),
    head: ?*Node = null,
    tail: ?*Node = null,
    ending: bool = false,
    failed: ?std.Io.File.Writer.Error = null,
    finished: bool = false,
};

/// What an `InputWriter` and its writing task share. `queue` guards every
/// field a caller and the task both touch; the file only the task uses once it
/// has started.
const State = struct {
    gpa: std.mem.Allocator,
    file: std.Io.File,
    queue: aegis.BlockingGuarded(Queue),
    /// The one waiter is the writing task, waiting for a batch or an end.
    more: aegis.Condition = .initLimit(1),
    closed: std.Io.Event = .unset,
    group: std.Io.Group = .init,

    fn init(gpa: std.mem.Allocator, file: std.Io.File, max_backlog: aegis.units.Bytes(usize)) State {
        return .{ .gpa = gpa, .file = file, .queue = .init(.{ .backlog = .init(max_backlog.raw()) }) };
    }

    /// Releases a batch and frees its node. Under the guard, like every use of
    /// the backlog it was charged to.
    fn free(state: *State, node: *Node) void {
        node.batch.deinit();
        state.gpa.destroy(node);
    }

    fn next(state: *State, io: std.Io) std.Io.Cancelable!?*Node {
        var held = try state.queue.acquire(io);
        defer held.deinit(io);
        while (held.value().head == null and !held.value().ending and held.value().failed == null) {
            state.more.wait(io, &held, .none) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                // unreachable: the wait has no timeout, and the writing task is the one waiter.
                error.Timeout, error.WaiterLimit => unreachable,
            };
        }
        const queue = held.value();
        if (queue.failed != null) return null;
        const node = queue.head orelse {
            std.debug.assert(queue.tail == null);
            return null;
        };
        queue.head = node.next;
        if (queue.head == null) queue.tail = null;
        std.debug.assert(node.batch.borrow().bytes.len > 0);
        return node;
    }

    /// The writing task: each batch in order, then the pipe closed.
    fn run(state: *State, io: std.Io) void {
        var failure: ?std.Io.File.Writer.Error = null;
        defer {
            // Only this task ever uses or closes the transferred pipe.
            state.file.close(io);
            var held = state.queue.acquireUncancelable(io);
            defer held.deinit(io);
            const queue = held.value();
            if (queue.failed == null) queue.failed = failure;
            // Every batch still queued gives its charge back with its bytes.
            while (queue.head) |node| {
                queue.head = node.next;
                state.free(node);
            }
            queue.tail = null;
            queue.ending = true;
            queue.finished = true;
            state.closed.set(io);
        }
        while (true) {
            const node = state.next(io) catch |err| {
                failure = err;
                return;
            } orelse return;
            handles.writeStreamingAll(io, state.file, node.batch.borrow().bytes) catch |err| {
                var held = state.queue.acquireUncancelable(io);
                defer held.deinit(io);
                // Publish the failure before releasing the batch's backlog.
                if (held.value().failed == null) held.value().failed = err;
                state.free(node);
                return;
            };
            var held = state.queue.acquireUncancelable(io);
            defer held.deinit(io);
            // Written: the batch's bytes and the charge `queue` made for it go back together.
            state.free(node);
        }
    }
};

/// A writer over a `Child` that is never spawned: what the tests below need
/// is the queue, not the pipe.
const TestWriter = Writer(struct {}).InputWriter;

/// Tests only: the fault plans of the tests below.
const shakedown = @import("shakedown");

test "InputWriter isOpen takes a contended mutex without cancellation" {
    const Release = struct {
        /// The holder lets go as the waiter enters its wait, so the wait
        /// finds the word changed and returns.
        fn unlock(_: std.Io, context: *anyopaque) void {
            const mutex: *std.Io.Mutex = @ptrCast(@alignCast(context)); // safe: the plan hands this test's mutex as the context
            mutex.state.store(.unlocked, .release);
        }
    };
    var state: State = .init(std.testing.allocator, undefined, .fromRaw(0));
    var writer: TestWriter = .{ .state = &state };
    // A cancelable wait would fail the test, through any cancel.
    const observed = try shakedown.FaultIo.init(std.testing.allocator, std.testing.io, .{ .plan = &.{
        .{ .at = .{ .nth = .{ .call = .futexWaitUncancelable, .n = 1 } }, .fault = .{ .call = .{ .ctx = &state.queue.mutex, .f = Release.unlock } } },
        .{ .at = .{ .nth = .{ .call = .futexWait, .n = 1 } }, .fault = .cancel, .times = 0 },
    } });
    defer observed.deinit();
    state.queue.mutex.state.store(.locked_once, .release);
    try std.testing.expect(writer.isOpen(observed.io()));
    try std.testing.expectEqual(@as(u64, 1), observed.count(.futexWaitUncancelable));
    try std.testing.expectEqual(@as(u64, 0), observed.count(.futexWait));
}
