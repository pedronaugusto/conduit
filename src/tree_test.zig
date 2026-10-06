const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const c = std.c;
const is_windows = builtin.os.tag == .windows;
const access = @import("tree.zig").test_access;
const Deadline = access.Deadline;
const wait_for = access.wait_for;
const Dirents = @import("tree.zig").Dirents;
const signalDescendants = @import("tree.zig").signalDescendants;
const signalDescendantsGuarded = access.signalDescendantsGuarded;
const waitCaptured = access.waitCaptured;
const provenBelow = access.provenBelow;
const parentOf = access.parentOf;
const collect = access.collect;
const collectLinux = access.collectLinux;
const LinuxRelation = access.LinuxRelation;
const processRelationLinux = access.processRelationLinux;
const parseLinuxStat = access.parseLinuxStat;
const startTime = @import("tree.zig").startTime;
const captureStarted = @import("tree.zig").captureStarted;
const captureStartedProcess = access.captureStartedProcess;
const killRecorded = @import("tree.zig").killRecorded;
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
const hasChildren = @import("tree.zig").hasChildren;
const DarwinForks = access.DarwinForks;
const NoForks = access.NoForks;
const Members = @import("tree.zig").Members;
const members = @import("tree.zig").members;
const test_options = @import("conduit_test_options");
const membersLinux = access.membersLinux;
const membersDarwin = access.membersDarwin;
test "a descendant snapshot cannot authorize a signal to an unrelated captured identity" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    const testing = std.testing;
    const io = testing.io;
    const Child = @import("child.zig").Child;
    const options: Child.SpawnOptions = .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    };
    var root = try Child.spawn(testing.allocator, io, options);
    defer root.release(io) catch unreachable;
    defer _ = root.killWait(io, 0) catch {};
    var witness = try Child.spawn(testing.allocator, io, options);
    defer witness.release(io) catch unreachable;
    defer _ = witness.killWait(io, 0) catch {};

    // A listed descendant could have been reaped and its pid reused before
    // capture. Retain a live witness in that snapshot: its stable identity
    // alone proves nothing about its relation to the root.
    access.snapshot(witness.state.id);
    defer access.snapshot(null);
    try testing.expectEqual(@as(usize, 0), try signalDescendants(root.state.id, .CONT, null));
    var captured = access.capture(root.state.id).?;
    defer captured.deinit();
    try testing.expectEqual(@as(usize, 0), try captured.signalDescendants(.CONT, null));
}

test "a group member held before KILL is accounted for while still visible" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    const Child = @import("child.zig").Child;
    var child = try Child.spawn(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30 & echo $!; wait" },
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
        .detach = true,
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};
    var buffer: [32]u8 = undefined;
    var output = child.stdoutFile().?.reader(testing.io, &buffer);
    const descendant = try std.fmt.parseInt(posix.pid_t, (try output.interface.takeDelimiter('\n')).?, 10);
    const since = (try startTime(child.state.id)).?;
    const descendant_start = (try startTime(descendant)).?;
    try testing.expectEqual(@as(usize, 1), try signalGroupSinceImpl(child.state.id, child.state.id, since, @enumFromInt(0), &.{}));
    try testing.expectEqual(@as(usize, 0), try signalGroupSinceImpl(child.state.id, child.state.id, since, @enumFromInt(0), &.{.{ .pid = descendant, .start = descendant_start }}));
    try testing.expectEqual(@as(usize, 1), try signalGroupSinceImpl(child.state.id, child.state.id, since, @enumFromInt(0), &.{.{ .pid = descendant, .start = descendant_start +% 1 }}));
}

test "the descendants of this process include a child it just started" {
    const testing = std.testing;
    const Child = @import("child.zig").Child;
    // The systems that cannot answer answer nothing, which is correct and not
    // something to assert a pid against.
    const can_list = builtin.os.tag == .linux or switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
        else => false,
    };
    if (!can_list) return error.SkipZigTest;

    var child = try Child.spawn(testing.allocator, testing.io, .{
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
    try collect(allocator, c.getpid(), null, &found);
    for (found.items) |process| {
        if (process.pid == child.state.id) return;
    }
    return error.TestChildWasNotFound;
}

test "a group is empty but for its leader once what the leader started has ended" {
    const testing = std.testing;
    const Child = @import("child.zig").Child;
    const can_list = builtin.os.tag == .linux or switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
        else => false,
    };
    if (!can_list) return error.SkipZigTest;

    // The shell leads the group, and the `sleep` it starts is in it.
    var child = try Child.spawn(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30 & read x; kill $!; wait" },
        // The shell reports the job it killed on its standard error.
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
        .detach = true,
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};
    const pgid = child.state.pgid.?;

    var deadline: Deadline = .in(testing.io, 5000);
    while (members(pgid, child.state.id) != .others) {
        if (deadline.remainingMs(testing.io) == 0) return error.TestMemberNotSeen;
        try std.Io.sleep(testing.io, .fromMilliseconds(2), .awake);
    }
    child.closeStdin(testing.io);
    deadline = .in(testing.io, 5000);
    while (members(pgid, child.state.id) != .none) {
        if (deadline.remainingMs(testing.io) == 0) return error.TestMemberStayed;
        try std.Io.sleep(testing.io, .fromMilliseconds(2), .awake);
    }
}

test "a Linux process with a child of its own is said to have one, and one without is not" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    const Child = @import("child.zig").Child;

    var leaf = try Child.spawn(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdio = .ignore,
    });
    defer leaf.deinit(testing.io);
    defer _ = leaf.killWait(testing.io, 0) catch {};
    try testing.expect(!hasChildren(leaf.state.id));

    // The `;` keeps the shell from replacing itself with `sleep`.
    var parent = try Child.spawn(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30; :" },
        .stdio = .ignore,
    });
    defer parent.deinit(testing.io);
    defer _ = parent.killWait(testing.io, 0) catch {};
    const deadline: Deadline = .in(testing.io, 5000);
    while (!hasChildren(parent.state.id)) {
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

    const Child = @import("child.zig").Child;
    var child = try Child.spawn(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.deinit(testing.io);
    const pid = child.state.id;
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
    const Child = @import("child.zig").Child;
    var child = try Child.spawn(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};
    const started = (try startTime(child.state.id)).?;
    try testing.expect((try captureStarted(child.state.id, started + 1)) == null);
    try testing.expect((try captureStarted(child.state.id, started -% 1)) == null);
    var captured = (try captureStarted(child.state.id, started)).?;
    defer captured.deinit();
    try testing.expectEqual(child.state.id, captured.processId());
    try testing.expect(captured.alive());
    if (builtin.os.tag == .macos) {
        try testing.expectError(error.Unsupported, captured.signalGroupSince(child.state.id, started, .CONT));
    }
    // A signal the shell's default action ignores, sent through the capture.
    try testing.expect(captured.signal(.CONT));
    child.stdinFile().?.close(testing.io);
    _ = child.takeStdin();
    _ = try child.wait(testing.io);
    // Ended and reaped: the capture reaches nothing, whoever has the number.
    try testing.expect(!captured.alive());
    try testing.expect(!captured.signal(.CONT));
    try testing.expect((try captureStarted(child.state.id, started)) == null);
}

test "a captured pid wait expires while it runs and wakes when it ends" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }
    const testing = std.testing;
    const Child = @import("child.zig").Child;
    var child = try Child.spawn(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdio = .ignore,
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};
    const since = (try startTime(child.state.id)).?;
    var captured = (try captureStarted(child.state.id, since)).?;
    defer captured.deinit();
    if (try captured.wait(testing.io, 20)) return error.TestCapturedWaitEndedTooSoon;
    try testing.expect(captured.signal(.TERM));
    if (!try captured.wait(testing.io, 5000)) return error.TestCapturedWaitMissedExit;
    _ = try child.wait(testing.io);
}

test "killRecorded waits for a recorded root and a descendant it captured" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }
    const testing = std.testing;
    const Child = @import("child.zig").Child;
    var child = try Child.spawn(testing.allocator, testing.io, .{
        .argv = &.{test_options.tree_fixture},
        .stdio = .{ .streams = .{ .stdin = .ignore, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};
    var buffer: [32]u8 = undefined;
    var output = child.stdoutFile().?.reader(testing.io, &buffer);
    const descendant = try std.fmt.parseInt(posix.pid_t, (try output.interface.takeDelimiter('\n')).?, 10);
    const since = (try startTime(child.state.id)).?;
    var stage: []const u8 = "rejecting a mismatched start time";
    errdefer |err| std.debug.print("recorded tree: {s} failed with {s}; root {d} start {?d}, descendant {d} start {?d}\n", .{
        stage,      @errorName(err),                  child.state.id, startTime(child.state.id) catch null,
        descendant, startTime(descendant) catch null,
    });
    var captured = (try captureStarted(descendant, (try startTime(descendant)).?)).?;
    defer captured.deinit();
    defer _ = captured.signal(.KILL);
    try testing.expect(!try killRecorded(testing.io, .{ .pid = child.state.id, .start = since +% 1, .grace_ms = 20 }));
    try testing.expect((try startTime(child.state.id)) != null);
    stage = "ending the recorded tree";
    try testing.expect(try killRecorded(testing.io, .{ .pid = child.state.id, .start = since, .grace_ms = 20 }));
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
    const Child = @import("child.zig").Child;
    var child = try Child.spawn(testing.allocator, testing.io, .{
        .argv = &.{ test_options.tree_fixture, "--fail-report" },
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
    const Child = @import("child.zig").Child;
    // The leader waits on its input, so it is still running when its start
    // time is read, and ends when that input closes.
    var leader = try Child.spawn(testing.allocator, testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30 & echo $!; read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
        .detach = true,
    });
    defer leader.deinit(testing.io);
    defer _ = leader.killWait(testing.io, 0) catch {};
    const group = leader.state.pgid.?;
    const since = (try startTime(leader.state.id)).?;
    var captured = (try captureStarted(leader.state.id, since)).?;
    defer captured.deinit();
    var buffer: [32]u8 = undefined;
    var output = leader.stdoutFile().?.reader(testing.io, &buffer);
    const member = try std.fmt.parseInt(posix.pid_t, (try output.interface.takeDelimiter('\n')).?, 10);
    try testing.expectEqual(@as(usize, 1), try captured.signalGroupSince(group, since, .CONT));
    errdefer {
        if (members(group, leader.state.id) == .others) _ = c.kill(-group, .KILL);
    }
    leader.closeStdin(testing.io);
    _ = try leader.wait(testing.io);
    try testing.expectEqual(Members.others, members(group, leader.state.id));
    try testing.expectEqual(@as(usize, 1), try signalGroupSince(group, leader.state.id, since, .KILL));
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
    const Child = @import("child.zig").Child;
    var child = try Child.spawn(testing.allocator, io, .{
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
    const Child = @import("child.zig").Child;
    var child = try Child.spawn(testing.allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", "echo before; read x; exec /bin/sh -c 'echo after; read x'" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.release(io) catch unreachable;
    defer _ = child.killWait(io, 0) catch {};
    var buffer: [64]u8 = undefined;
    var reader = child.stdoutFile().?.reader(io, &buffer);
    try testing.expectEqualStrings("before", (try reader.interface.takeDelimiter('\n')).?);
    var process = DarwinProcess.capture(child.processId().?).?;
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
    const Child = @import("child.zig").Child;
    var child = try Child.spawn(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.release(std.testing.io) catch unreachable;
    defer _ = child.killWait(std.testing.io, 0) catch {};
    const held = DarwinProcess.capture(child.state.id).?;
    var parent = DarwinProcess.capture(c.getpid()).?;
    try std.testing.expect(held.childOf(&parent));
    parent.unique_id +%= 1;
    try std.testing.expect(!held.childOf(&parent));
    parent = held;
    try std.testing.expect(!held.childOf(&parent));
}

//======================================================================
// The kernel's records, over generated input.
//======================================================================

/// A `/proc/<pid>/stat` record around a command name that can hold
/// anything a name can -- spaces, parentheses, what looks like the fields
/// after it -- read back field by field.
fn statReadsBack(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;
    var record: std.ArrayList(u8) = .empty;
    defer record.deinit(std.testing.allocator);
    const gpa = std.testing.allocator;

    const pieces = [_][]const u8{ "a", " ", ")", "(", ") S 1 2 3 4", "\n", "\xff", "0", "-1", ") " };
    try record.print(gpa, "{d} (", .{smith.value(u16)});
    while (!smith.eosWeightedSimple(2, 1)) try record.appendSlice(gpa, pieces[smith.index(pieces.len)]);
    const states = "RSDZTtWXxKPI";
    const state = states[smith.index(states.len)];
    const ppid: posix.pid_t = smith.valueRangeAtMost(i32, 0, std.math.maxInt(i32));
    const pgrp: posix.pid_t = smith.valueRangeAtMost(i32, 0, std.math.maxInt(i32));
    const session: posix.pid_t = smith.valueRangeAtMost(i32, 0, std.math.maxInt(i32));
    const start = smith.value(u64);
    try record.print(gpa, ") {c} {d} {d} {d}", .{ state, ppid, pgrp, session });
    // Fields 7 to 21, some of them negative, then the start time and the
    // fields after it -- unless the record stops short.
    const fields = smith.valueRangeAtMost(u8, 0, 18);
    for (7..7 + @as(usize, fields)) |field| {
        if (field == 22) {
            try record.print(gpa, " {d}", .{start});
        } else try record.print(gpa, " {d}", .{smith.value(i32)});
    }
    // The kernel ends the record with a newline after its last field, which
    // is well past the ones read here.
    if (7 + @as(usize, fields) > 23 and smith.boolWeighted(1, 1)) try record.append(gpa, '\n');

    const relation = parseLinuxStat(record.items) orelse return error.TestExpectedRelation;
    try std.testing.expectEqual(state, relation.state);
    try std.testing.expectEqual(ppid, relation.ppid);
    try std.testing.expectEqual(pgrp, relation.pgrp);
    try std.testing.expectEqual(session, relation.session);
    try std.testing.expectEqual(if (7 + @as(usize, fields) > 22) @as(?u64, start) else null, relation.start);

    // Any bytes at all are a relation or none, and never a crash.
    var junk: [64]u8 = undefined;
    _ = parseLinuxStat(junk[0..smith.slice(&junk)]);
}

test "a stat record reads back whatever its command name holds" {
    try std.testing.fuzz({}, statReadsBack, .{});
}

/// What `getdents64` wrote, or bytes that only look like it: every name
/// comes from inside the bytes, holds no NUL, and the walk ends.
fn direntsStayInside(_: void, smith: *std.testing.Smith) anyerror!void {
    @disableInstrumentation();
    const reclen_at = @offsetOf(std.os.linux.dirent64, "reclen");
    const name_at = @offsetOf(std.os.linux.dirent64, "name");
    const endian = builtin.cpu.arch.endian();
    var bytes: [256]u8 = @splat(0);
    var end: usize = 0;
    while (end + name_at < bytes.len and !smith.eosWeightedSimple(3, 1)) {
        if (smith.boolWeighted(3, 1)) {
            // A record as the kernel writes one: its length rounded up to
            // eight, its name NUL-terminated.
            var name: [24]u8 = undefined;
            const len = smith.sliceWeightedBytes(&name, &.{.rangeAtMost(u8, 1, 255, 1)});
            const reclen = std.mem.alignForward(usize, name_at + len + 1, 8);
            if (end + reclen > bytes.len) break;
            std.mem.writeInt(u16, bytes[end + reclen_at ..][0..2], @intCast(reclen), endian);
            @memcpy(bytes[end + name_at ..][0..len], name[0..len]);
            end += reclen;
        } else {
            end += smith.slice(bytes[end..]);
        }
    }
    var names: Dirents = .{ .bytes = bytes[0..end] };
    var seen: usize = 0;
    while (names.next()) |name| {
        seen += 1;
        try std.testing.expect(seen <= end / (name_at + 1));
        try std.testing.expect(@intFromPtr(name.ptr) >= @intFromPtr(&bytes) and
            @intFromPtr(name.ptr) + name.len <= @intFromPtr(&bytes) + end);
        try std.testing.expect(std.mem.findScalar(u8, name, 0) == null);
    }
}

test "getdents64 records are read from inside what was read" {
    try std.testing.fuzz({}, direntsStayInside, .{});
}

test "the stat and dirent properties hold over seeded rounds" {
    var prng: std.Random.DefaultPrng = .init(0x57a7);
    var bytes: [256]u8 = undefined;
    for (0..256) |i| {
        for (&bytes) |*byte| byte.* = switch (prng.random().uintLessThan(u8, 10)) {
            0...6 => 0,
            7, 8 => prng.random().uintLessThan(u8, 16),
            else => prng.random().int(u8),
        };
        inline for (.{ statReadsBack, direntsStayInside }) |property| {
            var smith: std.testing.Smith = .{ .in = &bytes };
            property({}, &smith) catch |err| switch (err) {
                error.SkipZigTest => {},
                else => {
                    std.debug.print("seeded round {d}: {t}\n", .{ i, err });
                    return err;
                },
            };
        }
    }
}
