//! The console calls the terminal primitives make on Windows, which
//! `std.os.windows` carries the types for and not the entry points.
//!
//! Every one is an `extern` declaration against the system import library,
//! and nothing here is reached off Windows. They live with the primitives,
//! in the module that may be imported without the rest of conduit, and
//! conduit's own Windows code takes them from here.

const std = @import("std");
const windows = std.os.windows;

pub const DWORD = windows.DWORD;
pub const HANDLE = windows.HANDLE;
pub const BOOL = windows.BOOL;
pub const SHORT = windows.SHORT;
pub const WORD = windows.WORD;
pub const COORD = windows.COORD;

/// `GetLastError` as `error.Unexpected`, keeping the number.
///
/// Not `std.os.windows.unexpectedError`, which in a Debug build prints the
/// code by its tag name — and `Win32Error` is a non-exhaustive enum, so a code
/// nobody has named ends the process rather than returning the error the
/// caller was about to handle. A library may not do that to a program over a
/// failure it can describe. The number says as much as the name and cannot
/// fail to be printed.
pub fn unexpected(err: windows.Win32Error) std.Io.UnexpectedError {
    @branchHint(.cold);
    if (std.options.unexpected_error_tracing) {
        std.debug.print("conduit: error.Unexpected: GetLastError({d})\n", .{@intFromEnum(err)});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    }
    return error.Unexpected;
}

pub const ENABLE_PROCESSED_INPUT: DWORD = 0x0001;
pub const ENABLE_LINE_INPUT: DWORD = 0x0002;
pub const ENABLE_ECHO_INPUT: DWORD = 0x0004;
pub const ENABLE_WINDOW_INPUT: DWORD = 0x0008;
pub const ENABLE_MOUSE_INPUT: DWORD = 0x0010;
pub const ENABLE_INSERT_MODE: DWORD = 0x0020;
pub const ENABLE_QUICK_EDIT_MODE: DWORD = 0x0040;
pub const ENABLE_EXTENDED_FLAGS: DWORD = 0x0080;
pub const ENABLE_VIRTUAL_TERMINAL_INPUT: DWORD = 0x0200;

pub const ENABLE_PROCESSED_OUTPUT: DWORD = 0x0001;
pub const ENABLE_WRAP_AT_EOL_OUTPUT: DWORD = 0x0002;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING: DWORD = 0x0004;
pub const DISABLE_NEWLINE_AUTO_RETURN: DWORD = 0x0008;

pub extern "kernel32" fn GetConsoleMode(
    hConsoleHandle: HANDLE,
    lpMode: *DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetConsoleMode(
    hConsoleHandle: HANDLE,
    dwMode: DWORD,
) callconv(.winapi) BOOL;

pub const SMALL_RECT = extern struct {
    Left: SHORT,
    Top: SHORT,
    Right: SHORT,
    Bottom: SHORT,
};

pub const CONSOLE_SCREEN_BUFFER_INFO = extern struct {
    dwSize: COORD,
    dwCursorPosition: COORD,
    wAttributes: WORD,
    srWindow: SMALL_RECT,
    dwMaximumWindowSize: COORD,
};

pub extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: HANDLE,
    lpConsoleScreenBufferInfo: *CONSOLE_SCREEN_BUFFER_INFO,
) callconv(.winapi) BOOL;
