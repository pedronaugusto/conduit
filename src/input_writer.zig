//! Bounded, ordered input for a child on a pipe.
//!
//! `Child.inputWriter` takes the child's stdin pipe and starts its one writing
//! task. `queue` copies bytes and never waits for the child to read; `end`
//! closes the pipe after those bytes, and `wait` reports delivery or the first
//! failure. Delivery means written to the pipe, not consumed by the child.
//!
//! The writer owns its pipe independently of the Child. It may move before
//! being shared, but must not be copied. `queue`, `end` and `wait` may run on
//! several tasks; `cancel` has one caller at a time. Stop all callers before
//! `deinit`, which cancels and joins the writing task before freeing anything.
//! The allocator and Io used to create it must outlive it. Its own allocator
//! calls are serialized; a shared allocator must support its other users.

const std = @import("std");
const handles = @import("handles.zig");
const ChildState = @import("child/state.zig");

pub fn Writer(comptime Child: type) type {
    return struct {
        pub const InputWriter = enum(usize) {
            _,

            pub const Options = struct {
                /// Bytes accepted but not yet written, queued and in flight together.
                /// A batch stays charged until its whole write completes. Zero accepts
                /// only empty writes. The queue's allocation metadata is additional.
                max_backlog: usize,
            };

            pub const StartError = std.mem.Allocator.Error || std.Io.ConcurrentError || error{NoStdinPipe};
            pub const WriteError = std.Io.File.Writer.Error;
            pub const QueueError = WriteError || std.mem.Allocator.Error || error{ BacklogFull, InputClosed };

            /// Starts a writer and transfers the stdin pipe to it. `Child.inputWriter` is
            /// the same operation. On error the pipe remains the child's, untouched.
            /// A terminal has no separate input to close and is `error.NoStdinPipe`.
            /// Do not use an earlier copy of the pipe after this succeeds.
            pub fn init(io: std.Io, allocator: std.mem.Allocator, child: *Child, options: Options) StartError!InputWriter {
                const child_state = ChildState.optional(child) orelse return error.NoStdinPipe;
                const file = child_state.stdin orelse return error.NoStdinPipe;
                const state = try allocator.create(State);
                errdefer allocator.destroy(state);
                state.* = .{ .allocator = allocator, .file = file, .max_backlog = options.max_backlog };
                try state.group.concurrent(io, run, .{ state, io });
                ChildState.get(child).stdin = null;
                return @enumFromInt(@intFromPtr(state)); // safe: the owner retains this allocated State until deinit.
            }

            /// Whether input is still accepted, regardless of available backlog space.
            /// An uncancelable snapshot; end, cancellation or failure makes it false.
            /// A later queue call still checks its own acceptance and may fail.
            pub fn isOpen(writer: *const InputWriter, io: std.Io) bool {
                const state = writer.get();
                state.mutex.lockUncancelable(io);
                defer state.mutex.unlock(io);
                return !state.ending and state.failed == null;
            }

            /// Copies all of `bytes` into the queue, or accepts none of it. Concurrent
            /// calls are ordered by acquisition of the queue mutex; bytes within a call
            /// stay together. That mutex is held for allocation and copying, never for a
            /// pipe write. `BacklogFull` is a refusal, not a wait or a partial enqueue.
            /// After a write failure, every call returns that same error.
            pub fn queue(writer: *InputWriter, io: std.Io, bytes: []const u8) QueueError!void {
                const state = writer.get();
                try state.mutex.lock(io);
                defer state.mutex.unlock(io);
                if (state.failed) |err| return err;
                if (state.ending) return error.InputClosed;
                if (bytes.len > state.max_backlog - state.backlog) return error.BacklogFull;
                if (bytes.len == 0) return;
                const node = try state.allocator.create(Node);
                errdefer state.allocator.destroy(node);
                node.* = .{ .bytes = try state.allocator.dupe(u8, bytes) };
                if (state.tail) |tail| tail.next = node else state.head = node;
                state.tail = node;
                state.backlog += bytes.len;
                state.more.signal(io);
            }

            /// Refuses further input and asks the task to close the pipe after everything
            /// already queued. Returns at once, and is idempotent. A retained failure is
            /// returned instead. `wait` observes the eventual closure or failure.
            pub fn end(writer: *InputWriter, io: std.Io) WriteError!void {
                const state = writer.get();
                state.mutex.lockUncancelable(io);
                defer state.mutex.unlock(io);
                if (state.failed) |err| return err;
                state.ending = true;
                state.more.signal(io);
            }

            /// Waits until the pipe is closed, returning the first write failure or
            /// `Canceled` if delivery was abandoned. It does not request an end itself.
            /// Canceling a waiting caller leaves delivery running for the other callers.
            pub fn wait(writer: *InputWriter, io: std.Io) WriteError!void {
                const state = writer.get();
                try state.closed.wait(io);
                state.mutex.lockUncancelable(io);
                defer state.mutex.unlock(io);
                if (state.failed) |err| return err;
            }

            /// Abandons pending input, interrupts a blocked write and joins the task.
            /// No descriptor is closed under a write. Later calls report `Canceled`;
            /// an earlier write failure, or successful closure, stays final. Idempotent.
            /// Only one caller may cancel at a time; queue, end and wait may run alongside.
            pub fn cancel(writer: *InputWriter, io: std.Io) void {
                const state = writer.get();
                state.mutex.lockUncancelable(io);
                if (!state.finished and state.failed == null) state.failed = error.Canceled;
                state.mutex.unlock(io);
                state.group.cancel(io);
            }

            /// Cancels and joins the task, then frees the queue and state. Call after
            /// other users have stopped. Idempotent; after it only deinit may be called.
            pub fn deinit(writer: *InputWriter, io: std.Io) void {
                if (@intFromEnum(writer.*) == 0) return;
                writer.cancel(io);
                const state = writer.get();
                state.allocator.destroy(state);
                writer.* = @enumFromInt(0);
            }

            fn get(writer: *const InputWriter) *State {
                return @ptrFromInt(@intFromEnum(writer.*)); // safe: init allocated a State; deinit alone destroys it.
            }

            const Node = struct {
                next: ?*Node = null,
                bytes: []u8,
            };

            const State = struct {
                allocator: std.mem.Allocator,
                file: std.Io.File,
                max_backlog: usize,
                mutex: std.Io.Mutex = .init,
                more: std.Io.Condition = .init,
                head: ?*Node = null,
                tail: ?*Node = null,
                backlog: usize = 0,
                ending: bool = false,
                failed: ?WriteError = null,
                finished: bool = false,
                closed: std.Io.Event = .unset,
                group: std.Io.Group = .init,

                fn free(state: *State, node: *Node) void {
                    state.allocator.free(node.bytes);
                    state.allocator.destroy(node);
                }

                fn next(state: *State, io: std.Io) std.Io.Cancelable!?*Node {
                    try state.mutex.lock(io);
                    defer state.mutex.unlock(io);
                    while (state.head == null and !state.ending and state.failed == null)
                        try state.more.wait(io, &state.mutex);
                    if (state.failed != null) return null;
                    const node = state.head orelse return null;
                    state.head = node.next;
                    if (state.head == null) state.tail = null;
                    return node;
                }
            };

            fn run(state: *State, io: std.Io) void {
                var failure: ?WriteError = null;
                defer {
                    // Only this task ever uses or closes the transferred pipe.
                    state.file.close(io);
                    state.mutex.lockUncancelable(io);
                    defer state.mutex.unlock(io);
                    if (state.failed == null) state.failed = failure;
                    while (state.head) |node| {
                        state.head = node.next;
                        state.free(node);
                    }
                    state.tail = null;
                    state.backlog = 0;
                    state.ending = true;
                    state.finished = true;
                    state.closed.set(io);
                }
                while (true) {
                    const node = state.next(io) catch |err| {
                        failure = err;
                        return;
                    } orelse return;
                    handles.writeStreamingAll(state.file, io, node.bytes) catch |err| {
                        state.mutex.lockUncancelable(io);
                        defer state.mutex.unlock(io);
                        // Publish the failure before releasing the batch's backlog.
                        if (state.failed == null) state.failed = err;
                        state.free(node);
                        return;
                    };
                    state.mutex.lockUncancelable(io);
                    state.backlog -= node.bytes.len;
                    state.free(node);
                    state.mutex.unlock(io);
                }
            }

            test "InputWriter isOpen takes a contended mutex without cancellation" {
                const Backend = struct {
                    mutex: *std.Io.Mutex,
                    waits: usize = 0,
                    fn wait(userdata: ?*anyopaque, _: *const u32, _: u32) void {
                        const backend: *@This() = @ptrCast(@alignCast(userdata.?)); // safe: this test supplies its Backend as userdata.
                        backend.waits += 1;
                        backend.mutex.state.store(.unlocked, .release);
                    }
                    fn canceled(_: ?*anyopaque, _: *const u32, _: u32, _: std.Io.Timeout) std.Io.Cancelable!void {
                        return error.Canceled;
                    }
                    fn wake(_: ?*anyopaque, _: *const u32, _: u32) void {}
                };
                var state: State = .{ .allocator = std.testing.allocator, .file = undefined, .max_backlog = 0 };
                var writer: InputWriter = @enumFromInt(@intFromPtr(&state)); // safe: this synthetic writer borrows the State for this test only.
                var backend: Backend = .{ .mutex = &state.mutex };
                var vtable = std.testing.io.vtable.*;
                vtable.futexWait = Backend.canceled;
                vtable.futexWaitUncancelable = Backend.wait;
                vtable.futexWake = Backend.wake;
                const observed_io: std.Io = .{ .userdata = &backend, .vtable = &vtable };
                state.mutex.state.store(.locked_once, .release);
                try std.testing.expect(writer.isOpen(observed_io));
                try std.testing.expectEqual(@as(usize, 1), backend.waits);
            }
        };
    };
}
