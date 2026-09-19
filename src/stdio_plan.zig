//! What the child's three standard streams are connected to, minus the
//! handles.
//!
//! The decisions are the same on both systems: which stream gets what, that
//! one null device serves every stream that asked for it, that `stderr_to` is
//! applied last and undoes a standard-error pipe that was already planned, and
//! which of the handles involved the parent must close once the child has its
//! own copies. What differs is the calls that make a handle, and those are the
//! two the caller supplies.
//!
//! The two spawn implementations then keep only what is theirs: on POSIX,
//! putting the handles at descriptors 0, 1 and 2 in an order that cannot cross
//! them; on Windows, naming them in a startup record and saying which the
//! child may inherit.

const std = @import("std");

const Child = @import("Child.zig");
const handles = @import("handles.zig");

/// A stream handle: `std.posix.fd_t` on POSIX, `HANDLE` on Windows.
pub const Handle = std.Io.File.Handle;

/// The two ends of a new pipe, named by who keeps which.
pub const Pipe = struct {
    /// The end the child is given.
    child: Handle,
    /// The end this process keeps.
    parent: Handle,
};

/// What the child gets for one of its three standard streams.
pub const Target = union(enum) {
    /// Whatever the parent has there. On POSIX that is a descriptor left
    /// alone; on Windows the parent's handle has to be named, because saying
    /// which handles a child gets is all or nothing there.
    inherit,
    /// This handle.
    place: Handle,
    /// Nothing: the child starts with no stream there.
    close,
};

/// Builds a `Plan` with `system`'s handles.
///
/// `system` is a namespace with three declarations:
///
/// * `Error`, the error set its two calls may fail with;
/// * `openNull() Error!Handle`, the null device, opened for both directions so
///   that one handle can serve any of the three streams;
/// * `openPipe(child_reads: bool) Error!Pipe`.
pub fn Plan(comptime system: type) type {
    return struct {
        /// What the child gets, by stream: standard input, output, error.
        child: [3]Target = @splat(.inherit),
        /// The subset of `child` this `Plan` opened, and must close in the
        /// parent once the child has its own copies. A null device shared by
        /// more than one stream appears once, at the stream that opened it.
        owned: [3]?Handle = @splat(null),
        /// The parent's end of each pipe, by the stream it serves in the
        /// child.
        parent: [3]?std.Io.File = @splat(null),

        const Self = @This();

        /// `on_pty` is the terminal end, for a child whose whole set of
        /// streams is a pseudo-terminal, and `null` for every other spawn --
        /// including a pseudoconsole, which a child is attached to rather than
        /// handed on a stream, and whose `Plan` is therefore empty.
        pub fn init(io: std.Io, options: Child.SpawnOptions, on_pty: ?Handle) system.Error!Self {
            var plan: Self = .{};
            errdefer plan.closeAll(io);

            switch (options.stdio) {
                // The terminal end on all three, and nothing this `Plan` owns:
                // the pair is the caller's.
                .pty => if (on_pty) |slave| {
                    plan.child = @splat(.{ .place = slave });
                },
                else => {
                    // One null device serves every stream that asked for it.
                    var null_device: ?Handle = null;
                    for (options.stdio.perStream(), 0..) |stream, slot| switch (stream) {
                        .inherit => {},
                        .close => plan.child[slot] = .close,
                        .file => |f| plan.child[slot] = .{ .place = f.handle },
                        .ignore => {
                            const handle = null_device orelse opened: {
                                const device = try system.openNull();
                                plan.owned[slot] = device;
                                null_device = device;
                                break :opened device;
                            };
                            plan.child[slot] = .{ .place = handle };
                        },
                        .pipe => {
                            // Standard input is the one the child reads.
                            const ends = try system.openPipe(slot == 0);
                            plan.child[slot] = .{ .place = ends.child };
                            plan.owned[slot] = ends.child;
                            plan.parent[slot] = handles.file(ends.parent);
                        },
                    };
                },
            }

            if (options.stderr_to) |f| {
                // A standard-error pipe that was planned is undone: the caller
                // asked for the file instead, and the file is theirs, not this
                // `Plan`'s.
                if (plan.owned[2]) |handle| {
                    handles.file(handle).close(io);
                    plan.owned[2] = null;
                }
                if (plan.parent[2]) |end| {
                    end.close(io);
                    plan.parent[2] = null;
                }
                plan.child[2] = .{ .place = f.handle };
            }

            return plan;
        }

        /// Closes the handles that exist only for the child. Called in the
        /// parent once the child has copies of its own. Idempotent.
        pub fn closeChildSide(plan: *Self, io: std.Io) void {
            for (&plan.owned) |*slot| {
                const handle = slot.* orelse continue;
                handles.file(handle).close(io);
                slot.* = null;
            }
        }

        /// Closes everything this `Plan` opened, on the path where no child
        /// was started or the child failed before it could run. Idempotent, so
        /// the failure path may close twice without closing a handle that has
        /// since been handed to something else.
        pub fn closeAll(plan: *Self, io: std.Io) void {
            plan.closeChildSide(io);
            for (&plan.parent) |*slot| {
                const f = slot.* orelse continue;
                f.close(io);
                slot.* = null;
            }
        }
    };
}
