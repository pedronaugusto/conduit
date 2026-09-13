//! Terminal attributes, window size and identity of an open handle.
//!
//! Every function here takes a raw `std.Io.File.Handle` rather than a
//! `std.Io.File`, because none of these operations is one `std.Io` abstracts:
//! each is a single synchronous call on the handle that never blocks. The
//! handle may be either end of a `Pty`, or one of the process's own standard
//! streams when that is attached to a terminal.
//!
//! None of these functions take ownership of the handle.
//!
//! # The two platforms
//!
//! On POSIX a terminal is one descriptor with one set of attributes, and
//! `rawMode` sets them with `tcsetattr`.
//!
//! On Windows a console is two handles with two unrelated sets of mode flags:
//! an input handle that decides how keys arrive, and a screen-buffer handle
//! that decides how bytes written are interpreted. A full-screen program needs
//! both changed, so `rawMode` is called once per handle and works out which
//! kind it was given — a screen buffer answers `GetConsoleScreenBufferInfo`
//! and an input handle does not. `Saved` remembers which, so `restore` puts
//! back the right set.
//!
//! `winSize` has the same split: on Windows it is a property of the screen
//! buffer, so it wants the *output* handle, and an input handle is
//! `error.NotATerminal`.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;

const is_windows = builtin.os.tag == .windows;
const win32 = if (is_windows) @import("win32.zig") else struct {};
const windows = std.os.windows;

/// A terminal handle. `std.posix.fd_t` on POSIX, `HANDLE` on Windows, which is
/// what `std.Io.File.Handle` already is on both.
pub const Handle = std.Io.File.Handle;

/// The one error every call here can return for a reason the caller cannot act
/// on. `std.posix` and `std.os.windows` both alias this same set.
pub const UnexpectedError = std.Io.UnexpectedError;

/// The dimensions of a terminal.
///
/// `rows` and `cols` are character cells and are what programs read through
/// `TIOCGWINSZ` on POSIX and `GetConsoleScreenBufferInfo` on Windows. The
/// pixel fields are advisory: most terminals report zero for them, Windows
/// consoles have no notion of them at all, and a program that needs a pixel
/// size should treat zero as "unknown" rather than as a real measurement.
pub const Size = struct {
    rows: u16,
    cols: u16,
    x_pixel: u16 = 0,
    y_pixel: u16 = 0,

    fn fromWinsize(ws: posix.winsize) Size {
        return .{
            .rows = ws.row,
            .cols = ws.col,
            .x_pixel = ws.xpixel,
            .y_pixel = ws.ypixel,
        };
    }

    fn toWinsize(size: Size) posix.winsize {
        return .{
            .row = size.rows,
            .col = size.cols,
            .xpixel = size.x_pixel,
            .ypixel = size.y_pixel,
        };
    }

    /// The Windows geometry, which has no pixels and is signed. A dimension
    /// that does not fit in a `SHORT` is clamped rather than wrapped.
    pub fn toCoord(size: Size) windows.COORD {
        const max = std.math.maxInt(i16);
        return .{
            .X = @intCast(@min(size.cols, max)),
            .Y = @intCast(@min(size.rows, max)),
        };
    }
};

/// The terminal attributes captured by `rawMode`, to be handed back to
/// `restore`.
///
/// An opaque snapshot: callers should not interpret it. On POSIX it is the
/// platform `termios`; on Windows it is the console mode word plus which of
/// the two kinds of console handle it came from.
pub const Saved = if (is_windows) struct {
    mode: win32.DWORD,
    kind: Kind,

    /// Which set of mode flags `mode` holds. The two sets share bit values and
    /// mean different things, so putting an input mode back on a screen buffer
    /// would be silent nonsense.
    pub const Kind = enum { input, screen_buffer };
} else struct {
    termios: posix.termios,
};

pub const RawModeError = error{
    /// The handle is not a terminal.
    NotATerminal,
    /// POSIX only: this process is in an orphaned background process group and
    /// may not change the attributes of its controlling terminal.
    ProcessOrphaned,
} || UnexpectedError;

/// Puts the terminal into raw mode and returns the attributes it had before,
/// which `restore` puts back.
///
/// Raw mode means: no line buffering, no echo, no signal or control-character
/// processing on input, no post-processing on output, and a read that returns
/// as soon as one byte is available. It is what a full-screen program wants
/// from the terminal it draws on, and — this is the part that matters to
/// `Proxy` — it is what makes Ctrl-C arrive as the byte `0x03` instead of
/// becoming a signal for the program that called this.
///
/// On Windows the two halves of a console are separate handles, so this is
/// called once for each and works out which it was given:
///
/// * an input handle loses `ENABLE_LINE_INPUT`, `ENABLE_ECHO_INPUT` and
///   `ENABLE_PROCESSED_INPUT` and gains `ENABLE_VIRTUAL_TERMINAL_INPUT`, so
///   keys arrive as the escape sequences a terminal program expects;
/// * a screen buffer gains `ENABLE_VIRTUAL_TERMINAL_PROCESSING` and
///   `DISABLE_NEWLINE_AUTO_RETURN`, so what a child writes through a
///   pseudoconsole is rendered rather than printed.
///
/// The change applies to the terminal, not to the handle, so it outlives the
/// process unless `restore` is called. Callers should pair the two with
/// `defer`.
pub fn rawMode(handle: Handle) RawModeError!Saved {
    if (is_windows) return rawModeWindows(handle);

    const saved = posix.tcgetattr(handle) catch |err| return termiosError(err);

    var raw = saved;
    raw.iflag.IGNBRK = false;
    raw.iflag.BRKINT = false;
    raw.iflag.PARMRK = false;
    raw.iflag.ISTRIP = false;
    raw.iflag.INLCR = false;
    raw.iflag.IGNCR = false;
    raw.iflag.ICRNL = false;
    raw.iflag.IXON = false;
    raw.oflag.OPOST = false;
    raw.lflag.ECHO = false;
    raw.lflag.ECHONL = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cflag.PARENB = false;
    raw.cflag.CSIZE = .CS8;
    // A read of the terminal returns as soon as one byte is there, and never
    // waits on a timer.
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;

    posix.tcsetattr(handle, .FLUSH, raw) catch |err| return termiosError(err);
    return .{ .termios = saved };
}

pub const RestoreError = RawModeError;

/// Puts back the attributes `rawMode` captured.
///
/// On POSIX pending input is discarded, so a key pressed while the terminal
/// was raw is not delivered to the program that follows. Windows has no
/// equivalent flush, and the mode change takes effect on the next read.
pub fn restore(handle: Handle, saved: Saved) RestoreError!void {
    if (is_windows) {
        if (win32.SetConsoleMode(handle, saved.mode) == .FALSE) return consoleError(RestoreError);
        return;
    }
    posix.tcsetattr(handle, .FLUSH, saved.termios) catch |err| return termiosError(err);
}

pub const WinSizeError = error{
    /// The handle is not a terminal. On Windows this is also what an input
    /// handle gets: the geometry belongs to the screen buffer.
    NotATerminal,
} || UnexpectedError;

/// Reads the terminal's window size.
///
/// On Windows this is the size of the visible window rather than of the scroll
/// buffer behind it, because that rectangle is what a full-screen program may
/// draw in, and that is what the POSIX number means.
pub fn winSize(handle: Handle) WinSizeError!Size {
    if (is_windows) {
        var info: win32.CONSOLE_SCREEN_BUFFER_INFO = undefined;
        if (win32.GetConsoleScreenBufferInfo(handle, &info) == .FALSE) {
            return consoleError(WinSizeError);
        }
        return .{
            .rows = @intCast(@max(0, info.srWindow.Bottom - info.srWindow.Top + 1)),
            .cols = @intCast(@max(0, info.srWindow.Right - info.srWindow.Left + 1)),
        };
    }
    var ws: posix.winsize = undefined;
    switch (c.errno(c.ioctl(handle, T.GWINSZ, @intFromPtr(&ws)))) {
        .SUCCESS => return .fromWinsize(ws),
        .NOTTY => return error.NotATerminal,
        .BADF => unreachable, // Invalid descriptor.
        .FAULT => unreachable, // `ws` is on this stack.
        else => |err| return posix.unexpectedErrno(err),
    }
}

pub const SetWinSizeError = WinSizeError;

/// Sets the terminal's window size. POSIX only.
///
/// This may be issued on either end of a pseudo-terminal and is seen by both.
/// The kernel sends `SIGWINCH` to the terminal's foreground process group when
/// the size changes, which is how a program running on the far end learns to
/// redraw; that signal only reaches a child that has the terminal as its
/// controlling terminal (see `Child.SpawnOptions.detach`).
///
/// Referring to this declaration on Windows is a compile error. A
/// pseudoconsole is resized with `Pty.resize`, which is the portable call; a
/// real console's window belongs to the terminal hosting it, not to the
/// program running inside.
pub const setWinSize = if (is_windows)
    @compileError("setWinSize is POSIX-only: resize a pseudoconsole with Pty.resize")
else
    setWinSizePosix;

fn setWinSizePosix(handle: Handle, size: Size) SetWinSizeError!void {
    const ws = size.toWinsize();
    switch (c.errno(c.ioctl(handle, T.SWINSZ, @intFromPtr(&ws)))) {
        .SUCCESS => return,
        .NOTTY => return error.NotATerminal,
        .BADF => unreachable, // Invalid descriptor.
        .FAULT => unreachable, // `ws` is on this stack.
        else => |err| return posix.unexpectedErrno(err),
    }
}

/// Whether the handle refers to a terminal.
///
/// This asks about the handle only. A handle can be a terminal without being
/// the process's controlling terminal, which is exactly the situation of a
/// child spawned on a pseudo-terminal without `detach`.
///
/// On Windows "is a terminal" means "is a console handle", of either kind: a
/// console mode can be read from it.
pub fn isTty(handle: Handle) bool {
    if (is_windows) {
        var mode: win32.DWORD = undefined;
        return win32.GetConsoleMode(handle, &mode) != .FALSE;
    }
    return c.isatty(handle) != 0;
}

pub const TtyNameError = error{
    /// The handle is not a terminal.
    NotATerminal,
    /// `buffer` is too short for the name and its terminating byte.
    NameTooLong,
} || UnexpectedError;

/// Writes the pathname of the terminal into `buffer` and returns the part of
/// it that was used. POSIX only.
///
/// The result is a `/dev` path such as `/dev/pts/3` or `/dev/ttys004`. A
/// buffer of `std.fs.max_path_bytes` is always enough.
///
/// Referring to this declaration on Windows is a compile error: a console is
/// an object, not an entry in a namespace, and has no pathname to report.
pub const ttyName = if (is_windows)
    @compileError("ttyName is POSIX-only: a Windows console has no pathname")
else
    ttyNamePosix;

fn ttyNamePosix(handle: Handle, buffer: []u8) TtyNameError![]const u8 {
    if (buffer.len == 0) return error.NameTooLong;
    const rc = ttyname_r(handle, buffer.ptr, buffer.len);
    if (rc == 0) return std.mem.sliceTo(buffer, 0);
    // POSIX has this one return the error number rather than set `errno`; a
    // libc that returns -1 instead is covered by reading `errno` for the
    // negative case.
    const err: posix.E = if (rc < 0)
        c.errno(@as(c_int, -1))
    else
        @enumFromInt(@as(u16, @truncate(@as(u32, @intCast(rc)))));
    return switch (err) {
        .NOTTY, .BADF, .INVAL => error.NotATerminal,
        .RANGE => error.NameTooLong,
        else => posix.unexpectedErrno(err),
    };
}

pub const ForegroundGroupError = error{
    /// The handle is not a terminal.
    NotATerminal,
    /// The terminal has no foreground process group: nothing has claimed it as
    /// a controlling terminal, or the session that had it is gone.
    NoForegroundGroup,
} || UnexpectedError;

/// The process group the terminal will send its generated signals to. POSIX
/// only.
///
/// This is the question `isTty` cannot answer. A descriptor can be a terminal
/// without being anybody's *controlling* terminal, and that is exactly the
/// state of a pair whose child was spawned without `Child.SpawnOptions.detach`:
/// the child sees a terminal, can read the window size, and will never receive
/// the `SIGINT` a Ctrl-C on that terminal generates, because there is no
/// foreground group for the line discipline to send it to. Asking the master
/// end of a pair is how a program tells the two apart -- and, for a child that
/// did claim the terminal, it is how a program learns which group is currently
/// in the foreground, which is not always the child it started: a shell moves
/// that group around as it runs jobs.
///
/// Referring to this declaration on Windows is a compile error: a console has
/// no foreground process group, and the nearest thing -- which process gets a
/// Ctrl-C -- is decided per process group by `CREATE_NEW_PROCESS_GROUP` rather
/// than held by the console.
pub const foregroundGroup = if (is_windows)
    @compileError("foregroundGroup is POSIX-only: a console has no foreground process group")
else
    foregroundGroupPosix;

fn foregroundGroupPosix(handle: Handle) ForegroundGroupError!posix.pid_t {
    const group = tcgetpgrp(handle);
    if (group < 0) return switch (c.errno(@as(c_int, -1))) {
        .NOTTY => error.NoForegroundGroup,
        .BADF, .INVAL => error.NotATerminal,
        else => |err| posix.unexpectedErrno(err),
    };

    // A terminal nobody has claimed does not report that as a failure, and the
    // two systems do not report the same thing: Linux answers zero, Darwin a
    // sentinel above the range a process can be given. Rather than know that
    // number, the answer is tested for what the caller actually wants to know
    // -- whether a signal sent here would reach anything. A group that exists
    // but may not be signalled by this process answers `EPERM`, which is still
    // an existing group.
    if (group <= 0) return error.NoForegroundGroup;
    if (c.kill(-group, @enumFromInt(0)) != 0 and c.errno(@as(c_int, -1)) == .SRCH) {
        return error.NoForegroundGroup;
    }
    return group;
}

//======================================================================
// Windows.
//======================================================================

fn rawModeWindows(handle: Handle) RawModeError!Saved {
    var mode: win32.DWORD = undefined;
    if (win32.GetConsoleMode(handle, &mode) == .FALSE) return consoleError(RawModeError);

    // Which half of the console this is. Only a screen buffer answers this
    // call, and the two sets of mode flags share bit values, so guessing would
    // mean silently writing an input mode onto an output handle.
    var info: win32.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    const is_screen_buffer = win32.GetConsoleScreenBufferInfo(handle, &info) != .FALSE;

    const raw: win32.DWORD = if (is_screen_buffer)
        // Virtual terminal processing needs processed output to be on; it is
        // the processor. `DISABLE_NEWLINE_AUTO_RETURN` stops the console from
        // adding a carriage return to a line feed as well, which would undo
        // the positioning a pseudoconsole child already wrote correctly.
        mode | win32.ENABLE_PROCESSED_OUTPUT |
            win32.ENABLE_VIRTUAL_TERMINAL_PROCESSING |
            win32.DISABLE_NEWLINE_AUTO_RETURN
    else
        // Without virtual terminal input, keys arrive as console input records
        // that a byte stream cannot carry. With it they arrive as the escape
        // sequences a terminal program already knows how to read -- and
        // Ctrl-C, which `ENABLE_PROCESSED_INPUT` would have turned into a
        // control event for this process, arrives as the byte 0x03.
        (mode & ~(win32.ENABLE_LINE_INPUT |
            win32.ENABLE_ECHO_INPUT |
            win32.ENABLE_PROCESSED_INPUT)) | win32.ENABLE_VIRTUAL_TERMINAL_INPUT;

    if (win32.SetConsoleMode(handle, raw) == .FALSE) return consoleError(RawModeError);
    return .{
        .mode = mode,
        .kind = if (is_screen_buffer) .screen_buffer else .input,
    };
}

/// `GetLastError` as one of the console error sets above. A handle that is not
/// a console is the one case worth naming; every set here has it.
fn consoleError(comptime Set: type) Set {
    return switch (windows.GetLastError()) {
        .INVALID_HANDLE, .INVALID_FUNCTION, .INVALID_PARAMETER => error.NotATerminal,
        else => |err| windows.unexpectedError(err),
    };
}

//======================================================================
// POSIX.
//======================================================================

/// Either of the standard library's two termios error sets, narrowed to the
/// one this package publishes. Both carry exactly these cases.
const TermiosError = posix.TermiosGetError || posix.TermiosSetError;

fn termiosError(err: TermiosError) RawModeError {
    return switch (err) {
        error.NotATerminal => error.NotATerminal,
        error.ProcessOrphaned => error.ProcessOrphaned,
        error.Unexpected => error.Unexpected,
    };
}

/// Not declared in `std.c`. Returns the error number directly on the systems
/// that follow POSIX here, and -1 with `errno` set on the ones that do not.
extern "c" fn ttyname_r(fd: posix.fd_t, buf: [*]u8, buflen: usize) c_int;

/// `TIOCGPGRP` by its POSIX name. Not declared in `std.c` either, and the
/// function is the portable spelling: the ioctl request number differs between
/// Linux and Darwin the way the window-size ones below do.
extern "c" fn tcgetpgrp(fd: posix.fd_t) posix.pid_t;

/// The ioctl request numbers this package issues.
///
/// `std.c.T` carries them for most systems, but the Darwin table in the
/// standard library stops at `TIOCGWINSZ`, so the Darwin branch spells all
/// three out from `<sys/ttycom.h>`. They are `c_int` because that is what
/// `ioctl` takes, and the constants have the high bit set.
pub const T = switch (builtin.os.tag) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => struct {
        pub const GWINSZ: c_int = @bitCast(@as(u32, 0x40087468));
        pub const SWINSZ: c_int = @bitCast(@as(u32, 0x80087467));
        pub const SCTTY: c_int = @bitCast(@as(u32, 0x20007461));
    },
    .windows => struct {},
    else => struct {
        pub const GWINSZ: c_int = @bitCast(@as(u32, c.T.IOCGWINSZ));
        pub const SWINSZ: c_int = @bitCast(@as(u32, c.T.IOCSWINSZ));
        pub const SCTTY: c_int = @bitCast(@as(u32, c.T.IOCSCTTY));
    },
};
