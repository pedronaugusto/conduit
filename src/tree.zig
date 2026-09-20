//! The descendants of a process, and reaching them with a signal.
//!
//! A process group is the POSIX address for "the child and what it started",
//! and it is the right one almost always. It has two holes. A descendant that
//! calls `setsid` or `setpgid` leaves the group and a signal addressed to the
//! group no longer reaches it. And `kill(-pgid)` is not atomic against a
//! `fork` inside the group: a process started while the signal was being
//! delivered is in the group without having been in it when the signal was
//! sent.
//!
//! This file closes the first hole by asking the operating system who the
//! descendants of a process are, and `Child.kill` closes the second by asking
//! again. What each system can answer is different, and `Child.kill` documents
//! the guarantee that leaves:
//!
//! * **Linux** exposes every process's parent and process group in `/proc`, so
//!   one process-table pass names the whole tree.
//! * **Darwin** has `proc_listchildpids`, which answers the same question.
//! * **The BSDs and illumos** have neither without reading the whole process
//!   table through `sysctl`, so there the process group is the whole of the
//!   reach, as it was.
//!
//! No system names a process that has *both* left the group and been orphaned
//! before anyone looked: an orphan belongs to `init`, and nothing relates it
//! to the child any more.
//!
//! POSIX only. The walk allocates enough storage to name the whole tree, and
//! reports allocation failure rather than silently leaving a suffix of it
//! alive. A process is captured as a stable kernel identity before the walk
//! retains it: a pidfd on Linux and an audit token on Darwin. A PID alone is
//! never used as a later signal target because it may have been recycled by
//! then.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;

/// Sends `sig` to every descendant of `root`, deepest first, and returns how
/// many of them it reached.
///
/// Deepest first because the opposite order orphans: a process signalled
/// before the ones below it leaves them to `init`, where no walk names them
/// and only their process group is left to reach them by.
///
/// `in_group` is the process group `Child.kill` is about to signal on its own,
/// or `null` when it is going to signal the child alone. A descendant that is
/// already in that group is left to it, so the ordinary tree — where nothing
/// has changed its group — gets exactly the one signal it always did.
///
/// Best effort throughout. A descendant this process may not signal, or one
/// that ends between being named and being signalled, is not a failure of the
/// caller's kill: the answer `Child.kill` reports is the one from the child's
/// own signal.
pub fn signalDescendants(root: posix.pid_t, sig: posix.SIG, in_group: ?posix.pid_t) std.mem.Allocator.Error!usize {
    // The ordinary tree fits here and never reaches the page allocator. What
    // may grow without a bound still can: exhausting this storage falls back
    // to pages and reports that failure before a partial pass is sent.
    var scratch = std.heap.stackFallback(16 * 1024, std.heap.page_allocator);
    const allocator = scratch.get();

    var found: std.ArrayList(Process) = .empty;
    defer {
        for (found.items) |*process| process.deinit();
        found.deinit(allocator);
    }
    try collect(root, in_group, &found, allocator);

    var reached: usize = 0;
    var i = found.items.len;
    while (i > 0) {
        i -= 1;
        const process = &found.items[i];
        const pid = process.pid;
        // Nothing this package started can be `init` or this process itself,
        // and a signal to either would be a bug worth refusing rather than
        // sending.
        if (pid <= 1 or pid == c.getpid()) continue;
        if (process.signal(sig)) reached += 1;
    }
    return reached;
}

/// Fills `into` with the descendants of `root`, breadth first, and returns how
/// many there were.
///
/// Breadth first so that the order in the array is by generation, which makes
/// walking it backwards the deepest-first order `signalDescendants` sends in.
fn collect(
    root: posix.pid_t,
    in_group: ?posix.pid_t,
    into: *std.ArrayList(Process),
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    if (comptime builtin.os.tag == .linux) {
        return collectLinux(root, in_group, into, allocator);
    }

    var descendants: std.ArrayList(posix.pid_t) = .empty;
    defer descendants.deinit(allocator);

    try captureChildren(root, in_group, &descendants, into, allocator);
    var expanded: usize = 0;
    while (expanded < descendants.items.len) : (expanded += 1) {
        try captureChildren(descendants.items[expanded], in_group, &descendants, into, allocator);
    }
}

/// Linux exposes the parent and process group in every process's `stat` file.
/// Read the process directory once, then walk the resulting relationships in
/// memory instead of opening every thread's `children` file at every level.
fn collectLinux(
    root: posix.pid_t,
    in_group: ?posix.pid_t,
    into: *std.ArrayList(Process),
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    const Record = struct {
        pid: posix.pid_t,
        ppid: posix.pid_t,
        pgrp: posix.pid_t,
    };

    var records: std.ArrayList(Record) = .empty;
    defer records.deinit(allocator);

    const dir = c.open("/proc", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (dir < 0) return;
    defer _ = c.close(dir);

    var entries: [4096]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    while (true) {
        const rc = std.os.linux.getdents64(dir, &entries, entries.len);
        if (std.os.linux.errno(rc) != .SUCCESS or rc == 0) break;

        var offset: usize = 0;
        while (offset < rc) {
            const entry: *align(1) const std.os.linux.dirent64 = @ptrCast(&entries[offset]);
            offset += entry.reclen;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
            const pid = std.fmt.parseInt(posix.pid_t, name, 10) catch continue;
            const relation = processRelationLinux(pid) orelse continue;
            try records.append(allocator, .{
                .pid = pid,
                .ppid = relation.ppid,
                .pgrp = relation.pgrp,
            });
        }
    }

    var parents: std.ArrayList(posix.pid_t) = .empty;
    defer parents.deinit(allocator);
    try parents.append(allocator, root);

    var expanded: usize = 0;
    while (expanded < parents.items.len) : (expanded += 1) {
        const parent = parents.items[expanded];
        for (records.items) |record| {
            if (record.ppid != parent) continue;
            try parents.append(allocator, record.pid);
            if (in_group) |pgid| if (record.pgrp == pgid) continue;
            var process = Process.capture(record.pid) orelse continue;
            into.append(allocator, process) catch |err| {
                process.deinit();
                return err;
            };
        }
    }
}

const LinuxRelation = struct {
    ppid: posix.pid_t,
    pgrp: posix.pid_t,
};

fn processRelationLinux(pid: posix.pid_t) ?LinuxRelation {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/stat", .{pid}) catch return null;
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = c.close(fd);

    var text: [4096]u8 = undefined;
    const n = c.read(fd, &text, text.len);
    if (n <= 0) return null;
    return parseLinuxStat(text[0..@intCast(n)]);
}

fn parseLinuxStat(text: []const u8) ?LinuxRelation {
    // The command name is parenthesized and may itself contain spaces or a
    // closing parenthesis. The final one is the separator before the state,
    // parent and process-group fields.
    const close = std.mem.lastIndexOfScalar(u8, text, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    _ = fields.next() orelse return null; // state
    const ppid = std.fmt.parseInt(posix.pid_t, fields.next() orelse return null, 10) catch return null;
    const pgrp = std.fmt.parseInt(posix.pid_t, fields.next() orelse return null, 10) catch return null;
    return .{ .ppid = ppid, .pgrp = pgrp };
}

fn captureChildren(
    parent: posix.pid_t,
    in_group: ?posix.pid_t,
    descendants: *std.ArrayList(posix.pid_t),
    into: *std.ArrayList(Process),
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    const first = descendants.items.len;
    try childrenOf(parent, descendants, allocator);
    for (descendants.items[first..]) |pid| {
        // The group signal is already a stable address for this process. Only
        // an escapee needs a separate identity retained for the later signal.
        if (in_group) |pgid| if (getpgid(pid) == pgid) continue;
        var process = Process.capture(pid) orelse continue;
        into.append(allocator, process) catch |err| {
            process.deinit();
            return err;
        };
    }
}

const Process = switch (builtin.os.tag) {
    .linux => LinuxProcess,
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => DarwinProcess,
    else => NoProcess,
};

const LinuxProcess = struct {
    pid: posix.pid_t,
    pidfd: std.os.linux.fd_t,

    fn capture(pid: posix.pid_t) ?LinuxProcess {
        const rc = std.os.linux.pidfd_open(pid, 0);
        if (std.os.linux.errno(rc) != .SUCCESS) return null;
        return .{ .pid = pid, .pidfd = @intCast(rc) };
    }

    fn signal(process: *const LinuxProcess, sig: posix.SIG) bool {
        const rc = std.os.linux.pidfd_send_signal(process.pidfd, sig, null, 0);
        return std.os.linux.errno(rc) == .SUCCESS;
    }

    fn deinit(process: *LinuxProcess) void {
        _ = std.os.linux.close(process.pidfd);
    }
};

const AuditToken = extern struct { val: [8]c_uint };

const DarwinProcess = struct {
    pid: posix.pid_t,
    token: AuditToken,

    fn capture(pid: posix.pid_t) ?DarwinProcess {
        var info: ProcUniqueInfo = undefined;
        const written = proc_pidinfo(pid, proc_pid_unique_info, 0, &info, @sizeOf(ProcUniqueInfo));
        if (written != @sizeOf(ProcUniqueInfo)) return null;
        var token: AuditToken = .{ .val = @splat(0) };
        token.val[5] = @bitCast(pid);
        token.val[7] = @bitCast(info.id_version);
        return .{ .pid = pid, .token = token };
    }

    fn signal(process: *const DarwinProcess, sig: posix.SIG) bool {
        var token = process.token;
        return proc_signal_with_audittoken(&token, @intCast(@intFromEnum(sig))) == 0;
    }

    fn deinit(process: *DarwinProcess) void {
        _ = process;
    }
};

const ProcUniqueInfo = extern struct {
    executable_uuid: [16]u8,
    unique_id: u64,
    parent_unique_id: u64,
    id_version: i32,
    reserved2: u32,
    reserved3: u64,
    reserved4: u64,
};

const NoProcess = struct {
    pid: posix.pid_t,

    fn capture(pid: posix.pid_t) ?NoProcess {
        _ = pid;
        return null;
    }

    fn signal(process: *const NoProcess, sig: posix.SIG) bool {
        _ = process;
        _ = sig;
        return false;
    }

    fn deinit(process: *NoProcess) void {
        _ = process;
    }
};

const proc_pid_unique_info = 17;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, size: c_int) c_int;
extern "c" fn proc_signal_with_audittoken(token: *AuditToken, sig: c_int) c_int;

/// The immediate children of `pid`.
const childrenOf = switch (builtin.os.tag) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => childrenOfDarwin,
    // No cheap way to ask, so the process group is the whole of the reach.
    else => childrenOfNobody,
};

fn childrenOfNobody(
    pid: posix.pid_t,
    into: *std.ArrayList(posix.pid_t),
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    _ = pid;
    _ = into;
    _ = allocator;
}

//======================================================================
// Darwin.
//======================================================================

/// From `<libproc.h>`, which is part of the system library rather than a
/// library of its own. Returns the number of children it wrote, or a negative
/// number.
extern "c" fn proc_listchildpids(ppid: posix.pid_t, buffer: ?*anyopaque, buffersize: c_int) c_int;

fn childrenOfDarwin(
    pid: posix.pid_t,
    into: *std.ArrayList(posix.pid_t),
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    // One call for the ordinary case. Asking for an estimate first doubles
    // the system calls for every leaf in the tree; only a full buffer needs
    // the sizing call and retry.
    var local: [32]posix.pid_t = undefined;
    const written = proc_listchildpids(pid, &local, @sizeOf(@TypeOf(local)));
    if (written <= 0) return;
    const local_count: usize = @intCast(written);
    if (local_count < local.len) {
        try into.appendSlice(allocator, local[0..local_count]);
        return;
    }

    const estimate = proc_listchildpids(pid, null, 0);
    if (estimate <= 0) return;
    var capacity: usize = @max(@as(usize, @intCast(estimate)), local.len * 2);
    while (true) {
        const first = into.items.len;
        try into.resize(allocator, first + capacity);
        const bytes: c_int = @intCast(capacity * @sizeOf(posix.pid_t));
        const count = proc_listchildpids(pid, into.items[first..].ptr, bytes);
        if (count <= 0) {
            into.shrinkRetainingCapacity(first);
            return;
        }
        const child_count: usize = @intCast(count);
        if (child_count < capacity) {
            into.shrinkRetainingCapacity(first + child_count);
            return;
        }
        into.shrinkRetainingCapacity(first);
        capacity = std.math.mul(usize, capacity, 2) catch return error.OutOfMemory;
    }
}

//======================================================================
// Shared.
//======================================================================

/// Not declared in `std.c`, and the one question that tells a descendant which
/// `Child.kill` is about to reach anyway from one that has left the group.
extern "c" fn getpgid(pid: posix.pid_t) posix.pid_t;
extern "c" fn pause() c_int;

test "a descendant that escaped the process group is still killed" {
    // A correctness test only: there is deliberately no clock or latency
    // assertion in it. The first child makes a group, its child leaves that
    // group and session, and the same two-part signal `Child.kill` uses must
    // still end both.
    var report: [2]posix.fd_t = undefined;
    if (c.pipe(&report) != 0) return error.SkipZigTest;

    const root = c.fork();
    if (root < 0) {
        _ = c.close(report[0]);
        _ = c.close(report[1]);
        return error.SkipZigTest;
    }
    if (root == 0) {
        _ = c.close(report[0]);
        if (c.setpgid(0, 0) != 0) c._exit(120);
        const escaped = c.fork();
        if (escaped < 0) c._exit(121);
        if (escaped == 0) {
            if (c.setsid() < 0) c._exit(122);
            const own_pid = c.getpid();
            _ = c.write(report[1], std.mem.asBytes(&own_pid), @sizeOf(posix.pid_t));
            _ = c.close(report[1]);
            while (true) _ = pause();
        }
        _ = c.close(report[1]);
        while (true) _ = pause();
    }

    _ = c.close(report[1]);
    defer _ = c.close(report[0]);
    defer {
        _ = c.kill(-root, .KILL);
        var status: c_int = undefined;
        _ = c.waitpid(root, &status, 0);
    }

    var escaped: posix.pid_t = undefined;
    const bytes = std.mem.asBytes(&escaped);
    var filled: usize = 0;
    while (filled < bytes.len) {
        const n = c.read(report[0], bytes.ptr + filled, bytes.len - filled);
        if (n > 0) {
            filled += @intCast(n);
        } else if (n == 0) {
            return error.TestChildSaidNothing;
        } else if (c.errno(@as(c_int, -1)) != .INTR) {
            return error.TestChildSaidNothing;
        }
    }
    defer _ = c.kill(escaped, .KILL);

    try std.testing.expect(getpgid(escaped) != root);
    try std.testing.expectEqual(@as(usize, 1), try signalDescendants(root, .KILL, root));
    _ = c.kill(-root, .KILL);

    var waited_ms: u32 = 0;
    while (waited_ms < 5000) : (waited_ms += 2) {
        if (c.kill(escaped, @as(posix.SIG, @enumFromInt(0))) != 0 and
            c.errno(@as(c_int, -1)) == .SRCH) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
    return error.TestEscapedDescendantSurvived;
}

test "the descendants of this process include a child it just started" {
    const testing = std.testing;
    const Child = @import("Child.zig");
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
    var scratch = std.heap.stackFallback(16 * 1024, std.heap.page_allocator);
    const allocator = scratch.get();
    defer {
        for (found.items) |*process| process.deinit();
        found.deinit(allocator);
    }
    try collect(c.getpid(), null, &found, allocator);
    for (found.items) |process| {
        if (process.pid == child.id) return;
    }
    return error.TestChildWasNotFound;
}

test "a Linux stat record yields its parent and process group" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const relation = parseLinuxStat("12 (a name) with ) punctuation) S 7 9 0 0 0").?;
    try std.testing.expectEqual(@as(posix.pid_t, 7), relation.ppid);
    try std.testing.expectEqual(@as(posix.pid_t, 9), relation.pgrp);
}
