//! Whether a process id names a process now, on every system this package
//! supports.
const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const Id = @import("child_types.zig").Id;

const is_windows = builtin.os.tag == .windows;
const win32 = if (is_windows) @import("win32.zig") else struct {};

/// Whether a process has the id `pid` now: `true`, `false`, or `null` where
/// the system will not say.
///
/// A process that has ended but whose id is not yet given back — a POSIX
/// zombie nobody has reaped, a Windows process whose handle someone still
/// holds — still has it, so this is `true` for it. A process this one may not
/// signal or open still exists, and is `true` too. An id that cannot name a
/// single process (zero or below on POSIX, where `kill` would address a
/// group) is `false`.
///
/// Ids are reused. `true` says that some process has the number, not that it
/// is the one written down beside it; `false` says that none has, which stays
/// true only until the next process takes it. On Linux and Darwin, write
/// `startTime` down with the id and compare it later to tell the process from
/// a successor.
pub fn processExists(pid: Id) ?bool {
    if (comptime is_windows) return existsWindows(pid);
    if (pid <= 0) return false;
    return switch (posix.errno(std.c.kill(pid, @enumFromInt(0)))) {
        .SUCCESS => true,
        // There, and someone else's.
        .PERM => true,
        .SRCH => false,
        else => null,
    };
}

fn existsWindows(pid: Id) ?bool {
    const windows = std.os.windows;
    const handle = win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, .FALSE, pid) orelse
        return switch (windows.GetLastError()) {
            // There, and not to be opened by this process.
            .ACCESS_DENIED => true,
            // No process has the id.
            .INVALID_PARAMETER => false,
            else => null,
        };
    windows.CloseHandle(handle);
    return true;
}
