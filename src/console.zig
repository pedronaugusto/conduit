//! A Windows console's input: its records, a key going down among them, and
//! a bounded wait for the next one, for a program that reads keys from the
//! console itself. Nothing here is reached off Windows.
//!
//! The kernel32 calls behind it are private (`win32`, a module neither of
//! conduit's exports).

const std = @import("std");
const reactor = @import("reactor");
const win32 = @import("win32");
const windows = std.os.windows;

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

// aegis: boundary: kernel32's PeekConsoleInputW, declared as Microsoft's documentation gives it
extern "kernel32" fn PeekConsoleInputW(handle: windows.HANDLE, buffer: [*]InputRecord, capacity: windows.DWORD, read_count: *windows.DWORD) callconv(.winapi) windows.BOOL;
// aegis: boundary: kernel32's ReadConsoleInputW, declared as Microsoft's documentation gives it
extern "kernel32" fn ReadConsoleInputW(handle: windows.HANDLE, buffer: [*]InputRecord, capacity: windows.DWORD, read_count: *windows.DWORD) callconv(.winapi) windows.BOOL;

pub const WaitResult = enum { ready, timed_out };

/// What `waitInput` can meet.
pub const WaitInputError = error{
    /// The wait failed for a reason the system did not name.
    Unexpected,
    /// The task was cancelled.
    Canceled,
};

/// Wait for any console input record to arrive, up to `timeout`. A zero
/// timeout asks and does not wait. The wait is reactor's, on the input
/// handle as an object: on a runtime it holds no thread, and either way a
/// cancel ends it.
pub fn waitInput(io: std.Io, handle: windows.HANDLE, timeout: std.Io.Timeout) WaitInputError!WaitResult {
    reactor.wait(io, .{ .object = handle }, timeout) catch |err| return switch (err) {
        error.Timeout => .timed_out,
        error.Canceled => error.Canceled,
        error.Unsupported => unreachable, // unreachable: reactor waits on a Windows object on every `Io`
        error.Unexpected => error.Unexpected,
    };
    return .ready;
}

/// Look at queued records without consuming them. A caller can ignore
/// non-key records and then drain them with `readInput` before waiting again.
pub fn peekInput(handle: windows.HANDLE, buffer: []InputRecord) std.Io.UnexpectedError!usize {
    if (buffer.len == 0) return 0;
    var count: windows.DWORD = 0;
    if (PeekConsoleInputW(handle, buffer.ptr, @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD))), &count) == .FALSE)
        return win32.unexpected(windows.GetLastError());
    return count;
}

/// Consume up to `buffer.len` records from a console input buffer.
pub fn readInput(handle: windows.HANDLE, buffer: []InputRecord) std.Io.UnexpectedError!usize {
    if (buffer.len == 0) return 0;
    var count: windows.DWORD = 0;
    if (ReadConsoleInputW(handle, buffer.ptr, @intCast(@min(buffer.len, std.math.maxInt(windows.DWORD))), &count) == .FALSE)
        return win32.unexpected(windows.GetLastError());
    return count;
}
