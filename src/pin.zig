//! Where a value was when a task or a process-wide registration began to
//! hold a pointer to it, checked on each later call in safe builds: a value
//! moved after `start` is caught at its next call, not by whatever the task
//! later does with the stale pointer.

const builtin = @import("builtin");
const std = @import("std");

/// Safety follows this module's own optimization mode, not the standard
/// library's.
const safe = builtin.mode.runtimeSafety();

pub const Pin = struct {
    at: if (safe) ?usize else void = if (safe) null else {},

    /// Records where `owner` is now.
    pub fn set(pin: *Pin, owner: *const anyopaque) void {
        if (safe) pin.at = @intFromPtr(owner); // safe: the address is compared, never turned back into a pointer.
    }

    /// Asserts that `owner` is where `set` found it, if it was set.
    pub fn check(pin: *const Pin, owner: *const anyopaque) void {
        if (safe) if (pin.at) |at| std.debug.assert(at == @intFromPtr(owner)); // safe: compared only.
    }
};

test "a pin holds an address only once set, and accepts it after" {
    var pin: Pin = .{};
    var here: u8 = 0;
    var there: u8 = 0;
    pin.check(&there);
    pin.set(&here);
    pin.check(&here);
}
