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
