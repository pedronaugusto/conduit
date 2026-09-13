//! Child processes and pseudo-terminals on POSIX.
//!
//! Three things the standard library has no answer for, and one it does:
//!
//! * `Pty` opens a pseudo-terminal pair and sets and reads its window size.
//! * `Child` spawns a program on that pair, in its own session, with the pair
//!   as its controlling terminal — which is what makes the child believe it is
//!   talking to a terminal, right down to Ctrl-C arriving as `SIGINT`. It also
//!   spawns on pipes, on inherited streams, or on `/dev/null`, and it kills,
//!   reaps and waits.
//! * `rawMode`, `winSize` and the rest are the terminal ioctls a full-screen
//!   program needs on its own standard input.
//! * `wait` is the standard library's: `Child.wait` hands the process id to
//!   `std.process.Child.wait`, so it is a cancelation point and uses whatever
//!   the `std.Io` implementation has for waiting on a process.
//!
//! `Reaper` puts a wait on a background task so a program can poll for a
//! child's death, and `Proxy` is the two-direction byte pump between a master
//! and a pair of files.
//!
//! # Platforms
//!
//! Linux, macOS and the BSDs. libc must be linked: the pseudo-terminal
//! interface (`posix_openpt`, `grantpt`, `unlockpt`, `ptsname_r`) is a libc
//! interface on every one of them, and Darwin has no stable system-call ABI to
//! reach past it.
//!
//! # The Windows seam
//!
//! Where a Windows implementation would attach, recorded so the shape of this
//! API can be judged against it before anyone writes one.
//!
//! Windows has no pseudo-terminal device and no `fork`. Its equivalent is
//! ConPTY: `CreatePseudoConsole` returns an `HPCON` plus the two pipe handles
//! that carry the console's input and output, `ResizePseudoConsole` changes the
//! geometry, and a child is attached to it by passing the `HPCON` in a
//! `PROC_THREAD_ATTRIBUTE_LIST` to `CreateProcessW`.
//!
//! Mapping that onto the declarations here:
//!
//! * `Pty.master` and `Pty.slave` are `std.posix.fd_t`, which on Windows is a
//!   `HANDLE`. The master would be the read end of the console's output pipe
//!   paired with the write end of its input pipe — two handles where POSIX has
//!   one — so `Pty` would grow a platform-dependent representation and
//!   `masterFile` would have to say which direction it returns. This is the
//!   one place the current API would have to change shape rather than merely
//!   gain a branch.
//! * `Pty.open`, `Pty.resize` and `Pty.size` map directly onto
//!   `CreatePseudoConsole`, `ResizePseudoConsole` and a remembered size.
//! * `Child.SpawnOptions.detach` maps onto `CREATE_NEW_PROCESS_GROUP`.
//!   ConPTY makes the console the child's console unconditionally, so the
//!   controlling-terminal half of `detach` has no Windows counterpart and the
//!   flag would mean only "own process group" there.
//! * `Child.wait` already delegates to `std.process.Child`, which is
//!   cross-platform, and `Child.kill` would become `TerminateProcess` or a
//!   `GenerateConsoleCtrlEvent` to the group.
//! * `rawMode` and `restore` map onto `GetConsoleMode` and `SetConsoleMode`
//!   with `ENABLE_VIRTUAL_TERMINAL_INPUT`; `winSize` onto
//!   `GetConsoleScreenBufferInfo`. `ttyName` has no counterpart.
//!
//! Nothing about the POSIX implementation forecloses any of that. What it does
//! do is assume one descriptor for the master, which is the seam to widen
//! first.

const builtin = @import("builtin");
const std = @import("std");

const tty = @import("tty.zig");

comptime {
    if (builtin.os.tag == .windows) @compileError(
        "zpty is POSIX-only: it opens pseudo-terminals with posix_openpt and " ++
            "starts children with fork and execve, neither of which Windows has. " ++
            "A Windows port would go behind the same API through ConPTY; see the " ++
            "\"The Windows seam\" in this file's module doc comment.",
    );
    if (!builtin.link_libc) @compileError(
        "zpty requires libc: the POSIX pseudo-terminal interface is a libc " ++
            "interface. Set `link_libc = true` on the module that imports it.",
    );
}

/// A pseudo-terminal pair.
pub const Pty = @import("Pty.zig");
/// A child process on a pseudo-terminal, on pipes, or on inherited streams.
pub const Child = @import("Child.zig");
/// A background wait, so a caller can poll for a child's death.
pub const Reaper = @import("Reaper.zig");
/// A byte pump between a pseudo-terminal master and a pair of files.
pub const Proxy = @import("Proxy.zig");

/// How a child process ended. An alias for `std.process.Child.Term`.
pub const Term = Child.Term;
/// The dimensions of a terminal.
pub const Size = tty.Size;
/// The terminal attributes `rawMode` captured, to give back to `restore`.
pub const Saved = tty.Saved;

/// Puts a terminal into raw mode and returns what to pass to `restore`.
pub const rawMode = tty.rawMode;
pub const RawModeError = tty.RawModeError;
/// Puts back the attributes `rawMode` captured.
pub const restore = tty.restore;
pub const RestoreError = tty.RestoreError;
/// Reads a terminal's window size.
pub const winSize = tty.winSize;
pub const WinSizeError = tty.WinSizeError;
/// Sets a terminal's window size.
pub const setWinSize = tty.setWinSize;
pub const SetWinSizeError = tty.SetWinSizeError;
/// Whether a descriptor is a terminal.
pub const isTty = tty.isTty;
/// The `/dev` pathname of a terminal descriptor.
pub const ttyName = tty.ttyName;
pub const TtyNameError = tty.TtyNameError;

test {
    _ = Pty;
    _ = Child;
    _ = Reaper;
    _ = Proxy;
    _ = tty;
    _ = @import("spawn_test.zig");
}
