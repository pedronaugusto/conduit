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
//! A walk cannot name a process that left its group and was orphaned before
//! anyone looked. Contained Darwin children retain observed lineage separately
//! (`lineage.zig`).
//!
//! POSIX only. The walk names the tree in a bounded stack buffer that holds
//! the tree and never the whole process table, and reports
//! `error.OutOfMemory` if it cannot hold the whole tree rather than
//! silently leaving a suffix of it alive. A process is captured as a
//! stable kernel identity before the walk retains it: a pidfd on Linux and
//! a unique process id on Darwin. Every candidate's ancestry is then proved
//! through held identities before signalling. A PID alone is
//! never used as a later signal target because it may have been recycled by
//! then.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;
const Deadline = @import("deadline.zig").Deadline;
const wait_for = @import("wait.zig");
const adoption_record = @import("orphans/adoption_record.zig");
const SupervisorRecord = @import("child/contract.zig").SupervisorRecord;
const cgroups = @import("cgroup.zig");

// A recycled entry in a process-table snapshot, before it is signalled.
var snapshot_witness: if (builtin.is_test) ?posix.pid_t else void = if (builtin.is_test) null else {};
// A controlled exec between identity lookup and token delivery.
var before_token_delivery: if (builtin.is_test) ?*const fn () void else void = if (builtin.is_test) null else {};

/// The names in what `getdents64` wrote, read from its bytes rather than cast
/// out of them: a record that would run past them, or that does not hold a
/// name, ends the walk instead of being read.
pub const Dirents = struct {
    bytes: []const u8,
    offset: usize = 0,

    const reclen_at = @offsetOf(std.os.linux.dirent64, "reclen");
    const name_at = @offsetOf(std.os.linux.dirent64, "name");

    pub fn next(names: *Dirents) ?[]const u8 {
        const rest = names.bytes[names.offset..];
        if (rest.len <= name_at) return null;
        const reclen = std.mem.readInt(u16, rest[reclen_at..][0..2], builtin.cpu.arch.endian());
        if (reclen <= name_at or reclen > rest.len) return null;
        names.offset += reclen;
        return std.mem.sliceTo(rest[name_at..reclen], 0);
    }
};

test "a getdents64 record that would run past what was read, or holds no name, ends the walk" {
    const endian = builtin.cpu.arch.endian();
    var bytes: [64]u8 = @splat(0);
    // One record of 24 bytes named "12", then one that claims 200.
    std.mem.writeInt(u16, bytes[Dirents.reclen_at..][0..2], 24, endian);
    @memcpy(bytes[Dirents.name_at..][0..2], "12");
    std.mem.writeInt(u16, bytes[24 + Dirents.reclen_at ..][0..2], 200, endian);
    var names: Dirents = .{ .bytes = &bytes };
    try std.testing.expectEqualStrings("12", names.next().?);
    try std.testing.expectEqual(null, names.next());

    // A record length of zero would never move the walk on.
    std.mem.writeInt(u16, bytes[Dirents.reclen_at..][0..2], 0, endian);
    names = .{ .bytes = &bytes };
    try std.testing.expectEqual(null, names.next());
}

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
///
/// Use this by-number form only while holding an unreaped child: that keeps
/// its pid from being reused. For a process from an earlier run, capture its
/// identity and call `CapturedPid.signalDescendants` instead.
pub fn signalDescendants(root: posix.pid_t, sig: posix.SIG, in_group: ?posix.pid_t) std.mem.Allocator.Error!usize {
    return signalDescendantsGuarded(root, null, sig, in_group);
}

/// A final force while the exited, unreaped leader still owns this group id.
/// Forks of that leader have completed by now; repeated passes cover forks
/// of surviving members. The caller must retain reap ownership throughout.
pub fn forceHeldGroup(pgid: posix.pid_t, leader: posix.pid_t) void {
    if (builtin.is_test) _ = testing_hook.group_forces.fetchAdd(1, .monotonic);
    for (0..3) |_| {
        _ = c.kill(-pgid, .KILL);
        if (members(pgid, leader) == .none) break;
    }
}

/// Walk below a held process and prove each candidate's ancestry before
/// signalling, while the root still holds its original identity. A pid
/// recycled before capture cannot authorize a signal just by being in the
/// snapshot. On Darwin `alive` checks the stable process unique id.
fn signalDescendantsGuarded(root: posix.pid_t, guard: ?*const Process, sig: posix.SIG, in_group: ?posix.pid_t) std.mem.Allocator.Error!usize {
    var captured_root: ?Process = if (guard == null) Process.capture(root) else null;
    defer if (captured_root) |*held| held.deinit();
    const anchor = guard orelse if (captured_root) |*held| held else return 0;
    if (!anchor.alive()) return 0;
    if (builtin.is_test) _ = walks.fetchAdd(1, .monotonic);
    if (builtin.is_test and testing_hook.walk_full) return error.OutOfMemory;
    // Exhausting this bounded workspace reports OutOfMemory before sending
    // a partial pass.
    var storage: [64 * 1024]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = scratch.allocator();

    var found: std.ArrayList(Process) = .empty;
    defer {
        for (found.items) |*process| process.deinit();
        found.deinit(allocator);
    }
    try collect(allocator, root, in_group, &found);
    if (builtin.is_test) if (snapshot_witness) |pid| {
        var process = Process.capture(pid) orelse unreachable;
        found.append(allocator, process) catch |err| {
            process.deinit();
            return err;
        };
    };

    // A read of the process table may have outlived the root. In that case
    // none of the relationships just read proves whose descendants they are.
    if (!anchor.alive()) return 0;

    // A stable identity only binds a signal to the captured process; it does
    // not prove that a pid from an earlier snapshot was still a descendant
    // when it was captured. Prove every link through held identities before
    // delivering anything, so allocation failure cannot send a partial pass.
    var proven: std.ArrayList(bool) = .empty;
    defer proven.deinit(allocator);
    for (found.items) |*process| try proven.append(allocator, try provenBelow(allocator, anchor, process));
    if (!anchor.alive()) return 0;

    var reached: usize = 0;
    var i = found.items.len;
    while (i > 0) {
        i -= 1;
        if (!proven.items[i]) continue;
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

/// Wait for a held process to end without reaping it. Linux polls the held
/// pidfd; Darwin registers NOTE_EXIT with kqueue while the unique process id still
/// matches. If registration is unavailable, a bounded 1–4 ms clock-based
/// check is used. True means gone; false means the deadline passed.
fn waitCaptured(io: std.Io, process: *const Process, timeout_ms: u32) std.Io.Cancelable!bool {
    if (!process.alive()) return true;
    const deadline: Deadline = .in(io, timeout_ms);
    const watch: ?wait_for.Watch = if (builtin.os.tag == .linux)
        .{ .handle = process.pidfd }
    else
        wait_for.Watch.open(process.pid);
    defer if (builtin.os.tag != .linux) if (watch) |opened| opened.close();
    // Registration by number on Darwin is checked against the held unique
    // id immediately afterward; it cannot turn a reused pid into a wait
    // for the wrong process.
    if (!process.alive()) return true;
    var interval_ms: u32 = 1;
    while (true) {
        const left = deadline.remainingMs(io);
        if (left == 0) return !process.alive();
        if (watch) |opened| {
            _ = opened.ended(@min(left, wait_for.slice_ms));
            try std.Io.checkCancel(io);
        } else {
            try std.Io.sleep(io, .fromMilliseconds(@min(left, interval_ms)), .awake);
            interval_ms = @min(interval_ms * 2, 4);
        }
        if (!process.alive()) return true;
    }
}

/// A child list is only a snapshot. Recheck each link through held process
/// identities so a parent that ended, or a reused pid, cannot turn an entry
/// in that list into permission to signal a stranger.
fn provenBelow(allocator: std.mem.Allocator, root: *const Process, candidate: *const Process) std.mem.Allocator.Error!bool {
    var chain: std.ArrayList(Process) = .empty;
    defer {
        for (chain.items) |*held| held.deinit();
        chain.deinit(allocator);
    }
    var current = candidate;
    while (current.alive()) {
        const parent_pid = parentOf(current.pid) orelse return false;
        if (parent_pid <= 1 or parent_pid == current.pid) return false;
        if (parent_pid == root.pid) {
            return root.alive() and current.alive() and parentOf(current.pid) == root.pid;
        }
        var parent = Process.capture(parent_pid) orelse return false;
        if (!parent.alive() or !current.alive() or parentOf(current.pid) != parent_pid) {
            parent.deinit();
            return false;
        }
        chain.append(allocator, parent) catch |err| {
            parent.deinit();
            return err;
        };
        current = &chain.items[chain.items.len - 1];
    }
    return false;
}

fn parentOf(pid: posix.pid_t) ?posix.pid_t {
    if (comptime builtin.os.tag == .linux) return (processRelationLinux(pid) orelse return null).ppid;
    if (comptime builtin.os.tag == .macos) {
        var info: ProcBsdInfo = undefined;
        if (proc_pidinfo(pid, proc_pidtbsdinfo, 0, &info, @sizeOf(ProcBsdInfo)) != @sizeOf(ProcBsdInfo)) return null;
        return @intCast(info.ppid);
    }
    return null;
}

/// Fills `into` with the descendants of `root`, each after its parent, which
/// makes walking it backwards the deepest-first order `signalDescendants`
/// sends in.
fn collect(
    allocator: std.mem.Allocator,
    root: posix.pid_t,
    in_group: ?posix.pid_t,
    into: *std.ArrayList(Process),
) std.mem.Allocator.Error!void {
    if (comptime builtin.os.tag == .linux) {
        return collectLinux(allocator, root, in_group, into);
    }

    var descendants: std.ArrayList(posix.pid_t) = .empty;
    defer descendants.deinit(allocator);

    try captureChildren(allocator, root, in_group, &descendants, into);
    var expanded: usize = 0;
    while (expanded < descendants.items.len) : (expanded += 1) {
        try captureChildren(allocator, descendants.items[expanded], in_group, &descendants, into);
    }
}

/// Linux exposes the parent and process group in every process's `stat` file.
fn collectLinux(
    allocator: std.mem.Allocator,
    root: posix.pid_t,
    in_group: ?posix.pid_t,
    into: *std.ArrayList(Process),
) std.mem.Allocator.Error!void {
    var table = ProcTable.open() orelse return;
    defer table.close();
    var below: std.ArrayList(TableRecord) = .empty;
    defer below.deinit(allocator);
    try treeFromTable(ProcTable, allocator, &table, root, &below);
    for (below.items) |record| {
        if (in_group) |pgid| if (record.pgrp == pgid) continue;
        var process = Process.capture(record.pid) orelse continue;
        into.append(allocator, process) catch |err| {
            process.deinit();
            return err;
        };
    }
}

/// One process's entry in the table, as far as a walk needs it.
const TableRecord = struct {
    pid: posix.pid_t,
    ppid: posix.pid_t,
    pgrp: posix.pid_t,
};

/// `/proc` read as a process table, one pass at a time.
const ProcTable = struct {
    dir: c.fd_t,
    entries: [4096]u8 align(@alignOf(std.os.linux.dirent64)) = undefined,
    names: Dirents = .{ .bytes = &.{} },

    fn open() ?ProcTable {
        const dir = c.open("/proc", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
        if (dir < 0) return null;
        return .{ .dir = dir };
    }

    fn close(table: *ProcTable) void {
        _ = c.close(table.dir);
        table.* = undefined;
    }

    /// Starts the next pass from the beginning of the directory.
    fn rewind(table: *ProcTable) void {
        _ = std.os.linux.lseek(table.dir, 0, std.os.linux.SEEK.SET);
        table.names = .{ .bytes = &.{} };
    }

    fn next(table: *ProcTable) ?TableRecord {
        while (true) {
            while (table.names.next()) |name| {
                const pid = std.fmt.parseInt(posix.pid_t, name, 10) catch continue;
                const relation = processRelationLinux(pid) orelse continue;
                return .{ .pid = pid, .ppid = relation.ppid, .pgrp = relation.pgrp };
            }
            const rc = std.os.linux.getdents64(table.dir, &table.entries, table.entries.len);
            if (std.os.linux.errno(rc) != .SUCCESS or rc == 0) return null;
            table.names = .{ .bytes = table.entries[0..rc] };
        }
    }
};

/// Fills `into` with the descendants of `root`, each after its parent, from a
/// process table read through `rewind` and `next`.
///
/// The walk keeps the tree and never the table: a pass keeps each process
/// whose parent it already holds, and passes repeat until one adds nothing.
/// `/proc` lists in ascending pid order, so a child numbered above its parent
/// is kept in the same pass; one numbered below it, after pid wrap-around, is
/// kept by the next. The workspace is therefore bounded by the size of the
/// tree, whatever the size of the system.
fn treeFromTable(
    comptime Table: type,
    allocator: std.mem.Allocator,
    table: *Table,
    root: posix.pid_t,
    into: *std.ArrayList(TableRecord),
) std.mem.Allocator.Error!void {
    while (true) {
        const before = into.items.len;
        table.rewind();
        while (table.next()) |record| {
            if (record.pid == root or inTree(into.items, record.pid)) continue;
            if (record.ppid != root and !inTree(into.items, record.ppid)) continue;
            try into.append(allocator, record);
        }
        if (into.items.len == before) return;
    }
}

fn inTree(records: []const TableRecord, pid: posix.pid_t) bool {
    for (records) |record| if (record.pid == pid) return true;
    return false;
}

test "the Linux walk holds the tree, not the process table" {
    // Twenty thousand processes, a tree of five below 100 among them, and a
    // walk workspace the size of the one `signalDescendants` uses. One of the
    // tree has a lower number than its parent, as after pid wrap-around.
    const Fake = struct {
        const Self = @This();
        at: usize = 0,

        const system = 20_000;
        const tree = [_]TableRecord{
            .{ .pid = 30_001, .ppid = 100, .pgrp = 100 },
            .{ .pid = 30_002, .ppid = 30_001, .pgrp = 100 },
            .{ .pid = 30_003, .ppid = 30_002, .pgrp = 30_003 },
            .{ .pid = 50, .ppid = 30_003, .pgrp = 30_003 },
            .{ .pid = 40, .ppid = 50, .pgrp = 30_003 },
        };

        fn rewind(fake: *Self) void {
            fake.at = 0;
        }

        fn next(fake: *Self) ?TableRecord {
            defer fake.at += 1;
            if (fake.at < system) {
                const pid: posix.pid_t = @intCast(1000 + fake.at);
                return .{ .pid = pid, .ppid = 1, .pgrp = pid };
            }
            // Ascending, as /proc lists them.
            const order = [_]usize{ 4, 3, 0, 1, 2 };
            if (fake.at - system < order.len) return tree[order[fake.at - system]];
            return null;
        }
    };
    var storage: [64 * 1024]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&storage);
    var fake: Fake = .{};
    var below: std.ArrayList(TableRecord) = .empty;
    try treeFromTable(Fake, scratch.allocator(), &fake, 100, &below);
    try std.testing.expectEqual(Fake.tree.len, below.items.len);
    // Each after its parent, so walking it backwards signals deepest first.
    for (below.items, 0..) |record, i| {
        if (record.ppid == 100) continue;
        for (below.items[0..i]) |earlier| {
            if (earlier.pid == record.ppid) break;
        } else return error.TestParentAfterChild;
    }
}

const LinuxRelation = struct {
    state: u8,
    ppid: posix.pid_t,
    pgrp: posix.pid_t,
    session: posix.pid_t,
    /// Field 22: when the process started, in clock ticks after boot.
    start: ?u64 = null,
};

fn processRelationLinux(pid: posix.pid_t) ?LinuxRelation {
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/stat", .{pid}, 0) catch return null;
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
    const close = std.mem.findScalarLast(u8, text, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, text[close + 1 ..], ' ');
    const state = fields.next() orelse return null;
    if (state.len != 1) return null;
    const ppid = std.fmt.parseInt(posix.pid_t, fields.next() orelse return null, 10) catch return null;
    const pgrp = std.fmt.parseInt(posix.pid_t, fields.next() orelse return null, 10) catch return null;
    const session = std.fmt.parseInt(posix.pid_t, fields.next() orelse return null, 10) catch return null;
    // Fields 7 to 21, then 22, the start time. A record that stops short of
    // it still names the process's relations.
    var start: ?u64 = null;
    for (7..22) |_| {
        if (fields.next() == null) break;
    } else start = std.fmt.parseInt(u64, fields.next() orelse "", 10) catch null;
    return .{ .state = state[0], .ppid = ppid, .pgrp = pgrp, .session = session, .start = start };
}

/// One procfs snapshot for the adoption owner, checked against its held pidfd afterwards.
pub fn adoptionRecord(pid: posix.pid_t) ?adoption_record.Record {
    const relation = processRelationLinux(pid) orelse return null;
    return .{ .pid = pid, .start = relation.start orelse return null, .group = relation.pgrp, .session = relation.session };
}

/// When the running process `pid` started, as a number no later process
/// given the same pid shares: with the pid, it names one process for as long
/// as the system is up, so a pid written down now and read back later can be
/// told apart from a stranger that was given the number since.
///
/// The unit is the system's own and only equality means anything. **Linux**:
/// field 22 of `/proc/<pid>/stat`, clock ticks after boot. **Darwin**:
/// `proc_pidinfo`'s `PROC_PIDTBSDINFO`, microseconds since the epoch.
///
/// `null` when there is no such process, or it has ended and waits to be
/// reaped: a zombie runs nothing. `error.Unsupported` on every other system,
/// where there is no cheap way to ask.
pub const StartTimeError = error{
    /// The system has no cheap way to ask: everywhere but Linux and Darwin.
    Unsupported,
};

pub fn startTime(pid: posix.pid_t) StartTimeError!?u64 {
    if (builtin.os.tag == .windows) @compileError("startTime is POSIX-only");
    switch (builtin.os.tag) {
        .linux => {
            const relation = processRelationLinux(pid) orelse return null;
            if (relation.state == 'Z' or relation.state == 'X') return null;
            return relation.start;
        },
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => {
            var info: ProcBsdInfo = undefined;
            const written = proc_pidinfo(pid, proc_pidtbsdinfo, 0, &info, @sizeOf(ProcBsdInfo));
            if (written != @sizeOf(ProcBsdInfo)) return null;
            if (info.status == proc_status_zombie) return null;
            return info.start_tvsec *% std.time.us_per_s +% info.start_tvusec;
        },
        else => return error.Unsupported,
    }
}

/// A process held by a kernel identity rather than by its number: a pidfd on
/// Linux, a unique process id on Darwin. `signal` reaches that process or
/// nothing — once it has ended, never a process given the same pid since.
/// `alive` says whether it has ended (a zombie has); ask it rather than
/// sending signal 0, which Darwin refuses through a token. `processId()` is the
/// number it had, for reports. `wait(io, timeout_ms)` waits without reaping:
/// poll on the held pidfd on Linux, kqueue NOTE_EXIT on Darwin, and bounded
/// 1–4 ms clock-based checks only if no event registration is available.
/// `deinit` lets go of it.
/// What `CapturedPid.signalGroupSince` can meet, the same on every system.
pub const SignalGroupError = error{
    /// The group cannot be reached by proof here: by number on Darwin, or a
    /// group this capture's session did not start.
    Unsupported,
    /// Darwin: the group's member list could not be held.
    OutOfMemory,
};

pub const CapturedPid = enum(u128) {
    _,

    fn wrap(process: Process) CapturedPid {
        const identity: u64 = switch (builtin.os.tag) {
            .linux => @intCast(process.pidfd),
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => process.unique_id,
            else => 0,
        };
        return @enumFromInt(@as(u128, @as(u32, @bitCast(process.pid))) | (@as(u128, identity) << 32));
    }

    fn unwrap(captured: CapturedPid) Process {
        const bits = @intFromEnum(captured);
        const pid: posix.pid_t = @bitCast(@as(u32, @truncate(bits)));
        const identity: u64 = @truncate(bits >> 32);
        return switch (builtin.os.tag) {
            .linux => .{ .pid = pid, .pidfd = @intCast(identity) },
            .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => .{ .pid = pid, .unique_id = identity },
            else => .{ .pid = pid },
        };
    }

    /// The captured number for reports, never authority to signal by number.
    pub fn processId(captured: *const CapturedPid) posix.pid_t {
        return captured.unwrap().pid;
    }

    pub fn alive(captured: *const CapturedPid) bool {
        return captured.unwrap().alive();
    }

    pub fn signal(captured: *const CapturedPid, sig: posix.SIG) bool {
        return captured.unwrap().signal(sig);
    }

    pub fn signalDescendants(captured: *const CapturedPid, sig: posix.SIG, in_group: ?posix.pid_t) std.mem.Allocator.Error!usize {
        return captured.unwrap().signalDescendants(sig, in_group);
    }

    pub fn signalGroupSince(captured: *const CapturedPid, group: posix.pid_t, since: u64, sig: posix.SIG) SignalGroupError!usize {
        return captured.unwrap().signalGroupSince(group, since, sig);
    }

    pub fn wait(captured: *const CapturedPid, io: std.Io, timeout_ms: u32) std.Io.Cancelable!bool {
        return captured.unwrap().wait(io, timeout_ms);
    }

    /// Release exactly once; do not copy an owning captured identity.
    pub fn deinit(captured: *CapturedPid) void {
        var process = captured.unwrap();
        process.deinit();
        captured.* = undefined;
    }
};

/// Holds the process `pid` names if it is the one that started at `since`
/// (a `startTime` answer written down earlier), so that a program sweeping
/// up after a crashed run of itself can signal what it recorded with no
/// window in which the number could be given to someone else. `null` when
/// nothing runs at `pid` or what does started at another time.
///
/// **Linux**: the pidfd is opened first and the start time read after it;
/// the pidfd is then asked whether its process is still there, so a start
/// time read from a successor, after the captured process had ended, is
/// never taken for the captured one's. **Darwin**: one `proc_pidinfo` call
/// answers the start time and stable unique process id together. Delivery
/// refreshes the audit version only while that unique id matches, so exec
/// preserves the capture and PID reuse cannot authorize a signal. `error.Unsupported` elsewhere.
pub const CaptureError = error{
    /// Everywhere but Linux and Darwin.
    Unsupported,
};

pub fn captureStarted(pid: posix.pid_t, since: u64) CaptureError!?CapturedPid {
    if (builtin.os.tag == .windows) @compileError("captureStarted is POSIX-only");
    return CapturedPid.wrap((try captureStartedProcess(pid, since)) orelse return null);
}

fn captureStartedProcess(pid: posix.pid_t, since: u64) error{Unsupported}!?Process {
    if (pid <= 1 or since == 0) return switch (builtin.os.tag) {
        .linux, .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => null,
        else => error.Unsupported,
    };
    switch (builtin.os.tag) {
        .linux => {
            var process = LinuxProcess.capture(pid) orelse return null;
            if ((try startTime(pid)) != since or !process.signal(@enumFromInt(0))) {
                process.deinit();
                return null;
            }
            return process;
        },
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => {
            return DarwinProcess.captureStarted(pid, since);
        },
        else => return error.Unsupported,
    }
}

pub const RecordedOptions = struct {
    pid: posix.pid_t,
    start: u64,
    group: ?posix.pid_t = null,
    /// A handle returned by `Cgroup.openRecorded`, borrowed for this call.
    cgroup: ?*cgroups.Cgroup.Recorded = null,
    /// Linux: the private adoption owner. It receives TERM as a request to
    /// empty its scope; never kill that owner before it has reaped the tree.
    supervisor: ?SupervisorRecord = null,
    grace_ms: u32,
};

/// What `endRecorded` can meet.
pub const EndRecordedError = error{
    /// The record names something this system cannot end by proof: a
    /// supervisor off Linux, or a group on Darwin.
    Unsupported,
    /// Something in the recorded group could not be proven to descend from
    /// the recorded root, and was left alone.
    Unproven,
    /// A held process or the recorded cgroup refused to end.
    UnableToEnd,
    /// The walk could not hold the recorded root's tree.
    OutOfMemory,
    /// The task was cancelled during the grace.
    Canceled,
};

/// Ask a recorded process and every descendant still provably below it to
/// end, wait for the grace, then make any held survivors end. A verified
/// recorded cgroup is the complete reach on Linux, including orphans and
/// new forks. Without one, each descendant is captured while the recorded
/// root is still alive and held through both signals. A group member with no
/// captured parent link is never signalled; `error.Unproven` reports one on
/// Linux after the proven processes have ended. Darwin cannot enumerate a
/// group by proven descent after reparenting and reports `error.Unsupported`
/// for a requested group. A successful return means the processes this call
/// proved and held have ended or have been sent SIGKILL; `true` means there
/// was something to end. A held identity cannot survive a delivered SIGKILL,
/// even when the kernel has not yet made its exit observable to a waiter.
pub fn endRecorded(io: std.Io, options: RecordedOptions) EndRecordedError!bool {
    if (builtin.os.tag == .windows) @compileError("endRecorded is POSIX-only");
    if (options.supervisor) |record| {
        if (builtin.os.tag != .linux) return error.Unsupported;
        const boot = cgroups.bootIdentity() orelse return error.Unproven;
        if (!std.mem.eql(u8, &boot, &record.boot)) return error.Unproven;
        var ended = false;
        if (try captureStarted(record.pid, record.start)) |captured| {
            var owner = captured;
            defer owner.deinit();
            if (!owner.signal(.TERM) and owner.alive()) return error.UnableToEnd;
            if (!try owner.wait(io, options.grace_ms +| 1000)) return error.UnableToEnd;
            ended = true;
        }
        if (options.cgroup) |contained| {
            const had_members = contained.populated() != .none;
            if (had_members) {
                if (!contained.kill()) return error.UnableToEnd;
                if (!try contained.waitEmpty(io, 1000)) return error.UnableToEnd;
            }
            _ = contained.remove();
            ended = ended or had_members;
        }
        return ended;
    }
    if (options.cgroup) |contained| {
        const had_members = contained.populated() != .none;
        if (had_members) {
            // Even if the member list cannot be read, the verified cgroup
            // can still be ended with cgroup.kill after the grace.
            _ = try contained.signalMembers(.TERM, 0, null);
            if (!try contained.waitEmpty(io, options.grace_ms)) {
                if (!contained.kill()) return error.UnableToEnd;
                if (!try contained.waitEmpty(io, 1000)) return error.UnableToEnd;
            }
        }
        _ = contained.remove();
        // A process with permission to leave its cgroup may still be the
        // recorded root outside it. The pid and start record remains useful.
        var fallback = options;
        fallback.cgroup = null;
        return (try endRecorded(io, fallback)) or had_members;
    }

    var root = (try captureStartedProcess(options.pid, options.start)) orelse {
        if (options.group) |group| {
            if (group != options.pid) return error.Unproven;
            if (comptime builtin.os.tag == .linux) {
                if ((try signalGroupSince(group, options.pid, options.start, @enumFromInt(0))) > 0) return error.Unproven;
            } else return error.Unsupported;
        }
        return false;
    };
    defer root.deinit();
    var storage: [64 * 1024]u8 = undefined;
    var scratch = std.heap.FixedBufferAllocator.init(&storage);
    const allocator = scratch.allocator();
    var found: std.ArrayList(Process) = .empty;
    defer {
        for (found.items) |*process| process.deinit();
        found.deinit(allocator);
    }
    try collect(allocator, root.pid, null, &found);
    if (!root.alive()) return error.Unproven;

    var verified: std.ArrayList(bool) = .empty;
    defer verified.deinit(allocator);
    var accounted: std.ArrayList(Started) = .empty;
    defer accounted.deinit(allocator);
    var unproven = false;
    for (found.items) |*process| {
        const holds = try provenBelow(allocator, &root, process);
        try verified.append(allocator, holds);
        if (!holds and process.alive()) unproven = true;
        if (holds and builtin.os.tag == .linux and options.group != null) {
            if (try startTime(process.pid)) |since| try accounted.append(allocator, .{ .pid = process.pid, .start = since });
        }
    }

    var i = found.items.len;
    while (i > 0) {
        i -= 1;
        if (verified.items[i]) _ = found.items[i].signal(.TERM);
    }
    _ = root.signal(.TERM);

    const grace: Deadline = .in(io, options.grace_ms);
    for (found.items, verified.items) |*process, holds| {
        if (holds and process.alive()) _ = try process.wait(io, grace.remainingMs(io));
    }
    if (root.alive()) _ = try root.wait(io, grace.remainingMs(io));

    for (found.items, verified.items) |*process, holds| {
        if (holds) try killHeld(Process, process);
    }
    try killHeld(Process, &root);

    if (options.group) |group| {
        if (group != options.pid) return error.Unproven;
        if (comptime builtin.os.tag == .linux) {
            // A held member may still appear in /proc immediately after a
            // delivered KILL. It is already accounted for by that signal;
            // only members outside the captured set are unproven.
            if ((try signalGroupSinceImpl(group, options.pid, options.start, @enumFromInt(0), accounted.items)) > 0) return error.Unproven;
        } else return error.Unsupported;
    }
    if (unproven) return error.Unproven;
    return true;
}

/// The signal goes through the held identity, so delivery is proof that this
/// process cannot continue. A failed delivery still needs an exit check: it
/// may have ended on its own, or the kernel may have refused the signal.
fn killHeld(comptime Held: type, process: *const Held) error{UnableToEnd}!void {
    if (!process.alive()) return;
    if (!process.signal(.KILL) and process.alive()) return error.UnableToEnd;
}

test "a held process is ended when KILL is delivered before exit is observable" {
    const Fake = struct {
        const Self = @This();
        live: bool = true,
        deliver: bool,
        sent: *bool,

        fn alive(self: *const Self) bool {
            return self.live;
        }

        fn signal(self: *const Self, sig: posix.SIG) bool {
            std.debug.assert(sig == .KILL);
            self.sent.* = true;
            return self.deliver;
        }
    };
    var sent = false;
    try killHeld(Fake, &.{ .deliver = true, .sent = &sent });
    try std.testing.expect(sent);
    sent = false;
    try std.testing.expectError(error.UnableToEnd, killHeld(Fake, &.{ .deliver = false, .sent = &sent }));
    try std.testing.expect(sent);
    sent = false;
    try killHeld(Fake, &.{ .live = false, .deliver = false, .sent = &sent });
    try std.testing.expect(!sent);
}

/// Signal the live members of a Linux process group whose leader was
/// started at `since`. A crashed parent's death signal can end the leader
/// before the next process can walk its tree; its group still names the
/// children it left. A member is captured by pidfd before its group and
/// start time are checked, and is signalled through that same descriptor.
/// The leader is left to the caller, which may hold its own identity.
/// On Darwin this by-number call is `error.Unsupported`:
/// `proc_listpgrppids` identifies current members, and audit tokens hold
/// each member's identity, but an ordinary group's membership and a later
/// start time do not prove descent. POSIX permits another process in the
/// session to join the group, and Darwin exposes no parent history after
/// reparenting. `CapturedPid.signalGroupSince` handles the narrower case
/// where the captured leader created the session itself.
pub fn signalGroupSince(group: posix.pid_t, leader: posix.pid_t, since: u64, sig: posix.SIG) error{Unsupported}!usize {
    return signalGroupSinceImpl(group, leader, since, sig, &.{});
}

const Started = struct { pid: posix.pid_t, start: u64 };

fn signalGroupSinceImpl(group: posix.pid_t, leader: posix.pid_t, since: u64, sig: posix.SIG, accounted: []const Started) error{Unsupported}!usize {
    if (comptime builtin.os.tag != .linux) return error.Unsupported;
    if (group <= 1 or since == 0) return 0;
    const dir = c.open("/proc", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (dir < 0) return 0;
    defer _ = c.close(dir);

    var reached: usize = 0;
    var entries: [4096]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    while (true) {
        const rc = std.os.linux.getdents64(dir, &entries, entries.len);
        if (std.os.linux.errno(rc) != .SUCCESS or rc == 0) break;
        var names: Dirents = .{ .bytes = entries[0..rc] };
        while (names.next()) |name| {
            const pid = std.fmt.parseInt(posix.pid_t, name, 10) catch continue;
            if (pid <= 1 or pid == leader or pid == c.getpid()) continue;
            var process = LinuxProcess.capture(pid) orelse continue;
            defer process.deinit();
            const relation = processRelationLinux(pid) orelse continue;
            if (relation.pgrp != group or relation.start == null or relation.start.? < since or
                relation.state == 'Z' or relation.state == 'X') continue;
            // /proc can briefly show a process after its pidfd reports exit.
            // Compare its original start too, so a successor at the same
            // number remains visible to this check.
            var already_held = false;
            for (accounted) |held| {
                if (held.pid == pid and held.start == relation.start.?) {
                    already_held = true;
                    break;
                }
            }
            if (already_held) continue;
            // The proc path could now name a successor. The pidfd cannot:
            // an ended capture refuses the signal instead of reaching it.
            if (process.signal(sig)) reached += 1;
        }
    }
    return reached;
}

/// `struct proc_bsdinfo` from `<sys/proc_info.h>`, as far as the start time.
const ProcBsdInfo = extern struct {
    flags: u32,
    status: u32,
    xstatus: u32,
    pid: u32,
    ppid: u32,
    uid: u32,
    gid: u32,
    ruid: u32,
    rgid: u32,
    svuid: u32,
    svgid: u32,
    rfu_1: u32,
    comm: [16]u8,
    name: [32]u8,
    nfiles: u32,
    pgid: u32,
    pjobc: u32,
    e_tdev: u32,
    e_tpgid: u32,
    nice: i32,
    start_tvsec: u64,
    start_tvusec: u64,
};

const proc_pidtbsdinfo = 3;
/// `SZOMB` from `<sys/proc.h>`.
const proc_status_zombie = 5;

fn captureChildren(
    allocator: std.mem.Allocator,
    parent: posix.pid_t,
    in_group: ?posix.pid_t,
    descendants: *std.ArrayList(posix.pid_t),
    into: *std.ArrayList(Process),
) std.mem.Allocator.Error!void {
    const first = descendants.items.len;
    try childrenOf(allocator, parent, descendants);
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

    pub fn signal(process: *const LinuxProcess, sig: posix.SIG) bool {
        const rc = std.os.linux.pidfd_send_signal(process.pidfd, sig, null, 0);
        return std.os.linux.errno(rc) == .SUCCESS;
    }

    pub fn signalDescendants(process: *const LinuxProcess, sig: posix.SIG, in_group: ?posix.pid_t) std.mem.Allocator.Error!usize {
        return signalDescendantsGuarded(process.pid, process, sig, in_group);
    }

    /// Reach a recorded Linux group only while this is still its leader.
    pub fn signalGroupSince(process: *const LinuxProcess, group: posix.pid_t, since: u64, sig: posix.SIG) error{Unsupported}!usize {
        if (process.pid != group or !process.alive() or (try startTime(process.pid)) != since) return 0;
        return signalGroupSinceImpl(group, process.pid, since, sig, &.{});
    }

    pub fn wait(process: *const LinuxProcess, io: std.Io, timeout_ms: u32) std.Io.Cancelable!bool {
        return waitCaptured(io, process, timeout_ms);
    }

    /// Whether the process has not ended. A pidfd becomes readable when its
    /// process exits, reaped or not.
    pub fn alive(process: *const LinuxProcess) bool {
        var fds = [_]posix.pollfd{.{ .fd = process.pidfd, .events = posix.POLL.IN, .revents = 0 }};
        const rc = std.os.linux.poll(&fds, 1, 0);
        return std.os.linux.errno(rc) == .SUCCESS and rc == 0;
    }

    pub fn deinit(process: *LinuxProcess) void {
        _ = std.os.linux.close(process.pidfd);
        process.* = undefined;
    }
};

const AuditToken = extern struct { val: [8]c_uint };

pub const DarwinProcess = struct {
    pid: posix.pid_t,
    unique_id: u64,

    pub fn capture(pid: posix.pid_t) ?DarwinProcess {
        var info: ProcUniqueInfo = undefined;
        const written = proc_pidinfo(pid, proc_pid_unique_info, 0, &info, @sizeOf(ProcUniqueInfo));
        if (written != @sizeOf(ProcUniqueInfo)) return null;
        return .{ .pid = pid, .unique_id = info.unique_id };
    }

    /// The process at `pid` if it started at `since`, from one lookup that
    /// answers the start time and stable unique process id together.
    fn captureStarted(pid: posix.pid_t, since: u64) ?DarwinProcess {
        var info: BsdInfoWithUniqueId = undefined;
        const written = proc_pidinfo(pid, proc_pidt_bsdinfowithuniqid, 0, &info, @sizeOf(BsdInfoWithUniqueId));
        if (written != @sizeOf(BsdInfoWithUniqueId)) return null;
        if (info.bsd.status == proc_status_zombie) return null;
        if (info.bsd.start_tvsec *% std.time.us_per_s +% info.bsd.start_tvusec != since) return null;
        return .{ .pid = pid, .unique_id = info.unique.unique_id };
    }

    /// A lineage edge proved by kernel unique ids, even after reparenting.
    /// Used only for candidates enumerated below the retained parent.
    pub fn childOf(process: *const DarwinProcess, parent: *const DarwinProcess) bool {
        var child: ProcUniqueInfo = undefined;
        return proc_pidinfo(process.pid, proc_pid_unique_info, 0, &child, @sizeOf(ProcUniqueInfo)) == @sizeOf(ProcUniqueInfo) and
            child.unique_id == process.unique_id and child.parent_unique_id == parent.unique_id;
    }

    /// The kernel refuses signal 0 through a token (`EINVAL`), so `alive`
    /// and not this is how to ask whether the process is still there.
    pub fn signal(process: *const DarwinProcess, sig: posix.SIG) bool {
        // Exec changes the audit version, not the process unique id. Every
        // refresh proves the same process; the kernel checks the version at
        // delivery, closing the reuse window after that proof. Retry only a
        // changed version, with a bound for a process that keeps execing.
        var previous: ?i32 = null;
        for (0..3) |_| {
            const info = process.current() orelse return false;
            if (previous == info.unique.id_version) return false;
            var token: AuditToken = .{ .val = @splat(0) };
            token.val[5] = @bitCast(process.pid);
            token.val[7] = @bitCast(info.unique.id_version);
            if (builtin.is_test) if (before_token_delivery) |exec| exec();
            if (proc_signal_with_audittoken(&token, @intCast(@intFromEnum(sig))) == 0) return true;
            previous = info.unique.id_version;
        }
        return false;
    }

    pub fn signalDescendants(process: *const DarwinProcess, sig: posix.SIG, in_group: ?posix.pid_t) std.mem.Allocator.Error!usize {
        return signalDescendantsGuarded(process.pid, process, sig, in_group);
    }

    /// A session created by this leader cannot be joined from outside it:
    /// every later member is a descendant, even if its parent has gone.
    /// An ordinary group in an older session can be joined by an unrelated
    /// process there, so that group remains `error.Unsupported`.
    pub fn signalGroupSince(process: *const DarwinProcess, group: posix.pid_t, since: u64, sig: posix.SIG) error{ Unsupported, OutOfMemory }!usize {
        if (group <= 1 or process.pid != group or !process.alive()) return 0;
        if (getsid(process.pid) != process.pid or getpgid(process.pid) != group or
            (try startTime(process.pid)) != since) return error.Unsupported;

        var storage: [32 * 1024]u8 = undefined;
        var scratch = std.heap.FixedBufferAllocator.init(&storage);
        const allocator = scratch.allocator();
        var pids: std.ArrayList(posix.pid_t) = .empty;
        defer pids.deinit(allocator);
        var capacity: usize = 64;
        while (true) {
            try pids.resize(allocator, capacity);
            const count = proc_listpgrppids(group, pids.items.ptr, @intCast(capacity * @sizeOf(posix.pid_t)));
            if (count < 0) return error.Unsupported;
            if (@as(usize, @intCast(count)) < capacity) {
                pids.shrinkRetainingCapacity(@intCast(count));
                break;
            }
            capacity = std.math.mul(usize, capacity, 2) catch return error.OutOfMemory;
            if (capacity > @as(usize, std.math.maxInt(c_int)) / @sizeOf(posix.pid_t)) return error.OutOfMemory;
        }

        var held: std.ArrayList(DarwinProcess) = .empty;
        defer held.deinit(allocator);
        for (pids.items) |pid| {
            if (pid <= 1 or pid == process.pid or pid == c.getpid()) continue;
            const member = DarwinProcess.capture(pid) orelse continue;
            var info: ProcBsdInfo = undefined;
            if (proc_pidinfo(pid, proc_pidtbsdinfo, 0, &info, @sizeOf(ProcBsdInfo)) != @sizeOf(ProcBsdInfo) or
                info.pgid != @as(u32, @intCast(group)) or
                info.start_tvsec *% std.time.us_per_s +% info.start_tvusec < since or
                getsid(pid) != process.pid or !member.alive()) continue;
            try held.append(allocator, member);
        }
        // The group and session may be re-used only after the original one
        // has gone. Check the stable unique id after enumeration and before
        // the first signal; every member checks its own id before delivery.
        if (!process.alive()) return 0;
        var reached: usize = 0;
        for (held.items) |*member| {
            if (member.signal(sig)) reached += 1;
        }
        return reached;
    }

    pub fn wait(process: *const DarwinProcess, io: std.Io, timeout_ms: u32) std.Io.Cancelable!bool {
        return waitCaptured(io, process, timeout_ms);
    }

    /// Look up the current executable only while the stable process identity
    /// still matches. A reused pid can never supply a new delivery token.
    fn current(process: *const DarwinProcess) ?BsdInfoWithUniqueId {
        var info: BsdInfoWithUniqueId = undefined;
        const written = proc_pidinfo(process.pid, proc_pidt_bsdinfowithuniqid, 0, &info, @sizeOf(BsdInfoWithUniqueId));
        if (written != @sizeOf(BsdInfoWithUniqueId) or
            info.unique.unique_id != process.unique_id or info.bsd.status == proc_status_zombie) return null;
        return info;
    }

    pub fn alive(process: *const DarwinProcess) bool {
        return process.current() != null;
    }

    pub fn deinit(process: *DarwinProcess) void {
        process.* = undefined;
    }
};

/// `struct proc_bsdinfowithuniqid` from `<sys/proc_info.h>`.
const BsdInfoWithUniqueId = extern struct {
    bsd: ProcBsdInfo,
    unique: ProcUniqueInfo,
};
const proc_pidt_bsdinfowithuniqid = 18;

comptime {
    // The sizes `proc_pidinfo` checks the buffer against.
    std.debug.assert(@sizeOf(ProcBsdInfo) == 136);
    std.debug.assert(@sizeOf(ProcUniqueInfo) == 56);
    std.debug.assert(@sizeOf(BsdInfoWithUniqueId) == 192);
}

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

    pub fn signal(process: *const NoProcess, sig: posix.SIG) bool {
        _ = process;
        _ = sig;
        return false;
    }

    pub fn signalDescendants(process: *const NoProcess, sig: posix.SIG, in_group: ?posix.pid_t) std.mem.Allocator.Error!usize {
        _ = process;
        _ = sig;
        _ = in_group;
        return 0;
    }

    pub fn signalGroupSince(process: *const NoProcess, group: posix.pid_t, since: u64, sig: posix.SIG) error{Unsupported}!usize {
        _ = process;
        _ = group;
        _ = since;
        _ = sig;
        return error.Unsupported;
    }

    pub fn wait(process: *const NoProcess, io: std.Io, timeout_ms: u32) std.Io.Cancelable!bool {
        _ = process;
        _ = io;
        _ = timeout_ms;
        return true;
    }

    pub fn alive(process: *const NoProcess) bool {
        _ = process;
        return false;
    }

    pub fn deinit(process: *NoProcess) void {
        process.* = undefined;
    }
};

const proc_pid_unique_info = 17;
extern "c" fn proc_pidinfo(pid: c_int, flavor: c_int, arg: u64, buffer: *anyopaque, size: c_int) c_int;
extern "c" fn proc_signal_with_audittoken(token: *AuditToken, sig: c_int) c_int;

/// The immediate children of `pid`.
fn childrenOf(allocator: std.mem.Allocator, pid: posix.pid_t, into: *std.ArrayList(posix.pid_t)) std.mem.Allocator.Error!void {
    return switch (builtin.os.tag) {
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => childrenOfDarwin(allocator, pid, into),
        // No cheap way to ask, so the process group is the whole of the reach.
        else => childrenOfNobody(allocator, pid, into),
    };
}

fn childrenOfNobody(
    allocator: std.mem.Allocator,
    pid: posix.pid_t,
    into: *std.ArrayList(posix.pid_t),
) std.mem.Allocator.Error!void {
    _ = allocator;
    _ = pid;
    _ = into;
}

//======================================================================
// Darwin.
//======================================================================

/// From `<libproc.h>`, which is part of the system library rather than a
/// library of its own. Returns the number of children it wrote, or a negative
/// number.
extern "c" fn proc_listchildpids(ppid: posix.pid_t, buffer: ?*anyopaque, buffersize: c_int) c_int;

fn childrenOfDarwin(allocator: std.mem.Allocator, pid: posix.pid_t, into: *std.ArrayList(posix.pid_t)) std.mem.Allocator.Error!void {
    observedChildrenOfDarwin(allocator, pid, into) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SystemResources => return,
    };
}

/// An observer must distinguish an unreadable list from an empty one.
pub fn observedChildrenOfDarwin(
    allocator: std.mem.Allocator,
    pid: posix.pid_t,
    into: *std.ArrayList(posix.pid_t),
) error{ OutOfMemory, SystemResources }!void {
    // One call for the ordinary case. Asking for an estimate first doubles
    // the system calls for every leaf in the tree; only a full buffer needs
    // the sizing call and retry.
    var local: [32]posix.pid_t = undefined;
    const written = proc_listchildpids(pid, &local, @sizeOf(@TypeOf(local)));
    if (written < 0) return error.SystemResources;
    if (written == 0) return;
    const local_count: usize = @intCast(written);
    if (local_count < local.len) {
        try into.appendSlice(allocator, local[0..local_count]);
        return;
    }

    const estimate = proc_listchildpids(pid, null, 0);
    if (estimate < 0) return error.SystemResources;
    if (estimate == 0) return;
    var capacity: usize = @max(@as(usize, @intCast(estimate)), local.len * 2);
    while (true) {
        const first = into.items.len;
        try into.resize(allocator, first + capacity);
        const bytes: c_int = @intCast(capacity * @sizeOf(posix.pid_t));
        const count = proc_listchildpids(pid, into.items[first..].ptr, bytes);
        if (count <= 0) {
            into.shrinkRetainingCapacity(first);
            if (count < 0) return error.SystemResources;
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
// Whether a child has forked.
//======================================================================

/// How many walks `signalDescendants` has started, in a test build: what
/// lets a test say a stop took the plain path.
pub var walks: std.atomic.Value(usize) = .init(0);

/// Whether this system can say that a child has nothing below it without a
/// walk: Darwin by the watch on its forks (`Forks`), Linux by `hasChildren`.
pub const knows_leaves = Forks.supported or builtin.os.tag == .linux;

/// Whether `pid` has a child of its own now, or this cannot be said.
///
/// **Linux**: `/proc/<pid>/task/<tid>/children`, one small read per thread
/// of the process, where the walk is a read of every process's `stat` on
/// the system. A process's children are the ones its threads made, and only
/// they could have been named by the walk's first level, so an empty answer
/// for every thread means the walk would name nothing. It says "none now"
/// rather than "never", which for the walk is the same thing: a descendant
/// whose parent has gone belongs to `init` and no walk names it either.
///
/// `true` wherever the answer is not known: another system, a `/proc`
/// without the `children` files (a kernel built without
/// `CONFIG_PROC_CHILDREN`), a process that cannot be read. That is the walk,
/// as it would have been.
pub fn hasChildren(pid: posix.pid_t) bool {
    if (comptime builtin.os.tag != .linux) return true;
    // The main thread first: a process that forks usually forks from it,
    // and then one read answers without listing the threads.
    var main_buffer: [64]u8 = undefined;
    const main_path = std.fmt.bufPrintSentinel(&main_buffer, "/proc/{d}/task/{d}/children", .{ pid, pid }, 0) catch return true;
    const main_fd = c.open(main_path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (main_fd < 0) return true;
    var first: [1]u8 = undefined;
    const main_n = c.read(main_fd, &first, 1);
    _ = c.close(main_fd);
    if (main_n != 0) return true;

    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/task", .{pid}, 0) catch return true;
    const dir = c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (dir < 0) return true;
    defer _ = c.close(dir);

    var threads: usize = 0;
    var entries: [1024]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    while (true) {
        const rc = std.os.linux.getdents64(dir, &entries, entries.len);
        if (std.os.linux.errno(rc) != .SUCCESS) return true;
        if (rc == 0) break;
        var names: Dirents = .{ .bytes = entries[0..rc] };
        while (names.next()) |name| {
            const tid = std.fmt.parseInt(posix.pid_t, name, 10) catch continue;
            threads += 1;
            // Read above.
            if (tid == pid) continue;
            var file_buffer: [32]u8 = undefined;
            const file = std.fmt.bufPrintSentinel(&file_buffer, "{s}/children", .{name}, 0) catch return true;
            const fd = c.openat(dir, file, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
            if (fd < 0) return true;
            var byte: [1]u8 = undefined;
            const n = c.read(fd, &byte, 1);
            _ = c.close(fd);
            // A child's number, or a read that failed: either way, the walk.
            if (n != 0) return true;
        }
    }
    // A process with no thread to list is one that cannot be read.
    return threads == 0;
}

/// Whether a child has ever forked, which is the question that decides
/// whether a stop needs the walk at all.
///
/// A child that has never forked has no descendants: nothing but the child
/// itself can make one. Its stop is then the signal alone, and on Darwin that
/// saves the walk's two passes over the whole process table
/// (`proc_listchildpids` is one each time it is asked). A child that has
/// forked, even once, gets the walk exactly as before.
///
/// **Darwin**: a kqueue with an `EVFILT_PROC`/`NOTE_FORK` registration on the
/// child, made by `spawn` before the child runs one instruction of the program
/// it executes: `posix_spawn` starts it suspended and `spawn` resumes it once
/// the registration is in, and the fork path holds the child before its
/// `execve` until the parent says the registration is in. So there is no
/// fork the watch was too late for. The kernel posts the note in the parent's
/// `fork` before the new process can run, so a process that has run — and
/// could have left the group — was always noted first. Darwin has no
/// `NOTE_TRACK`, so the note says *that* the child forked and not what it
/// started; that is enough to decide.
///
/// It is a queue of its own and not the one `Reaper` waits on for the end:
/// that one is opened when the `Reaper`'s task first runs, which is after
/// the child has, and a note taken off a queue by a wait is gone for the
/// next reader, so the two questions would race for it.
///
/// **Everywhere else** there is no watch, and `any` answers `true`: the walk,
/// as it always was.
pub const Forks = switch (builtin.os.tag) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => DarwinForks,
    else => NoForks,
};

pub const DarwinForks = struct {
    /// The kqueue, or `null` where none could be had: then every question
    /// answers `true`. Not inherited by any child: the kernel confines a
    /// kqueue to the process that made it.
    queue: ?posix.fd_t,
    /// A note once taken off the queue. The registration clears on reading
    /// (the kernel makes every `EVFILT_PROC` one `EV_CLEAR`), so what one
    /// question learned is kept here for the next.
    seen: std.atomic.Value(bool) = .init(false),
    exited: std.atomic.Value(bool) = .init(false),
    /// Held by the task reading the queue. A second task that asks meanwhile
    /// could otherwise find the queue emptied by the first and the note not
    /// yet kept, so it answers `true` instead, which is the walk.
    reading: std.atomic.Value(bool) = .init(false),

    pub const supported = true;
    pub const none: DarwinForks = .{ .queue = null };

    /// Registers the watch on `pid`, which must not have run yet. `none`
    /// when the system refuses one; the caller starts the child all the same.
    pub fn watch(pid: posix.pid_t) DarwinForks {
        if (builtin.is_test) testing_hook.atWatch(pid);
        const queue = c.kqueue();
        if (queue < 0) return none;
        // `kevent64` here as in `any`: a kqueue takes one of the two forms
        // and refuses the other.
        var change = [_]c.kevent64_s{.{
            .ident = @intCast(pid),
            .filter = c.EVFILT.PROC,
            .flags = c.EV.ADD | c.EV.ENABLE,
            .fflags = c.NOTE.FORK | c.NOTE.EXIT,
            .data = 0,
            .udata = 0,
            .ext = .{ 0, 0 },
        }};
        var nothing: [0]c.kevent64_s = undefined;
        if (c.kevent64(queue, &change, 1, &nothing, 0, .{ .IMMEDIATE = true }, null) < 0) {
            _ = c.close(queue);
            return none;
        }
        return .{ .queue = queue };
    }

    /// Whether the child has forked since `watch`, or this cannot be said.
    /// Never blocks.
    ///
    /// After the child has ended the registration is gone, and every fork it
    /// made was noted before that: a `fork` posts its note before it returns
    /// to the process that called it.
    pub fn any(forks: *DarwinForks) bool {
        if (forks.seen.load(.acquire)) return true;
        const queue = forks.queue orelse return true;
        if (forks.reading.swap(true, .acquire)) return true;
        defer forks.reading.store(false, .release);
        // `KEVENT_FLAG_IMMEDIATE` rather than a timeout of zero, which only
        // `kevent64` takes, without entering a timed wait.
        var events: [2]c.kevent64_s = undefined;
        var nothing: [0]c.kevent64_s = undefined;
        const ready = c.kevent64(queue, &nothing, 0, &events, events.len, .{ .IMMEDIATE = true }, null);
        if (ready < 0) return true;
        for (events[0..@intCast(ready)]) |event| {
            if (event.fflags & c.NOTE.FORK != 0) forks.seen.store(true, .release);
            if (event.fflags & c.NOTE.EXIT != 0) forks.exited.store(true, .release);
        }
        return forks.seen.load(.acquire);
    }

    /// The exit registered before the child ran, including a note consumed
    /// by a concurrent fork check. Null means no queue could be registered.
    pub fn ended(forks: *DarwinForks, milliseconds: u32) ?bool {
        if (forks.exited.load(.acquire)) return true;
        const queue = forks.queue orelse return null;
        if (forks.reading.swap(true, .acquire)) return false;
        defer forks.reading.store(false, .release);
        if (forks.exited.load(.acquire)) return true;
        var events: [2]c.kevent64_s = undefined;
        var nothing: [0]c.kevent64_s = undefined;
        const timeout: c.timespec = .{
            .sec = @intCast(milliseconds / 1000),
            .nsec = @intCast((milliseconds % 1000) * std.time.ns_per_ms),
        };
        const ready = c.kevent64(queue, &nothing, 0, &events, events.len, .{}, &timeout);
        if (ready < 0) return null;
        for (events[0..@intCast(ready)]) |event| {
            if (event.fflags & c.NOTE.FORK != 0) forks.seen.store(true, .release);
            if (event.fflags & c.NOTE.EXIT != 0) forks.exited.store(true, .release);
        }
        return forks.exited.load(.acquire);
    }

    pub fn close(forks: *DarwinForks) void {
        if (forks.queue) |queue| _ = c.close(queue);
        forks.queue = null;
    }
};

/// Test builds only: what a test needs to show the watch has no window.
pub const testing_hook = struct {
    pub var group_forces: std.atomic.Value(usize) = .init(0);
    /// Makes every descendant walk fail as one too large to hold would.
    pub var walk_full: bool = false;
    /// How long `Forks.watch` waits before it registers: time in which a
    /// child that was not being held would run its program, and fork.
    pub var hold_ms: u32 = 0;
    /// Whether the child had run its program by the time `Forks.watch`
    /// registered, for the last watch made: `null` before the first.
    pub var ran_before_watch: ?bool = null;

    fn atWatch(pid: posix.pid_t) void {
        if (hold_ms > 0) {
            const pause_for: c.timespec = .{
                .sec = @intCast(hold_ms / 1000),
                .nsec = @intCast(@as(u64, hold_ms % 1000) * std.time.ns_per_ms),
            };
            _ = c.nanosleep(&pause_for, null);
        }
        ran_before_watch = ranProgram(pid);
    }

    /// A child held by `posix_spawn` is stopped (`SSTOP`), and one held by
    /// the fork path has not executed yet, so it is still this program.
    fn ranProgram(pid: posix.pid_t) bool {
        var info: ProcBsdInfo = undefined;
        if (proc_pidinfo(pid, proc_pidtbsdinfo, 0, &info, @sizeOf(ProcBsdInfo)) != @sizeOf(ProcBsdInfo)) return true;
        if (info.status == proc_status_stopped) return false;
        var own: [4096]u8 = undefined;
        var its: [4096]u8 = undefined;
        const own_len = proc_pidpath(c.getpid(), &own, own.len);
        const its_len = proc_pidpath(pid, &its, its.len);
        if (own_len <= 0 or its_len <= 0) return true;
        return !std.mem.eql(u8, own[0..@intCast(own_len)], its[0..@intCast(its_len)]);
    }

    /// `SSTOP` from `<sys/proc.h>`.
    const proc_status_stopped = 4;
    extern "c" fn proc_pidpath(pid: c_int, buffer: [*]u8, size: u32) c_int;
};

pub const NoForks = struct {
    pub const supported = false;
    pub const none: NoForks = .{};

    pub fn watch(pid: posix.pid_t) NoForks {
        _ = pid;
        return .{};
    }

    pub fn any(forks: *NoForks) bool {
        _ = forks;
        return true;
    }

    pub fn close(forks: *NoForks) void {
        _ = forks;
    }
};

//======================================================================
// A process group's members.
//======================================================================

/// Whether a process group holds anything but its leader.
pub const Members = enum {
    /// Something other than `leader` is in the group and has not ended.
    others,
    /// Nothing is, or only processes that have ended and wait to be reaped.
    none,
    /// This system cannot say without reading its whole process table.
    unknown,
};

/// Whether a process other than `leader` is still running in process group
/// `pgid`.
///
/// The leader is left out because the caller asking is the one holding it:
/// a leader that has ended and is not yet reaped keeps the group's id from
/// being given to anyone else, which is what makes a signal to `-pgid` safe
/// while this is asked. Linux answers from one `/proc` pass, leaving out a
/// process that has ended; Darwin from `proc_listpgrppids`, which names the
/// group's processes and not their state, so a member that has ended and
/// whose parent has not yet reaped it is counted until it is. The BSDs and
/// illumos answer `unknown`.
pub fn members(pgid: posix.pid_t, leader: posix.pid_t) Members {
    return switch (builtin.os.tag) {
        .linux => membersLinux(pgid, leader),
        .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => membersDarwin(pgid, leader),
        else => .unknown,
    };
}

fn membersLinux(pgid: posix.pid_t, leader: posix.pid_t) Members {
    const dir = c.open("/proc", .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (dir < 0) return .unknown;
    defer _ = c.close(dir);

    var entries: [4096]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    while (true) {
        const rc = std.os.linux.getdents64(dir, &entries, entries.len);
        if (std.os.linux.errno(rc) != .SUCCESS) return .unknown;
        if (rc == 0) return .none;

        var names: Dirents = .{ .bytes = entries[0..rc] };
        while (names.next()) |name| {
            const pid = std.fmt.parseInt(posix.pid_t, name, 10) catch continue;
            if (pid == leader) continue;
            const relation = processRelationLinux(pid) orelse continue;
            // `Z` has ended and waits for its parent; `X` is being torn down.
            if (relation.pgrp == pgid and relation.state != 'Z' and relation.state != 'X') return .others;
        }
    }
}

/// From `<libproc.h>`, like `proc_listchildpids`. Returns the number of
/// processes it wrote, or a negative number.
extern "c" fn proc_listpgrppids(pgrpid: posix.pid_t, buffer: ?*anyopaque, buffersize: c_int) c_int;

fn membersDarwin(pgid: posix.pid_t, leader: posix.pid_t) Members {
    // A leader and one more is the whole of the question, but the list comes
    // in no promised order, so it is asked for with room for a crowd and
    // asked again, larger, only when it came back full.
    var local: [64]posix.pid_t = undefined;
    const written = proc_listpgrppids(pgid, &local, @sizeOf(@TypeOf(local)));
    if (written < 0) return .unknown;
    const count: usize = @intCast(written);
    for (local[0..@min(count, local.len)]) |pid| if (pid != leader and pid > 0) return .others;
    if (count < local.len) return .none;
    // Full, and every one of them the leader: impossible, but not something
    // to answer `none` for without looking.
    return .unknown;
}

//======================================================================
// Shared.
//======================================================================

/// Not declared in `std.c`, and the one question that tells a descendant which
/// `Child.kill` is about to reach anyway from one that has left the group.
extern "c" fn getpgid(pid: posix.pid_t) posix.pid_t;
extern "c" fn getsid(pid: posix.pid_t) posix.pid_t;
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
    var held = Process.capture(root).?;
    defer held.deinit();
    try std.testing.expectEqual(@as(usize, 1), try held.signalDescendants(.KILL, root));
    _ = c.kill(-root, .KILL);

    const deadline: Deadline = .in(std.testing.io, 5000);
    while (deadline.remainingMs(std.testing.io) > 0) {
        if (c.kill(escaped, @as(posix.SIG, @enumFromInt(0))) != 0 and
            c.errno(@as(c_int, -1)) == .SRCH) return;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
    }
    return error.TestEscapedDescendantSurvived;
}

test "a Linux stat record yields its parent and process group" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const relation = parseLinuxStat("12 (a name) with ) punctuation) S 7 9 0 0 0").?;
    try std.testing.expectEqual(@as(u8, 'S'), relation.state);
    try std.testing.expectEqual(@as(posix.pid_t, 7), relation.ppid);
    try std.testing.expectEqual(@as(posix.pid_t, 9), relation.pgrp);
    try std.testing.expectEqual(@as(?u64, null), relation.start);
}

test "a Linux stat record yields its start time, field 22" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // pid (comm) state ppid pgrp session tty tpgid flags minflt cminflt
    // majflt cmajflt utime stime cutime cstime priority nice threads
    // itrealvalue starttime vsize
    const relation = parseLinuxStat("12 (a (b) c) S 7 9 9 0 -1 4194560 100 0 0 0 3 1 0 0 20 0 1 0 987654 4096").?;
    try std.testing.expectEqual(@as(?u64, 987654), relation.start);
}

test "a captured Darwin session leader proves its group's member" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var report: [2]posix.fd_t = undefined;
    if (c.pipe(&report) != 0) return error.SkipZigTest;
    const leader = c.fork();
    if (leader < 0) {
        _ = c.close(report[0]);
        _ = c.close(report[1]);
        return error.SkipZigTest;
    }
    if (leader == 0) {
        _ = c.close(report[0]);
        if (c.setsid() < 0) c._exit(120);
        const member = c.fork();
        if (member < 0) c._exit(121);
        if (member == 0) {
            _ = c.close(report[1]);
            while (true) _ = pause();
        }
        _ = c.write(report[1], std.mem.asBytes(&member), @sizeOf(posix.pid_t));
        _ = c.close(report[1]);
        while (true) _ = pause();
    }
    _ = c.close(report[1]);
    defer _ = c.close(report[0]);
    defer {
        _ = c.kill(leader, .KILL);
        var status: c_int = undefined;
        _ = c.waitpid(leader, &status, 0);
    }
    var member: posix.pid_t = undefined;
    if (c.read(report[0], std.mem.asBytes(&member), @sizeOf(posix.pid_t)) != @sizeOf(posix.pid_t))
        return error.TestChildSaidNothing;
    defer _ = c.kill(member, .KILL);
    const since = (try startTime(leader)).?;
    var captured = (try captureStarted(leader, since)).?;
    defer captured.deinit();
    try std.testing.expectEqual(@as(usize, 1), try captured.signalGroupSince(leader, since, .CONT));
    try std.testing.expectEqual(@as(usize, 1), try captured.signalGroupSince(leader, since, .KILL));
}

test "CapturedPid does not expose signal identities as writable fields" {
    try std.testing.expect(@typeInfo(CapturedPid) == .@"enum");
}

pub const test_access = if (builtin.is_test) struct {
    pub const current = DarwinProcess.current;
    pub const capture = FixtureProcess.capture;
    pub const Deadline = FixtureDeadline;
    pub const wait_for = fixture_wait_for;
    pub const signalDescendantsGuarded = fixtureSignalDescendantsGuarded;
    pub const waitCaptured = fixtureWaitCaptured;
    pub const provenBelow = fixtureProvenBelow;
    pub const parentOf = fixtureParentOf;
    pub const collect = fixture_collect;
    pub const collectLinux = fixtureCollectLinux;
    pub const LinuxRelation = FixtureLinuxRelation;
    pub const processRelationLinux = fixtureProcessRelationLinux;
    pub const parseLinuxStat = fixtureParseLinuxStat;
    pub const captureStartedProcess = fixtureCaptureStartedProcess;
    pub const killHeld = fixtureKillHeld;
    pub const Started = FixtureStarted;
    pub const signalGroupSinceImpl = fixtureSignalGroupSinceImpl;
    pub const ProcBsdInfo = FixtureProcBsdInfo;
    pub const proc_pidtbsdinfo = fixture_proc_pidtbsdinfo;
    pub const proc_status_zombie = fixture_proc_status_zombie;
    pub const captureChildren = fixtureCaptureChildren;
    pub const Process = FixtureProcess;
    pub const LinuxProcess = FixtureLinuxProcess;
    pub const AuditToken = FixtureAuditToken;
    pub const BsdInfoWithUniqueId = FixtureBsdInfoWithUniqueId;
    pub const proc_pidt_bsdinfowithuniqid = fixture_proc_pidt_bsdinfowithuniqid;
    pub const ProcUniqueInfo = FixtureProcUniqueInfo;
    pub const NoProcess = FixtureNoProcess;
    pub const proc_pid_unique_info = fixture_proc_pid_unique_info;
    pub const childrenOf = fixtureChildrenOf;
    pub const childrenOfNobody = fixtureChildrenOfNobody;
    pub const childrenOfDarwin = fixtureChildrenOfDarwin;
    pub const DarwinForks = FixtureDarwinForks;
    pub const NoForks = FixtureNoForks;
    pub const membersLinux = fixtureMembersLinux;
    pub const membersDarwin = fixtureMembersDarwin;

    pub fn snapshot(pid: ?posix.pid_t) void {
        snapshot_witness = pid;
    }
    pub fn delivery(callback: ?*const fn () void) void {
        before_token_delivery = callback;
    }
} else struct {};
const FixtureDeadline = Deadline;
const fixture_wait_for = wait_for;
const fixtureSignalDescendantsGuarded = signalDescendantsGuarded;
const fixtureWaitCaptured = waitCaptured;
const fixtureProvenBelow = provenBelow;
const fixtureParentOf = parentOf;
const fixture_collect = collect;
const fixtureCollectLinux = collectLinux;
const FixtureLinuxRelation = LinuxRelation;
const fixtureProcessRelationLinux = processRelationLinux;
const fixtureParseLinuxStat = parseLinuxStat;
const fixtureCaptureStartedProcess = captureStartedProcess;
const fixtureKillHeld = killHeld;
const FixtureStarted = Started;
const fixtureSignalGroupSinceImpl = signalGroupSinceImpl;
const FixtureProcBsdInfo = ProcBsdInfo;
const fixture_proc_pidtbsdinfo = proc_pidtbsdinfo;
const fixture_proc_status_zombie = proc_status_zombie;
const fixtureCaptureChildren = captureChildren;
const FixtureProcess = Process;
const FixtureLinuxProcess = LinuxProcess;
const FixtureAuditToken = AuditToken;
const FixtureBsdInfoWithUniqueId = BsdInfoWithUniqueId;
const fixture_proc_pidt_bsdinfowithuniqid = proc_pidt_bsdinfowithuniqid;
const FixtureProcUniqueInfo = ProcUniqueInfo;
const FixtureNoProcess = NoProcess;
const fixture_proc_pid_unique_info = proc_pid_unique_info;
const fixtureChildrenOf = childrenOf;
const fixtureChildrenOfNobody = childrenOfNobody;
const fixtureChildrenOfDarwin = childrenOfDarwin;
const FixtureDarwinForks = DarwinForks;
const FixtureNoForks = NoForks;
const fixtureMembersLinux = membersLinux;
const fixtureMembersDarwin = membersDarwin;
