//! Child processes and pseudo-terminals, on POSIX and on Windows.
//!
//! Four things the standard library has no answer for, and one it does:
//!
//! * `Pty` opens a pseudo-terminal pair and sets and reads its window size.
//! * `Child` spawns a program on that pair — which is what makes the child
//!   believe it is talking to a terminal, right down to Ctrl-C arriving as
//!   `SIGINT` — and also on pipes, on inherited streams, or on the null
//!   device. It kills, reaps, waits, and collects what the child wrote.
//! * `rawMode`, `winSize` and the rest are the terminal calls a full-screen
//!   program needs on its own standard streams.
//! * `spawnShell` is the user's shell on a pair, with the defaults every
//!   terminal program would otherwise write out itself.
//! * `wait` is the standard library's: `Child.wait` hands the process on to
//!   `std.process.Child.wait`, so it is a cancelation point and uses whatever
//!   the `std.Io` implementation has for waiting on a process.
//!
//! `Reaper` puts a wait on a background task so a program can poll for a
//! child's death, `Proxy` is the two-direction byte pump between a master and
//! a pair of files — and the thing that keeps the child's terminal the same
//! size as the program's own — and `environ` builds a child's environment out
//! of this process's own.
//!
//! # Platforms
//!
//! Linux, macOS, the BSDs and Windows.
//!
//! On POSIX, libc must be linked: the pseudo-terminal interface
//! (`posix_openpt`, `grantpt`, `unlockpt`, `ptsname_r`) is a libc interface on
//! every one of them, and Darwin has no stable system-call ABI to reach past
//! it. On Windows nothing of the sort is needed and libc is not required: the
//! calls are `kernel32` imports, declared in `src/win32.zig`.
//!
//! Windows 10 version 1809 is the floor. `CreatePseudoConsole` arrived there,
//! and it is imported statically rather than looked up, so a binary that links
//! this package will not start on anything older.
//!
//! # What is the same, and what is not
//!
//! The same API covers both systems, and it is honest about the two places the
//! systems themselves disagree:
//!
//! * **The master is two handles.** POSIX gives one bidirectional descriptor;
//!   ConPTY gives two pipes. So `Pty` has `read` and `write` on both — the
//!   same descriptor twice on POSIX — and no caller has to know which it holds.
//! * **`Pty.closeSlave` is wanted at different moments.** On POSIX, right
//!   after `Child.spawn`, or a read of the master never finishes. On Windows
//!   it is `ClosePseudoConsole`, which ends the child, so it is called when the
//!   program is done. `spawnShell` absorbs that difference; `Pty.closeSlave`
//!   documents it.
//!
//! Three declarations exist only on POSIX, because what they name exists only
//! there: `setWinSize` (a console's window belongs to its host), `ttyName` (a
//! console has no pathname) and `Pty.slaveFile` (a pseudoconsole is not a
//! stream). Referring to one on Windows is a compile error that says so.
//!
//! `Child.SpawnOptions.detach` and `Child.Signal` are the two places where the
//! same call means less on Windows than on POSIX, and both say exactly how
//! much less.

const builtin = @import("builtin");
const std = @import("std");

const tty = @import("tty.zig");
const environ_impl = @import("environ.zig");
const shell = @import("shell.zig");

const is_windows = builtin.os.tag == .windows;

comptime {
    switch (builtin.os.tag) {
        .windows,
        .linux,
        .driverkit,
        .ios,
        .maccatalyst,
        .macos,
        .tvos,
        .visionos,
        .watchos,
        .dragonfly,
        .freebsd,
        .netbsd,
        .openbsd,
        .illumos,
        => {},
        else => @compileError(
            "conduit supports Linux, macOS, the BSDs and Windows. Every other " ++
                "system either has no pseudo-terminal or no way to start a " ++
                "process, and this package would rather not compile than " ++
                "pretend otherwise.",
        ),
    }
    if (!is_windows and !builtin.link_libc) @compileError(
        "conduit requires libc on POSIX: the pseudo-terminal interface is a libc " ++
            "interface there. Set `link_libc = true` on the module that " ++
            "imports it. Windows needs no libc.",
    );
}

/// A pseudo-terminal pair.
pub const Pty = @import("Pty.zig");
/// A child process on a pseudo-terminal, on pipes, or on inherited streams.
pub const Child = @import("Child.zig");
/// A background wait, so a caller can poll for a child's death.
pub const Reaper = @import("Reaper.zig");
/// A byte pump, and a window-size forwarder, between a pseudo-terminal master
/// and a pair of files.
pub const Proxy = @import("Proxy.zig");

/// How a child process ended. An alias for `std.process.Child.Term`.
pub const Term = Child.Term;
/// The dimensions of a terminal.
pub const Size = tty.Size;
/// The terminal attributes `rawMode` captured, to give back to `restore`.
pub const Saved = tty.Saved;
/// A stream handle: `std.posix.fd_t` on POSIX, `HANDLE` on Windows.
pub const Handle = tty.Handle;

/// The user's shell on a new pseudo-terminal, with a terminal program's
/// defaults.
pub const spawnShell = shell.spawnShell;
/// What `spawnShell` returns: the pair, and the shell running on it.
pub const Shell = shell.Shell;
/// The options `spawnShell` takes.
pub const ShellOptions = shell.Options;
pub const SpawnShellError = shell.SpawnShellError;

/// Building a child's environment out of this process's own.
///
/// `environ.inherit(allocator, &.{.{ .name = "TERM", .value = "xterm-256color" }})`
/// is the whole of it: a `std.process.Environ.Map` the caller owns, ready for
/// `Child.SpawnOptions.environ`, with the named variables set or — for a
/// `null` value — removed.
pub const environ = environ_impl;

/// Puts a terminal into raw mode and returns what to pass to `restore`.
pub const rawMode = tty.rawMode;
pub const RawModeError = tty.RawModeError;
/// Puts back the attributes `rawMode` captured.
pub const restore = tty.restore;
pub const RestoreError = tty.RestoreError;
/// Reads a terminal's window size. On Windows, of a console screen buffer.
pub const winSize = tty.winSize;
pub const WinSizeError = tty.WinSizeError;
/// Sets a terminal's window size. POSIX only; on Windows resize the pair with
/// `Pty.resize` instead.
pub const setWinSize = if (is_windows)
    @compileError("setWinSize is POSIX-only: resize a pseudoconsole with Pty.resize")
else
    tty.setWinSize;
pub const SetWinSizeError = tty.SetWinSizeError;
/// Whether a handle is a terminal.
pub const isTty = tty.isTty;
/// The process group a terminal sends its generated signals to. POSIX only,
/// and the way to tell a child that merely *sees* a terminal from one that is
/// running on it.
pub const foregroundGroup = if (is_windows)
    @compileError("foregroundGroup is POSIX-only: a console has no foreground process group")
else
    tty.foregroundGroup;
pub const ForegroundGroupError = tty.ForegroundGroupError;
/// The `/dev` pathname of a terminal descriptor. POSIX only.
pub const ttyName = if (is_windows)
    @compileError("ttyName is POSIX-only: a Windows console has no pathname")
else
    tty.ttyName;
pub const TtyNameError = tty.TtyNameError;

test {
    _ = Pty;
    _ = Child;
    _ = Reaper;
    _ = Proxy;
    _ = tty;
    _ = environ_impl;
    _ = shell;
    _ = @import("spawn_test.zig");
}
