//! A cgroup of its own for each child, on Linux: a container no descendant
//! leaves by forking, by changing its process group or session, or by being
//! orphaned.
//!
//! A process group is an address, and the walk in `tree.zig` follows parent
//! links, which an orphan no longer has. A cgroup v2 is a set the kernel
//! keeps: a process is born into its parent's and stays there whatever it
//! does with its group, its session or its parent, until something with the
//! right to moves it. So where this process may make a cgroup below its own
//! — a subtree delegated to it, as systemd does for a user's session
//! manager and for `Delegate=yes` units, or a container given a writable
//! cgroup mount — `spawn` makes one per child and puts the child in it before
//! it runs its program, and `Child.kill` ends the whole of it:
//!
//! * `.kill` writes `1` to `cgroup.kill` (Linux 5.14), which the kernel makes
//!   safe against a fork in the cgroup while it is being delivered.
//! * `.terminate` and `.interrupt` read `cgroup.procs` and signal each member
//!   through a pidfd, the member confirmed still in the cgroup after its pidfd
//!   was opened, so a pid given to someone else meanwhile is not signalled.
//! * `cgroup.events` says whether anything in it is still running, which is
//!   how `Reaper.Options.end_tree` knows the tree has gone. A process that has
//!   ended and waits to be reaped is not counted, which is what lets the
//!   `Reaper` ask while it holds the child's own zombie.
//!
//! Whether this process may is found out, never assumed: `/proc/self/cgroup`
//! for where it is, `/proc/self/mountinfo` for where the cgroup v2 hierarchy
//! is mounted, `cgroup.kill` for a kernel new enough, and then the first
//! `mkdir`. A refusal at any step — a read-only mount, a cgroup owned by
//! someone else, a cgroup v1 system, a kernel before 5.14 — is remembered for
//! the life of the process, and every child from then on is started as it
//! was before, with the walk as its reach.
//!
//! The child joins by writing `0` to the new cgroup's `cgroup.procs` in the
//! fork child, before anything else it does: so a contained spawn always
//! takes the fork, since `posix_spawn` has no step that can write. The
//! descriptor is opened by the parent, close-on-exec. A child that cannot
//! join says so on the report pipe and runs uncontained; the parent then
//! removes the cgroup and stops trying.
//!
//! `Child.deinit` removes the cgroup. One still holding processes — what a
//! child started and nobody ended — cannot be removed while they run and is
//! left to them: it is remembered, and removed by a later spawn or `deinit`
//! of this process once it is empty. Up to sixteen such cgroups retain their
//! directory handles so later cleanup cannot remove a replacement at the same
//! name. Those processes stay contained and run on as they would have.
//!
//! What stays out of reach: a descendant that moves itself to another cgroup
//! it may write to — asks systemd for a scope of its own, say. The cgroup is
//! the reach, and that process has left it.

const builtin = @import("builtin");
const std = @import("std");
const posix = std.posix;
const c = std.c;
const Deadline = @import("deadline.zig").Deadline;

/// Whether this system has cgroups for `spawn` to use at all.
pub const supported = builtin.os.tag == .linux;

/// The cgroup a child was put in, or none. Linux only; elsewhere a type
/// that is always none.
pub const Cgroup = if (supported) LinuxCgroup else NoCgroup;

/// The boot that gives a recorded directory inode its meaning.
/// A complete UUID is required; a partial read never becomes an identity.
pub fn bootIdentity() ?[36]u8 {
    if (comptime !supported) return null;
    const fd = c.open("/proc/sys/kernel/random/boot_id", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var boot: [36]u8 = undefined;
    var filled: usize = 0;
    while (filled < boot.len) {
        const n = c.read(fd, boot[filled..].ptr, boot.len - filled);
        if (n < 0 and c.errno(n) == .INTR) continue;
        if (n <= 0) return null;
        filled += @intCast(n);
    }
    for (boot, 0..) |byte, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (byte != '-') return null;
        } else if (!std.ascii.isHex(byte)) return null;
    }
    return boot;
}

/// Test builds only: what lets a test run a child on the walk where a cgroup
/// could be had.
pub const testing_hook = struct {
    /// `prepare` answers `null` while this is set.
    pub var off: bool = false;
};

/// Whether anything but the leader's zombie is left: `tree.Members` in all
/// but name, kept apart so this file owns its own answer.
pub const Populated = enum { others, none, unknown };

//======================================================================
// Where this process's cgroup is.
//======================================================================

/// The directory of the cgroup this process is in, found once and kept.
const Place = struct {
    const Found = enum(u8) { unknown, finding, found, none };
    var found: std.atomic.Value(Found) = .init(.unknown);
    /// Written once, while `found` is `finding`, and read after `found`.
    var path_buffer: [std.fs.max_path_bytes:0]u8 = undefined;
    var path_len: usize = 0;
    /// Set once a cgroup could not be made or joined here: no more are
    /// tried. Those already made are still where `path` says.
    var refused: std.atomic.Value(bool) = .init(false);

    fn path() ?[:0]const u8 {
        while (true) switch (found.load(.acquire)) {
            .found => return path_buffer[0..path_len :0],
            .none => return null,
            .finding => std.Thread.yield() catch {},
            .unknown => {
                if (found.cmpxchgStrong(.unknown, .finding, .acquire, .monotonic) != null) continue;
                const ok = find();
                found.store(if (ok) .found else .none, .release);
            },
        };
    }

    /// Where a new cgroup may be made, or `null`.
    fn usable() ?[:0]const u8 {
        if (refused.load(.monotonic)) return null;
        return path();
    }

    fn refuse() void {
        refused.store(true, .monotonic);
    }

    fn find() bool {
        var own_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const own = ownCgroup(&own_buffer) orelse return false;
        var mount_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const mount = cgroup2Mount(&mount_buffer, &root_buffer) orelse return false;

        // The hierarchy may be mounted from below its root (a bind mount of a
        // subtree), in which case this process's path starts with it.
        const below: []const u8 = if (std.mem.eql(u8, mount.root, "/"))
            own
        else if (std.mem.startsWith(u8, own, mount.root) and
            (own.len == mount.root.len or own[mount.root.len] == '/'))
            own[mount.root.len..]
        else
            return false;
        const joined = std.fmt.bufPrintZ(&path_buffer, "{s}{s}", .{
            mount.point,
            if (std.mem.eql(u8, below, "/")) "" else below,
        }) catch return false;
        path_len = joined.len;

        // A kernel with no `cgroup.kill` (before 5.14) has no way to end a
        // cgroup at once, and this file does not pretend otherwise.
        var kill_buffer: [std.fs.max_path_bytes + 16]u8 = undefined;
        const kill_path = std.fmt.bufPrintZ(&kill_buffer, "{s}/cgroup.kill", .{joined}) catch return false;
        return c.faccessat(c.AT.FDCWD, kill_path, 0, 0) == 0;
    }
};

/// This process's path in the cgroup v2 hierarchy, from the `0::` line of
/// `/proc/self/cgroup`. `null` on a system with no such line (cgroup v1
/// only), or for a cgroup that has been removed.
fn ownCgroup(buffer: []u8) ?[]const u8 {
    const fd = c.open("/proc/self/cgroup", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = c.close(fd);
    var filled: usize = 0;
    while (filled < buffer.len) {
        const n = c.read(fd, buffer[filled..].ptr, buffer.len - filled);
        if (n <= 0) break;
        filled += @intCast(n);
    }
    var lines = std.mem.splitScalar(u8, buffer[0..filled], '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "0::")) continue;
        const path = line["0::".len..];
        if (path.len == 0 or path[0] != '/' or std.mem.endsWith(u8, path, " (deleted)")) return null;
        return path;
    }
    return null;
}

const Mount = struct { point: []const u8, root: []const u8 };

/// Where the cgroup v2 hierarchy is mounted, and from which of its
/// directories: the first `cgroup2` line of `/proc/self/mountinfo`. Read a
/// line at a time, since the file has no bound.
fn cgroup2Mount(point_buffer: []u8, root_buffer: []u8) ?Mount {
    const fd = c.open("/proc/self/mountinfo", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (fd < 0) return null;
    defer _ = c.close(fd);

    var window: [8192]u8 = undefined;
    var held: usize = 0;
    var at_end = false;
    // Inside a line longer than the window: an overlay mount with many
    // layers, say. It is not a cgroup2 line, and is read past.
    var skipping = false;
    while (true) {
        if (!at_end and held < window.len) {
            const n = c.read(fd, window[held..].ptr, window.len - held);
            if (n <= 0) at_end = true else held += @intCast(n);
        }
        const newline = std.mem.indexOfScalar(u8, window[0..held], '\n') orelse {
            if (at_end) return null;
            if (held == window.len) {
                skipping = true;
                held = 0;
            }
            continue;
        };
        if (!skipping) {
            if (parseMountLine(window[0..newline], point_buffer, root_buffer)) |mount| return mount;
        }
        skipping = false;
        std.mem.copyForwards(u8, window[0 .. held - newline - 1], window[newline + 1 .. held]);
        held -= newline + 1;
    }
}

/// One `mountinfo` line, if it is a `cgroup2` mount: fields 4 and 5 are the
/// root and the mount point, and the file system type follows the ` - `.
fn parseMountLine(line: []const u8, point_buffer: []u8, root_buffer: []u8) ?Mount {
    const separator = std.mem.indexOf(u8, line, " - ") orelse return null;
    var after = std.mem.tokenizeScalar(u8, line[separator + " - ".len ..], ' ');
    if (!std.mem.eql(u8, after.next() orelse return null, "cgroup2")) return null;
    var fields = std.mem.tokenizeScalar(u8, line[0..separator], ' ');
    _ = fields.next() orelse return null; // mount id
    _ = fields.next() orelse return null; // parent id
    _ = fields.next() orelse return null; // major:minor
    const root = unescape(fields.next() orelse return null, root_buffer) orelse return null;
    const point = unescape(fields.next() orelse return null, point_buffer) orelse return null;
    return .{ .point = point, .root = root };
}

/// `mountinfo` writes a space, a tab, a newline and a backslash in a path as
/// three octal digits after a backslash.
fn unescape(text: []const u8, into: []u8) ?[]const u8 {
    var out: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (out += 1) {
        if (out == into.len) return null;
        if (text[i] == '\\' and i + 4 <= text.len) {
            into[out] = std.fmt.parseInt(u8, text[i + 1 .. i + 4], 8) catch return null;
            i += 4;
        } else {
            into[out] = text[i];
            i += 1;
        }
    }
    return into[0..out];
}

//======================================================================
// Cgroups that could not be removed yet.
//======================================================================

/// The name of a cgroup this package made: `conduit-<owner>-<sequence>`, the
/// owner being this process's pid when it was made, so two processes in one
/// cgroup cannot choose the same name.
const Name = struct {
    owner: posix.pid_t,
    sequence: u32,

    fn path(name: Name, buffer: []u8) ?[:0]const u8 {
        const base = Place.path() orelse return null;
        return std.fmt.bufPrintZ(buffer, "{s}/conduit-{d}-{d}", .{ base, name.owner, name.sequence }) catch null;
    }

    /// `true` once the cgroup is gone, whoever removed it.
    fn remove(name: Name) bool {
        var buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
        const at = name.path(&buffer) orelse return true;
        if (c.rmdir(at) == 0) return true;
        return c.errno(@as(c_int, -1)) != .BUSY;
    }
};

/// Cgroups whose processes outlived the `Child` that made them. Removed as
/// soon as they are empty, by the next spawn or `deinit` to look.
const Leftovers = struct {
    /// Sixteen at a time. Past that, one is left for whatever removes this
    /// process's own cgroup: systemd a unit's, a container runtime its own.
    var owners: [16]?LinuxCgroup = @splat(null);
    var held: std.atomic.Value(bool) = .init(false);

    fn lock() void {
        while (held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.Thread.yield() catch {};
    }

    fn unlock() void {
        held.store(false, .release);
    }

    fn add(cgroup: LinuxCgroup) void {
        lock();
        defer unlock();
        for (&owners) |*slot| if (slot.* == null) {
            slot.* = cgroup;
            return;
        };
        // Bounded retention: a directory past the bound remains for the
        // owner of this process's cgroup, with no later by-name removal.
        _ = c.close(cgroup.innerConst().dir);
    }

    fn sweep() void {
        if (held.load(.monotonic)) return;
        lock();
        defer unlock();
        for (&owners) |*slot| if (slot.*) |*cgroup| {
            if (cgroup.remove()) {
                slot.* = null;
            } else if (cgroup.namedIdentity() == .gone) {
                // The original is gone or no longer has our name. Retire
                // only its handle; the replacement belongs to somebody else.
                _ = c.close(cgroup.inner().dir);
                slot.* = null;
            }
        };
    }
};

//======================================================================
// A child's cgroup.
//======================================================================

var sequence: std.atomic.Value(u32) = .init(0);

const CgroupState = struct {
    /// The child's cgroup directory, opened `O_PATH`, or -1 for none.
    dir: posix.fd_t,
    name: Name,
};

const LinuxCgroup = enum(@Int(.unsigned, @sizeOf(CgroupState) * 8)) {
    _,

    fn inner(value: *LinuxCgroup) *CgroupState {
        return @ptrCast(@alignCast(value)); // safe: construction writes inline state; the enum holds its size and alignment.
    }

    fn innerConst(value: *const LinuxCgroup) *const CgroupState {
        return @ptrCast(@alignCast(value)); // safe: observes the same initialized inline state without copying it.
    }

    fn init(dir: posix.fd_t, name: Name) LinuxCgroup {
        var value: LinuxCgroup = undefined;
        value.inner().* = .{ .dir = dir, .name = name };
        return value;
    }

    pub const Recorded = LinuxRecorded;

    // All bytes are 0xff: the directory is -1 on every layout, and the
    // unused name has no ownership. This also permits a comptime constant.
    pub const none: LinuxCgroup = @enumFromInt(std.math.maxInt(@Int(.unsigned, @sizeOf(CgroupState) * 8)));

    pub fn active(cgroup: *const LinuxCgroup) bool {
        return cgroup.innerConst().dir >= 0;
    }

    /// The directory inode that identifies this cgroup for this boot.
    pub fn id(cgroup: *const LinuxCgroup) ?u64 {
        if (!cgroup.active()) return null;
        var st: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(cgroup.innerConst().dir, "", std.os.linux.AT.EMPTY_PATH, .{ .INO = true }, &st);
        if (std.os.linux.errno(rc) != .SUCCESS or st.ino == 0) return null;
        return st.ino;
    }

    /// Open a cgroup recorded by an earlier run only while `path` still
    /// names the cgroup with `recorded_id`. The returned handle holds that
    /// directory for all member operations; a replacement at the same path
    /// can never become their target. The caller must also compare a recorded
    /// boot id, since inode identities are only valid within one boot.
    pub fn openRecorded(path_name: []const u8, recorded_id: u64) ?Recorded {
        return Recorded.open(path_name, recorded_id);
    }

    /// A new cgroup for a child about to be started, and the descriptor the
    /// fork child joins it through. `null` where this process may not make
    /// one, and from then on.
    pub fn prepare() ?Pending {
        if (builtin.is_test and testing_hook.off) return null;
        _ = Place.usable() orelse return null;
        Leftovers.sweep();

        const owner = c.getpid();
        var tries: u8 = 0;
        const name: Name = while (tries < 8) : (tries += 1) {
            const candidate: Name = .{ .owner = owner, .sequence = sequence.fetchAdd(1, .monotonic) };
            var buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
            const at = candidate.path(&buffer) orelse return null;
            if (c.mkdir(at, 0o755) == 0) break candidate;
            switch (c.errno(@as(c_int, -1))) {
                // Left by an earlier process that had this pid.
                .EXIST => continue,
                // Read-only, not this process's to write, or gone: not here.
                .ACCES, .PERM, .ROFS, .NOENT, .NOTDIR => {
                    Place.refuse();
                    return null;
                },
                // `NOSPC` is `cgroup.max.descendants` reached, which frees up
                // as children go: this child without one, the next one asks.
                else => return null,
            }
        } else return null;

        var buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
        const at = name.path(&buffer) orelse return null;
        const dir = c.open(at, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .PATH = true, .CLOEXEC = true });
        if (dir < 0) {
            _ = name.remove();
            return null;
        }
        const procs = c.openat(dir, "cgroup.procs", .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
        if (procs < 0) {
            _ = c.close(dir);
            _ = name.remove();
            Place.refuse();
            return null;
        }
        return Pending.init(init(dir, name), procs);
    }

    /// Where the cgroup is, for a report or a test.
    pub fn path(cgroup: *const LinuxCgroup, buffer: []u8) ?[:0]const u8 {
        if (!cgroup.active()) return null;
        return cgroup.innerConst().name.path(buffer);
    }

    const NamedIdentity = enum { matching, gone, unknown };

    fn namedIdentity(cgroup: *const LinuxCgroup) NamedIdentity {
        const owned_id = cgroup.id() orelse return .unknown;
        var buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
        const at = cgroup.path(&buffer) orelse return .unknown;
        const current = c.open(at, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .PATH = true, .NOFOLLOW = true, .CLOEXEC = true });
        if (current < 0) return if (c.errno(@as(c_int, -1)) == .NOENT) .gone else .unknown;
        defer _ = c.close(current);
        const check = init(current, cgroup.innerConst().name);
        const named_id = check.id() orelse return .unknown;
        return if (named_id == owned_id) .matching else .gone;
    }

    /// Remove an empty cgroup, refusing a path that now names another one.
    /// Returns false while it is populated or the path cannot be verified.
    /// Linux cannot compare the inode and remove the name atomically; a
    /// replacement between verification and removal can change the final entry.
    pub fn remove(cgroup: *LinuxCgroup) bool {
        if (!cgroup.active()) return true;
        if (cgroup.namedIdentity() != .matching) return false;
        var buffer: [std.fs.max_path_bytes + 64]u8 = undefined;
        const at = cgroup.path(&buffer) orelse return false;
        if (c.rmdir(at) != 0) return false;
        _ = c.close(cgroup.inner().dir);
        cgroup.* = none;
        return true;
    }

    pub fn kill(cgroup: *const LinuxCgroup) bool {
        return (MemberOps{ .dir = cgroup.innerConst().dir }).kill();
    }

    pub fn signalMembers(cgroup: *const LinuxCgroup, sig: posix.SIG, leader: posix.pid_t, in_group: ?posix.pid_t) std.mem.Allocator.Error!?usize {
        return (MemberOps{ .dir = cgroup.innerConst().dir }).signalMembers(sig, leader, in_group);
    }

    pub fn populated(cgroup: *const LinuxCgroup) Populated {
        return (MemberOps{ .dir = cgroup.innerConst().dir }).populated();
    }

    pub fn waitEmpty(cgroup: *const LinuxCgroup, io: std.Io, timeout_ms: u32) std.Io.Cancelable!bool {
        return (MemberOps{ .dir = cgroup.innerConst().dir }).waitEmpty(io, timeout_ms);
    }

    /// Lets go of the cgroup and removes it, or leaves it to be removed once
    /// what is in it has ended. Idempotent.
    pub fn release(cgroup: *LinuxCgroup) void {
        releaseWith(cgroup, Cleanup);
    }

    fn releaseWith(cgroup: *LinuxCgroup, comptime System: type) void {
        if (!cgroup.active()) return;
        if (System.remove(cgroup)) return;
        const retained = cgroup.*;
        cgroup.* = none;
        System.remember(retained);
        System.sweep();
    }

    const Cleanup = struct {
        fn remove(cgroup: *LinuxCgroup) bool {
            return cgroup.remove();
        }
        fn remember(cgroup: LinuxCgroup) void {
            Leftovers.add(cgroup);
        }
        fn sweep() void {
            Leftovers.sweep();
        }
    };
};

/// A cgroup found from a saved path and inode, with its parent held open.
/// The caller must check the saved boot id before using an inode from a record.
const RecordedState = struct {
    parent: posix.fd_t,
    dir: posix.fd_t,
    name: [std.fs.max_name_bytes + 1]u8,
    name_len: usize,
    recorded_id: u64,
};

const LinuxRecorded = enum(@Int(.unsigned, @sizeOf(RecordedState) * 8)) {
    _,

    fn inner(value: *LinuxRecorded) *RecordedState {
        return @ptrCast(@alignCast(value)); // safe: construction writes inline state; the enum holds its size and alignment.
    }

    fn innerConst(value: *const LinuxRecorded) *const RecordedState {
        return @ptrCast(@alignCast(value)); // safe: observes the same initialized inline state without copying it.
    }

    fn open(path_name: []const u8, recorded_id: u64) ?LinuxRecorded {
        if (recorded_id == 0 or path_name.len < 2 or path_name.len >= std.fs.max_path_bytes or path_name[0] != '/' or
            std.mem.indexOfScalar(u8, path_name, 0) != null) return null;
        const slash = std.mem.lastIndexOfScalar(u8, path_name, '/') orelse return null;
        const base = path_name[slash + 1 ..];
        if (base.len == 0 or base.len > std.fs.max_name_bytes or
            std.mem.eql(u8, base, ".") or std.mem.eql(u8, base, "..")) return null;

        var parent_name: [std.fs.max_path_bytes]u8 = undefined;
        const parent_len = if (slash == 0) 1 else slash;
        @memcpy(parent_name[0..parent_len], path_name[0..parent_len]);
        parent_name[parent_len] = 0;
        const parent = c.open(parent_name[0..parent_len :0], .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .PATH = true, .CLOEXEC = true });
        if (parent < 0) return null;
        var keep = false;
        defer {
            if (!keep) _ = c.close(parent);
        }

        var result: LinuxRecorded = undefined;
        result.inner().* = .{ .parent = parent, .dir = -1, .name = undefined, .name_len = base.len, .recorded_id = recorded_id };
        @memcpy(result.inner().name[0..base.len], base);
        result.inner().name[base.len] = 0;
        result.inner().dir = c.openat(parent, result.inner().name[0..base.len :0], .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .PATH = true, .NOFOLLOW = true, .CLOEXEC = true });
        if (result.inner().dir < 0) return null;
        defer {
            if (!keep) _ = c.close(result.inner().dir);
        }
        if (result.id() != recorded_id or !result.namedIdentityMatches()) return null;
        const events = c.openat(result.inner().dir, "cgroup.events", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (events < 0) return null;
        _ = c.close(events);
        keep = true;
        return result;
    }

    pub fn active(recorded: *const LinuxRecorded) bool {
        return recorded.innerConst().dir >= 0;
    }

    pub fn id(recorded: *const LinuxRecorded) ?u64 {
        if (!recorded.active()) return null;
        var st: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(recorded.innerConst().dir, "", std.os.linux.AT.EMPTY_PATH, .{ .INO = true }, &st);
        if (std.os.linux.errno(rc) != .SUCCESS or st.ino == 0) return null;
        return st.ino;
    }

    /// Whether the name in the held parent is still the recorded
    /// directory: `statx` on the name, not following a link.
    fn namedIdentityMatches(recorded: *const LinuxRecorded) bool {
        var st: std.os.linux.Statx = undefined;
        const rc = std.os.linux.statx(recorded.innerConst().parent, recorded.innerConst().name[0..recorded.innerConst().name_len :0], std.os.linux.AT.SYMLINK_NOFOLLOW, .{ .INO = true }, &st);
        return std.os.linux.errno(rc) == .SUCCESS and st.ino == recorded.innerConst().recorded_id;
    }

    /// Remove the empty directory through the held parent only if its name
    /// still has the recorded inode. A rename or replacement between this
    /// check and unlinkat can still change the final entry; Linux has no
    /// conditional unlinkat that compares the inode atomically.
    pub fn remove(recorded: *LinuxRecorded) bool {
        if (!recorded.active()) return true;
        if (!recorded.namedIdentityMatches()) return false;
        if (c.unlinkat(recorded.inner().parent, recorded.inner().name[0..recorded.inner().name_len :0], c.AT.REMOVEDIR) != 0) return false;
        _ = c.close(recorded.inner().dir);
        _ = c.close(recorded.inner().parent);
        recorded.inner().dir = -1;
        recorded.inner().parent = -1;
        return true;
    }

    pub fn release(recorded: *LinuxRecorded) void {
        if (!recorded.active()) return;
        if (recorded.remove()) return;
        _ = c.close(recorded.inner().dir);
        _ = c.close(recorded.inner().parent);
        recorded.inner().dir = -1;
        recorded.inner().parent = -1;
    }

    pub fn kill(recorded: *const LinuxRecorded) bool {
        return (MemberOps{ .dir = recorded.innerConst().dir }).kill();
    }

    pub fn signalMembers(recorded: *const LinuxRecorded, sig: posix.SIG, leader: posix.pid_t, in_group: ?posix.pid_t) std.mem.Allocator.Error!?usize {
        return (MemberOps{ .dir = recorded.innerConst().dir }).signalMembers(sig, leader, in_group);
    }

    pub fn populated(recorded: *const LinuxRecorded) Populated {
        return (MemberOps{ .dir = recorded.innerConst().dir }).populated();
    }

    pub fn waitEmpty(recorded: *const LinuxRecorded, io: std.Io, timeout_ms: u32) std.Io.Cancelable!bool {
        return (MemberOps{ .dir = recorded.innerConst().dir }).waitEmpty(io, timeout_ms);
    }
};

const MemberOps = struct {
    dir: posix.fd_t,

    fn active(ops: *const MemberOps) bool {
        return ops.dir >= 0;
    }

    /// Ends everything in the cgroup, the child with it: `cgroup.kill`.
    /// `false` if the kernel refused, and the caller has the walk.
    pub fn kill(cgroup: *const MemberOps) bool {
        const fd = c.openat(cgroup.dir, "cgroup.kill", .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
        if (fd < 0) return false;
        defer _ = c.close(fd);
        return c.write(fd, "1", 1) == 1;
    }

    /// Sends `sig` to every member but `leader` and those in the process
    /// group `in_group` (the caller signals those itself), each through a
    /// pidfd opened before the member is confirmed still in the cgroup. How
    /// many it reached, or `null` when the members could not be read and the
    /// caller has the walk.
    pub fn signalMembers(
        cgroup: *const MemberOps,
        sig: posix.SIG,
        leader: posix.pid_t,
        in_group: ?posix.pid_t,
    ) std.mem.Allocator.Error!?usize {
        var storage: [64 * 1024]u8 = undefined;
        var scratch = std.heap.FixedBufferAllocator.init(&storage);
        const allocator = scratch.allocator();

        var named: std.ArrayList(posix.pid_t) = .empty;
        defer named.deinit(allocator);
        if (!try cgroup.readMembers(&named, allocator)) return null;

        var captured: std.ArrayList(Held) = .empty;
        defer {
            for (captured.items) |held| _ = c.close(held.pidfd);
            captured.deinit(allocator);
        }
        for (named.items) |pid| {
            if (pid == leader or pid <= 1 or pid == c.getpid()) continue;
            if (in_group) |pgid| if (getpgid(pid) == pgid) continue;
            const rc = std.os.linux.pidfd_open(pid, 0);
            if (std.os.linux.errno(rc) != .SUCCESS) continue;
            captured.append(allocator, .{ .pid = pid, .pidfd = @intCast(rc) }) catch |err| {
                _ = c.close(@intCast(rc));
                return err;
            };
        }
        if (captured.items.len == 0) return 0;

        // A pidfd names the process that had the pid when it was opened. That
        // process is in the cgroup if the pid is listed now and the process is
        // still there when signalled: it held the number all along.
        named.clearRetainingCapacity();
        if (!try cgroup.readMembers(&named, allocator)) return null;
        std.mem.sort(posix.pid_t, named.items, {}, std.sort.asc(posix.pid_t));
        var reached: usize = 0;
        for (captured.items) |held| {
            if (std.sort.binarySearch(posix.pid_t, named.items, held.pid, orderPid) == null) continue;
            const rc = std.os.linux.pidfd_send_signal(held.pidfd, sig, null, 0);
            if (std.os.linux.errno(rc) == .SUCCESS) reached += 1;
        }
        return reached;
    }

    const Held = struct { pid: posix.pid_t, pidfd: posix.fd_t };

    fn orderPid(key: posix.pid_t, item: posix.pid_t) std.math.Order {
        return std.math.order(key, item);
    }

    /// `cgroup.procs`, every pid in it. `false` if it cannot be read.
    fn readMembers(
        cgroup: *const MemberOps,
        into: *std.ArrayList(posix.pid_t),
        allocator: std.mem.Allocator,
    ) std.mem.Allocator.Error!bool {
        const fd = c.openat(cgroup.dir, "cgroup.procs", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd < 0) return false;
        defer _ = c.close(fd);
        var window: [4096]u8 = undefined;
        var held: usize = 0;
        while (true) {
            const n = c.read(fd, window[held..].ptr, window.len - held);
            if (n < 0) return false;
            held += @intCast(n);
            // Whole lines only; a number cut by the end of a read waits for
            // the next one.
            const last = std.mem.lastIndexOfScalar(u8, window[0..held], '\n');
            const complete = if (last) |at| at + 1 else if (n == 0) held else 0;
            var numbers = std.mem.tokenizeAny(u8, window[0..complete], "\n ");
            while (numbers.next()) |word| {
                const pid = std.fmt.parseInt(posix.pid_t, word, 10) catch continue;
                try into.append(allocator, pid);
            }
            std.mem.copyForwards(u8, window[0 .. held - complete], window[complete..held]);
            held -= complete;
            if (n == 0) return true;
        }
    }

    /// Whether anything is still running in the cgroup, from
    /// `cgroup.events`. A process that has ended and waits to be reaped is
    /// not.
    pub fn populated(cgroup: *const MemberOps) Populated {
        const fd = c.openat(cgroup.dir, "cgroup.events", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd < 0) return .unknown;
        defer _ = c.close(fd);
        var text: [256]u8 = undefined;
        const n = c.read(fd, &text, text.len);
        if (n <= 0) return .unknown;
        var lines = std.mem.splitScalar(u8, text[0..@intCast(n)], '\n');
        while (lines.next()) |line| {
            if (std.mem.eql(u8, line, "populated 0")) return .none;
            if (std.mem.eql(u8, line, "populated 1")) return .others;
        }
        return .unknown;
    }

    /// Wait for `cgroup.events` to say the cgroup is empty. The event file
    /// wakes a poll when `populated` changes. If it cannot be opened or
    /// polled, only then use bounded 1–4 ms clock-based checks. True means
    /// empty; false means the deadline passed or the state could not be read.
    pub fn waitEmpty(cgroup: *const MemberOps, io: std.Io, timeout_ms: u32) std.Io.Cancelable!bool {
        if (!cgroup.active()) return true;
        const deadline: Deadline = .in(io, timeout_ms);
        const events = c.openat(cgroup.dir, "cgroup.events", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        defer {
            if (events >= 0) _ = c.close(events);
        }
        var watching = events >= 0;
        var text: [256]u8 = undefined;
        if (watching) _ = c.read(events, &text, text.len);
        var interval_ms: u32 = 1;
        while (true) {
            if (cgroup.populated() == .none) return true;
            const left = deadline.remainingMs(io);
            if (left == 0) return false;
            if (watching) {
                var fds = [_]posix.pollfd{.{ .fd = events, .events = posix.POLL.PRI, .revents = 0 }};
                const rc = std.os.linux.poll(&fds, 1, @intCast(@min(left, 5)));
                if (std.os.linux.errno(rc) == .SUCCESS) {
                    if (rc > 0) {
                        _ = std.os.linux.lseek(events, 0, std.os.linux.SEEK.SET);
                        _ = c.read(events, &text, text.len);
                    }
                    try std.Io.checkCancel(io);
                    continue;
                }
                watching = false;
            }
            try std.Io.sleep(io, .fromMilliseconds(@min(left, interval_ms)), .awake);
            interval_ms = @min(interval_ms * 2, 4);
        }
    }
};

/// A cgroup made for a child not yet started, and the descriptor the fork
/// child writes itself into it through.
const PendingState = struct {
    cgroup: Cgroup,
    procs: posix.fd_t,
};

pub const Pending = enum(@Int(.unsigned, @sizeOf(PendingState) * 8)) {
    _,

    fn inner(pending: *Pending) *PendingState {
        return @ptrCast(@alignCast(pending)); // safe: prepare initializes inline storage of this size and alignment.
    }

    fn init(cgroup: Cgroup, procs: posix.fd_t) Pending {
        var pending: Pending = undefined;
        pending.inner().* = .{ .cgroup = cgroup, .procs = procs };
        return pending;
    }

    /// Borrows the join descriptor until started or abandon consumes it; -1 afterwards.
    pub fn joinDescriptor(pending: Pending) posix.fd_t {
        const state: *const PendingState = @ptrCast(@alignCast(&pending)); // safe: reads the initialized inline storage without taking ownership.
        return state.procs;
    }

    /// The child is running, having joined or not. The cgroup to keep, or
    /// none if it did not join, and then no more cgroups for this process.
    /// Consumes the handoff; later calls own neither descriptor nor cgroup.
    pub fn started(pending: *Pending, joined: bool) Cgroup {
        const had_join = pending.closeProcs();
        var kept = pending.inner().cgroup;
        pending.inner().cgroup = .none;
        if (!joined) {
            kept.release();
            if (supported and had_join) Place.refuse();
        }
        return kept;
    }

    /// No child after all. Consumes the handoff; idempotent.
    pub fn abandon(pending: *Pending) void {
        _ = pending.closeProcs();
        pending.inner().cgroup.release();
    }

    fn closeProcs(pending: *Pending) bool {
        if (builtin.os.tag == .windows) return false; // No Windows prepare can create a join descriptor.
        const fd = pending.inner().procs;
        pending.inner().procs = -1;
        if (fd < 0) return false;
        _ = c.close(fd);
        return true;
    }
};

/// Internal fork handoff: reserve the scope's final force before the root runs.
/// The supervisor owns only this descriptor, never the caller's Cgroup state.
pub fn supervisorKillDescriptor(pending: Pending) ?posix.fd_t {
    if (!supported) return null;
    const state: *const PendingState = @ptrCast(@alignCast(&pending)); // safe: borrows initialized inline storage without transferring its descriptors.
    const fd = c.openat(state.cgroup.innerConst().dir, "cgroup.kill", .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
    return if (fd >= 0) fd else null;
}

/// Puts the calling process in the cgroup `procs` is the `cgroup.procs` of.
/// For the fork child: one `write`, async-signal-safe.
pub fn join(procs: posix.fd_t) bool {
    return c.write(procs, "0", 1) == 1;
}

const NoCgroup = enum(u8) {
    _,
    pub const Recorded = NoRecorded;
    pub const none: NoCgroup = @enumFromInt(0);

    pub fn active(cgroup: *const NoCgroup) bool {
        _ = cgroup;
        return false;
    }

    pub fn id(cgroup: *const NoCgroup) ?u64 {
        _ = cgroup;
        return null;
    }

    pub fn openRecorded(path_name: []const u8, recorded_id: u64) ?Recorded {
        _ = path_name;
        _ = recorded_id;
        return null;
    }

    pub fn remove(cgroup: *NoCgroup) bool {
        _ = cgroup;
        return true;
    }

    pub fn prepare() ?Pending {
        return null;
    }

    pub fn path(cgroup: *const NoCgroup, buffer: []u8) ?[:0]const u8 {
        _ = cgroup;
        _ = buffer;
        return null;
    }

    pub fn kill(cgroup: *const NoCgroup) bool {
        _ = cgroup;
        return false;
    }

    pub fn signalMembers(
        cgroup: *const NoCgroup,
        sig: posix.SIG,
        leader: posix.pid_t,
        in_group: ?posix.pid_t,
    ) std.mem.Allocator.Error!?usize {
        _ = cgroup;
        _ = sig;
        _ = leader;
        _ = in_group;
        return null;
    }

    pub fn populated(cgroup: *const NoCgroup) Populated {
        _ = cgroup;
        return .unknown;
    }

    pub fn waitEmpty(cgroup: *const NoCgroup, io: std.Io, timeout_ms: u32) std.Io.Cancelable!bool {
        _ = cgroup;
        _ = io;
        _ = timeout_ms;
        return true;
    }

    pub fn release(cgroup: *NoCgroup) void {
        _ = cgroup;
    }
};

const NoRecorded = enum(u8) {
    _,
    pub fn active(_: *const NoRecorded) bool {
        return false;
    }
    pub fn id(_: *const NoRecorded) ?u64 {
        return null;
    }
    pub fn remove(_: *NoRecorded) bool {
        return true;
    }
    pub fn release(_: *NoRecorded) void {}
    pub fn kill(_: *const NoRecorded) bool {
        return false;
    }
    pub fn signalMembers(_: *const NoRecorded, _: posix.SIG, _: posix.pid_t, _: ?posix.pid_t) std.mem.Allocator.Error!?usize {
        return null;
    }
    pub fn populated(_: *const NoRecorded) Populated {
        return .unknown;
    }
    pub fn waitEmpty(_: *const NoRecorded, _: std.Io, _: u32) std.Io.Cancelable!bool {
        return true;
    }
};

extern "c" fn getpgid(pid: posix.pid_t) posix.pid_t;

test "a cgroup2 line of mountinfo names its mount point and root, and nothing else does" {
    var point: [64]u8 = undefined;
    var root: [64]u8 = undefined;
    const found = parseMountLine(
        "35 24 0:30 / /sys/fs/cgroup rw,nosuid,nodev,noexec,relatime shared:9 - cgroup2 cgroup2 rw,nsdelegate",
        &point,
        &root,
    ).?;
    try std.testing.expectEqualStrings("/sys/fs/cgroup", found.point);
    try std.testing.expectEqualStrings("/", found.root);

    const escaped = parseMountLine(
        "40 24 0:31 /a\\040b /mnt/with\\040space rw - cgroup2 none rw",
        &point,
        &root,
    ).?;
    try std.testing.expectEqualStrings("/mnt/with space", escaped.point);
    try std.testing.expectEqualStrings("/a b", escaped.root);

    try std.testing.expect(parseMountLine(
        "25 24 0:22 / /sys/fs/cgroup/memory rw - cgroup cgroup rw,memory",
        &point,
        &root,
    ) == null);
}

test "cgroup handles expose no writable directory ownership" {
    try std.testing.expect(@typeInfo(Cgroup) == .@"enum");
    try std.testing.expect(@typeInfo(Cgroup.Recorded) == .@"enum");
}

test "deferred cgroup cleanup keeps directory ownership instead of removing a replacement" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const Replacement = struct {
        var unlinks: usize = 0;
        var closes: usize = 0;
        var retained: ?LinuxCgroup = null;

        fn remove(_: *LinuxCgroup) bool {
            // The owned directory has been renamed and its old name now
            // belongs to a replacement. The identity-aware removal refuses.
            return false;
        }
        fn close(_: posix.fd_t) void {
            closes += 1;
        }
        fn removeName(_: Name) bool {
            unlinks += 1;
            return true;
        }
        fn remember(cgroup: LinuxCgroup) void {
            retained = cgroup;
        }
        fn sweep() void {}
    };
    Replacement.unlinks = 0;
    Replacement.closes = 0;
    Replacement.retained = null;
    var cgroup = LinuxCgroup.init(7, .{ .owner = 123, .sequence = 1 });
    cgroup.releaseWith(Replacement);
    try std.testing.expectEqual(@as(usize, 0), Replacement.unlinks);
    try std.testing.expectEqual(@as(usize, 0), Replacement.closes);
    try std.testing.expect(!cgroup.active());
    var retained = Replacement.retained orelse return error.TestDirectoryOwnerLost;
    try std.testing.expect(retained.active());
    try std.testing.expectEqual(@as(posix.fd_t, 7), retained.inner().dir);
}

test "a consumed cgroup handoff cannot close a recycled join descriptor" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const ends = try @import("handles.zig").pipe();
    defer _ = c.close(ends[0]);
    var pending = Pending.init(.none, ends[1]);
    errdefer pending.abandon();
    var kept = pending.started(true);
    defer kept.release();

    // Force the just-closed descriptor to name a different, live pipe end.
    // No allocator or clock decides whether reuse happens in this test.
    try std.testing.expectEqual(ends[1], c.dup2(ends[0], ends[1]));
    defer _ = c.close(ends[1]);
    pending.abandon();
    _ = pending.started(true);
    try std.testing.expect(c.fcntl(ends[1], c.F.GETFD, @as(c_int, 0)) >= 0);
}

test "Pending exposes no writable cgroup handoff ownership" {
    try std.testing.expect(@typeInfo(Pending) == .@"enum");
}
