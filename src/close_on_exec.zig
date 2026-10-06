//! Pipes that no unrelated child is handed, and the lock that keeps this
//! package's spawns out of the moment a pipe has no flag yet.
//!
//! They are in `conduit.tty`, the module that links no C library on Linux,
//! because a program that draws its own screen wants a pipe of its own -- a
//! resize wake, say -- as much as conduit does, and the lock only works if
//! that pipe and conduit's spawns take the same one.
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const system = posix.system;

const is_windows = builtin.os.tag == .windows;

/// Whether a descriptor on this system can be opened close-on-exec in one
/// call, or needs a second one.
///
/// `pipe2` and `O_CLOEXEC` carry the flag where they exist. Darwin has no
/// `pipe2`, so a pipe there is `pipe` and then two `fcntl`s, and between them
/// the two ends have no flag at all.
pub const opening_is_two_calls = !is_windows and @TypeOf(system.pipe2) == void;

/// Keeps this package's own forks out of the gap between such an open and the
/// call that marks it.
///
/// A child started in that moment inherits a descriptor that has nothing to do
/// with it and keeps the far end of it waiting. There is no flag to close the
/// gap on Darwin, so what closes it is that the two never happen at once:
/// `openingDescriptors` is held while a pipe is made, `startingAChild` while a
/// child is started, and they are the same lock.
///
/// **It reaches this package's spawns and no others.** A `fork` somewhere else
/// in the program is still free to land in the gap, and nothing a library can
/// hold would stop it. The other windows are smaller and are written down
/// where they are: `Pty.open` marks the master in a second call on a system
/// whose `posix_openpt` refuses the flag, and a descriptor the caller opened
/// without the flag is the caller's to close with `SpawnOptions.fd_policy`.
///
/// It is one lock per program only while the program builds one conduit: a
/// program and a package it depends on that pin two conduits have two.
///
/// Where an open carries its own flag this is not compiled at all.
pub const ForkGap = struct {
    var held: std.atomic.Value(bool) = .init(false);

    /// Taken while a descriptor is being opened and marked.
    pub fn openingDescriptors() void {
        if (opening_is_two_calls) take();
    }

    /// Taken while a child is being started, which is the moment a descriptor
    /// with no flag on it would be copied into.
    pub fn startingAChild() void {
        if (opening_is_two_calls) take();
    }

    pub fn release() void {
        if (!opening_is_two_calls) return;
        std.debug.assert(held.load(.monotonic));
        held.store(false, .release);
    }

    fn take() void {
        while (held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            // Both sections are a few system calls long, so the wait is short
            // and the scheduler is the right place to spend it. A system that
            // cannot yield only brings the next try sooner.
            std.Thread.yield() catch |err| switch (err) {
                error.SystemCannotYield => {},
            };
        }
    }
};

pub const PipeOptions = struct {
    /// Both ends `O_NONBLOCK`: for a pipe a signal handler writes into, or
    /// one drained without waiting.
    nonblocking: bool = false,
};

pub const PipeError = error{
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
} || std.Io.UnexpectedError;

/// A pipe, both ends close-on-exec: `pipe2` where the system has it, and
/// `pipe` with the flag set in the `ForkGap` where it has not. POSIX only.
pub const pipe = if (is_windows)
    @compileError("pipe is POSIX-only")
else
    pipePosix;

fn pipePosix(options: PipeOptions) PipeError![2]posix.fd_t {
    var ends: [2]posix.fd_t = undefined;
    if (opening_is_two_calls) {
        // No `pipe2` here, so the flag is a second call and there is a gap
        // between the two. `ForkGap` is what keeps this package's own spawns
        // out of it.
        ForkGap.openingDescriptors();
        defer ForkGap.release();
        try opened(system.pipe(&ends));
        errdefer for (ends) |fd| {
            _ = system.close(fd);
        };
        for (ends) |fd| {
            try set(fd, posix.F.SETFD, posix.FD_CLOEXEC);
            if (options.nonblocking) try set(fd, posix.F.SETFL, @bitCast(posix.O{ .NONBLOCK = true }));
        }
    } else {
        try opened(system.pipe2(&ends, .{ .CLOEXEC = true, .NONBLOCK = options.nonblocking }));
    }
    return ends;
}

fn opened(rc: anytype) PipeError!void {
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        else => |err| return posix.unexpectedErrno(err),
    }
}

fn set(fd: posix.fd_t, command: i32, flags: u32) std.Io.UnexpectedError!void {
    // A fresh pipe's flags are known: nothing on either, so the one asked
    // for is all there is to set.
    switch (posix.errno(system.fcntl(fd, command, @as(usize, flags)))) {
        .SUCCESS => {},
        else => |err| return posix.unexpectedErrno(err),
    }
}
