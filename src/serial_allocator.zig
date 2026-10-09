//! An allocator whose calls are made one at a time, for work spread over
//! tasks that is given one allocator by a caller who may not have made it safe
//! to share: an arena, a fixed buffer, a debug allocator built single-threaded.
const std = @import("std");
const aegis = @import("aegis");

pub const SerialAllocator = struct {
    /// The allocator interface has no `std.Io` to pass, so this is the one
    /// place conduit keeps one: the borrow lasts as long as the allocator.
    io: std.Io,
    /// The caller's allocator, reachable only while the guard is held.
    parent: aegis.BlockingGuarded(std.mem.Allocator),

    /// Borrows `parent` and `io`, which must outlive the result.
    pub fn init(parent: std.mem.Allocator, io: std.Io) SerialAllocator {
        return .{ .io = io, .parent = .init(parent) };
    }

    /// Borrows `serial`, which must stay where it is while the result is used.
    pub fn allocator(serial: *SerialAllocator) std.mem.Allocator {
        return .{ .ptr = serial, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn of(raw: *anyopaque) *SerialAllocator {
        return @ptrCast(@alignCast(raw)); // safe: `allocator` installs a live SerialAllocator as the pointer.
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const serial = of(raw);
        var held = serial.parent.acquireUncancelable(serial.io);
        defer held.deinit(serial.io);
        return held.value().rawAlloc(len, alignment, ret);
    }

    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const serial = of(raw);
        var held = serial.parent.acquireUncancelable(serial.io);
        defer held.deinit(serial.io);
        return held.value().rawResize(memory, alignment, len, ret);
    }

    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const serial = of(raw);
        var held = serial.parent.acquireUncancelable(serial.io);
        defer held.deinit(serial.io);
        return held.value().rawRemap(memory, alignment, len, ret);
    }

    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const serial = of(raw);
        var held = serial.parent.acquireUncancelable(serial.io);
        defer held.deinit(serial.io);
        held.value().rawFree(memory, alignment, ret);
    }
};
