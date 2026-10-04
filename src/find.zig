//! Where a program named by a bare name would be found, asked on its own.
//!
//! `Child.spawn` searches for its program itself, in the child, and that is
//! where the search belongs: resolving a name and then starting what it
//! resolved to is two steps, and a window between them for the answer to
//! change. This is for the other question — whether something is installed at
//! all, to say so to a user — which is a lookup and nothing else.

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const is_windows = builtin.os.tag == .windows;
const windows_search = @import("Child/windows_search.zig");
const child_windows = if (is_windows) @import("Child/child_windows.zig") else struct {};

/// Where `name` resolves for a child given `environ`, by the rules
/// `Child.spawn` uses with `path_search = .child_environ`, or `null` when it
/// names nothing that could be run.
///
/// **POSIX**: a name with a `/` is itself; otherwise each entry of `PATH` in
/// turn, an empty one being the current directory, and the first that holds
/// something executable that is not a directory. With no `PATH` the search is
/// the one a shell falls back to. Relative entries resolve against this
/// process's working directory — `spawn` resolves them against the child's,
/// which is the same thing unless `cwd` is set.
///
/// **Windows**: the directory of this executable, the current directory, the
/// system directories, then `PATH`, with `.exe` supplied to a name with no
/// extension; a name with a separator or a drive is itself if it is a file.
/// Batch scripts are refused here as they are by spawn.
///
/// The path is allocated with `allocator` and is the caller's.
pub fn findProgram(
    io: std.Io,
    allocator: Allocator,
    environ: *const std.process.Environ.Map,
    name: []const u8,
) Allocator.Error!?[]u8 {
    if (name.len == 0) return null;
    if (is_windows) {
        var arena_state: std.heap.ArenaAllocator = .init(allocator);
        defer arena_state.deinit();
        if (!child_windows.isBareProgram(name)) {
            return directWindowsProgram(io, allocator, name);
        }
        if (windows_search.isBatchFile(name)) return null;
        const found = try child_windows.findBare(io, arena_state.allocator(), name, environ) orelse return null;
        return try allocator.dupe(u8, found);
    }

    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        return if (runnable(io, name)) try allocator.dupe(u8, name) else null;
    }
    // As `spawn`'s own search: what `confstr(_CS_PATH)` reports on the
    // systems this package supports.
    const directories = environ.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var it = std.mem.splitScalar(u8, directories, ':');
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    while (it.next()) |dir| {
        const prefix = if (dir.len == 0) "." else dir;
        const candidate = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ prefix, name }) catch continue;
        if (runnable(io, candidate)) return try allocator.dupe(u8, candidate);
    }
    return null;
}

/// A program that already names a Windows path still has to be a file.
/// This check uses the Io filesystem, so it is exercised on every host.
fn directWindowsProgram(io: std.Io, allocator: Allocator, name: []const u8) Allocator.Error!?[]u8 {
    if (windows_search.isBatchFile(name)) return null;
    const stat = std.Io.Dir.cwd().statFile(io, name, .{}) catch return null;
    if (stat.kind == .directory) return null;
    return try allocator.dupe(u8, name);
}

/// A file with an execute bit that this process may execute: what
/// `execve` asks. A directory is "executable" in the sense `access` asks
/// about, and runs nothing; and a privileged process passes `access` on a
/// file with no execute bit at all on some file systems, where `execve`
/// would still refuse it.
fn runnable(io: std.Io, path: []const u8) bool {
    const cwd = std.Io.Dir.cwd();
    const st = cwd.statFile(io, path, .{}) catch return false;
    if (st.kind == .directory) return false;
    if (st.permissions.toMode() & 0o111 == 0) return false;
    cwd.access(io, path, .{ .execute = true }) catch return false;
    return true;
}

test "a program on PATH is found where the search finds it, and a missing one is not" {
    if (is_windows) return error.SkipZigTest;
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = path_buffer[0..try tmp.dir.realPath(testing.io, &path_buffer)];

    // Not executable, then executable; and a directory by the same name
    // earlier on the path, which is passed over.
    try tmp.dir.createDirPath(testing.io, "early/prog");
    try tmp.dir.createDirPath(testing.io, "late");
    const f = try tmp.dir.createFile(testing.io, "late/prog", .{});
    f.close(testing.io);

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/early::{s}/late", .{ dir, dir });
    defer testing.allocator.free(path);
    try environ.put("PATH", path);

    try testing.expect(try findProgram(testing.io, testing.allocator, &environ, "prog") == null);
    try tmp.dir.setFilePermissions(testing.io, "late/prog", .fromMode(0o755), .{});
    const found = (try findProgram(testing.io, testing.allocator, &environ, "prog")).?;
    defer testing.allocator.free(found);
    const expected = try std.fmt.allocPrint(testing.allocator, "{s}/late/prog", .{dir});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, found);

    try testing.expect(try findProgram(testing.io, testing.allocator, &environ, "no-such-program") == null);
    // A name that is a path is itself, when it can be run.
    const direct = (try findProgram(testing.io, testing.allocator, &environ, expected)).?;
    defer testing.allocator.free(direct);
    try testing.expectEqualStrings(expected, direct);
}

test "on Windows a bare name is found on PATH with .exe supplied, and a directory by that name is passed over" {
    // The Windows half of the test above. Which of the places a search goes
    // holds the file is the part only a Windows machine can say; the order
    // of the places is `windows_search`'s, tested everywhere.
    if (!is_windows) return error.SkipZigTest;
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const dir = path_buffer[0..try tmp.dir.realPath(testing.io, &path_buffer)];

    try tmp.dir.createDirPath(testing.io, "early\\conduit-find-probe.exe");
    try tmp.dir.createDirPath(testing.io, "late");
    const f = try tmp.dir.createFile(testing.io, "late\\conduit-find-probe.exe", .{});
    f.close(testing.io);

    var environ: std.process.Environ.Map = .init(testing.allocator);
    defer environ.deinit();
    const path = try std.fmt.allocPrint(testing.allocator, "{s}\\early;{s}\\late", .{ dir, dir });
    defer testing.allocator.free(path);
    try environ.put("PATH", path);

    const expected = try std.fmt.allocPrint(testing.allocator, "{s}\\late\\conduit-find-probe.exe", .{dir});
    defer testing.allocator.free(expected);
    for ([_][]const u8{ "conduit-find-probe", "conduit-find-probe.exe" }) |name| {
        const found = (try findProgram(testing.io, testing.allocator, &environ, name)).?;
        defer testing.allocator.free(found);
        try testing.expectEqualStrings(expected, found);
    }
    try testing.expect(try findProgram(testing.io, testing.allocator, &environ, "conduit-no-such-program") == null);
    // A name that is a path is itself when it is there, and nothing when not.
    const direct = (try findProgram(testing.io, testing.allocator, &environ, expected)).?;
    defer testing.allocator.free(direct);
    try testing.expectEqualStrings(expected, direct);
    try testing.expect(try findProgram(testing.io, testing.allocator, &environ, "C:\\conduit\\no\\such.exe") == null);
}

test "a Windows program path refuses directories and batch files" {
    const testing = std.testing;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "directory.exe");
    const batch = try tmp.dir.createFile(io, "program.CMD", .{});
    batch.close(io);
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory = buffer[0..try tmp.dir.realPath(io, &buffer)];
    for ([_][]const u8{ "directory.exe", "program.CMD" }) |name| {
        const path = try std.fs.path.join(testing.allocator, &.{ directory, name });
        defer testing.allocator.free(path);
        const found = try directWindowsProgram(io, testing.allocator, path);
        defer if (found) |owned| testing.allocator.free(owned);
        try testing.expect(found == null);
        if (is_windows) try testing.expect(try findProgram(io, testing.allocator, &.init(testing.allocator), path) == null);
    }
}
