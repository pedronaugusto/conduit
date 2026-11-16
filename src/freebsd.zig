//! FreeBSD's process table as `sysctl kern.proc` answers it: a process's
//! `struct kinfo_proc` (`<sys/user.h>`), read through the fields conduit asks
//! of it. std declares neither the structure nor the request, so both are
//! here, for the 64-bit targets alone (amd64, arm64, riscv64, powerpc64),
//! where the structure is `KINFO_PROC_SIZE`, 1088 bytes: every answer is
//! checked against that size before a field is read.
const std = @import("std");
const builtin = @import("builtin");

const c = std.c;
const posix = std.posix;

/// Whether this target reads the table: FreeBSD on a 64-bit architecture.
pub const supported = builtin.target.os.tag == .freebsd and @sizeOf(usize) == 8;

/// `KINFO_PROC_SIZE` on the 64-bit architectures.
const kinfo_size = 1088;

/// Byte offsets into `struct kinfo_proc` (FreeBSD 12 and later, 64-bit), as
/// `<sys/user.h>` lays it out: eight pointers after two ints, then the ids.
const at = struct {
    const structsize = 0; // int
    const pid = 72; // pid_t
    const ppid = 76;
    const pgid = 80;
    const sid = 88;
    const rssize = 264; // segsz_t (long), pages
    const start = 336; // struct timeval: tv_sec (time_t), tv_usec (long)
    const stat = 388; // char, an S* state
    const rusage = 608; // struct rusage: two timevals, then ru_maxrss (long, KiB)
    const maxrss = rusage + 32;
};

/// `ki_stat` of a process that has ended and waits to be reaped.
const szomb = 5;

const ctl_kern = 1;
const kern_proc = 14;
const kern_proc_pid = 1;
const kern_proc_pgrp = 2;
const kern_proc_proc = 8;

/// What conduit reads of one process's entry.
pub const Process = struct {
    pid: posix.pid_t,
    parent: posix.pid_t,
    group: posix.pid_t,
    session: posix.pid_t,
    /// When it started: seconds and microseconds since the epoch, as the
    /// kernel gives it (its start in uptime, plus the boot time).
    start_seconds: u64,
    start_microseconds: u64,
    /// Ended and waiting to be reaped: it runs nothing and holds no memory.
    zombie: bool,
    /// Resident pages now, and the most resident memory it has held, in KiB.
    resident_pages: u64,
    max_resident_kib: u64,

    fn read(entry: *const [kinfo_size]u8) ?Process {
        if (field(c_int, entry, at.structsize) != kinfo_size) return null;
        return .{
            .pid = field(posix.pid_t, entry, at.pid),
            .parent = field(posix.pid_t, entry, at.ppid),
            .group = field(posix.pid_t, entry, at.pgid),
            .session = field(posix.pid_t, entry, at.sid),
            .start_seconds = std.math.cast(u64, field(i64, entry, at.start)) orelse return null,
            .start_microseconds = std.math.cast(u64, field(i64, entry, at.start + 8)) orelse return null,
            .zombie = entry[at.stat] == szomb,
            .resident_pages = std.math.cast(u64, field(i64, entry, at.rssize)) orelse return null,
            .max_resident_kib = std.math.cast(u64, field(i64, entry, at.maxrss)) orelse return null,
        };
    }
};

fn field(comptime T: type, entry: *const [kinfo_size]u8, offset: usize) T {
    return std.mem.readInt(T, entry[offset..][0..@sizeOf(T)], builtin.target.cpu.arch.endian());
}

/// The entry of `pid`, or null where no process has that number (or the
/// kernel answers in a shape this file does not read).
pub fn process(pid: posix.pid_t) ?Process {
    comptime std.debug.assert(supported);
    if (pid <= 0) return null;
    var entry: [kinfo_size]u8 align(8) = undefined;
    var len: usize = entry.len;
    const name = [_]c_int{ ctl_kern, kern_proc, kern_proc_pid, pid };
    if (c.sysctl(&name, name.len, &entry, &len, null, 0) != 0) return null;
    // No such process: the kernel answers nothing.
    if (len != kinfo_size) return null;
    const found = Process.read(&entry) orelse return null;
    return if (found.pid == pid) found else null;
}

pub const ListError = std.mem.Allocator.Error || error{Unexpected};

/// Every process (`group` null), or every process of the group `group`,
/// appended to `into`. The table can grow between the size asked and the
/// copy, so the copy is asked again, larger, until it fits.
pub fn list(gpa: std.mem.Allocator, group: ?posix.pid_t, into: *std.ArrayList(Process)) ListError!void {
    comptime std.debug.assert(supported);
    const name_all = [_]c_int{ ctl_kern, kern_proc, kern_proc_proc, 0 };
    const name_group = [_]c_int{ ctl_kern, kern_proc, kern_proc_pgrp, group orelse 0 };
    const name: []const c_int = if (group == null) name_all[0..3] else &name_group;
    var attempts: usize = 0;
    while (attempts < 8) : (attempts += 1) {
        var len: usize = 0;
        if (c.sysctl(name.ptr, @intCast(name.len), null, &len, null, 0) != 0) return error.Unexpected;
        // Room for the processes started while the copy is made.
        len += len / 4 + kinfo_size * 8;
        const bytes = try gpa.alignedAlloc(u8, .of(u64), len);
        defer gpa.free(bytes);
        if (c.sysctl(name.ptr, @intCast(name.len), bytes.ptr, &len, null, 0) != 0) {
            if (c.errno(@as(c_int, -1)) == .NOMEM) continue;
            return error.Unexpected;
        }
        if (len % kinfo_size != 0) return error.Unexpected;
        try into.ensureUnusedCapacity(gpa, len / kinfo_size);
        var offset: usize = 0;
        while (offset < len) : (offset += kinfo_size) {
            const found = Process.read(bytes[offset..][0..kinfo_size]) orelse return error.Unexpected;
            into.appendAssumeCapacity(found);
        }
        return;
    }
    return error.Unexpected;
}

test "the table's entry for this process names it, its parent, group and session, and when it started" {
    if (!supported) return error.SkipZigTest;
    const self = c.getpid();
    const me = process(self) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(self, me.pid);
    try std.testing.expectEqual(c.getppid(), me.parent);
    try std.testing.expect(me.group > 0 and me.session > 0);
    try std.testing.expect(!me.zombie);
    try std.testing.expect(me.start_seconds > 0 and me.start_microseconds < 1_000_000);
    try std.testing.expect(me.resident_pages > 0 and me.max_resident_kib > 0);
    // Asked again, the entry is the same process.
    const again = process(self) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(me.start_seconds, again.start_seconds);
    try std.testing.expectEqual(me.start_microseconds, again.start_microseconds);
    try std.testing.expectEqual(@as(?Process, null), process(std.math.maxInt(posix.pid_t)));
}

test "the whole table holds this process, and its group's holds it too" {
    if (!supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var all: std.ArrayList(Process) = .empty;
    defer all.deinit(gpa);
    try list(gpa, null, &all);
    var group: std.ArrayList(Process) = .empty;
    defer group.deinit(gpa);
    const me = process(c.getpid()) orelse return error.TestUnexpectedResult;
    try list(gpa, me.group, &group);
    const self = c.getpid();
    var in_all = false;
    for (all.items) |p| in_all = in_all or p.pid == self;
    var in_group = false;
    for (group.items) |p| {
        try std.testing.expectEqual(me.group, p.group);
        in_group = in_group or p.pid == self;
    }
    try std.testing.expect(in_all and in_group);
}
