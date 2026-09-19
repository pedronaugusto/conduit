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

/// `PSEUDOCONSOLE_RESIZE_QUIRK`: a resize does not reflow what the client has
/// already written.
pub const PSEUDOCONSOLE_RESIZE_QUIRK: DWORD = 0x00000002;
/// `PSEUDOCONSOLE_WIN32_INPUT_MODE`: what is written to the console's input is
/// read as Windows input records rather than as a character stream.
pub const PSEUDOCONSOLE_WIN32_INPUT_MODE: DWORD = 0x00000004;
/// `PSEUDOCONSOLE_PASSTHROUGH_MODE`: the client's output reaches the reader as
/// the client wrote it. Windows 11 22H2 and newer; older systems refuse the
/// whole call with `E_INVALIDARG`.
pub const PSEUDOCONSOLE_PASSTHROUGH_MODE: DWORD = 0x00000008;

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
// Job objects.
//======================================================================

/// A job object is a set of processes the operating system keeps together: a
/// process assigned to one puts everything it starts in the same job, and the
/// job can be ended or accounted for as a unit. It is the Windows answer to
/// the question a POSIX process group answers.
pub extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*SECURITY_ATTRIBUTES,
    lpName: ?LPCWSTR,
) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn AssignProcessToJobObject(
    hJob: HANDLE,
    hProcess: HANDLE,
) callconv(.winapi) BOOL;

/// Ends every process in the job, each with `uExitCode`.
pub extern "kernel32" fn TerminateJobObject(
    hJob: HANDLE,
    uExitCode: UINT,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetInformationJobObject(
    hJob: HANDLE,
    JobObjectInformationClass: c_int,
    lpJobObjectInformation: *anyopaque,
    cbJobObjectInformationLength: DWORD,
) callconv(.winapi) BOOL;

/// `JobObjectExtendedLimitInformation` in `JOBOBJECTINFOCLASS`.
pub const JobObjectExtendedLimitInformation: c_int = 9;

/// Every process still in the job is ended when the last handle to the job is
/// closed.
pub const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: DWORD = 0x00002000;
/// `ActiveProcessLimit` is in force: a process that would be one too many does
/// not start.
pub const JOB_OBJECT_LIMIT_ACTIVE_PROCESS: DWORD = 0x00000008;
/// `ProcessMemoryLimit` is in force, per process in the job.
pub const JOB_OBJECT_LIMIT_PROCESS_MEMORY: DWORD = 0x00000100;
/// `JobMemoryLimit` is in force, across the job.
pub const JOB_OBJECT_LIMIT_JOB_MEMORY: DWORD = 0x00000200;

/// `JobObjectCpuRateControlInformation` in `JOBOBJECTINFOCLASS`.
pub const JobObjectCpuRateControlInformation: c_int = 15;

pub const JOB_OBJECT_CPU_RATE_CONTROL_ENABLE: DWORD = 0x00000001;
pub const JOB_OBJECT_CPU_RATE_CONTROL_HARD_CAP: DWORD = 0x00000004;

/// The rate is in hundredths of a percent of one processor: 10_000 is a whole
/// one.
pub const JOBOBJECT_CPU_RATE_CONTROL_INFORMATION = extern struct {
    ControlFlags: DWORD,
    Value: DWORD,
};

pub const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: windows.LARGE_INTEGER,
    PerJobUserTimeLimit: windows.LARGE_INTEGER,
    LimitFlags: DWORD,
    MinimumWorkingSetSize: SIZE_T,
    MaximumWorkingSetSize: SIZE_T,
    ActiveProcessLimit: DWORD,
    Affinity: windows.ULONG_PTR,
    PriorityClass: DWORD,
    SchedulingClass: DWORD,
};

pub const IO_COUNTERS = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

pub const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION,
    IoInfo: IO_COUNTERS,
    ProcessMemoryLimit: SIZE_T,
    JobMemoryLimit: SIZE_T,
    PeakProcessMemoryUsed: SIZE_T,
    PeakJobMemoryUsed: SIZE_T,
};

/// Lets a thread `CreateProcessW` started suspended begin running. Returns the
/// previous suspend count, or `maxInt(DWORD)` on failure.
pub extern "kernel32" fn ResumeThread(hThread: HANDLE) callconv(.winapi) DWORD;

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

/// What `GetFileAttributesW` returns when it could not look at the path.
pub const INVALID_FILE_ATTRIBUTES: DWORD = 0xFFFFFFFF;
pub const FILE_ATTRIBUTE_DIRECTORY: DWORD = 0x00000010;

pub extern "kernel32" fn GetFileAttributesW(
    lpFileName: [*:0]const u16,
) callconv(.winapi) DWORD;

/// Looks one variable up in this process's environment.
///
/// With a null buffer and a size of zero this reports the room the value would
/// need and zero when there is no such variable, which is all a presence check
/// wants. One call, and no walk of the process environment block under the
/// loader's lock.
pub extern "kernel32" fn GetEnvironmentVariableW(
    lpName: [*:0]const u16,
    lpBuffer: ?[*]u16,
    nSize: DWORD,
) callconv(.winapi) DWORD;

/// Ends every pending I/O this process issued on `hFile`, whichever thread
/// issued it. The way to release a thread blocked in a synchronous read of a
/// pipe without closing the handle under it.
pub extern "kernel32" fn CancelIoEx(
    hFile: HANDLE,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetHandleInformation(
    hObject: HANDLE,
    dwMask: DWORD,
    dwFlags: DWORD,
) callconv(.winapi) BOOL;

/// What `SetHandleInformation` would be changing. Read before a spawn marks a
/// caller's handle inheritable, so that the flag can be put back after.
pub extern "kernel32" fn GetHandleInformation(
    hObject: HANDLE,
    lpdwFlags: *DWORD,
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

/// `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`: number 2, input, of thread scope.
///
/// The list of handles a child may inherit. Without it `bInheritHandles` means
/// *every* inheritable handle this process holds, which is far more than the
/// three a child is being given.
pub const PROC_THREAD_ATTRIBUTE_HANDLE_LIST: usize = 0x00020002;

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
