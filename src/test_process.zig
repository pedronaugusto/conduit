//! A tree fixture with no shell or launch broker.
//! Windows gives the descendant a separate console and no inherited streams,
//! reports its pid and exits. POSIX reports a descendant only after waitpid
//! observes it stopped, and keeps the root alive for recorded-tree cleanup.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

extern "kernel32" fn Sleep(milliseconds: windows.DWORD) callconv(.winapi) void;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (builtin.os.tag != .windows) return posixTree(init, args.len > 1 and std.mem.eql(u8, args[1], "--fail-report"));
    if (args.len > 1 and std.mem.eql(u8, args[1], "--grandchild")) {
        Sleep(std.math.maxInt(windows.DWORD));
        return;
    }
    const program = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, args[0]);
    const command = try std.fmt.allocPrint(allocator, "\"{s}\" --grandchild", .{args[0]});
    const line = try std.unicode.wtf8ToWtf16LeAllocZ(allocator, command);
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
        std.debug.print("fixture CreateProcessW failed: {d}\n", .{@intFromEnum(windows.GetLastError())});
        return error.FixtureSpawnFailed;
    }
    defer windows.CloseHandle(process.hProcess);
    defer windows.CloseHandle(process.hThread);
    var buffer: [64]u8 = undefined;
    const report = try std.fmt.bufPrint(&buffer, "pid {d}.\n", .{process.dwProcessId});
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
    const report = try std.fmt.bufPrint(&buffer, "{d}\n", .{descendant});
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
