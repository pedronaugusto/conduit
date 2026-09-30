//! A Windows tree fixture with no shell, broker or inherited streams.
//! The parent creates a sleeping descendant in a new console, reports its
//! pid, and exits. The test's job owns both processes from before they run.
const std = @import("std");
const windows = std.os.windows;

extern "kernel32" fn Sleep(milliseconds: windows.DWORD) callconv(.winapi) void;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
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
