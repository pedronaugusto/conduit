//! How much memory a live process holds, asked of the operating system by the
//! process's identity: `Child.memory` is the public entry.
const std = @import("std");
const builtin = @import("builtin");

const c = std.c;
const posix = std.posix;
const windows = std.os.windows;
const win32 = @import("win32.zig");

/// What a process holds now and the most it has held since it started, in
/// bytes, each system's own measure of it:
///
/// - **Linux**: the resident set, `VmRSS` and `VmHWM` of `/proc/<pid>/status`.
/// - **Darwin**: the physical footprint (what Activity Monitor and Xcode call
///   memory), `ri_phys_footprint` and `ri_lifetime_max_phys_footprint` of
///   `proc_pid_rusage`. Darwin keeps no peak resident size it will tell
///   another process, so both figures are footprints: the dirty and compressed
///   pages the process owns, not the clean pages of its program file.
/// - **Windows**: the working set, `WorkingSetSize` and `PeakWorkingSetSize`
///   of `GetProcessMemoryInfo`.
///
/// Compare figures from one system with each other, not across systems.
pub const Memory = struct {
    current: u64,
    peak: u64,
};

pub const Error = error{
    /// The process has ended: reaped, retired, or a zombie whose memory is gone.
    ProcessEnded,
    /// This system has no way to ask, or the child is simulated.
    Unsupported,
    /// The system refused or answered something unreadable.
    Unexpected,
};

/// Linux and Darwin take the process id, Windows the process handle.
pub fn of(identity: if (builtin.target.os.tag == .windows) windows.HANDLE else posix.pid_t) Error!Memory {
    switch (builtin.target.os.tag) {
        .linux => return linuxMemory(identity),
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => return darwinMemory(identity),
        .windows => return windowsMemory(identity),
        else => return error.Unsupported,
    }
}

fn linuxMemory(pid: posix.pid_t) Error!Memory {
    var path_buffer: [64]u8 = undefined;
    const path = std.mem.printSentinel(&path_buffer, "/proc/{d}/status", .{pid}, 0) catch unreachable; // unreachable: a pid prints in 64 bytes
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return switch (c.errno(fd)) {
        .NOENT, .SRCH => error.ProcessEnded,
        else => error.Unexpected,
    };
    defer _ = c.close(fd);
    // The status file is about 1.5 KiB; the two lines come early in it.
    var text: [8192]u8 = undefined;
    var filled: usize = 0;
    while (filled < text.len) {
        const n = c.read(fd, text[filled..].ptr, text.len - filled);
        if (n < 0) {
            if (c.errno(n) == .INTR) continue;
            return if (c.errno(n) == .SRCH) error.ProcessEnded else error.Unexpected;
        }
        if (n == 0) break;
        filled += @intCast(n);
    }
    return parseLinuxStatus(text[0..filled]);
}

/// The two lines of a Linux `/proc/<pid>/status`, in KiB. A zombie's status
/// has neither: its memory is gone.
pub fn parseLinuxStatus(text: []const u8) Error!Memory {
    var current: ?u64 = null;
    var peak: ?u64 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const slot = if (std.mem.startsWith(u8, line, "VmRSS:")) &current else if (std.mem.startsWith(u8, line, "VmHWM:")) &peak else continue;
        var fields = std.mem.tokenizeAny(u8, line[6..], " \t");
        const kib = std.fmt.parseInt(u64, fields.next() orelse return error.Unexpected, 10) catch return error.Unexpected;
        const unit = fields.next() orelse return error.Unexpected;
        if (!std.mem.eql(u8, unit, "kB")) return error.Unexpected;
        slot.* = std.math.mul(u64, kib, 1024) catch return error.Unexpected;
    }
    if (current == null and peak == null) return error.ProcessEnded;
    return .{ .current = current orelse return error.Unexpected, .peak = peak orelse return error.Unexpected };
}

/// `struct rusage_info_v4` of `<sys/resource.h>`, through the fields read.
const RusageInfoV4 = extern struct {
    uuid: [16]u8,
    user_time: u64,
    system_time: u64,
    pkg_idle_wkups: u64,
    interrupt_wkups: u64,
    pageins: u64,
    wired_size: u64,
    resident_size: u64,
    phys_footprint: u64,
    proc_start_abstime: u64,
    proc_exit_abstime: u64,
    child_user_time: u64,
    child_system_time: u64,
    child_pkg_idle_wkups: u64,
    child_interrupt_wkups: u64,
    child_pageins: u64,
    child_elapsed_abstime: u64,
    diskio_bytesread: u64,
    diskio_byteswritten: u64,
    cpu_time_qos_default: u64,
    cpu_time_qos_maintenance: u64,
    cpu_time_qos_background: u64,
    cpu_time_qos_utility: u64,
    cpu_time_qos_legacy: u64,
    cpu_time_qos_user_initiated: u64,
    cpu_time_qos_user_interactive: u64,
    billed_system_time: u64,
    serviced_system_time: u64,
    logical_writes: u64,
    lifetime_max_phys_footprint: u64,
    instructions: u64,
    cycles: u64,
    billed_energy: u64,
    serviced_energy: u64,
    interval_max_phys_footprint: u64,
    runnable_time: u64,
};
const rusage_info_v4 = 4;
extern "c" fn proc_pid_rusage(pid: c_int, flavor: c_int, buffer: *RusageInfoV4) c_int;

fn darwinMemory(pid: posix.pid_t) Error!Memory {
    var info: RusageInfoV4 = undefined;
    if (proc_pid_rusage(pid, rusage_info_v4, &info) != 0) return switch (c.errno(@as(c_int, -1))) {
        .SRCH => error.ProcessEnded,
        else => error.Unexpected,
    };
    // A zombie keeps its counters but no memory: its footprint reads zero.
    if (info.proc_exit_abstime != 0) return error.ProcessEnded;
    return .{ .current = info.phys_footprint, .peak = @max(info.lifetime_max_phys_footprint, info.phys_footprint) };
}

fn windowsMemory(process: windows.HANDLE) Error!Memory {
    var counters: win32.ProcessMemoryCounters = undefined;
    counters.cb = @sizeOf(win32.ProcessMemoryCounters);
    if (win32.K32GetProcessMemoryInfo(process, &counters, @sizeOf(win32.ProcessMemoryCounters)) == .FALSE) return error.Unexpected;
    return .{ .current = counters.working_set_size, .peak = counters.peak_working_set_size };
}

test "a Linux status gives its resident set and its peak, and a zombie's is ended" {
    const status = "Name:\tserver\nVmPeak:\t  123456 kB\nVmHWM:\t   70000 kB\nVmRSS:\t    6000 kB\nThreads:\t4\n";
    const memory = try parseLinuxStatus(status);
    try std.testing.expectEqual(@as(u64, 6000 * 1024), memory.current);
    try std.testing.expectEqual(@as(u64, 70000 * 1024), memory.peak);
    try std.testing.expectError(error.ProcessEnded, parseLinuxStatus("Name:\tserver\nState:\tZ (zombie)\n"));
    try std.testing.expectError(error.Unexpected, parseLinuxStatus("VmRSS:\t12 MB\nVmHWM:\t1 kB\n"));
}
