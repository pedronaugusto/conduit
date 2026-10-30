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
//! Nothing in it is public API: it is a module of its own (`win32`) that
//! `conduit.tty` and `conduit` import and neither exports, so a binding both
//! need is declared once, and it is the seam between `Pty`, `Child` and `tty`
//! and the operating system. Nothing here is reached off Windows.
//!
//! Windows' names, in Zig's casing: `JOBOBJECT_BASIC_LIMIT_INFORMATION` is
//! `JobObjectBasicLimitInformation`, `WAIT_TIMEOUT` is `wait_timeout`, and the
//! information class `JobObjectBasicAccountingInformation` is
//! `job_object_basic_accounting_information`. Functions keep their symbol
//! names, and the types `std.os.windows` declares are taken from there.
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
const log = std.log.scoped(.conduit);

pub const Hresult = windows.LONG;

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

/// `S_OK`. Every `HRESULT` this package reads is either this or a failure.
pub const ok: Hresult = 0;

//======================================================================
// Pseudoconsoles.
//======================================================================

/// A pseudoconsole. The Windows counterpart of the slave end of a
/// pseudo-terminal pair: the object a child process is attached to, not a
/// stream anything reads or writes.
pub const Hpcon = *anyopaque;

/// Creates a pseudoconsole of `size` reading its input from `hInput` and
/// writing its output to `hOutput`.
///
/// The two handles are the *console's* ends of a pair of pipes: the console
/// reads what the controlling program wrote into the other end of `hInput`,
/// and writes what the controlling program will read from the other end of
/// `hOutput`. The console duplicates both, so the caller closes its copies as
/// soon as this returns.
// aegis: boundary(A019): kernel32's CreatePseudoConsole, declared as Microsoft's documentation gives it
pub extern "kernel32" fn CreatePseudoConsole(
    size: windows.COORD,
    hInput: windows.HANDLE,
    hOutput: windows.HANDLE,
    dwFlags: windows.DWORD,
    phPC: *?Hpcon,
) callconv(.winapi) Hresult;

/// `PSEUDOCONSOLE_RESIZE_QUIRK`: a resize does not reflow what the client has
/// already written.
pub const pseudoconsole_resize_quirk: windows.DWORD = 0x00000002;
/// `PSEUDOCONSOLE_WIN32_INPUT_MODE`: what is written to the console's input is
/// read as Windows input records rather than as a character stream.
pub const pseudoconsole_win32_input_mode: windows.DWORD = 0x00000004;
/// `PSEUDOCONSOLE_PASSTHROUGH_MODE`: the client's output reaches the reader as
/// the client wrote it. Windows 11 22H2 and newer; older systems refuse the
/// whole call with `E_INVALIDARG`.
pub const pseudoconsole_passthrough_mode: windows.DWORD = 0x00000008;

/// Changes a pseudoconsole's geometry. The attached client is told the way a
/// program on a POSIX terminal is told by `SIGWINCH`: through the console API
/// it already polls.
// aegis: boundary(A019): kernel32's ResizePseudoConsole, declared as Microsoft's documentation gives it
pub extern "kernel32" fn ResizePseudoConsole(
    hPC: Hpcon,
    size: windows.COORD,
) callconv(.winapi) Hresult;

/// Shuts a pseudoconsole down and releases it.
///
/// This ends the attached client: there is no Windows counterpart of closing
/// only the parent's copy of a slave descriptor while the child keeps its own.
// aegis: boundary(A019): kernel32's ClosePseudoConsole, declared as Microsoft's documentation gives it
pub extern "kernel32" fn ClosePseudoConsole(hPC: Hpcon) callconv(.winapi) void;

//======================================================================
// Job objects.
//======================================================================

/// A job object is a set of processes the operating system keeps together: a
/// process assigned to one puts everything it starts in the same job, and the
/// job can be ended or accounted for as a unit. It is the Windows answer to
/// the question a POSIX process group answers.
// aegis: boundary(A019): kernel32's CreateJobObjectW, declared as Microsoft's documentation gives it
pub extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*windows.SECURITY_ATTRIBUTES,
    lpName: ?windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;

// aegis: boundary(A019): kernel32's AssignProcessToJobObject, declared as Microsoft's documentation gives it
pub extern "kernel32" fn AssignProcessToJobObject(
    hJob: windows.HANDLE,
    hProcess: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

/// Whether a held process belongs to this specific job. The test fixtures
/// prove this before asking job termination to reach the grandchild.
// aegis: boundary(A019): kernel32's IsProcessInJob, declared as Microsoft's documentation gives it
pub extern "kernel32" fn IsProcessInJob(
    ProcessHandle: windows.HANDLE,
    JobHandle: windows.HANDLE,
    Result: *windows.BOOL,
) callconv(.winapi) windows.BOOL;

/// Ends every process in the job, each with `uExitCode`.
// aegis: boundary(A019): kernel32's TerminateJobObject, declared as Microsoft's documentation gives it
pub extern "kernel32" fn TerminateJobObject(
    hJob: windows.HANDLE,
    uExitCode: windows.UINT,
) callconv(.winapi) windows.BOOL;

// aegis: boundary(A019): kernel32's QueryInformationJobObject, declared as Microsoft's documentation gives it
pub extern "kernel32" fn QueryInformationJobObject(
    hJob: windows.HANDLE,
    JobObjectInformationClass: c_int,
    lpJobObjectInformation: *anyopaque,
    cbJobObjectInformationLength: windows.DWORD,
    lpReturnLength: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;

// aegis: boundary(A019): kernel32's SetInformationJobObject, declared as Microsoft's documentation gives it
pub extern "kernel32" fn SetInformationJobObject(
    hJob: windows.HANDLE,
    JobObjectInformationClass: c_int,
    lpJobObjectInformation: *anyopaque,
    cbJobObjectInformationLength: windows.DWORD,
) callconv(.winapi) windows.BOOL;

/// `JobObjectBasicAccountingInformation` in `JOBOBJECTINFOCLASS`.
pub const job_object_basic_accounting_information: c_int = 1;

pub const JobObjectBasicAccountingInformation = extern struct {
    TotalUserTime: windows.LARGE_INTEGER,
    TotalKernelTime: windows.LARGE_INTEGER,
    ThisPeriodTotalUserTime: windows.LARGE_INTEGER,
    ThisPeriodTotalKernelTime: windows.LARGE_INTEGER,
    TotalPageFaultCount: windows.DWORD,
    TotalProcesses: windows.DWORD,
    ActiveProcesses: windows.DWORD,
    TotalTerminatedProcesses: windows.DWORD,
};

/// `JobObjectExtendedLimitInformation` in `JOBOBJECTINFOCLASS`.
pub const job_object_extended_limit_information: c_int = 9;

/// Every process still in the job is ended when the last handle to the job is
/// closed.
pub const job_object_limit_kill_on_job_close: windows.DWORD = 0x00002000;
/// `ActiveProcessLimit` is in force: a process that would be one too many does
/// not start.
pub const job_object_limit_active_process: windows.DWORD = 0x00000008;
/// `ProcessMemoryLimit` is in force, per process in the job.
pub const job_object_limit_process_memory: windows.DWORD = 0x00000100;
/// `JobMemoryLimit` is in force, across the job.
pub const job_object_limit_job_memory: windows.DWORD = 0x00000200;

/// `JobObjectCpuRateControlInformation` in `JOBOBJECTINFOCLASS`.
pub const job_object_cpu_rate_control_information: c_int = 15;

pub const job_object_cpu_rate_control_enable: windows.DWORD = 0x00000001;
pub const job_object_cpu_rate_control_hard_cap: windows.DWORD = 0x00000004;

/// The rate is in hundredths of a percent of one processor: 10_000 is a whole
/// one.
pub const JobObjectCpuRateControlInformation = extern struct {
    ControlFlags: windows.DWORD,
    Value: windows.DWORD,
};

pub const JobObjectBasicLimitInformation = extern struct {
    PerProcessUserTimeLimit: windows.LARGE_INTEGER,
    PerJobUserTimeLimit: windows.LARGE_INTEGER,
    LimitFlags: windows.DWORD,
    MinimumWorkingSetSize: windows.SIZE_T,
    MaximumWorkingSetSize: windows.SIZE_T,
    ActiveProcessLimit: windows.DWORD,
    Affinity: windows.ULONG_PTR,
    PriorityClass: windows.DWORD,
    SchedulingClass: windows.DWORD,
};

pub const IoCounters = extern struct {
    ReadOperationCount: u64,
    WriteOperationCount: u64,
    OtherOperationCount: u64,
    ReadTransferCount: u64,
    WriteTransferCount: u64,
    OtherTransferCount: u64,
};

pub const JobObjectExtendedLimitInformation = extern struct {
    BasicLimitInformation: JobObjectBasicLimitInformation,
    IoInfo: IoCounters,
    ProcessMemoryLimit: windows.SIZE_T,
    JobMemoryLimit: windows.SIZE_T,
    PeakProcessMemoryUsed: windows.SIZE_T,
    PeakJobMemoryUsed: windows.SIZE_T,
};

/// Lets a thread `CreateProcessW` started suspended begin running. Returns the
/// previous suspend count, or `maxInt(DWORD)` on failure.
// aegis: boundary(A019): kernel32's ResumeThread, declared as Microsoft's documentation gives it
pub extern "kernel32" fn ResumeThread(hThread: windows.HANDLE) callconv(.winapi) windows.DWORD;

//======================================================================
// Handles and pipes.
//======================================================================

// aegis: boundary(A019): kernel32's CreatePipe, declared as Microsoft's documentation gives it
pub extern "kernel32" fn CreatePipe(
    hReadPipe: *windows.HANDLE,
    hWritePipe: *windows.HANDLE,
    lpPipeAttributes: ?*windows.SECURITY_ATTRIBUTES,
    nSize: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub const handle_flag_inherit: windows.DWORD = 0x00000001;

/// What `GetFileAttributesW` returns when it could not look at the path.
pub const invalid_file_attributes: windows.DWORD = 0xFFFFFFFF;
pub const file_attribute_directory: windows.DWORD = 0x00000010;

// aegis: boundary(A019): kernel32's GetFileAttributesW, declared as Microsoft's documentation gives it
pub extern "kernel32" fn GetFileAttributesW(
    lpFileName: [*:0]const u16,
) callconv(.winapi) windows.DWORD;

/// Looks one variable up in this process's environment.
///
/// With a null buffer and a size of zero this reports the room the value would
/// need and zero when there is no such variable, which is all a presence check
/// wants. One call, and no walk of the process environment block under the
/// loader's lock.
// aegis: boundary(A019): kernel32's GetEnvironmentVariableW, declared as Microsoft's documentation gives it
pub extern "kernel32" fn GetEnvironmentVariableW(
    lpName: [*:0]const u16,
    lpBuffer: ?[*]u16,
    nSize: windows.DWORD,
) callconv(.winapi) windows.DWORD;

// aegis: boundary(A019): kernel32's SetHandleInformation, declared as Microsoft's documentation gives it
pub extern "kernel32" fn SetHandleInformation(
    hObject: windows.HANDLE,
    dwMask: windows.DWORD,
    dwFlags: windows.DWORD,
) callconv(.winapi) windows.BOOL;

/// What `SetHandleInformation` would be changing. Read before a spawn marks a
/// caller's handle inheritable, so that the flag can be put back after.
// aegis: boundary(A019): kernel32's GetHandleInformation, declared as Microsoft's documentation gives it
pub extern "kernel32" fn GetHandleInformation(
    hObject: windows.HANDLE,
    lpdwFlags: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub const duplicate_same_access: windows.DWORD = 0x00000002;

// aegis: boundary(A019): kernel32's DuplicateHandle, declared as Microsoft's documentation gives it
pub extern "kernel32" fn DuplicateHandle(
    hSourceProcessHandle: windows.HANDLE,
    hSourceHandle: windows.HANDLE,
    hTargetProcessHandle: windows.HANDLE,
    lpTargetHandle: *windows.HANDLE,
    dwDesiredAccess: windows.DWORD,
    bInheritHandle: windows.BOOL,
    dwOptions: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub const generic_read: windows.DWORD = 0x80000000;
pub const generic_write: windows.DWORD = 0x40000000;
pub const file_share_read: windows.DWORD = 0x00000001;
pub const file_share_write: windows.DWORD = 0x00000002;
pub const open_existing: windows.DWORD = 3;

/// Opens a file or a device by name: here, `CONIN$` and `CONOUT$`, the
/// console's input buffer and screen buffer, whatever the standard handles
/// were redirected to.
// aegis: boundary(A019): kernel32's CreateFileW, declared as Microsoft's documentation gives it
pub extern "kernel32" fn CreateFileW(
    lpFileName: windows.LPCWSTR,
    dwDesiredAccess: windows.DWORD,
    dwShareMode: windows.DWORD,
    lpSecurityAttributes: ?*windows.SECURITY_ATTRIBUTES,
    dwCreationDisposition: windows.DWORD,
    dwFlagsAndAttributes: windows.DWORD,
    hTemplateFile: ?windows.HANDLE,
) callconv(.winapi) windows.HANDLE;

//======================================================================
// Process and thread attribute lists.
//======================================================================

/// An opaque, caller-allocated block whose size `InitializeProcThreadAttributeList`
/// reports. It is passed by address and never inspected.
pub const ProcThreadAttributeList = opaque {};

/// `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`, from `<processthreadsapi.h>`:
/// number 22, input, of thread-and-process scope.
pub const proc_thread_attribute_pseudoconsole: usize = 0x00020016;

/// `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`: number 2, input, of thread scope.
///
/// The list of handles a child may inherit. Without it `bInheritHandles` means
/// *every* inheritable handle this process holds, which is far more than the
/// three a child is being given.
pub const proc_thread_attribute_handle_list: usize = 0x00020002;

// aegis: boundary(A019): kernel32's InitializeProcThreadAttributeList, declared as Microsoft's documentation gives it
pub extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*ProcThreadAttributeList,
    dwAttributeCount: windows.DWORD,
    dwFlags: windows.DWORD,
    lpSize: *windows.SIZE_T,
) callconv(.winapi) windows.BOOL;

// aegis: boundary(A019): kernel32's UpdateProcThreadAttribute, declared as Microsoft's documentation gives it
pub extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: *ProcThreadAttributeList,
    dwFlags: windows.DWORD,
    Attribute: usize,
    lpValue: ?*anyopaque,
    cbSize: windows.SIZE_T,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*windows.SIZE_T,
) callconv(.winapi) windows.BOOL;

// aegis: boundary(A019): kernel32's DeleteProcThreadAttributeList, declared as Microsoft's documentation gives it
pub extern "kernel32" fn DeleteProcThreadAttributeList(
    lpAttributeList: *ProcThreadAttributeList,
) callconv(.winapi) void;

/// `STARTUPINFOEXW`. The plain `STARTUPINFOW` is the first field, which is why
/// `CreateProcessW` takes a pointer to it and reads the rest only when
/// `extended_startupinfo_present` is set.
pub const StartupInfoExW = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: ?*ProcThreadAttributeList,
};

pub const startf_usestdhandles: windows.DWORD = 0x00000100;

/// What kind of object a handle is, for the C runtime's flags on an
/// inherited descriptor.
pub const file_type_char: windows.DWORD = 0x0002;
/// `FILE_TYPE_PIPE`, what `GetFileType` answers for a pipe or a socket.
pub const file_type_pipe: windows.DWORD = 0x0003;
// aegis: boundary(A019): kernel32's GetFileType, declared as Microsoft's documentation gives it
pub extern "kernel32" fn GetFileType(hFile: windows.HANDLE) callconv(.winapi) windows.DWORD;

//======================================================================
// Processes.
//======================================================================

// aegis: boundary(A019): kernel32's TerminateProcess, declared as Microsoft's documentation gives it
pub extern "kernel32" fn TerminateProcess(
    hProcess: windows.HANDLE,
    uExitCode: windows.UINT,
) callconv(.winapi) windows.BOOL;

/// Enough access to wait on a process this package did not start and to ask
/// how it ended. Used by the tests, which is where a process named only by its
/// id has to be looked at.
pub const synchronize: windows.DWORD = 0x00100000;
pub const process_terminate: windows.DWORD = 0x00000001;
pub const process_query_limited_information: windows.DWORD = 0x00001000;

// aegis: boundary(A019): kernel32's OpenProcess, declared as Microsoft's documentation gives it
pub extern "kernel32" fn OpenProcess(
    dwDesiredAccess: windows.DWORD,
    bInheritHandle: windows.BOOL,
    dwProcessId: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

// aegis: boundary(A019): kernel32's GetExitCodeProcess, declared as Microsoft's documentation gives it
pub extern "kernel32" fn GetExitCodeProcess(
    hProcess: windows.HANDLE,
    lpExitCode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub const wait_object_0: windows.DWORD = 0;
pub const wait_timeout: windows.DWORD = 258;
// aegis: boundary(A019): kernel32's WaitForSingleObject, declared as Microsoft's documentation gives it
pub extern "kernel32" fn WaitForSingleObject(
    hHandle: windows.HANDLE,
    dwMilliseconds: windows.DWORD,
) callconv(.winapi) windows.DWORD;

pub const ctrl_c_event: windows.DWORD = 0;
pub const ctrl_break_event: windows.DWORD = 1;

/// Sends a console control event to a process group. The only way to ask a
/// Windows process to stop that it can decline, and it works only for a group
/// that shares this process's console.
/// An event, for the tests: two handles to one event can be shown to be
/// one object by signalling through one and waiting on the other.
// aegis: boundary(A019): kernel32's CreateEventW, declared as Microsoft's documentation gives it
pub extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*windows.SECURITY_ATTRIBUTES,
    bManualReset: windows.BOOL,
    bInitialState: windows.BOOL,
    lpName: ?windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;
// aegis: boundary(A019): kernel32's SetEvent, declared as Microsoft's documentation gives it
pub extern "kernel32" fn SetEvent(hEvent: windows.HANDLE) callconv(.winapi) windows.BOOL;
// aegis: boundary(A019): kernel32's ResetEvent, declared as Microsoft's documentation gives it
pub extern "kernel32" fn ResetEvent(hEvent: windows.HANDLE) callconv(.winapi) windows.BOOL;

// aegis: boundary(A019): kernel32's GenerateConsoleCtrlEvent, declared as Microsoft's documentation gives it
pub extern "kernel32" fn GenerateConsoleCtrlEvent(
    dwCtrlEvent: windows.DWORD,
    dwProcessGroupId: windows.DWORD,
) callconv(.winapi) windows.BOOL;

//======================================================================
// The console: its modes and its screen buffer, `tty`'s calls.
//======================================================================

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

// aegis: boundary(A019): kernel32's GetConsoleMode, declared as Microsoft's documentation gives it
pub extern "kernel32" fn GetConsoleMode(
    hConsoleHandle: windows.HANDLE,
    lpMode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

// aegis: boundary(A019): kernel32's SetConsoleMode, declared as Microsoft's documentation gives it
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

// aegis: boundary(A019): kernel32's GetConsoleScreenBufferInfo, declared as Microsoft's documentation gives it
pub extern "kernel32" fn GetConsoleScreenBufferInfo(
    hConsoleOutput: windows.HANDLE,
    lpConsoleScreenBufferInfo: *ConsoleScreenBufferInfo,
) callconv(.winapi) windows.BOOL;

//======================================================================
// Process memory: `Child.memory`.
//======================================================================

/// `PROCESS_MEMORY_COUNTERS` of `<psapi.h>`.
pub const ProcessMemoryCounters = extern struct {
    cb: windows.DWORD,
    page_fault_count: windows.DWORD,
    peak_working_set_size: usize,
    working_set_size: usize,
    quota_peak_paged_pool_usage: usize,
    quota_paged_pool_usage: usize,
    quota_peak_non_paged_pool_usage: usize,
    quota_non_paged_pool_usage: usize,
    pagefile_usage: usize,
    peak_pagefile_usage: usize,
};
// aegis: boundary(A019): kernel32's K32GetProcessMemoryInfo, declared as Microsoft's documentation gives it
pub extern "kernel32" fn K32GetProcessMemoryInfo(process: windows.HANDLE, counters: *ProcessMemoryCounters, cb: windows.DWORD) callconv(.winapi) windows.BOOL;

//======================================================================
// The machine's name: `hostName`.
//======================================================================

/// `COMPUTER_NAME_FORMAT`'s `ComputerNameDnsHostname`: the DNS host name,
/// without the domain, which Winsock's `gethostname` returns.
pub const computer_name_dns_hostname: c_int = 1;
// aegis: boundary(A019): kernel32's GetComputerNameExW, declared as Microsoft's documentation gives it
pub extern "kernel32" fn GetComputerNameExW(NameType: c_int, lpBuffer: ?[*]u16, nSize: *windows.DWORD) callconv(.winapi) windows.BOOL;
