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
/// gap on Darwin, so what closes it is that the two never happen at once: a
/// pipe is made, and a child is started, inside `hold`, and it is one lock.
///
/// **It reaches this package's spawns and no others.** A `fork` somewhere else
/// in the program is still free to land in the gap, and nothing a library can
/// hold would stop it. The other windows are smaller and are written down
/// where they are: `Pty.open` marks the master in a second call on a system
/// whose `posix_openpt` refuses the flag, and a descriptor the caller opened
/// without the flag is the caller's to close with `SpawnOptions.fd_policy`.
/// A program that opens a descriptor of its own in two calls keeps conduit's
/// spawns out of that gap by doing it inside `hold`.
///
/// It is one lock per program only while the program builds one conduit: a
/// program and a package it depends on that pin two conduits have two.
///
/// Where an open carries its own flag, `hold` only calls the function.
pub const ForkGap = struct {
    var held: std.atomic.Value(bool) = .init(false);

    /// Calls `function` with `args` inside the lock, and leaves it however
    /// the call returns. The section is a few system calls long: the wait for
    /// it is a spin. It is not reentrant, so `function` makes no `pipe` and
    /// starts no child through conduit.
    pub fn hold(function: anytype, args: anytype) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
        if (!opening_is_two_calls) return @call(.auto, function, args);
        take();
        // A fork child inherits the lock as held and never returns here: it
        // runs a handful of system calls and execs.
        defer held.store(false, .release);
        return @call(.auto, function, args);
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
/// `pipe` with the flag set inside `ForkGap.hold` where it has not. POSIX only.
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
        try ForkGap.hold(pipeMarked, .{ &ends, options });
    } else {
        try opened(system.pipe2(&ends, .{ .CLOEXEC = true, .NONBLOCK = options.nonblocking }));
    }
    return ends;
}

fn pipeMarked(ends: *[2]posix.fd_t, options: PipeOptions) PipeError!void {
    try opened(system.pipe(ends));
    errdefer for (ends) |fd| {
        _ = system.close(fd);
    };
    for (ends) |fd| {
        try set(fd, posix.F.SETFD, posix.FD_CLOEXEC);
        if (options.nonblocking) try set(fd, posix.F.SETFL, @bitCast(posix.O{ .NONBLOCK = true }));
    }
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
