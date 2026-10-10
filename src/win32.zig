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
const console = @import("conduit.tty").console;

pub const Hresult = windows.LONG;

/// `GetLastError` as `error.Unexpected`, keeping the number. Declared with
/// the console calls in the terminal module, which needs it too.
pub const unexpected = console.unexpected;

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
pub extern "kernel32" fn CreatePseudoConsole(
    size: windows.COORD,
    hInput: windows.HANDLE,
    hOutput: windows.HANDLE,
    dwFlags: windows.DWORD,
    phPC: *Hpcon,
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
pub extern "kernel32" fn ResizePseudoConsole(
    hPC: Hpcon,
    size: windows.COORD,
) callconv(.winapi) Hresult;

/// Shuts a pseudoconsole down and releases it.
///
/// This ends the attached client: there is no Windows counterpart of closing
/// only the parent's copy of a slave descriptor while the child keeps its own.
pub extern "kernel32" fn ClosePseudoConsole(hPC: Hpcon) callconv(.winapi) void;

//======================================================================
// Job objects.
//======================================================================

/// A job object is a set of processes the operating system keeps together: a
/// process assigned to one puts everything it starts in the same job, and the
/// job can be ended or accounted for as a unit. It is the Windows answer to
/// the question a POSIX process group answers.
pub extern "kernel32" fn CreateJobObjectW(
    lpJobAttributes: ?*windows.SECURITY_ATTRIBUTES,
    lpName: ?windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;

pub extern "kernel32" fn AssignProcessToJobObject(
    hJob: windows.HANDLE,
    hProcess: windows.HANDLE,
) callconv(.winapi) windows.BOOL;

/// Whether a held process belongs to this specific job. The test fixtures
/// prove this before asking job termination to reach the grandchild.
pub extern "kernel32" fn IsProcessInJob(
    ProcessHandle: windows.HANDLE,
    JobHandle: windows.HANDLE,
    Result: *windows.BOOL,
) callconv(.winapi) windows.BOOL;

/// Ends every process in the job, each with `uExitCode`.
pub extern "kernel32" fn TerminateJobObject(
    hJob: windows.HANDLE,
    uExitCode: windows.UINT,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn QueryInformationJobObject(
    hJob: windows.HANDLE,
    JobObjectInformationClass: c_int,
    lpJobObjectInformation: *anyopaque,
    cbJobObjectInformationLength: windows.DWORD,
    lpReturnLength: ?*windows.DWORD,
) callconv(.winapi) windows.BOOL;

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
pub extern "kernel32" fn ResumeThread(hThread: windows.HANDLE) callconv(.winapi) windows.DWORD;

//======================================================================
// Handles and pipes.
//======================================================================

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

pub extern "kernel32" fn GetFileAttributesW(
    lpFileName: [*:0]const u16,
) callconv(.winapi) windows.DWORD;

/// Looks one variable up in this process's environment.
///
/// With a null buffer and a size of zero this reports the room the value would
/// need and zero when there is no such variable, which is all a presence check
/// wants. One call, and no walk of the process environment block under the
/// loader's lock.
pub extern "kernel32" fn GetEnvironmentVariableW(
    lpName: [*:0]const u16,
    lpBuffer: ?[*]u16,
    nSize: windows.DWORD,
) callconv(.winapi) windows.DWORD;

pub extern "kernel32" fn SetHandleInformation(
    hObject: windows.HANDLE,
    dwMask: windows.DWORD,
    dwFlags: windows.DWORD,
) callconv(.winapi) windows.BOOL;

/// What `SetHandleInformation` would be changing. Read before a spawn marks a
/// caller's handle inheritable, so that the flag can be put back after.
pub extern "kernel32" fn GetHandleInformation(
    hObject: windows.HANDLE,
    lpdwFlags: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub const duplicate_same_access: windows.DWORD = 0x00000002;

pub extern "kernel32" fn DuplicateHandle(
    hSourceProcessHandle: windows.HANDLE,
    hSourceHandle: windows.HANDLE,
    hTargetProcessHandle: windows.HANDLE,
    lpTargetHandle: *windows.HANDLE,
    dwDesiredAccess: windows.DWORD,
    bInheritHandle: windows.BOOL,
    dwOptions: windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub const generic_read = console.generic_read;
pub const generic_write = console.generic_write;
pub const file_share_read = console.file_share_read;
pub const file_share_write = console.file_share_write;
pub const open_existing = console.open_existing;
pub const CreateFileW = console.CreateFileW;

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

pub extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*ProcThreadAttributeList,
    dwAttributeCount: windows.DWORD,
    dwFlags: windows.DWORD,
    lpSize: *windows.SIZE_T,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: *ProcThreadAttributeList,
    dwFlags: windows.DWORD,
    Attribute: usize,
    lpValue: ?*anyopaque,
    cbSize: windows.SIZE_T,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*windows.SIZE_T,
) callconv(.winapi) windows.BOOL;

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
pub const file_type_pipe: windows.DWORD = 0x0003;
pub extern "kernel32" fn GetFileType(hFile: windows.HANDLE) callconv(.winapi) windows.DWORD;

//======================================================================
// Processes.
//======================================================================

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

pub extern "kernel32" fn OpenProcess(
    dwDesiredAccess: windows.DWORD,
    bInheritHandle: windows.BOOL,
    dwProcessId: windows.DWORD,
) callconv(.winapi) ?windows.HANDLE;

pub extern "kernel32" fn GetExitCodeProcess(
    hProcess: windows.HANDLE,
    lpExitCode: *windows.DWORD,
) callconv(.winapi) windows.BOOL;

pub const wait_object_0: windows.DWORD = 0;
pub const wait_timeout: windows.DWORD = 258;
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
pub extern "kernel32" fn CreateEventW(
    lpEventAttributes: ?*windows.SECURITY_ATTRIBUTES,
    bManualReset: windows.BOOL,
    bInitialState: windows.BOOL,
    lpName: ?windows.LPCWSTR,
) callconv(.winapi) ?windows.HANDLE;
pub extern "kernel32" fn SetEvent(hEvent: windows.HANDLE) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn ResetEvent(hEvent: windows.HANDLE) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn GenerateConsoleCtrlEvent(
    dwCtrlEvent: windows.DWORD,
    dwProcessGroupId: windows.DWORD,
) callconv(.winapi) windows.BOOL;

//======================================================================
// Console mode: declared in the terminal module, whose call it is.
//======================================================================

pub const GetConsoleMode = console.GetConsoleMode;
