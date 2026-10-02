const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const is_windows = builtin.os.tag == .windows;
const State = @import("child_state.zig");
const access = @import("tree.zig").test_access;
const Deadline = access.Deadline;
const wait_for = access.wait_for;
const Dirents = @import("tree.zig").Dirents;
const signalDescendants = @import("tree.zig").signalDescendants;
const forceHeldGroup = @import("tree.zig").forceHeldGroup;
const signalDescendantsGuarded = access.signalDescendantsGuarded;
const waitCaptured = access.waitCaptured;
const provenBelow = access.provenBelow;
const parentOf = access.parentOf;
const collect = access.collect;
const collectLinux = access.collectLinux;
const LinuxRelation = access.LinuxRelation;
const processRelationLinux = access.processRelationLinux;
const parseLinuxStat = access.parseLinuxStat;
const adoptionRecord = @import("tree.zig").adoptionRecord;
const startTime = @import("tree.zig").startTime;
const CapturedPid = @import("tree.zig").CapturedPid;
const captureStarted = @import("tree.zig").captureStarted;
const captureStartedProcess = access.captureStartedProcess;
const RecordedOptions = @import("tree.zig").RecordedOptions;
const endRecorded = @import("tree.zig").endRecorded;
const killHeld = access.killHeld;
const signalGroupSince = @import("tree.zig").signalGroupSince;
const Started = access.Started;
const signalGroupSinceImpl = access.signalGroupSinceImpl;
const ProcBsdInfo = access.ProcBsdInfo;
const proc_pidtbsdinfo = access.proc_pidtbsdinfo;
const proc_status_zombie = access.proc_status_zombie;
const captureChildren = access.captureChildren;
const Process = access.Process;
const LinuxProcess = access.LinuxProcess;
const AuditToken = access.AuditToken;
const DarwinProcess = @import("tree.zig").DarwinProcess;
const BsdInfoWithUniqueId = access.BsdInfoWithUniqueId;
const proc_pidt_bsdinfowithuniqid = access.proc_pidt_bsdinfowithuniqid;
const ProcUniqueInfo = access.ProcUniqueInfo;
const NoProcess = access.NoProcess;
const proc_pid_unique_info = access.proc_pid_unique_info;
const childrenOf = access.childrenOf;
const childrenOfNobody = access.childrenOfNobody;
const childrenOfDarwin = access.childrenOfDarwin;
const observedChildrenOfDarwin = @import("tree.zig").observedChildrenOfDarwin;
const knows_leaves = @import("tree.zig").knows_leaves;
const hasChildren = @import("tree.zig").hasChildren;
const Forks = @import("tree.zig").Forks;
const DarwinForks = access.DarwinForks;
const testing_hook = @import("tree.zig").testing_hook;
const NoForks = access.NoForks;
const Members = @import("tree.zig").Members;
const members = @import("tree.zig").members;
const membersLinux = access.membersLinux;
const membersDarwin = access.membersDarwin;
test "a descendant snapshot cannot authorize a signal to an unrelated captured identity" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var watchdog: @import("test_support.zig").Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const Child = @import("Child.zig").Child;
    const options: Child.SpawnOptions = .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    };
    var root = try Child.spawn(io, testing.allocator, options);
    defer root.release(io) catch unreachable;
    defer _ = root.killWait(io, 0) catch {};
    var witness = try Child.spawn(io, testing.allocator, options);
    defer witness.release(io) catch unreachable;
    defer _ = witness.killWait(io, 0) catch {};

    // A listed descendant could have been reaped and its pid reused before
    // capture. Retain a live witness in that snapshot: its stable identity
    // alone proves nothing about its relation to the root.
    access.snapshot(State.get(&witness).id);
    defer access.snapshot(null);
    try testing.expectEqual(@as(usize, 0), try signalDescendants(State.get(&root).id, .CONT, null));
    var captured = access.capture(State.get(&root).id).?;
    defer captured.deinit();
    try testing.expectEqual(@as(usize, 0), try captured.signalDescendants(.CONT, null));
}

test "a group member held before KILL is accounted for while still visible" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    const Child = @import("Child.zig").Child;
    var child = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30 & echo $!; wait" },
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
        .detach = true,
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};
    var buffer: [32]u8 = undefined;
    var output = child.stdoutFile().?.reader(testing.io, &buffer);
    const descendant = try std.fmt.parseInt(posix.pid_t, (try output.interface.takeDelimiter('\n')).?, 10);
    const since = (try startTime(State.get(&child).id)).?;
    const descendant_start = (try startTime(descendant)).?;
    try testing.expectEqual(@as(usize, 1), try signalGroupSinceImpl(State.get(&child).id, State.get(&child).id, since, @enumFromInt(0), &.{}));
    try testing.expectEqual(@as(usize, 0), try signalGroupSinceImpl(State.get(&child).id, State.get(&child).id, since, @enumFromInt(0), &.{.{ .pid = descendant, .start = descendant_start }}));
    try testing.expectEqual(@as(usize, 1), try signalGroupSinceImpl(State.get(&child).id, State.get(&child).id, since, @enumFromInt(0), &.{.{ .pid = descendant, .start = descendant_start +% 1 }}));
}

test "the descendants of this process include a child it just started" {
    const testing = std.testing;
    const Child = @import("Child.zig").Child;
    // The systems that cannot answer answer nothing, which is correct and not
    // something to assert a pid against.
    const can_list = builtin.os.tag == .linux or switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
        else => false,
    };
    if (!can_list) return error.SkipZigTest;

    var child = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .stdio = .ignore,
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};

    var found: std.ArrayList(Process) = .empty;
    var storage: [64 * 1024]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = scratch.allocator();
    defer {
        for (found.items) |*process| process.deinit();
        found.deinit(allocator);
    }
    try collect(c.getpid(), null, &found, allocator);
    for (found.items) |process| {
        if (process.pid == State.get(&child).id) return;
    }
    return error.TestChildWasNotFound;
}

test "a group is empty but for its leader once what the leader started has ended" {
    const testing = std.testing;
    const Child = @import("Child.zig").Child;
    const can_list = builtin.os.tag == .linux or switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
        else => false,
    };
    if (!can_list) return error.SkipZigTest;

    // The shell leads the group, and the `sleep` it starts is in it.
    var child = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30 & read x; kill $!; wait" },
        // The shell reports the job it killed on its standard error.
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
        .detach = true,
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};
    const pgid = State.get(&child).pgid.?;

    var deadline: Deadline = .in(testing.io, 5000);
    while (members(pgid, State.get(&child).id) != .others) {
        if (deadline.remainingMs(testing.io) == 0) return error.TestMemberNotSeen;
        try std.Io.sleep(testing.io, .fromMilliseconds(2), .awake);
    }
    child.closeStdin(testing.io);
    deadline = .in(testing.io, 5000);
    while (members(pgid, State.get(&child).id) != .none) {
        if (deadline.remainingMs(testing.io) == 0) return error.TestMemberStayed;
        try std.Io.sleep(testing.io, .fromMilliseconds(2), .awake);
    }
}

test "a Linux process with a child of its own is said to have one, and one without is not" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    const Child = @import("Child.zig").Child;

    var leaf = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdio = .ignore,
    });
    defer leaf.deinit(testing.io);
    defer _ = leaf.killWait(testing.io, 0) catch {};
    try testing.expect(!hasChildren(State.get(&leaf).id));

    // The `;` keeps the shell from replacing itself with `sleep`.
    var parent = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30; :" },
        .stdio = .ignore,
    });
    defer parent.deinit(testing.io);
    defer _ = parent.killWait(testing.io, 0) catch {};
    const deadline: Deadline = .in(testing.io, 5000);
    while (!hasChildren(State.get(&parent).id)) {
        if (deadline.remainingMs(testing.io) == 0) return error.TestChildNotSeen;
        try std.Io.sleep(testing.io, .fromMilliseconds(2), .awake);
    }

    // Nothing to read is not "nothing below it": the answer is the walk.
    try testing.expect(hasChildren(std.math.maxInt(posix.pid_t)));
}

test "a process's start time is its own: the same while it runs, gone once it is reaped" {
    const testing = std.testing;
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }
    const own = (try startTime(c.getpid())).?;
    try std.testing.expectEqual(own, (try startTime(c.getpid())).?);

    const Child = @import("Child.zig").Child;
    var child = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.deinit(testing.io);
    const pid = State.get(&child).id;
    const started = (try startTime(pid)).?;
    try std.testing.expectEqual(started, (try startTime(pid)).?);
    // a process started after this one did not start before it
    try std.testing.expect(started >= own);
    child.stdinFile().?.close(testing.io);
    _ = child.takeStdin();
    _ = try child.wait(testing.io);
    try std.testing.expectEqual(@as(?u64, null), try startTime(pid));
}

test "a captured pid stays bound to the recorded process, and a start time that does not match refuses" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }
    const testing = std.testing;
    const Child = @import("Child.zig").Child;
    var child = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};
    const started = (try startTime(State.get(&child).id)).?;
    try testing.expect((try captureStarted(State.get(&child).id, started + 1)) == null);
    try testing.expect((try captureStarted(State.get(&child).id, started -% 1)) == null);
    var captured = (try captureStarted(State.get(&child).id, started)).?;
    defer captured.deinit();
    try testing.expectEqual(State.get(&child).id, captured.processId());
    try testing.expect(captured.alive());
    if (builtin.os.tag == .macos) {
        try testing.expectError(error.Unsupported, captured.signalGroupSince(State.get(&child).id, started, .CONT));
    }
    // A signal the shell's default action ignores, sent through the capture.
    try testing.expect(captured.signal(.CONT));
    child.stdinFile().?.close(testing.io);
    _ = child.takeStdin();
    _ = try child.wait(testing.io);
    // Ended and reaped: the capture reaches nothing, whoever has the number.
    try testing.expect(!captured.alive());
    try testing.expect(!captured.signal(.CONT));
    try testing.expect((try captureStarted(State.get(&child).id, started)) == null);
}

test "a captured pid wait expires while it runs and wakes when it ends" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }
    const testing = std.testing;
    const Child = @import("Child.zig").Child;
    var child = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdio = .ignore,
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};
    const since = (try startTime(State.get(&child).id)).?;
    var captured = (try captureStarted(State.get(&child).id, since)).?;
    defer captured.deinit();
    if (try captured.wait(testing.io, 20)) return error.TestCapturedWaitEndedTooSoon;
    try testing.expect(captured.signal(.TERM));
    if (!try captured.wait(testing.io, 5000)) return error.TestCapturedWaitMissedExit;
    _ = try child.wait(testing.io);
}

test "endRecorded waits for a recorded root and a descendant it captured" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }
    const testing = std.testing;
    const Child = @import("Child.zig").Child;
    var child = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{@import("conduit_test_options").tree_fixture},
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};
    var buffer: [32]u8 = undefined;
    var output = child.stdoutFile().?.reader(testing.io, &buffer);
    const descendant = try std.fmt.parseInt(posix.pid_t, (try output.interface.takeDelimiter('\n')).?, 10);
    const since = (try startTime(State.get(&child).id)).?;
    var stage: []const u8 = "rejecting a mismatched start time";
    errdefer |err| std.debug.print("recorded tree: {s} failed with {s}; root {d} start {?d}, descendant {d} start {?d}\n", .{
        stage,      @errorName(err),                  State.get(&child).id, startTime(State.get(&child).id) catch null,
        descendant, startTime(descendant) catch null,
    });
    var captured = (try captureStarted(descendant, (try startTime(descendant)).?)).?;
    defer captured.deinit();
    defer _ = captured.signal(.KILL);
    try testing.expect(!try endRecorded(testing.io, .{ .pid = State.get(&child).id, .start = since +% 1, .grace_ms = 20 }));
    try testing.expect((try startTime(State.get(&child).id)) != null);
    stage = "ending the recorded tree";
    try testing.expect(try endRecorded(testing.io, .{ .pid = State.get(&child).id, .start = since, .grace_ms = 20 }));
    stage = "observing the descendant's exit";
    // Cleanup proves delivery of KILL, which may precede observable exit.
    // Keep the same 20 ms budget when waiting on the held identity.
    if (!try captured.wait(testing.io, 20)) return error.TestDescendantStayed;
    try testing.expect((try startTime(descendant)) == null);
    _ = try child.wait(testing.io);
}

test "a failed tree fixture releases the descendant it still owns" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }
    const testing = std.testing;
    const Child = @import("Child.zig").Child;
    var child = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ @import("conduit_test_options").tree_fixture, "--fail-report" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .pipe } },
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};
    var buffer: [64]u8 = undefined;
    var output = child.stderrFile().?.reader(testing.io, &buffer);
    const descendant = try std.fmt.parseInt(posix.pid_t, (try output.interface.takeDelimiter('\n')).?, 10);
    const since = (try startTime(descendant)) orelse return error.TestFixtureDescendantMissing;
    var held = (try captureStarted(descendant, since)) orelse return error.TestFixtureDescendantMissing;
    defer held.deinit();
    defer _ = held.signal(.KILL);
    try child.stdinFile().?.writeStreamingAll(testing.io, "x");
    try testing.expectEqual(Child.Term{ .exited = 1 }, try child.wait(testing.io));
    if (!try held.wait(testing.io, 20)) return error.TestFixtureLeftDescendant;
}

test "a leaderless Linux group keeps the child its leader started" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    const Child = @import("Child.zig").Child;
    // The leader waits on its input, so it is still running when its start
    // time is read, and ends when that input closes.
    var leader = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30 & echo $!; read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
        .detach = true,
    });
    defer leader.deinit(testing.io);
    defer _ = leader.killWait(testing.io, 0) catch {};
    const group = State.get(&leader).pgid.?;
    const since = (try startTime(State.get(&leader).id)).?;
    var captured = (try captureStarted(State.get(&leader).id, since)).?;
    defer captured.deinit();
    var buffer: [32]u8 = undefined;
    var output = leader.stdoutFile().?.reader(testing.io, &buffer);
    const member = try std.fmt.parseInt(posix.pid_t, (try output.interface.takeDelimiter('\n')).?, 10);
    try testing.expectEqual(@as(usize, 1), try captured.signalGroupSince(group, since, .CONT));
    errdefer {
        if (members(group, State.get(&leader).id) == .others) _ = c.kill(-group, .KILL);
    }
    leader.closeStdin(testing.io);
    _ = try leader.wait(testing.io);
    try testing.expectEqual(Members.others, members(group, State.get(&leader).id));
    try testing.expectEqual(@as(usize, 1), try signalGroupSince(group, State.get(&leader).id, since, .KILL));
    const deadline: Deadline = .in(testing.io, 3000);
    while ((try startTime(member)) != null) {
        if (deadline.remainingMs(testing.io) == 0) return error.TestMemberStayed;
        try testing.io.sleep(.fromMilliseconds(20), .awake);
    }
}

test "a captured process keeps its identity across exec" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var watchdog: @import("test_support.zig").Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const Child = @import("Child.zig").Child;
    var child = try Child.spawn(io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "echo before; read x; exec /bin/sh -c 'echo after; read x'" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var buffer: [64]u8 = undefined;
    var reader = child.stdoutFile().?.reader(io, &buffer);
    try testing.expectEqualStrings("before", (try reader.interface.takeDelimiter('\n')).?);
    const pid = child.processId().?;
    const since = (try startTime(pid)).?;
    var captured = (try captureStarted(pid, since)).?;
    defer captured.deinit();
    try child.stdinFile().?.writeStreamingAll(io, "exec\n");
    try testing.expectEqualStrings("after", (try reader.interface.takeDelimiter('\n')).?);
    try testing.expect(captured.alive());
    try testing.expect(!try captured.wait(io, 0));
    try testing.expect(captured.signal(.STOP));
    try testing.expect(captured.signal(.CONT));
    try testing.expect(captured.signal(.KILL));
    try testing.expect(try captured.wait(io, 5000));
    try testing.expectEqual(Child.Term{ .signal = .KILL }, try child.wait(io));
}

test "Darwin token delivery refreshes after a concurrent exec and refuses a different unique id" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    var watchdog: @import("test_support.zig").Watchdog = .init(@src());
    try watchdog.start(io);
    defer watchdog.deinit(io);
    const Child = @import("Child.zig").Child;
    var child = try Child.spawn(io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "echo before; read x; exec /bin/sh -c 'echo after; read x'" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var buffer: [64]u8 = undefined;
    var reader = child.stdoutFile().?.reader(io, &buffer);
    try testing.expectEqualStrings("before", (try reader.interface.takeDelimiter('\n')).?);
    var process = Darwinaccess.capture(child.processId().?).?;
    const version = access.current(&process).?.unique.id_version;
    const Exec = struct {
        var child_ptr: *Child = undefined;
        var reader_ptr: *std.Io.Reader = undefined;
        var calls: usize = 0;
        fn exec() void {
            access.delivery(null);
            calls += 1;
            child_ptr.stdinFile().?.writeStreamingAll(std.testing.io, "exec\n") catch @panic("fixture input failed");
            const line = reader_ptr.takeDelimiter('\n') catch @panic("fixture output failed");
            std.testing.expectEqualStrings("after", line.?) catch @panic("fixture did not exec");
        }
    };
    Exec.child_ptr = &child;
    Exec.reader_ptr = &reader.interface;
    Exec.calls = 0;
    access.delivery(Exec.exec);
    defer access.delivery(null);
    try testing.expect(process.signal(.CONT));
    try testing.expectEqual(@as(usize, 1), Exec.calls);
    try testing.expect(access.current(&process).?.unique.id_version != version);
    try testing.expect(process.alive());
    var stranger = process;
    stranger.unique_id +%= 1;
    try testing.expect(!stranger.alive());
    try testing.expect(!stranger.signal(.KILL));
    try testing.expect(process.alive());
    try testing.expect(process.signal(.KILL));
    try testing.expectEqual(Child.Term{ .signal = .KILL }, try child.wait(io));
}

test "Darwin lineage proves the captured birth parent rather than its pid" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const Child = @import("Child.zig").Child;
    var child = try Child.spawn(std.testing.io, std.testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.release(std.testing.io) catch unreachable;
    defer _ = child.killWait(std.testing.io, 0) catch {};
    const held = Darwinaccess.capture(State.get(&child).id).?;
    var parent = Darwinaccess.capture(c.getpid()).?;
    try std.testing.expect(held.childOf(&parent));
    parent.unique_id +%= 1;
    try std.testing.expect(!held.childOf(&parent));
    parent = held;
    try std.testing.expect(!held.childOf(&parent));
}
