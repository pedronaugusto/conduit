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
extern "c" fn getpgid(pid: std.posix.pid_t) std.posix.pid_t;
extern "c" fn getsid(pid: std.posix.pid_t) std.posix.pid_t;

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
            .job_limits = if (windows) .{ .active_processes = 4 } else .{},
            .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
        };
        if (policy == .contain) options.descendants = .contain;
        var child = try Child.spawn(io, gpa, options);
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
            var member: win32.BOOL = .FALSE;
            try std.testing.expect(win32.IsProcessInJob(daemon.handle, State.get(&child).job.?, &member) != .FALSE);
            try std.testing.expect(member != .FALSE);
        }
        return .{ .child = child, .daemon = daemon, .tmp = tmp };
    }

    fn deinit(fixture: *Fixture) void {
        _ = fixture.child.killWait(io, 0) catch {};
        fixture.child.release(io) catch unreachable;
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
    inline for (.{ "wait", "tryWait", "output", "Reaper", "exit-7" }) |method| {
        var fixture = try Fixture.start(.survive, if (comptime std.mem.eql(u8, method, "exit-7")) "--exit-7" else "--escape");
        defer fixture.deinit();
        fixture.child.closeStdin(io);
        const term = if (comptime std.mem.eql(u8, method, "tryWait")) term: {
            const deadline: @import("deadline.zig").Deadline = .in(io, budget_ms);
            while (deadline.remainingMs(io) > 0) {
                if (try fixture.child.tryWait()) |term| break :term term;
                try io.sleep(.fromMilliseconds(2), .awake);
            }
            return error.TestChildDidNotExit;
        } else if (comptime std.mem.eql(u8, method, "output")) term: {
            var output = try fixture.child.output(io, gpa, .{ .timeout_ms = budget_ms });
            defer output.deinit(gpa);
            break :term output.term();
        } else if (comptime std.mem.eql(u8, method, "Reaper")) term: {
            var reaper: @import("Reaper.zig").Reaper = .init(&fixture.child, .{});
            try reaper.start(io);
            defer reaper.deinit(io) catch unreachable;
            break :term (try reaper.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
        } else (try fixture.child.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
        try std.testing.expectEqual(Child.Term{ .exited = if (comptime std.mem.eql(u8, method, "exit-7")) 7 else 0 }, term);
        if (windows) {
            var limits: win32.JOBOBJECT_EXTENDED_LIMIT_INFORMATION = undefined;
            try std.testing.expect(win32.QueryInformationJobObject(State.get(&fixture.child).job.?, win32.JobObjectExtendedLimitInformation, &limits, @sizeOf(@TypeOf(limits)), null) != .FALSE);
            try std.testing.expectEqual(@as(u32, 4), limits.BasicLimitInformation.ActiveProcessLimit);
            try std.testing.expect(limits.BasicLimitInformation.LimitFlags & win32.JOB_OBJECT_LIMIT_ACTIVE_PROCESS != 0);
            try std.testing.expect(limits.BasicLimitInformation.LimitFlags & win32.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE == 0);
        }
        fixture.child.release(io) catch unreachable;
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
            defer reaper.deinit(io) catch unreachable;
            try std.testing.expect(Child.succeeded((try reaper.waitTimeout(io, budget_ms)).?));
        }
        fixture.child.release(io) catch unreachable;
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
            fixture.child.release(io) catch unreachable;
            try fixture.expectEnded();
        }
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
            try std.testing.expect(getpgid(pid) != State.get(&fixture.child).pgid.?);
            try std.testing.expect(getsid(pid) != fixture.child.processId().?);
            try std.testing.expect(getsid(pid) != pid);
        }
        // The intermediate remains alive until EOF. Wait for all three
        // registrations, so this tests retained lineage under any scheduler;
        // immediate parent exit is measured separately below.
        if (builtin.os.tag == .macos) {
            const tracker = State.get(&fixture.child).lineage.?;
            const deadline: @import("deadline.zig").Deadline = .in(io, budget_ms);
            while (tracker.observed.load(.acquire) < 3 and deadline.remainingMs(io) > 0)
                try io.sleep(.fromMilliseconds(2), .awake);
            try std.testing.expect(tracker.observed.load(.acquire) >= 3);
        }
        fixture.child.closeStdin(io);
        if (comptime std.mem.eql(u8, method, "tryWait")) {
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
        } else if (comptime std.mem.eql(u8, method, "Reaper")) {
            var reaper: @import("Reaper.zig").Reaper = .init(&fixture.child, .{});
            try reaper.start(io);
            defer reaper.deinit(io) catch unreachable;
            try std.testing.expect(Child.succeeded((try reaper.waitTimeout(io, budget_ms)).?));
        } else try std.testing.expect(Child.succeeded((try fixture.child.waitTimeout(io, budget_ms)).?));
        fixture.child.release(io) catch unreachable;
        try fixture.expectEnded();
    }
}

test "Darwin measures the fork then exit registration race" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const attempts = 100;
    const hook = &@import("lineage.zig").testing_hook.delay_ms;
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
        if (delay_ms != 0) try std.testing.expect(escapes > 0);
    }
}

test "a Reaper subreaper ends and reaps a detached orphan without stealing another child" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const Reaper = @import("Reaper.zig").Reaper;
    const cgroups = @import("cgroup.zig");
    cgroups.testing_hook.off = true;
    defer cgroups.testing_hook.off = false;
    var fixture: Fixture = undefined;
    var reaper: Reaper = .init(&fixture.child, .{});
    // Activation precedes spawn: an intermediate can exit before start runs.
    try reaper.enableSubreaper();
    errdefer reaper.deinit(io) catch unreachable;
    fixture = try Fixture.start(.contain, "--double-fork");
    defer fixture.deinit();
    defer reaper.deinit(io) catch unreachable;
    var unrelated = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "read x; exit 7" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer unrelated.release(io) catch unreachable;
    defer _ = unrelated.killWait(io, 0) catch {};
    try std.testing.expect(!State.get(&fixture.child).cgroup.active());
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
    const cgroups = @import("cgroup.zig");
    cgroups.testing_hook.off = true;
    defer cgroups.testing_hook.off = false;
    var fixture: Fixture = undefined;
    var reaper: @import("Reaper.zig").Reaper = .init(&fixture.child, .{});
    try reaper.enableSubreaper();
    errdefer reaper.deinit(io) catch unreachable;
    fixture = try Fixture.start(.survive, "--race");
    const held = fixture.child.holdReap().?;
    var holding = true;
    defer {
        if (holding) held.release();
        reaper.stop(io, 0);
        _ = fixture.child.killWait(io, 0) catch {};
        reaper.deinit(io) catch unreachable;
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
    const deadline: @import("deadline.zig").Deadline = .in(io, budget_ms);
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
    const cgroups = @import("cgroup.zig");
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
        var child = try Child.spawn(io, gpa, .{ .argv = &.{ "/bin/sh", "-c", script }, .descendants = .contain, .stdio = .ignore });
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
    const cgroups = @import("cgroup.zig");
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
    try std.testing.expect(!try tree.endRecorded(io, .{ .pid = first.child.processId().?, .start = 0, .supervisor = wrong, .grace_ms = 0 }));
    try std.testing.expect(first.daemon.alive());
    try std.testing.expect(try tree.endRecorded(io, .{ .pid = first.child.processId().?, .start = 0, .supervisor = record.supervisor, .grace_ms = 0 }));
    try std.testing.expectEqual(Child.Term{ .signal = .KILL }, (try first.child.waitTimeout(io, budget_ms)).?);
    try first.expectEnded();
    try std.testing.expect(second.daemon.alive());
}

test "a failed contained exec leaves no private supervisor to wait for" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    try std.testing.expectError(error.FileNotFound, Child.spawn(io, gpa, .{
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
    var child = try Child.spawn(io, gpa, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .descendants = .contain,
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    const scope = State.get(&child).id;
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
    const scope = State.get(&fixture.child).id;
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
    const cgroups = @import("cgroup.zig");
    cgroups.testing_hook.off = true;
    defer cgroups.testing_hook.off = false;
    inline for (.{ std.posix.SIG.HUP, std.posix.SIG.INT, std.posix.SIG.QUIT, std.posix.SIG.TERM, std.posix.SIG.TSTP }) |signal| {
        var fixture = try Fixture.start(.contain, "--race");
        defer fixture.deinit();
        try std.testing.expectEqual(@as(c_int, 0), std.c.kill(State.get(&fixture.child).id, signal));
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
    const supervisor = @import("supervisor.zig");
    var fixture = try Fixture.start(.contain, "--race");
    defer fixture.deinit();
    const scope = State.get(&fixture.child).id;
    supervisor.testing_hook.fail_request = true;
    defer supervisor.testing_hook.fail_request = false;
    const Release = struct {
        fn run(child: *Child) !void {
            if (@hasDecl(Child, "release")) try child.release(io) else child.deinit(io);
        }
    };
    try std.testing.expectError(error.Unexpected, Release.run(&fixture.child));
    try std.testing.expectEqual(scope, State.get(&fixture.child).id);
    try std.testing.expect(fixture.daemon.alive());
    supervisor.testing_hook.fail_request = false;
    try Release.run(&fixture.child);
    try std.testing.expect(State.optional(&fixture.child) == null);
    try std.testing.expect(!fixture.daemon.alive());
}

test "a contained Windows wait confirms every Job member ended before returning" {
    if (!windows) return error.SkipZigTest;
    var watchdog: Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    inline for (.{ "wait", "tryWait", "output", "Reaper" }) |method| {
        var fixture = try Fixture.start(.contain, "--exit-7");
        defer fixture.deinit();
        fixture.child.closeStdin(io);
        const term = if (comptime std.mem.eql(u8, method, "tryWait")) term: {
            const deadline: @import("deadline.zig").Deadline = .in(io, budget_ms);
            while (deadline.remainingMs(io) > 0) {
                if (try fixture.child.tryWait()) |ended| break :term ended;
                try io.sleep(.fromMilliseconds(2), .awake);
            }
            return error.TestChildDidNotExit;
        } else if (comptime std.mem.eql(u8, method, "output")) term: {
            var output = try fixture.child.output(io, gpa, .{ .timeout_ms = budget_ms });
            defer output.deinit(gpa);
            break :term output.term();
        } else if (comptime std.mem.eql(u8, method, "Reaper")) term: {
            var reaper: @import("Reaper.zig").Reaper = .init(&fixture.child, .{});
            try reaper.start(io);
            defer reaper.deinit(io) catch unreachable;
            break :term (try reaper.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
        } else (try fixture.child.waitTimeout(io, budget_ms)) orelse return error.TestChildDidNotExit;
        try std.testing.expectEqual(Child.Term{ .exited = 7 }, term);
        try std.testing.expect(!fixture.daemon.alive());
        try std.testing.expect(try fixture.child.waitTree(io, 0));
    }
}
