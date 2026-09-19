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
//! POSIX only. Nothing here allocates: `Child.kill` takes no allocator, and a
//! kill that could fail for want of memory would be a poor kind of kill.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;

/// The most descendants one pass will name.
///
/// A bound rather than a guess: without an allocator the buffer is a fixed
/// array, and a tree larger than this is still reached through its process
/// group. Four generations of eight children each is 584; this is more than
/// any tree a spawn of this package's is likely to grow, and it is 2 KiB of
/// stack.
const max_descendants = 512;

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
pub fn signalDescendants(root: posix.pid_t, sig: posix.SIG, in_group: ?posix.pid_t) usize {
    var found: [max_descendants]posix.pid_t = undefined;
    const count = collect(root, &found);

    var reached: usize = 0;
    var i = count;
    while (i > 0) {
        i -= 1;
        const pid = found[i];
        // Nothing this package started can be `init` or this process itself,
        // and a signal to either would be a bug worth refusing rather than
        // sending.
        if (pid <= 1 or pid == c.getpid()) continue;
        if (in_group) |pgid| if (getpgid(pid) == pgid) continue;
        if (c.kill(pid, sig) == 0) reached += 1;
    }
    return reached;
}

/// Fills `into` with the descendants of `root`, breadth first, and returns how
/// many there were.
///
/// Breadth first so that the order in the array is by generation, which makes
/// walking it backwards the deepest-first order `signalDescendants` sends in.
fn collect(root: posix.pid_t, into: []posix.pid_t) usize {
    var count = childrenOf(root, into);
    var expanded: usize = 0;
    while (expanded < count) : (expanded += 1) {
        count += childrenOf(into[expanded], into[count..]);
    }
    return count;
}

/// The immediate children of `pid`, as many of them as `into` has room for.
const childrenOf = switch (builtin.os.tag) {
    .linux => childrenOfLinux,
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => childrenOfDarwin,
    // No cheap way to ask, so the process group is the whole of the reach.
    else => childrenOfNobody,
};

fn childrenOfNobody(pid: posix.pid_t, into: []posix.pid_t) usize {
    _ = pid;
    _ = into;
    return 0;
}

//======================================================================
// Darwin.
//======================================================================

/// From `<libproc.h>`, which is part of the system library rather than a
/// library of its own. Returns the number of children it wrote, or a negative
/// number.
extern "c" fn proc_listchildpids(ppid: posix.pid_t, buffer: ?*anyopaque, buffersize: c_int) c_int;

fn childrenOfDarwin(pid: posix.pid_t, into: []posix.pid_t) usize {
    if (into.len == 0) return 0;
    const bytes: c_int = @intCast(into.len * @sizeOf(posix.pid_t));
    const written = proc_listchildpids(pid, into.ptr, bytes);
    if (written <= 0) return 0;
    return @min(@as(usize, @intCast(written)), into.len);
}

//======================================================================
// Linux.
//======================================================================

/// `/proc/<pid>/task/<tid>/children` names the children one thread of a
/// process started, so the children of a process are the union over its
/// threads. A single-threaded child has one such file; a child with a thread
/// pool that forks from a worker has more, and missing those would be missing
/// exactly the descendants hardest to find another way.
fn childrenOfLinux(pid: posix.pid_t, into: []posix.pid_t) usize {
    if (into.len == 0) return 0;

    var path_buffer: [64]u8 = undefined;
    const tasks = std.fmt.bufPrintZ(&path_buffer, "/proc/{d}/task", .{pid}) catch return 0;
    const dir = c.open(tasks, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    if (dir < 0) return 0;
    defer _ = c.close(dir);

    var written: usize = 0;
    var entries: [2048]u8 align(@alignOf(std.os.linux.dirent64)) = undefined;
    while (written < into.len) {
        const rc = std.os.linux.getdents64(dir, &entries, entries.len);
        if (std.os.linux.errno(rc) != .SUCCESS) return written;
        if (rc == 0) return written;

        var offset: usize = 0;
        while (offset < rc and written < into.len) {
            const entry: *align(1) const std.os.linux.dirent64 = @ptrCast(&entries[offset]);
            offset += entry.reclen;
            const name: [*:0]const u8 = @ptrCast(&entry.name);
            if (name[0] == '.') continue;
            written += childrenOfThread(pid, std.mem.span(name), into[written..]);
        }
    }
    return written;
}

fn childrenOfThread(pid: posix.pid_t, tid: []const u8, into: []posix.pid_t) usize {
    var path_buffer: [96]u8 = undefined;
    const path = std.fmt.bufPrintZ(
        &path_buffer,
        "/proc/{d}/task/{s}/children",
        .{ pid, tid },
    ) catch return 0;
    const fd = c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return 0;
    defer _ = c.close(fd);

    // One read. The file is a single line of decimal numbers separated by
    // spaces, and a tree with more children of one thread than this holds is
    // one the process group is still reaching.
    var text: [4096]u8 = undefined;
    const read = c.read(fd, &text, text.len);
    if (read <= 0) return 0;

    var written: usize = 0;
    var numbers = std.mem.tokenizeAny(u8, text[0..@intCast(read)], " \n\t");
    while (numbers.next()) |number| {
        if (written == into.len) break;
        into[written] = std.fmt.parseInt(posix.pid_t, number, 10) catch continue;
        written += 1;
    }
    return written;
}

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

    var found: [max_descendants]posix.pid_t = undefined;
    const count = collect(c.getpid(), &found);
    try testing.expect(std.mem.indexOfScalar(posix.pid_t, found[0..count], child.id) != null);
}
