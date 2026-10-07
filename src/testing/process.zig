//! A tree fixture with no shell or launch broker.
//! Windows gives the descendant a separate console and no inherited streams,
//! reports its pid and exits. POSIX reports a descendant only after waitpid
//! observes it stopped, and keeps the root alive for recorded-tree cleanup.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

extern "c" fn pause() c_int;

extern "kernel32" fn WaitForSingleObject(handle: windows.HANDLE, milliseconds: windows.DWORD) callconv(.winapi) windows.DWORD;

extern "kernel32" fn Sleep(milliseconds: windows.DWORD) callconv(.winapi) void;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len > 1 and std.mem.eql(u8, args[1], "--daemon")) return daemonTree(init, args);
    if (builtin.target.os.tag != .windows) return posixTree(init, args.len > 1 and std.mem.eql(u8, args[1], "--fail-report"));
    if (args.len > 1 and std.mem.eql(u8, args[1], "--middle")) {
        const id = try daemonWindows(init, args[0], false);
        var buffer: [64]u8 = undefined;
        const report = try std.mem.print(&buffer, "{d}", .{id});
        try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = "daemon-pid", .data = report });
        return;
    }
    if (args.len > 1 and std.mem.eql(u8, args[1], "--grandchild")) {
        Sleep(std.math.maxInt(windows.DWORD));
        return;
    }
    const program = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, args[0]);
    const command = try gpa.print("\"{s}\" --grandchild", .{args[0]});
    const line = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, command);
    var startup: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    startup.cb = @sizeOf(windows.STARTUPINFOW);
    startup.dwFlags = windows.STARTF_USESHOWWINDOW;
    startup.wShowWindow = 0; // SW_HIDE; a console still exists for its own streams.
    var process: windows.PROCESS.INFORMATION = undefined;
    if (windows.kernel32.CreateProcessW(
        program.ptr,
        line.ptr,
        null,
        null,
        .FALSE,
        .{ .create_new_console = true },
        null,
        null,
        &startup,
        &process,
    ) == .FALSE) {
        std.debug.print("fixture CreateProcessW failed: {d}\n", .{@backingInt(windows.GetLastError())});
        return error.FixtureSpawnFailed;
    }
    defer windows.CloseHandle(process.hProcess);
    defer windows.CloseHandle(process.hThread);
    var buffer: [64]u8 = undefined;
    const report = try std.mem.print(&buffer, "pid {d}.\n", .{process.dwProcessId});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
}

fn posixTree(init: std.process.Init, fail_report: bool) !void {
    const c = std.c;
    const descendant = c.fork();
    if (descendant < 0) return error.FixtureForkFailed;
    if (descendant == 0) {
        // Only async-signal-safe calls in the fork child. It never execs,
        // so its captured Darwin audit token cannot change under the test.
        if (c.kill(c.getpid(), .STOP) != 0) c._exit(1);
        c._exit(0);
    }
    defer {
        // This direct child is still ours and unreaped. Any return, including
        // a failed report, ends and reaps it before the helper itself exits.
        _ = c.kill(descendant, .KILL);
        var departed: c_int = 0;
        while (c.waitpid(descendant, &departed, 0) < 0) {
            if (std.posix.errno(-1) != .INTR) break;
        }
    }
    var status: c_int = 0;
    while (c.waitpid(descendant, &status, std.posix.W.UNTRACED) < 0) {
        if (std.posix.errno(-1) != .INTR) return error.FixtureWaitFailed;
    }
    if (!std.posix.W.IFSTOPPED(@bitCast(status))) return error.FixtureDescendantDidNotStop;
    var buffer: [64]u8 = undefined;
    const report = try std.mem.print(&buffer, "{d}\n", .{descendant});
    if (fail_report) {
        try std.Io.File.stderr().writeStreamingAll(init.io, report);
        // Keep the child unreaped until the test has captured its identity.
        // A bare pid reported just before cleanup could already be reused.
        var acknowledged: [1]u8 = undefined;
        if (try std.Io.File.stdin().readStreaming(init.io, &.{&acknowledged}) != 1)
            return error.FixtureHandshakeFailed;
        return error.FixtureReportFailed;
    }
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
    try init.io.sleep(.fromSeconds(30), .awake);
}

// The root stays alive until the test has captured the daemon's identity.
// No daemon inherits the root's pipes; no shell or personal config is read.
fn daemonTree(init: std.process.Init, args: []const [:0]const u8) !void {
    const racing = args.len > 2 and std.mem.eql(u8, args[2], "--race");
    const double = racing or (args.len > 2 and std.mem.eql(u8, args[2], "--double-fork"));
    const escape = double or (args.len > 2 and std.mem.eql(u8, args[2], "--escape"));
    const id = if (builtin.target.os.tag == .windows)
        try daemonWindows(init, args[0], double)
    else posix: {
        const c = std.c;
        var ready: [2]c_int = undefined;
        if (c.pipe(&ready) != 0) return error.FixturePipeFailed;
        const pid = c.fork();
        if (pid < 0) return error.FixtureForkFailed;
        if (pid == 0) {
            _ = c.close(ready[0]);
            if (escape and c.setsid() < 0) c._exit(1);
            if (double) {
                const grandchild = c.fork();
                if (grandchild < 0) c._exit(1);
                if (grandchild > 0) {
                    // Keep the intermediate parent until the caller releases
                    // normal exit; its child has already left the private group.
                    var acknowledged: [1]u8 = undefined;
                    if (!racing) _ = c.read(0, &acknowledged, 1);
                    c._exit(0);
                }
            }
            _ = c.close(0);
            _ = c.close(1);
            _ = c.close(2);
            const daemon_pid: u32 = @intCast(c.getpid());
            if (c.write(ready[1], std.mem.asBytes(&daemon_pid).ptr, @sizeOf(u32)) != @sizeOf(u32)) c._exit(1);
            _ = c.close(ready[1]);
            while (true) _ = pause();
        }
        _ = c.close(ready[1]);
        defer _ = c.close(ready[0]);
        var daemon_pid: u32 = undefined;
        if (c.read(ready[0], std.mem.asBytes(&daemon_pid).ptr, @sizeOf(u32)) != @sizeOf(u32)) return error.FixtureHandshakeFailed;
        if (racing) {
            var status: c_int = 0;
            while (c.waitpid(pid, &status, 0) < 0) {
                if (std.posix.errno(-1) != .INTR) return error.FixtureWaitFailed;
            }
        }
        break :posix daemon_pid;
    };
    var buffer: [64]u8 = undefined;
    const report = try std.mem.print(&buffer, "{d}\n", .{id});
    try std.Io.File.stdout().writeStreamingAll(init.io, report);
    var byte: [1]u8 = undefined;
    _ = std.Io.File.stdin().readStreaming(init.io, &.{&byte}) catch |err| switch (err) {
        error.EndOfStream => 0,
        else => return err,
    };
    if (args.len > 2 and std.mem.eql(u8, args[2], "--exit-7")) std.process.exit(7);
}

/// Each generation has a separate console and inherits no root streams.
/// The intermediate exits before the root reports its detached grandchild.
fn daemonWindows(init: std.process.Init, executable: []const u8, double: bool) !u32 {
    const gpa = init.arena.allocator();
    const program = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, executable);
    const command = try gpa.print("\"{s}\" {s}", .{ executable, if (double) "--middle" else "--grandchild" });
    const line = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, command);
    var startup: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    startup.cb = @sizeOf(windows.STARTUPINFOW);
    startup.dwFlags = windows.STARTF_USESHOWWINDOW;
    var process: windows.PROCESS.INFORMATION = undefined;
    if (windows.kernel32.CreateProcessW(program.ptr, line.ptr, null, null, .FALSE, .{ .create_new_console = true }, null, null, &startup, &process) == .FALSE)
        return error.FixtureSpawnFailed;
    defer windows.CloseHandle(process.hThread);
    defer windows.CloseHandle(process.hProcess);
    if (!double) return process.dwProcessId;
    if (WaitForSingleObject(process.hProcess, 5000) != 0)
        return error.FixtureIntermediateDidNotExit;
    var buffer: [64]u8 = undefined;
    const report = try std.Io.Dir.cwd().readFile(init.io, "daemon-pid", &buffer);
    return std.fmt.parseInt(u32, report, 10);
}
