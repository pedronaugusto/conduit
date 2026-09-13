//! The Windows calls this package makes that `std.os.windows` does not
//! declare.
//!
//! Everything here is an `extern` declaration against a system import library,
//! in the same style as `std.os.windows.kernel32`. No C is involved: this file
//! exists because `std.os.windows` carries the types (`HANDLE`, `COORD`,
//! `STARTUPINFOW`, `SECURITY_ATTRIBUTES`) but not the console, pipe,
//! attribute-list and pseudoconsole entry points, and a package that needs
//! them has to spell them out somewhere.
//!
//! This file is compiled only on Windows targets. Nothing in it is public API;
//! it is the seam between `Pty`, `Child` and `tty` and the operating system.
//!
//! # Minimum version
//!
//! `CreatePseudoConsole`, `ResizePseudoConsole` and `ClosePseudoConsole`
//! arrived in Windows 10 version 1809 (build 17763) and are imported
//! statically, so a binary that links this package will not start on anything
//! older. That is the same floor ConPTY itself has, and it is stated in
//! README.md.

const std = @import("std");
const windows = std.os.windows;

pub const BOOL = windows.BOOL;
pub const DWORD = windows.DWORD;
pub const HANDLE = windows.HANDLE;
pub const HRESULT = windows.LONG;
pub const LPCWSTR = windows.LPCWSTR;
pub const LPWSTR = windows.LPWSTR;
pub const SHORT = windows.SHORT;
pub const SIZE_T = windows.SIZE_T;
pub const UINT = windows.UINT;
pub const WORD = windows.WORD;
pub const COORD = windows.COORD;
pub const SECURITY_ATTRIBUTES = windows.SECURITY_ATTRIBUTES;
pub const STARTUPINFOW = windows.STARTUPINFOW;

/// `S_OK`. Every `HRESULT` this package reads is either this or a failure.
pub const ok: HRESULT = 0;

//======================================================================
// Pseudoconsoles.
//======================================================================

/// A pseudoconsole. The Windows counterpart of the slave end of a
/// pseudo-terminal pair: the object a child process is attached to, not a
/// stream anything reads or writes.
pub const HPCON = *anyopaque;

/// Creates a pseudoconsole of `size` reading its input from `hInput` and
/// writing its output to `hOutput`.
///
/// The two handles are the *console's* ends of a pair of pipes: the console
/// reads what the controlling program wrote into the other end of `hInput`,
/// and writes what the controlling program will read from the other end of
/// `hOutput`. The console duplicates both, so the caller closes its copies as
/// soon as this returns.
pub extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: DWORD,
    phPC: *HPCON,
) callconv(.winapi) HRESULT;

/// Changes a pseudoconsole's geometry. The attached client is told the way a
/// program on a POSIX terminal is told by `SIGWINCH`: through the console API
/// it already polls.
pub extern "kernel32" fn ResizePseudoConsole(
    hPC: HPCON,
    size: COORD,
) callconv(.winapi) HRESULT;

/// Shuts a pseudoconsole down and releases it.
///
/// This ends the attached client: there is no Windows counterpart of closing
/// only the parent's copy of a slave descriptor while the child keeps its own.
pub extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;

//======================================================================
// Handles and pipes.
//======================================================================

pub extern "kernel32" fn CreatePipe(
    hReadPipe: *HANDLE,
    hWritePipe: *HANDLE,
    lpPipeAttributes: ?*SECURITY_ATTRIBUTES,
    nSize: DWORD,
) callconv(.winapi) BOOL;

pub const HANDLE_FLAG_INHERIT: DWORD = 0x00000001;

pub extern "kernel32" fn SetHandleInformation(
    hObject: HANDLE,
    dwMask: DWORD,
    dwFlags: DWORD,
) callconv(.winapi) BOOL;

pub const GENERIC_READ: DWORD = 0x80000000;
pub const GENERIC_WRITE: DWORD = 0x40000000;
pub const FILE_SHARE_READ: DWORD = 0x00000001;
pub const FILE_SHARE_WRITE: DWORD = 0x00000002;
pub const OPEN_EXISTING: DWORD = 3;

pub extern "kernel32" fn CreateFileW(
    lpFileName: LPCWSTR,
    dwDesiredAccess: DWORD,
    dwShareMode: DWORD,
    lpSecurityAttributes: ?*SECURITY_ATTRIBUTES,
    dwCreationDisposition: DWORD,
    dwFlagsAndAttributes: DWORD,
    hTemplateFile: ?HANDLE,
) callconv(.winapi) HANDLE;

pub const STD_INPUT_HANDLE: DWORD = @bitCast(@as(i32, -10));
pub const STD_OUTPUT_HANDLE: DWORD = @bitCast(@as(i32, -11));
pub const STD_ERROR_HANDLE: DWORD = @bitCast(@as(i32, -12));

pub extern "kernel32" fn GetStdHandle(nStdHandle: DWORD) callconv(.winapi) HANDLE;

//======================================================================
// Process and thread attribute lists.
//======================================================================

/// An opaque, caller-allocated block whose size `InitializeProcThreadAttributeList`
/// reports. It is passed by address and never inspected.
pub const PROC_THREAD_ATTRIBUTE_LIST = opaque {};

/// `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`, from `<processthreadsapi.h>`:
/// number 22, input, of thread-and-process scope.
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;

pub extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*PROC_THREAD_ATTRIBUTE_LIST,
    dwAttributeCount: DWORD,
    dwFlags: DWORD,
    lpSize: *SIZE_T,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: *PROC_THREAD_ATTRIBUTE_LIST,
    dwFlags: DWORD,
    Attribute: usize,
    lpValue: ?*anyopaque,
    cbSize: SIZE_T,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*SIZE_T,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn DeleteProcThreadAttributeList(
    lpAttributeList: *PROC_THREAD_ATTRIBUTE_LIST,
) callconv(.winapi) void;

/// `STARTUPINFOEXW`. The plain `STARTUPINFOW` is the first field, which is why
/// `CreateProcessW` takes a pointer to it and reads the rest only when
/// `extended_startupinfo_present` is set.
pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*PROC_THREAD_ATTRIBUTE_LIST,
};

pub const STARTF_USESTDHANDLES: DWORD = 0x00000100;

//======================================================================
// Processes.
//======================================================================

pub extern "kernel32" fn TerminateProcess(
    hProcess: HANDLE,
    uExitCode: UINT,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetExitCodeProcess(
    hProcess: HANDLE,
    lpExitCode: *DWORD,
) callconv(.winapi) BOOL;

/// The exit code a process that is still running reports. A process that
/// genuinely exits with this value is indistinguishable from a running one,
/// which is why `tryWait` asks `WaitForSingleObject` first.
pub const STILL_ACTIVE: DWORD = 259;

pub const WAIT_OBJECT_0: DWORD = 0;
pub const WAIT_TIMEOUT: DWORD = 258;
pub const WAIT_FAILED: DWORD = 0xFFFFFFFF;

pub extern "kernel32" fn WaitForSingleObject(
    hHandle: HANDLE,
    dwMilliseconds: DWORD,
) callconv(.winapi) DWORD;

pub const CTRL_C_EVENT: DWORD = 0;
pub const CTRL_BREAK_EVENT: DWORD = 1;

/// Sends a console control event to a process group. The only way to ask a
/// Windows process to stop that it can decline, and it works only for a group
/// that shares this process's console.
pub extern "kernel32" fn GenerateConsoleCtrlEvent(
    dwCtrlEvent: DWORD,
    dwProcessGroupId: DWORD,
) callconv(.winapi) BOOL;

//======================================================================
// Consoles.
//======================================================================

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
