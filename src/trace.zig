//! A diagnostic trace, silent unless the environment asks for it.
//!
//! `CONDUIT_TRACE` set to anything turns on a handful of lines about what this
//! package asked the operating system for: which spawn path ran, the flag word
//! and structure size `CreateProcessW` was given, the pseudoconsole handle at
//! the two places it appears, and how long a close took to come back.
//!
//! They exist because some of what this package does can only be watched on a
//! machine nobody can attach a debugger to. A continuous-integration log is
//! the whole of the instrument there, and a run that reports "it did not work"
//! without saying what was passed is a run that has to be repeated.
//!
//! Off costs one environment lookup, once. Nothing here is part of the API and
//! nothing a program does depends on it.

const builtin = @import("builtin");
const std = @import("std");

const is_windows = builtin.os.tag == .windows;

/// `0` not looked up yet, `1` off, `2` on.
var state: std.atomic.Value(u8) = .init(0);

/// Whether `CONDUIT_TRACE` is set. Looked up once; a race on the first call
/// reaches the same answer twice.
pub fn enabled() bool {
    switch (state.load(.acquire)) {
        1 => return false,
        2 => return true,
        else => {},
    }
    const on = look();
    state.store(if (on) 2 else 1, .release);
    return on;
}

/// One line, when the trace is on. The prefix says where it came from, because
/// it lands in a log beside everything else the run printed.
pub fn print(comptime format: []const u8, args: anytype) void {
    if (!enabled()) return;
    std.debug.print("conduit: " ++ format ++ "\n", args);
}

fn look() bool {
    if (is_windows) {
        const name = std.unicode.wtf8ToWtf16LeStringLiteral("CONDUIT_TRACE");
        return (std.process.Environ{ .block = .global }).getWindows(name) != null;
    }
    // libc is linked on every POSIX target this package supports, which is
    // what makes this one call rather than a walk of `environ`.
    return std.c.getenv("CONDUIT_TRACE") != null;
}
