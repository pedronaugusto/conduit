//! One descendant lifetime contract on every host.
const std = @import("std");
const builtin = @import("builtin");
const Child = @import("Child.zig").Child;
const State = @import("child_state.zig");
const windows = builtin.os.tag == .windows;
const win32 = if (windows) @import("win32.zig") else struct {};
const tree = if (windows) struct {} else @import("tree.zig");
const Watchdog = @import("test_support.zig").Watchdog;
const io = std.testing.io;
const gpa = std.testing.allocator;
const budget_ms = 5000;

const Process = if (windows) struct {
    handle: win32.HANDLE,
    fn capture(id: Child.Id) !@This() {
        return .{ .handle = win32.OpenProcess(win32.SYNCHRONIZE | win32.PROCESS_QUERY_LIMITED_INFORMATION | win32.PROCESS_TERMINATE, .FALSE, id) orelse return error.TestDaemonNotFound };
    }
    fn alive(process: *const @This()) bool {
        return win32.WaitForSingleObject(process.handle, 0) == win32.WAIT_TIMEOUT;
    }
    fn end(process: *@This()) void {
        _ = win32.TerminateProcess(process.handle, 1);
        _ = win32.WaitForSingleObject(process.handle, budget_ms);
        std.os.windows.CloseHandle(process.handle);
    }
} else struct {
    held: tree.CapturedPid,
    fn capture(id: Child.Id) !@This() {
        return .{ .held = (try tree.captureStarted(id, (try tree.startTime(id)) orelse return error.TestDaemonNotFound)) orelse return error.TestDaemonNotFound };
    }
    fn alive(process: *const @This()) bool {
        return process.held.alive();
    }
    fn end(process: *@This()) void {
        _ = process.held.signal(.KILL);
        _ = process.held.wait(io, budget_ms) catch {};
        process.held.deinit();
    }
};

const Fixture = struct {
    child: Child,
    daemon: Process,
    tmp: std.testing.TmpDir,

    fn start(policy: Child.Descendants, argument: []const u8) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = cwd_buffer[0..try tmp.dir.realPath(io, &cwd_buffer)];
        const program = try std.Io.Dir.cwd().realPathFileAlloc(io, @import("conduit_test_options").tree_fixture, gpa);
        defer gpa.free(program);
        var options: Child.SpawnOptions = .{
            .argv = &.{ program, "--daemon", argument },
            .cwd = cwd,
            .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
        };
        if (policy == .contain) options.descendants = .contain;
        var child = try Child.spawn(io, gpa, options);
        errdefer child.deinit(io);
        errdefer _ = child.killWait(io, 0) catch {};
        var buffer: [64]u8 = undefined;
        var reader = child.stdoutReader(io, &buffer).?;
        const line = try reader.interface.takeDelimiterExclusive('\n');
        const id = try std.fmt.parseInt(Child.Id, line, 10);
        var daemon = try Process.capture(id);
        errdefer daemon.end();
        try std.testing.expect(daemon.alive());
        if (windows) {
            var member: win32.BOOL = .FALSE;
            try std.testing.expect(win32.IsProcessInJob(daemon.handle, State.get(&child).job.?, &member) != .FALSE);
            try std.testing.expect(member != .FALSE);
        }
        return .{ .child = child, .daemon = daemon, .tmp = tmp };
    }

    fn deinit(fixture: *Fixture) void {
        _ = fixture.child.killWait(io, 0) catch {};
        fixture.child.deinit(io);
        fixture.daemon.end();
        fixture.tmp.cleanup();
    }

    fn expectEnded(fixture: *Fixture) !void {
        const deadline: @import("deadline.zig").Deadline = .in(io, budget_ms);
        while (fixture.daemon.alive() and deadline.remainingMs(io) > 0)
            try io.sleep(.fromMilliseconds(2), .awake);
        try std.testing.expect(!fixture.daemon.alive());
    }
};

test "normal reap and deinit leave a detached daemon alive by default" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var fixture = try Fixture.start(.survive, "--escape");
    defer fixture.deinit();
    fixture.child.closeStdin(io);
    const term = (try fixture.child.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
    try std.testing.expect(Child.succeeded(term));
    fixture.child.deinit(io);
    try std.testing.expect(fixture.daemon.alive());
    // Observe beyond the asynchronous termination boundary as well.
    try io.sleep(.fromMilliseconds(50), .awake);
    try std.testing.expect(fixture.daemon.alive());
}

test "containment ends a daemon after normal completion through every reap" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    inline for (.{ "wait", "tryWait", "output", "Reaper" }) |method| {
        var fixture = try Fixture.start(.contain, "");
        defer fixture.deinit();
        fixture.child.closeStdin(io);
        if (comptime std.mem.eql(u8, method, "wait")) {
            try std.testing.expect(Child.succeeded((try fixture.child.waitTimeout(io, budget_ms)).?));
        } else if (comptime std.mem.eql(u8, method, "tryWait")) {
            const deadline: @import("deadline.zig").Deadline = .in(io, budget_ms);
            const term = while (deadline.remainingMs(io) > 0) {
                if (try fixture.child.tryWait()) |term| break term;
                try io.sleep(.fromMilliseconds(2), .awake);
            } else return error.TestChildDidNotExit;
            try std.testing.expect(Child.succeeded(term));
        } else if (comptime std.mem.eql(u8, method, "output")) {
            var output = try fixture.child.output(io, gpa, .{ .timeout_ms = budget_ms });
            defer output.deinit(gpa);
            try std.testing.expect(Child.succeeded(output.term()));
        } else {
            var reaper: @import("Reaper.zig").Reaper = .init(&fixture.child, .{});
            try reaper.start(io);
            defer reaper.deinit(io);
            try std.testing.expect(Child.succeeded((try reaper.waitTimeout(io, budget_ms)).?));
        }
        fixture.child.deinit(io);
        try fixture.expectEnded();
    }
}

test "timeout kill killWait and output errors end a daemon in either policy" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    inline for (.{ Child.Descendants.survive, Child.Descendants.contain }) |policy| {
        inline for (.{ "timeout", "kill", "killWait", "error" }) |operation| {
            var fixture = try Fixture.start(policy, "--escape");
            defer fixture.deinit();
            if (comptime std.mem.eql(u8, operation, "timeout")) {
                var output = try fixture.child.output(io, gpa, .{ .timeout_ms = 50, .grace_ms = 50 });
                defer output.deinit(gpa);
                try std.testing.expect(output.timedOut());
            } else if (comptime std.mem.eql(u8, operation, "kill")) {
                try fixture.child.kill(.kill);
                _ = (try fixture.child.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
            } else if (comptime std.mem.eql(u8, operation, "killWait")) {
                _ = try fixture.child.killWait(io, 50);
            } else {
                fixture.child.stdoutFile().?.close(io);
                State.get(&fixture.child).stdout.?.handle = if (windows) std.os.windows.INVALID_HANDLE_VALUE else -1;
                defer _ = fixture.child.takeStdout();
                try std.testing.expectError(error.ReadFailed, fixture.child.output(io, gpa, .{}));
            }
            fixture.child.deinit(io);
            try fixture.expectEnded();
        }
    }
}
