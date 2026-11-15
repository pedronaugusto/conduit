//! Waits that spin, handing the processor back between tries: for the locks
//! a reap or a fork has no `std.Io` to wait on, and for the few sections
//! that are a handful of system calls long.
const std = @import("std");
const aegis = @import("aegis");

/// Gives the rest of this time slice to another thread. Every caller tries
/// its condition again after this returns, so a system that cannot yield
/// only brings the next try sooner: the wait costs processor time, not
/// correctness, and the processor is told it is a spin instead.
pub fn yield() void {
    std.Thread.yield() catch |err| switch (err) {
        error.SystemCannotYield => std.atomic.spinLoopHint(),
    };
}

/// A mutex of one aegis cell that spins, yielding between tries: for a lock
/// held across system calls (a descendant walk and signal delivery, a look
/// through `/proc`), past the bounded sections an aegis spin guard allows,
/// and taken where there is no `std.Io` to wait with (a reap, a fork). It is
/// async-signal-safe: taking and giving it back are a compare-and-swap and a
/// store. No data is coupled to it; what it protects its holder says.
pub const Lock = struct {
    /// Private: whether the lock is held.
    word: aegis.Atomic(Hold) = .init(.free),

    const Hold = enum(u8) { free, held };

    /// Takes the lock, yielding between tries.
    pub fn lock(spin_lock: *Lock) void {
        while (!spin_lock.tryLock()) yield();
    }

    /// Takes the lock if it is free now; never waits.
    pub fn tryLock(spin_lock: *Lock) bool {
        return spin_lock.word.cmpxchgStrong(.free, .held, .acquire, .monotonic) == null;
    }

    /// Gives back a lock this thread holds.
    pub fn unlock(spin_lock: *Lock) void {
        aegis.assert.invariant(spin_lock.word.load(.monotonic) == .held, "spin_lock.word.load(.monotonic) == .held");
        spin_lock.word.store(.free, .release);
    }
};

test "a lock spins until the holder releases it" {
    var mutex: Lock = .{};
    mutex.lock();
    try std.testing.expect(!mutex.tryLock());
    mutex.unlock();
    mutex.lock();
    mutex.unlock();
    try std.testing.expect(mutex.tryLock());
    mutex.unlock();
}
