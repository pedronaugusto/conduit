//! The console calls the terminal primitives make on Windows, which
//! `std.os.windows` carries the types for and not the entry points.
//!
//! Every one is an `extern` declaration against the system import library,
//! and nothing here is reached off Windows. They live with the primitives,
//! in the module that may be imported without the rest of conduit, and
//! conduit's own Windows code takes them from here.
//!
//! Windows' names, in Zig's casing: `ENABLE_LINE_INPUT` is
//! `enable_line_input` and `CONSOLE_SCREEN_BUFFER_INFO` is
//! `ConsoleScreenBufferInfo`. Functions keep their symbol names, and the
//! types `std.os.windows` declares are taken from there.

const std = @import("std");
const windows = std.os.windows;
const log = std.log.scoped(.conduit);

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
        log.warn("error.Unexpected: GetLastError({d})", .{@backingInt(err)});
        std.debug.dumpCurrentStackTrace(.{ .first_address = @returnAddress() });
    }
    return error.Unexpected;
}

pub const enable_processed_input: windows.DWORD = 0x0001;
pub const enable_line_input: windows.DWORD = 0x0002;
pub const enable_echo_input: windows.DWORD = 0x0004;
pub const enable_window_input: windows.DWORD = 0x0008;
pub const enable_mouse_input: windows.DWORD = 0x0010;
pub const enable_insert_mode: windows.DWORD = 0x0020;
pub const enable_quick_edit_mode: windows.DWORD = 0x0040;
pub const enable_extended_flags: windows.DWORD = 0x0080;
pub const enable_virtual_terminal_input: windows.DWORD = 0x0200;

pub const enable_processed_output: windows.DWORD = 0x0001;
pub const enable_wrap_at_eol_output: windows.DWORD = 0x0002;
pub const enable_virtual_terminal_processing: windows.DWORD = 0x0004;
pub const disable_newline_auto_return: windows.DWORD = 0x0008;

pub const generic_read: windows.DWORD = 0x80000000;
pub const generic_write: windows.DWORD = 0x40000000;
pub const file_share_read: windows.DWORD = 0x00000001;
pub const file_share_write: windows.DWORD = 0x00000002;
pub const open_existing: windows.DWORD = 3;

/// Opens a file or a device by name: here, `CONIN$` and `CONOUT$`, the
/// console's input buffer and screen buffer, whatever the standard handles
/// were redirected to.
pub extern "kernel32" fn CreateFileW(
    lpFileName: windows.LPCWSTR,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

/// Writes to a handle with no `std.Io` in between, which is what a panic
/// handler putting a console back has to hand.
pub extern "kernel32" fn WriteFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: windows.DWORD,
    lpNumberOfBytesWritten: ?*windows.DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn GetConsoleMode(
    hConsoleHandle: windows.HANDLE,
    lpMode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn SetConsoleMode(
    hConsoleHandle: windows.HANDLE,
    dwMode: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub const SmallRect = extern struct {
    Left: windows.SHORT,
    Top: windows.SHORT,
    Right: windows.SHORT,
    Bottom: windows.SHORT,
};

pub const ConsoleScreenBufferInfo = extern struct {
    dwSize: windows.COORD,
    dwCursorPosition: windows.COORD,
    wAttributes: windows.WORD,
    srWindow: SmallRect,
    dwMaximumWindowSize: windows.COORD,
};

pub extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: windows.HANDLE,
    lpConsoleScreenBufferInfo: *ConsoleScreenBufferInfo,
) callconv(.winapi) windows.BOOL;

/// A key event from a Windows console input buffer. Other input record
/// kinds are retained in `InputRecord.raw` so they can be discarded without
/// losing their size or alignment.
pub const KeyEvent = extern struct {
    down: i32,
    repeat_count: u16,
    virtual_key: u16,
    scan_code: u16,
    character: u16,
    control_keys: u32,
};

pub const InputRecord = extern struct {
    event_type: u16,
    event: extern union {
        key: KeyEvent,
        raw: [16]u8,
    },

    pub fn keyDown(record: InputRecord) bool {
        return record.event_type == key_event and record.event.key.down != 0;
    }
};

pub const key_event: u16 = 0x0001;

comptime {
    std.debug.assert(@sizeOf(InputRecord) == 20);
    std.debug.assert(@offsetOf(InputRecord, "event") == 4);
}

extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;
extern "kernel32" fn PeekConsoleInputW(handle: windows.HANDLE, buffer: [*]InputRecord, capacity: windows.DWORD, read_count: *windows.DWORD) callconv(.winapi) windows.BOOL;
extern "kernel32" fn ReadConsoleInputW(handle: windows.HANDLE, buffer: [*]InputRecord, capacity: windows.DWORD, read_count: *windows.DWORD) callconv(.winapi) windows.BOOL;

pub const WaitResult = enum { ready, timed_out };

/// Wait for any console input record to arrive, up to `milliseconds`.
pub fn waitInput(handle: windows.HANDLE, milliseconds: u32) std.Io.UnexpectedError!WaitResult {
    return switch (WaitForSingleObject(handle, milliseconds)) {
        0 => .ready,
        0x102 => .timed_out,
        else => unexpected(windows.GetLastError()),
    };
}

/// Look at queued records without consuming them. A caller can ignore
/// non-key records and then drain them with `readInput` before waiting again.
pub fn peekInput(handle: windows.HANDLE, buffer: []InputRecord) std.Io.UnexpectedError!usize {
    if (buffer.len == 0) return 0;
    var count: windows.DWORD = 0;
    if (PeekConsoleInputW(handle, buffer.ptr, @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD))), &count) == .FALSE)
        return unexpected(windows.GetLastError());
    return count;
}

/// Consume up to `buffer.len` records from a console input buffer.
pub fn readInput(handle: windows.HANDLE, buffer: []InputRecord) std.Io.UnexpectedError!usize {
    if (buffer.len == 0) return 0;
    var count: windows.DWORD = 0;
    if (ReadConsoleInputW(handle, buffer.ptr, @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD))), &count) == .FALSE)
        return unexpected(windows.GetLastError());
    return count;
}

test "a key-down input record has the Windows layout" {
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(InputRecord));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(InputRecord, "event"));
    const key: InputRecord = .{ .event_type = key_event, .event = .{ .key = .{
        .down = 1,
        .repeat_count = 1,
        .virtual_key = 0,
        .scan_code = 0,
        .character = 'a',
        .control_keys = 0,
    } } };
    try std.testing.expect(key.keyDown());
    var up = key;
    up.event.key.down = 0;
    try std.testing.expect(!up.keyDown());
}
