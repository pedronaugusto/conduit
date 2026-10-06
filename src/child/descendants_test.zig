//! One descendant lifetime contract on every host.
const std = @import("std");
const builtin = @import("builtin");
const Child = @import("../child.zig").Child;
const windows = builtin.os.tag == .windows;
const win32 = @import("../win32.zig");
const tree = @import("../tree.zig");
const cgroups = @import("../cgroup.zig");
const Watchdog = @import("../testing/support.zig").Watchdog;
const io = std.testing.io;
const gpa = std.testing.allocator;
const Deadline = @import("conduit.tty").Deadline;
const Reaper = @import("../reaper.zig").Reaper;
const lineage = @import("../lineage.zig");
const test_options = @import("conduit_test_options");
const budget_ms = 5000;
extern "c" fn getpgid(pid: std.posix.pid_t) std.posix.pid_t;
extern "c" fn getsid(pid: std.posix.pid_t) std.posix.pid_t;

const Process = if (windows) struct {
    handle: std.os.windows.HANDLE,
    fn capture(id: Child.Id) !Process {
        return .{ .handle = win32.OpenProcess(win32.synchronize | win32.process_query_limited_information | win32.process_terminate, .FALSE, id) orelse return error.TestDaemonNotFound };
    }
    fn alive(process: *const Process) bool {
        return win32.WaitForSingleObject(process.handle, 0) == win32.wait_timeout;
    }
    fn end(process: *Process) void {
        _ = win32.TerminateProcess(process.handle, 1);
        _ = win32.WaitForSingleObject(process.handle, budget_ms);
        std.os.windows.CloseHandle(process.handle);
    }
} else struct {
    held: tree.CapturedPid,
    fn capture(id: Child.Id) !Process {
        return .{ .held = (try tree.captureStarted(id, (try tree.startTime(id)) orelse return error.TestDaemonNotFound)) orelse return error.TestDaemonNotFound };
    }
    fn alive(process: *const Process) bool {
        return process.held.alive();
    }
    fn end(process: *Process) void {
        _ = process.held.signal(.KILL);
        // ziglint-ignore: Z026 cleanup after SIGKILL; what the test asserts was asserted before it
        _ = process.held.wait(io, budget_ms) catch {};
        process.held.deinit();
    }
};

const Fixture = struct {
    child: Child,
    daemon: Process,
    tmp: std.testing.TmpDir,
    /// Whether a test released the child itself; release ends a Child.
    released: bool = false,

    fn start(policy: Child.Descendants, argument: []const u8) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = cwd_buffer[0..try tmp.dir.realPath(io, &cwd_buffer)];
        const program = try std.Io.Dir.cwd().realPathFileAlloc(io, test_options.tree_fixture, gpa);
        defer gpa.free(program);
        var options: Child.SpawnOptions = .{
            .argv = &.{ program, "--daemon", argument },
            .cwd = cwd,
            .job_limits = if (windows) .{ .active_processes = 4 } else .{},
            .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
        };
        if (policy == .contain) options.descendants = .contain;
        var child = try Child.spawn(gpa, io, options);
        errdefer child.release(io) catch unreachable;
        errdefer _ = child.killWait(io, 0) catch {};
        var buffer: [64]u8 = undefined;
        var reader = child.stdoutReader(io, &buffer).?;
        const line = try reader.interface.takeDelimiterExclusive('\n');
        const id = try std.fmt.parseInt(Child.Id, line, 10);
        var daemon = try Process.capture(id);
        errdefer daemon.end();
        try std.testing.expect(daemon.alive());
        if (windows) {
            var member: std.os.windows.BOOL = .FALSE;
            try std.testing.expect(win32.IsProcessInJob(daemon.handle, child.state.job.?, &member) != .FALSE);
            try std.testing.expect(member != .FALSE);
        }
        return .{ .child = child, .daemon = daemon, .tmp = tmp };
    }

    fn release(fixture: *Fixture) Child.ReleaseError!void {
        try fixture.child.release(io);
        fixture.released = true;
    }

    fn deinit(fixture: *Fixture) void {
        if (!fixture.released) {
            // ziglint-ignore: Z026 cleanup; release below asserts the child is reaped
            _ = fixture.child.killWait(io, 0) catch {};
            fixture.child.release(io) catch unreachable;
        }
        fixture.daemon.end();
        fixture.tmp.cleanup();
        fixture.* = undefined;
    }

    fn expectEnded(fixture: *Fixture) !void {
        const deadline: Deadline = .in(io, budget_ms);
        while (fixture.daemon.alive() and deadline.remainingMs(io) > 0)
            try io.sleep(.fromMilliseconds(2), .awake);
        try std.testing.expect(!fixture.daemon.alive());
    }
};

test "normal reap and deinit leave a detached daemon alive by default" {
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    inline for (.{ "wait", "tryWait", "output", "Reaper", "exit-7" }) |method| {
        var fixture = try Fixture.start(.survive, if (comptime std.mem.eql(u8, method, "exit-7")) "--exit-7" else "--escape");
        defer fixture.deinit();
        fixture.child.closeStdin(io);
        const term = if (comptime std.mem.eql(u8, method, "tryWait")) term: {
            const deadline: Deadline = .in(io, budget_ms);
            while (deadline.remainingMs(io) > 0) {
                if (try fixture.child.tryWait()) |term| break :term term;
                try io.sleep(.fromMilliseconds(2), .awake);
            }
            return error.TestChildDidNotExit;
        } else if (comptime std.mem.eql(u8, method, "output")) term: {
            var output = try fixture.child.output(gpa, io, .{ .timeout_ms = budget_ms });
            defer output.deinit(gpa);
            break :term output.term();
        } else if (comptime std.mem.eql(u8, method, "Reaper")) term: {
            var reaper: Reaper = .init(&fixture.child, .{});
            try reaper.start(io);
            defer reaper.deinit(io);
            break :term (try reaper.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
        } else (try fixture.child.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
        try std.testing.expectEqual(Child.Term{ .exited = if (comptime std.mem.eql(u8, method, "exit-7")) 7 else 0 }, term);
        if (windows) {
            var limits: win32.JobObjectExtendedLimitInformation = undefined;
            try std.testing.expect(win32.QueryInformationJobObject(fixture.child.state.job.?, win32.job_object_extended_limit_information, &limits, @sizeOf(@TypeOf(limits)), null) != .FALSE);
            try std.testing.expectEqual(@as(u32, 4), limits.BasicLimitInformation.ActiveProcessLimit);
            try std.testing.expect(limits.BasicLimitInformation.LimitFlags & win32.job_object_limit_active_process != 0);
            try std.testing.expect(limits.BasicLimitInformation.LimitFlags & win32.job_object_limit_kill_on_job_close == 0);
        }
        fixture.release() catch unreachable;
        try std.testing.expect(fixture.daemon.alive());
        // Observe beyond the asynchronous termination boundary as well.
        try io.sleep(.fromMilliseconds(50), .awake);
        try std.testing.expect(fixture.daemon.alive());
    }
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
            const deadline: Deadline = .in(io, budget_ms);
            const term = while (deadline.remainingMs(io) > 0) {
                if (try fixture.child.tryWait()) |term| break term;
                try io.sleep(.fromMilliseconds(2), .awake);
            } else return error.TestChildDidNotExit;
            try std.testing.expect(Child.succeeded(term));
        } else if (comptime std.mem.eql(u8, method, "output")) {
            var output = try fixture.child.output(gpa, io, .{ .timeout_ms = budget_ms });
            defer output.deinit(gpa);
            try std.testing.expect(Child.succeeded(output.term()));
        } else {
            var reaper: Reaper = .init(&fixture.child, .{});
            try reaper.start(io);
            defer reaper.deinit(io);
            try std.testing.expect(Child.succeeded((try reaper.waitTimeout(io, budget_ms)).?));
        }
        fixture.release() catch unreachable;
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
                var output = try fixture.child.output(gpa, io, .{ .timeout_ms = 50, .grace_ms = 50 });
                defer output.deinit(gpa);
                try std.testing.expect(output.timedOut());
            } else if (comptime std.mem.eql(u8, operation, "kill")) {
                try fixture.child.kill(.kill);
                _ = (try fixture.child.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
            } else if (comptime std.mem.eql(u8, operation, "killWait")) {
                _ = try fixture.child.killWait(io, 50);
            } else {
                fixture.child.stdoutFile().?.close(io);
                fixture.child.state.stdout.?.handle = if (windows) std.os.windows.INVALID_HANDLE_VALUE else -1;
                defer _ = fixture.child.takeStdout();
                try std.testing.expectError(error.ReadFailed, fixture.child.output(gpa, io, .{}));
            }
            fixture.release() catch unreachable;
            try fixture.expectEnded();
        }
    }
}

test "a walk too large to hold still kills and reaps the child itself" {
    if (windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    // The walk is what is under test: a child in a cgroup is ended without one.
    cgroups.testing_hook.off = true;
    defer cgroups.testing_hook.off = false;
    tree.testing_hook.walk_full = true;
    defer tree.testing_hook.walk_full = false;
    {
        var fixture = try Fixture.start(.survive, "--escape");
        defer fixture.deinit();
        try std.testing.expectError(error.OutOfMemory, fixture.child.kill(.kill));
        const term = (try fixture.child.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
        try std.testing.expectEqual(Child.Term{ .signal = .KILL }, term);
    }
    {
        var fixture = try Fixture.start(.survive, "--escape");
        defer fixture.deinit();
        try std.testing.expectError(error.OutOfMemory, fixture.child.killWait(io, 0));
        try std.testing.expectEqual(Child.Term{ .signal = .KILL }, (try fixture.child.tryWait()).?);
    }
}

test "containment ends a double-forked session after normal exit" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux and !windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    inline for (.{ "wait", "tryWait", "output", "Reaper" }) |method| {
        var fixture = try Fixture.start(.contain, "--double-fork");
        defer fixture.deinit();

        if (!windows) {
            const pid = fixture.daemon.held.processId();
            try std.testing.expect(getpgid(pid) != fixture.child.state.pgid.?);
            try std.testing.expect(getsid(pid) != fixture.child.processId().?);
            try std.testing.expect(getsid(pid) != pid);
        }
        // The intermediate remains alive until EOF. Wait for all three
        // registrations, so this tests retained lineage under any scheduler;
        // immediate parent exit is measured separately below.
        if (builtin.os.tag == .macos) {
            const tracker = fixture.child.state.lineage.?;
            const deadline: Deadline = .in(io, budget_ms);
            while (tracker.observed.load(.acquire) < 3 and deadline.remainingMs(io) > 0)
                try io.sleep(.fromMilliseconds(2), .awake);
            try std.testing.expect(tracker.observed.load(.acquire) >= 3);
        }
        fixture.child.closeStdin(io);
        if (comptime std.mem.eql(u8, method, "tryWait")) {
            const deadline: Deadline = .in(io, budget_ms);
            const term = while (deadline.remainingMs(io) > 0) {
                if (try fixture.child.tryWait()) |term| break term;
                try io.sleep(.fromMilliseconds(2), .awake);
            } else return error.TestChildDidNotExit;
            try std.testing.expect(Child.succeeded(term));
        } else if (comptime std.mem.eql(u8, method, "output")) {
            var output = try fixture.child.output(gpa, io, .{ .timeout_ms = budget_ms });
            defer output.deinit(gpa);
            try std.testing.expect(Child.succeeded(output.term()));
        } else if (comptime std.mem.eql(u8, method, "Reaper")) {
            var reaper: Reaper = .init(&fixture.child, .{});
            try reaper.start(io);
            defer reaper.deinit(io);
            try std.testing.expect(Child.succeeded((try reaper.waitTimeout(io, budget_ms)).?));
        } else try std.testing.expect(Child.succeeded((try fixture.child.waitTimeout(io, budget_ms)).?));
        fixture.release() catch unreachable;
        try fixture.expectEnded();
    }
}

// A measurement, not a test: how often a detached descendant escapes the
// Darwin lineage observer, with and without a delay before it registers.
// Run with `zig build unit -Dmeasure -Dtest-filter=measures`.
test "Darwin measures the fork then exit registration race" {
    if (builtin.os.tag != .macos or !test_options.measure) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const attempts = 100;
    const hook = &lineage.testing_hook.delay_ms;
    defer hook.store(0, .release);
    for ([_]u32{ 0, 20 }) |delay_ms| {
        hook.store(delay_ms, .release);
        var escapes: usize = 0;
        for (0..attempts) |_| {
            var fixture = try Fixture.start(.contain, "--race");
            defer fixture.deinit();
            fixture.child.closeStdin(io);
            try std.testing.expect(Child.succeeded((try fixture.child.waitTimeout(io, budget_ms)).?));
            // A survivor is counted, then ended through the fixture's captured
            // identity. Measuring a race does not turn it into a guarantee.
            if (fixture.daemon.alive()) escapes += 1;
        }
        std.debug.print("Darwin fork/exit registration ({d} ms observer delay): {d}/{d} detached descendants escaped\n", .{ delay_ms, escapes, attempts });
    }
}

test "a Reaper subreaper ends and reaps a detached orphan without stealing another child" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    cgroups.testing_hook.off = true;
    defer cgroups.testing_hook.off = false;
    var fixture: Fixture = undefined;
    var reaper: Reaper = .init(&fixture.child, .{});
    // Activation precedes spawn: an intermediate can exit before start runs.
    try reaper.enableSubreaper();
    fixture = Fixture.start(.contain, "--double-fork") catch |err| {
        reaper.stop(io) catch unreachable;
        reaper.deinit(io);
        return err;
    };
    defer fixture.deinit();
    defer {
        reaper.stop(io) catch unreachable;
        reaper.deinit(io);
    }
    var unrelated = try Child.spawn(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "read x; exit 7" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer unrelated.release(io) catch unreachable;
    defer _ = unrelated.killWait(io, 0) catch {};
    try std.testing.expect(!fixture.child.state.cgroup.active());
    const daemon_id = fixture.daemon.held.processId();
    try reaper.start(io);
    fixture.child.closeStdin(io);
    try std.testing.expect(Child.succeeded((try reaper.waitTimeout(io, budget_ms)).?));
    try fixture.expectEnded();
    var status: c_int = 0;
    try std.testing.expectEqual(@as(c_int, -1), std.c.waitpid(daemon_id, &status, std.posix.W.NOHANG));
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(-1));
    try std.testing.expectEqual(@as(?Child.Term, null), try unrelated.tryWait());
    unrelated.closeStdin(io);
    try std.testing.expectEqual(Child.Term{ .exited = 7 }, (try unrelated.waitTimeout(io, budget_ms)).?);
}

test "a Reaper subreaper reaps an adopted exit while its root stays idle" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const linux = std.os.linux;
    cgroups.testing_hook.off = true;
    defer cgroups.testing_hook.off = false;
    var fixture: Fixture = undefined;
    var reaper: Reaper = .init(&fixture.child, .{});
    try reaper.enableSubreaper();
    fixture = Fixture.start(.survive, "--race") catch |err| {
        reaper.stop(io) catch unreachable;
        reaper.deinit(io);
        return err;
    };
    const held = fixture.child.holdReap().?;
    var holding = true;
    defer {
        if (holding) held.release();
        reaper.kill(io, 0);
        _ = fixture.child.killWait(io, 0) catch {};
        reaper.stop(io) catch unreachable;
        reaper.deinit(io);
        fixture.deinit();
    }
    try reaper.start(io);
    const pid = fixture.daemon.held.processId();
    const fd = linux.pidfd_open(pid, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(fd));
    defer _ = linux.close(@intCast(fd));
    var info = std.mem.zeroes(linux.siginfo_t);
    const flags = linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT;
    // The intermediate was reaped before the fixture reported readiness.
    // This proves adoption before CHILD could be used as evidence of a reap.
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.waitid(.PIDFD, @intCast(fd), &info, flags, null)));
    try std.testing.expect(fixture.daemon.held.signal(.KILL));
    const deadline: Deadline = .in(io, budget_ms);
    while (deadline.remainingMs(io) > 0) {
        const result = linux.errno(linux.waitid(.PIDFD, @intCast(fd), &info, flags, null));
        if (result == .CHILD) break;
        try std.testing.expect(result == .SUCCESS or result == .INTR);
        try io.sleep(.fromMilliseconds(2), .awake);
    }
    try std.testing.expectEqual(linux.E.CHILD, linux.errno(linux.waitid(.PIDFD, @intCast(fd), &info, flags, null)));
    try std.testing.expectEqual(@as(?Child.Term, null), try reaper.exit());
    held.release();
    holding = false;
    fixture.child.closeStdin(io);
    try std.testing.expect(Child.succeeded((try reaper.waitTimeout(io, budget_ms)).?));
}

test "independent contained Linux children end only their own detached orphans" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    cgroups.testing_hook.off = true;
    defer cgroups.testing_hook.off = false;
    var first = try Fixture.start(.contain, "--race");
    defer first.deinit();
    var second = try Fixture.start(.contain, "--race");
    defer second.deinit();
    first.child.closeStdin(io);
    try std.testing.expect(Child.succeeded((try first.child.waitTimeout(io, budget_ms)).?));
    try first.expectEnded();
    try std.testing.expect(second.daemon.alive());
    try std.testing.expectEqual(@as(?Child.Term, null), try second.child.tryWait());
    second.child.closeStdin(io);
    try std.testing.expect(Child.succeeded((try second.child.waitTimeout(io, budget_ms)).?));
    try second.expectEnded();
}

test "a private supervisor preserves the root exit code and signal" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    inline for (.{ "exit 7", "kill -TERM $$" }, .{ Child.Term{ .exited = 7 }, Child.Term{ .signal = .TERM } }) |script, expected| {
        var child = try Child.spawn(gpa, io, .{ .argv = &.{ "/bin/sh", "-c", script }, .descendants = .contain, .stdio = .ignore });
        defer child.release(io) catch unreachable;
        try std.testing.expectEqual(expected, (try child.waitTimeout(io, budget_ms)).?);
        try std.testing.expectEqual(expected, (try child.tryWait()).?);
    }
}

test "a saved private supervisor ends only its recorded scope" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    cgroups.testing_hook.off = true;
    defer cgroups.testing_hook.off = false;
    var first = try Fixture.start(.contain, "--race");
    defer first.deinit();
    var second = try Fixture.start(.contain, "--race");
    defer second.deinit();
    var buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
    const record = try first.child.containment(&buffer);
    try std.testing.expect(record.supervisor != null);
    try std.testing.expect(record.supervisor.?.pid != first.child.processId().?);
    var wrong = record.supervisor.?;
    wrong.start += 1;
    try std.testing.expect(!try tree.killRecorded(io, .{ .pid = first.child.processId().?, .start = 0, .supervisor = wrong, .grace_ms = 0 }));
    try std.testing.expect(first.daemon.alive());
    try std.testing.expect(try tree.killRecorded(io, .{ .pid = first.child.processId().?, .start = 0, .supervisor = record.supervisor, .grace_ms = 0 }));
    try std.testing.expectEqual(Child.Term{ .signal = .KILL }, (try first.child.waitTimeout(io, budget_ms)).?);
    try first.expectEnded();
    try std.testing.expect(second.daemon.alive());
}

test "a failed contained exec leaves no private supervisor to wait for" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    try std.testing.expectError(error.FileNotFound, Child.spawn(gpa, io, .{
        .argv = &.{"/no-such-conduit-contained-executable"},
        .descendants = .contain,
        .stdio = .ignore,
    }));
    // Tests run one at a time and own every child in this test process.
    var status: c_int = 0;
    try std.testing.expectEqual(@as(c_int, -1), std.c.waitpid(-1, &status, std.posix.W.NOHANG));
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(-1));
}

test "dropping a contained child ends and reaps its private supervisor" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    var child = try Child.spawn(gpa, io, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .descendants = .contain,
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    const scope = child.state.id;
    var status: c_int = 0;
    defer {
        while (std.c.waitpid(scope, &status, 0) < 0 and std.posix.errno(-1) == .INTR) {}
    }
    child.release(io) catch unreachable;
    try std.testing.expectEqual(@as(c_int, -1), std.c.waitpid(scope, &status, std.posix.W.NOHANG));
    try std.testing.expectEqual(std.posix.E.CHILD, std.posix.errno(-1));
}

test "a private supervisor has its own session and process group" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var fixture = try Fixture.start(.contain, "--race");
    defer fixture.deinit();
    const scope = fixture.child.state.id;
    try std.testing.expectEqual(scope, getsid(scope));
    try std.testing.expectEqual(scope, getpgid(scope));
    try std.testing.expect(getsid(scope) != getsid(0));
    try std.testing.expect(getpgid(scope) != getpgid(0));
}

test "every catchable supervisor stop ends and reaps its detached adoptee" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    cgroups.testing_hook.off = true;
    defer cgroups.testing_hook.off = false;
    inline for (.{ std.posix.SIG.HUP, std.posix.SIG.INT, std.posix.SIG.QUIT, std.posix.SIG.TERM, std.posix.SIG.TSTP }) |signal| {
        var fixture = try Fixture.start(.contain, "--race");
        defer fixture.deinit();
        try std.testing.expectEqual(@as(c_int, 0), std.c.kill(fixture.child.state.id, signal));
        const term = try fixture.child.waitTimeout(io, budget_ms);
        try std.testing.expectEqual(Child.Term{ .signal = .KILL }, term.?);
        try std.testing.expect(!fixture.daemon.alive());
    }
}

test "a failed private scope release keeps ownership for retry" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const supervisor = @import("../supervisor.zig");
    var fixture = try Fixture.start(.contain, "--race");
    defer fixture.deinit();
    const scope = fixture.child.state.id;
    supervisor.testing_hook.fail_request = true;
    defer supervisor.testing_hook.fail_request = false;
    try std.testing.expectError(error.Unexpected, fixture.release());
    try std.testing.expectEqual(scope, fixture.child.state.id);
    try std.testing.expect(fixture.daemon.alive());
    supervisor.testing_hook.fail_request = false;
    try fixture.release();
    try std.testing.expect(!fixture.daemon.alive());
}

test "a contained Windows wait confirms every Job member ended before returning" {
    if (!windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    inline for (.{ "wait", "tryWait", "output", "Reaper" }) |method| {
        errdefer std.debug.print("contained Windows completion via {s}\n", .{method});
        var fixture = try Fixture.start(.contain, "--exit-7");
        defer fixture.deinit();
        fixture.child.closeStdin(io);
        const term = if (comptime std.mem.eql(u8, method, "tryWait")) term: {
            const deadline: Deadline = .in(io, budget_ms);
            while (deadline.remainingMs(io) > 0) {
                if (try fixture.child.tryWait()) |ended| break :term ended;
                try io.sleep(.fromMilliseconds(2), .awake);
            }
            return error.TestChildDidNotExit;
        } else if (comptime std.mem.eql(u8, method, "output")) term: {
            var output = try fixture.child.output(gpa, io, .{ .timeout_ms = budget_ms });
            defer output.deinit(gpa);
            break :term output.term();
        } else if (comptime std.mem.eql(u8, method, "Reaper")) term: {
            var reaper: Reaper = .init(&fixture.child, .{});
            try reaper.start(io);
            defer reaper.deinit(io);
            break :term (try reaper.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
        } else (try fixture.child.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
        try std.testing.expectEqual(Child.Term{ .exited = 7 }, term);
        try std.testing.expect(!fixture.daemon.alive());
        try std.testing.expect(try fixture.child.waitTree(io, 0));
    }
}
