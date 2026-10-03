//! An allocator whose calls are made one at a time, for work spread over
//! tasks that is given one allocator by a caller who may not have made it safe
//! to share: an arena, a fixed buffer, a debug allocator built single-threaded.
const std = @import("std");

pub const SerialAllocator = struct {
    parent: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,

    /// Borrows `serial`, which must stay where it is while the result is used.
    pub fn allocator(serial: *SerialAllocator) std.mem.Allocator {
        return .{ .ptr = serial, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn of(raw: *anyopaque) *SerialAllocator {
        return @ptrCast(@alignCast(raw)); // safe: `allocator` installs a live SerialAllocator as the pointer.
    }

    fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const serial = of(raw);
        serial.mutex.lockUncancelable(serial.io);
        defer serial.mutex.unlock(serial.io);
        return serial.parent.rawAlloc(len, alignment, ret);
    }

    fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const serial = of(raw);
        serial.mutex.lockUncancelable(serial.io);
        defer serial.mutex.unlock(serial.io);
        return serial.parent.rawResize(memory, alignment, len, ret);
    }

    fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const serial = of(raw);
        serial.mutex.lockUncancelable(serial.io);
        defer serial.mutex.unlock(serial.io);
        return serial.parent.rawRemap(memory, alignment, len, ret);
    }

    fn free(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const serial = of(raw);
        serial.mutex.lockUncancelable(serial.io);
        defer serial.mutex.unlock(serial.io);
        serial.parent.rawFree(memory, alignment, ret);
    }
};
