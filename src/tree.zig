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
//! * **Linux** names the children of a process in
//!   `/proc/<pid>/task/<tid>/children`, one file per thread, so the whole tree
//!   is reachable by walking it.
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
    var found: std.ArrayList(Process) = .empty;
    defer {
        for (found.items) |*process| process.deinit();
        found.deinit(std.heap.page_allocator);
    }
    try collect(root, &found);

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
        if (in_group) |pgid| if (getpgid(pid) == pgid) continue;
        if (process.signal(sig)) reached += 1;
    }
    return reached;
}

/// Fills `into` with the descendants of `root`, breadth first, and returns how
/// many there were.
///
/// Breadth first so that the order in the array is by generation, which makes
/// walking it backwards the deepest-first order `signalDescendants` sends in.
fn collect(root: posix.pid_t, into: *std.ArrayList(Process)) std.mem.Allocator.Error!void {
    try captureChildren(root, into);
    var expanded: usize = 0;
    while (expanded < into.items.len) : (expanded += 1) {
        try captureChildren(into.items[expanded].pid, into);
    }
}

fn captureChildren(parent: posix.pid_t, into: *std.ArrayList(Process)) std.mem.Allocator.Error!void {
    var pids: std.ArrayList(posix.pid_t) = .empty;
    defer pids.deinit(std.heap.page_allocator);
    try childrenOf(parent, &pids);
    for (pids.items) |pid| {
        var process = Process.capture(pid) orelse continue;
        into.append(std.heap.page_allocator, process) catch |err| {
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
    .linux => childrenOfLinux,
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => childrenOfDarwin,
    // No cheap way to ask, so the process group is the whole of the reach.
    else => childrenOfNobody,
};

fn childrenOfNobody(pid: posix.pid_t, into: *std.ArrayList(posix.pid_t)) std.mem.Allocator.Error!void {
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

fn childrenOfDarwin(pid: posix.pid_t, into: *std.ArrayList(posix.pid_t)) std.mem.Allocator.Error!void {
    const estimate = proc_listchildpids(pid, null, 0);
    if (estimate <= 0) return;

    var capacity: usize = @intCast(estimate);
    while (true) {
        try into.resize(std.heap.page_allocator, capacity);
        const bytes: c_int = @intCast(capacity * @sizeOf(posix.pid_t));
        const written = proc_listchildpids(pid, into.items.ptr, bytes);
        if (written <= 0) {
            into.clearRetainingCapacity();
            return;
        }
        const count: usize = @intCast(written);
        if (count < capacity) {
            into.shrinkRetainingCapacity(count);
            return;
        }
        capacity = std.math.mul(usize, capacity, 2) catch return error.OutOfMemory;
    }
}

//======================================================================
// Linux.
//======================================================================

/// `/proc/<pid>/task/<tid>/children` names the children one thread of a
/// process started, so the children of a process are the union over its
/// threads. A single-threaded child has one such file; a child with a thread
/// pool that forks from a worker has more, and missing those would be missing
/// exactly the descendants hardest to find another way.
fn childrenOfLinux(pid: posix.pid_t, into: *std.ArrayList(posix.pid_t)) std.mem.Allocator.Error!void {
    var path_buffer: [64]u8 = undefined;
    const tasks = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/task", .{pid}) catch return;
    const dir = c.open(tasks, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (dir < 0) return;
    defer _ = c.close(dir);

    var entries: [2048]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    while (true) {
        const rc = std.os.linux.getdents64(dir, &entries, entries.len);
        if (std.os.linux.errno(rc) != .SUCCESS) return;
        if (rc == 0) return;

        var offset: usize = 0;
        while (offset < rc) {
            const entry: *align(1) const std.os.linux.dirent64 = @ptrCast(&entries[offset]);
            offset += entry.reclen;
            const name: [*:0]const u8 = @ptrCast(&entry.name);
            if (name[0] == '.') continue;
            try childrenOfThread(pid, std.mem.span(name), into);
        }
    }
}

fn childrenOfThread(pid: posix.pid_t, tid: []const u8, into: *std.ArrayList(posix.pid_t)) std.mem.Allocator.Error!void {
    var path_buffer: [96]u8 = undefined;
    const path = std.fmt.bufPrintZ(
        &path_buffer,
        "/proc/{d}/task/{s}/children",
        .{ pid, tid },
    ) catch return;
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return;
    defer _ = c.close(fd);

    var text: [4096]u8 = undefined;
    var parser: ChildNumberParser = .{};
    while (true) {
        const read = c.read(fd, &text, text.len);
        if (read <= 0) break;
        try parser.feed(text[0..@intCast(read)], into);
    }
    try parser.finish(into);
}

const ChildNumberParser = struct {
    value: u64 = 0,
    have_digit: bool = false,
    valid: bool = true,

    fn feed(parser: *ChildNumberParser, text: []const u8, into: *std.ArrayList(posix.pid_t)) std.mem.Allocator.Error!void {
        for (text) |byte| {
            if (byte >= '0' and byte <= '9') {
                parser.have_digit = true;
                parser.value = std.math.mul(u64, parser.value, 10) catch {
                    parser.valid = false;
                    continue;
                };
                parser.value = std.math.add(u64, parser.value, byte - '0') catch {
                    parser.valid = false;
                    continue;
                };
            } else {
                try parser.finish(into);
            }
        }
    }

    fn finish(parser: *ChildNumberParser, into: *std.ArrayList(posix.pid_t)) std.mem.Allocator.Error!void {
        if (parser.have_digit and parser.valid) {
            if (std.math.cast(posix.pid_t, parser.value)) |pid| {
                try into.append(std.heap.page_allocator, pid);
            }
        }
        parser.* = .{};
    }
};

//======================================================================
// Shared.
//======================================================================

/// Not declared in `std.c`, and the one question that tells a descendant which
/// `Child.kill` is about to reach anyway from one that has left the group.
extern "c" fn getpgid(pid: posix.pid_t) posix.pid_t;

test "the descendants of this process include a child it just started" {
    const testing = std.testing;
    const Child = @import("Child.zig");
    // The systems that cannot answer answer nothing, which is correct and not
    // something to assert a pid against.
    if (childrenOf == childrenOfNobody) return error.SkipZigTest;

    var child = try Child.spawn(testing.io, testing.allocator, .{
        .argv = &.{ "/bin/sh", "-c", "sleep 30" },
        .stdio = .ignore,
    });
    defer child.deinit(testing.io);
    defer _ = child.killWait(testing.io, 0) catch {};

    var found: std.ArrayList(Process) = .empty;
    defer {
        for (found.items) |*process| process.deinit();
        found.deinit(std.heap.page_allocator);
    }
    try collect(c.getpid(), &found);
    for (found.items) |process| {
        if (process.pid == child.id) return;
    }
    return error.TestChildWasNotFound;
}

test "a Linux children list is not truncated at 512 processes or one read" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;

    var found: std.ArrayList(posix.pid_t) = .empty;
    defer found.deinit(std.heap.page_allocator);
    var parser: ChildNumberParser = .{};
    var number: [32]u8 = undefined;
    for (0..513) |i| {
        const text = try std.fmt.bufPrint(&number, "{d} ", .{i + 2});
        const split = @min(text.len, (i % text.len) + 1);
        try parser.feed(text[0..split], &found);
        try parser.feed(text[split..], &found);
    }
    try parser.finish(&found);

    try std.testing.expectEqual(@as(usize, 513), found.items.len);
    try std.testing.expectEqual(@as(posix.pid_t, 514), found.items[512]);
}
