//! Waits that spin, handing the processor back between tries: for the locks
//! a reap or a fork has no `std.Io` to wait on, and for the few sections
//! that are a handful of system calls long.
const std = @import("std");

/// Gives the rest of this time slice to another thread. Every caller tries
/// its condition again after this returns, so a system that cannot yield
/// only brings the next try sooner: the wait costs processor time, not
/// correctness.
pub fn yield() void {
    std.Thread.yield() catch |err| switch (err) {
        error.SystemCannotYield => {},
    };
}

/// Takes `mutex`, yielding between tries.
pub fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) yield();
}

test "a lock spins until the holder releases it" {
    var mutex: std.atomic.Mutex = .unlocked;
    lock(&mutex);
    try std.testing.expect(!mutex.tryLock());
    mutex.unlock();
    lock(&mutex);
    mutex.unlock();
}
