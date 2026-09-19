//! The three one-line things the rest of this package does to a handle.
//!
//! Each of them was written out in two or three files, which is two or three
//! places for one idea to drift. They are here instead, named once.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;

const is_windows = builtin.os.tag == .windows;

/// A raw handle as a `std.Io.File`.
///
/// The file shares the handle rather than duplicating it: closing the file
/// closes the handle, and whoever owns the handle owns the file.
pub fn file(handle: std.Io.File.Handle) std.Io.File {
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

/// Marks a descriptor close-on-exec, so an unrelated child started while this
/// process holds it is not handed it. POSIX only.
///
/// Best effort: a descriptor that could not be marked is still a working
/// descriptor, and there is nothing a caller could usefully do about it.
///
/// Where the call that made the descriptor can carry the flag itself, it
/// should — `pipe2`, `O_CLOEXEC`, `F_DUPFD_CLOEXEC` — because the gap between
/// an open and a second call is a gap another thread can `fork` through. This
/// is for the descriptors whose opening call takes no such flag.
pub const setCloseOnExec = if (is_windows)
    @compileError("handles.setCloseOnExec is POSIX-only")
else
    setCloseOnExecPosix;

fn setCloseOnExecPosix(fd: posix.fd_t) void {
    _ = c.fcntl(fd, c.F.SETFD, @as(c_int, c.FD_CLOEXEC));
}

/// Whether a read error means the stream has finished rather than failed.
///
/// A pipe whose every writer is gone reports the end of the stream. A
/// pseudo-terminal master whose child is gone reports the end on Darwin and an
/// I/O error on Linux, where reading a master that has been hung up is an
/// error rather than an empty read. They are the same fact, and every reader
/// in this package -- `Child.output`, `Expect`, `Proxy`, `Pty` -- treats them
/// as one.
pub fn finished(err: anyerror) bool {
    return err == error.EndOfStream or err == error.InputOutput;
}

/// Whether a descriptor on this system can be opened close-on-exec in one
/// call, or needs a second one.
///
/// `pipe2` and `O_CLOEXEC` carry the flag where they exist. Darwin has no
/// `pipe2`, so a pipe there is `pipe` and then two `fcntl`s, and between them
/// the two ends have no flag at all.
pub const opening_is_two_calls = !is_windows and @TypeOf(c.pipe2) == void;

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
/// hold would stop it. The other two windows are smaller and are written down
/// where they are: `Pty.open` marks the master in a second call, and a
/// descriptor the caller opened without the flag is the caller's to close
/// with `SpawnOptions.fd_policy`.
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
        if (opening_is_two_calls) held.store(false, .release);
    }

    fn take() void {
        while (held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            // Both sections are a few system calls long, so the wait is short
            // and the scheduler is the right place to spend it.
            std.Thread.yield() catch {};
        }
    }
};
