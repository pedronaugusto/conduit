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
    if (builtin.is_test) _ = walks.fetchAdd(1, .monotonic);
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
    state: u8,
    ppid: posix.pid_t,
    pgrp: posix.pid_t,
    /// Field 22: when the process started, in clock ticks after boot.
    start: ?u64 = null,
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
    const state = fields.next() orelse return null;
    if (state.len != 1) return null;
    const ppid = std.fmt.parseInt(posix.pid_t, fields.next() orelse return null, 10) catch return null;
    const pgrp = std.fmt.parseInt(posix.pid_t, fields.next() orelse return null, 10) catch return null;
    // Fields 6 to 21, then 22, the start time. A record that stops short of
    // it still names the process's relations.
    var start: ?u64 = null;
    for (6..22) |_| {
        if (fields.next() == null) break;
    } else start = std.fmt.parseInt(u64, fields.next() orelse "", 10) catch null;
    return .{ .state = state[0], .ppid = ppid, .pgrp = pgrp, .start = start };
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
pub fn startTime(pid: posix.pid_t) error{Unsupported}!?u64 {
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
/// Linux, an audit token on Darwin. `signal` reaches that process or
/// nothing — once it has ended, never a process given the same pid since.
/// `alive` says whether it has ended (a zombie has); ask it rather than
/// sending signal 0, which Darwin refuses through a token. `pid` is the
/// number it had, for reports. `deinit` lets go of it.
pub const CapturedPid = Process;

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
/// answers the start time and the pid's version together, and the audit
/// token is made from that version; a signal through it is refused by the
/// kernel for any other process at that pid. `error.Unsupported` elsewhere.
pub fn captureStarted(pid: posix.pid_t, since: u64) error{Unsupported}!?CapturedPid {
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

/// Signal the live members of a Linux process group whose leader was
/// started at `since`. A crashed parent's death signal can end the leader
/// before the next process can walk its tree; its group still names the
/// children it left. A member is captured by pidfd before its group and
/// start time are checked, and is signalled through that same descriptor.
/// The leader is left to the caller, which may hold its own identity.
pub fn signalGroupSince(group: posix.pid_t, leader: posix.pid_t, since: u64, sig: posix.SIG) error{Unsupported}!usize {
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
        var offset: usize = 0;
        while (offset < rc) {
            const entry: *align(1) const std.os.linux.dirent64 = @ptrCast(&entries[offset]);
            offset += entry.reclen;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
            const pid = std.fmt.parseInt(posix.pid_t, name, 10) catch continue;
            if (pid <= 1 or pid == leader or pid == c.getpid()) continue;
            var process = LinuxProcess.capture(pid) orelse continue;
            defer process.deinit();
            const relation = processRelationLinux(pid) orelse continue;
            if (relation.pgrp != group or relation.start == null or relation.start.? < since or
                relation.state == 'Z' or relation.state == 'X') continue;
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

    pub fn signal(process: *const LinuxProcess, sig: posix.SIG) bool {
        const rc = std.os.linux.pidfd_send_signal(process.pidfd, sig, null, 0);
        return std.os.linux.errno(rc) == .SUCCESS;
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

    /// The process at `pid` if it started at `since`, from one lookup that
    /// answers the start time and the version of the pid together.
    fn captureStarted(pid: posix.pid_t, since: u64) ?DarwinProcess {
        var info: BsdInfoWithUniqueId = undefined;
        const written = proc_pidinfo(pid, proc_pidt_bsdinfowithuniqid, 0, &info, @sizeOf(BsdInfoWithUniqueId));
        if (written != @sizeOf(BsdInfoWithUniqueId)) return null;
        if (info.bsd.status == proc_status_zombie) return null;
        if (info.bsd.start_tvsec *% std.time.us_per_s +% info.bsd.start_tvusec != since) return null;
        var token: AuditToken = .{ .val = @splat(0) };
        token.val[5] = @bitCast(pid);
        token.val[7] = @bitCast(info.unique.id_version);
        return .{ .pid = pid, .token = token };
    }

    /// The kernel refuses signal 0 through a token (`EINVAL`), so `alive`
    /// and not this is how to ask whether the process is still there.
    pub fn signal(process: *const DarwinProcess, sig: posix.SIG) bool {
        var token = process.token;
        return proc_signal_with_audittoken(&token, @intCast(@intFromEnum(sig))) == 0;
    }

    /// Whether the process has not ended: the pid still has the version the
    /// token holds, and what holds it is not a zombie.
    pub fn alive(process: *const DarwinProcess) bool {
        var info: BsdInfoWithUniqueId = undefined;
        const written = proc_pidinfo(process.pid, proc_pidt_bsdinfowithuniqid, 0, &info, @sizeOf(BsdInfoWithUniqueId));
        if (written != @sizeOf(BsdInfoWithUniqueId)) return false;
        return info.unique.id_version == @as(i32, @bitCast(process.token.val[7])) and
            info.bsd.status != proc_status_zombie;
    }

    pub fn deinit(process: *DarwinProcess) void {
        _ = process;
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

    pub fn alive(process: *const NoProcess) bool {
        _ = process;
        return false;
    }

    pub fn deinit(process: *NoProcess) void {
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
    var path_buffer: [64]u8 = undefined;
    const path = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/task", .{pid}) catch return true;
    const dir = c.open(path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (dir < 0) return true;
    defer _ = c.close(dir);

    var threads: usize = 0;
    var entries: [1024]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    while (true) {
        const rc = std.os.linux.getdents64(dir, &entries, entries.len);
        if (std.os.linux.errno(rc) != .SUCCESS) return true;
        if (rc == 0) break;
        var offset: usize = 0;
        while (offset < rc) {
            const entry: *align(1) const std.os.linux.dirent64 = @ptrCast(&entries[offset]);
            offset += entry.reclen;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
            _ = std.fmt.parseInt(posix.pid_t, name, 10) catch continue;
            threads += 1;
            var file_buffer: [32]u8 = undefined;
            const file = std.fmt.bufPrintZ(&file_buffer, "{s}/children", .{name}) catch return true;
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

const DarwinForks = struct {
    /// The kqueue, or `null` where none could be had: then every question
    /// answers `true`. Not inherited by any child: the kernel confines a
    /// kqueue to the process that made it.
    queue: ?posix.fd_t,
    /// A note once taken off the queue. The registration clears on reading
    /// (the kernel makes every `EVFILT_PROC` one `EV_CLEAR`), so what one
    /// question learned is kept here for the next.
    seen: std.atomic.Value(bool) = .init(false),
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
            .fflags = c.NOTE.FORK,
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
        // `kevent64` takes: measured here, a zero timeout still costs 14 µs
        // a call, the flag 0.3 µs.
        var events: [2]c.kevent64_s = undefined;
        var nothing: [0]c.kevent64_s = undefined;
        const ready = c.kevent64(queue, &nothing, 0, &events, events.len, .{ .IMMEDIATE = true }, null);
        if (ready < 0) return true;
        for (events[0..@intCast(ready)]) |event| {
            if (event.fflags & c.NOTE.FORK != 0) forks.seen.store(true, .release);
        }
        return forks.seen.load(.acquire);
    }

    pub fn close(forks: *DarwinForks) void {
        if (forks.queue) |queue| _ = c.close(queue);
        forks.queue = null;
    }
};

/// Test builds only: what a test needs to show the watch has no window.
pub const testing_hook = struct {
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

const NoForks = struct {
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

        var offset: usize = 0;
        while (offset < rc) {
            const entry: *align(1) const std.os.linux.dirent64 = @ptrCast(&entries[offset]);
            offset += entry.reclen;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.name)));
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

test "a group is empty but for its leader once what the leader started has ended" {
    const testing = std.testing;
    const Child = @import("Child.zig");
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
    const pgid = child.pgid.?;

    var waited_ms: u32 = 0;
    while (members(pgid, child.id) != .others) : (waited_ms += 2) {
        if (waited_ms > 5000) return error.TestMemberNotSeen;
        try std.Io.sleep(testing.io, .fromMilliseconds(2), .awake);
    }
    child.closeStdin(testing.io);
    waited_ms = 0;
    while (members(pgid, child.id) != .none) : (waited_ms += 2) {
        if (waited_ms > 5000) return error.TestMemberStayed;
        try std.Io.sleep(testing.io, .fromMilliseconds(2), .awake);
    }
}

test "a Linux process with a child of its own is said to have one, and one without is not" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    const Child = @import("Child.zig");

    var leaf = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sleep", "30" },
        .stdio = .ignore,
    });
    defer leaf.deinit(testing.io);
    defer _ = leaf.killWait(testing.io, 0) catch {};
    try testing.expect(!hasChildren(leaf.id));

    // The `;` keeps the shell from replacing itself with `sleep`.
    var parent = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30; :" },
        .stdio = .ignore,
    });
    defer parent.deinit(testing.io);
    defer _ = parent.killWait(testing.io, 0) catch {};
    var waited_ms: u32 = 0;
    while (!hasChildren(parent.id)) : (waited_ms += 2) {
        if (waited_ms > 5000) return error.TestChildNotSeen;
        try std.Io.sleep(testing.io, .fromMilliseconds(2), .awake);
    }

    // Nothing to read is not "nothing below it": the answer is the walk.
    try testing.expect(hasChildren(std.math.maxInt(posix.pid_t)));
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

test "a process's start time is its own: the same while it runs, gone once it is reaped" {
    const testing = std.testing;
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }
    const own = (try startTime(c.getpid())).?;
    try std.testing.expectEqual(own, (try startTime(c.getpid())).?);

    const Child = @import("Child.zig");
    var child = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.deinit(testing.io);
    const pid = child.id;
    const started = (try startTime(pid)).?;
    try std.testing.expectEqual(started, (try startTime(pid)).?);
    // a process started after this one did not start before it
    try std.testing.expect(started >= own);
    child.stdin.?.close(testing.io);
    child.stdin = null;
    _ = try child.wait(testing.io);
    try std.testing.expectEqual(@as(?u64, null), try startTime(pid));
}

test "a captured pid stays bound to the recorded process, and a start time that does not match refuses" {
    switch (builtin.os.tag) {
        .linux, .macos => {},
        else => return error.SkipZigTest,
    }
    const testing = std.testing;
    const Child = @import("Child.zig");
    var child = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .ignore, .stderr = .ignore } },
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};
    const started = (try startTime(child.id)).?;
    try testing.expect((try captureStarted(child.id, started + 1)) == null);
    try testing.expect((try captureStarted(child.id, started -% 1)) == null);
    var captured = (try captureStarted(child.id, started)).?;
    defer captured.deinit();
    try testing.expectEqual(child.id, captured.pid);
    try testing.expect(captured.alive());
    // A signal the shell's default action ignores, sent through the capture.
    try testing.expect(captured.signal(.CONT));
    child.stdin.?.close(testing.io);
    child.stdin = null;
    _ = try child.wait(testing.io);
    // Ended and reaped: the capture reaches nothing, whoever has the number.
    try testing.expect(!captured.alive());
    try testing.expect(!captured.signal(.CONT));
    try testing.expect((try captureStarted(child.id, started)) == null);
}

test "a leaderless Linux group keeps the child its leader started" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const testing = std.testing;
    const Child = @import("Child.zig");
    // The leader waits on its input, so it is still running when its start
    // time is read, and ends when that input closes.
    var leader = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30 & echo $!; read x" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
        .detach = true,
    });
    defer leader.deinit(testing.io);
    defer _ = leader.killWait(testing.io, 0) catch {};
    const group = leader.pgid.?;
    const since = (try startTime(leader.id)).?;
    var buffer: [32]u8 = undefined;
    var output = leader.stdout.?.reader(testing.io, &buffer);
    const member = try std.fmt.parseInt(posix.pid_t, (try output.interface.takeDelimiter('\n')).?, 10);
    errdefer {
        if (members(group, leader.id) == .others) _ = c.kill(-group, .KILL);
    }
    leader.closeStdin(testing.io);
    _ = try leader.wait(testing.io);
    try testing.expectEqual(Members.others, members(group, leader.id));
    try testing.expectEqual(@as(usize, 1), try signalGroupSince(group, leader.id, since, .KILL));
    var waited: u32 = 0;
    while ((try startTime(member)) != null) : (waited += 20) {
        if (waited >= 3000) return error.TestMemberStayed;
        try testing.io.sleep(.fromMilliseconds(20), .awake);
    }
}
