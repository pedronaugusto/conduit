//! Where Windows looks for a program named by a bare name, as a list of
//! paths, with nothing asked of the file system.
//!
//! `Child.spawn` and `findProgram` search in the order `CreateProcessW`
//! documents: the directory of this executable, the current directory, the
//! 32-bit system directory, the 16-bit one beside it, the Windows directory,
//! then each entry of `PATH`, with `.exe` supplied to a name that has no
//! extension. Which of those paths holds a file is the one question that needs
//! a Windows machine; the order and the spelling do not, so they are worked
//! out here, and tested on every system this package builds on.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Whether `program` names a program to search for rather than a path: no
/// separator of either kind, and no drive.
pub fn isBareProgram(program: []const u8) bool {
    return std.mem.indexOfAny(u8, program, "\\/:") == null;
}

/// Whether the program is a batch script, which this package refuses to run.
///
/// `cmd.exe` re-parses the command line of a `.bat` or `.cmd` with rules no
/// argument serialisation survives, so an argument containing the right
/// characters becomes a second command. Refusing is the only honest answer for
/// an API whose argument list is data; a caller who wants a script can invoke
/// `cmd.exe /c` themselves and take responsibility for what they pass it.
pub fn isBatchFile(program: []const u8) bool {
    return endsWithIgnoringCase(program, ".bat") or endsWithIgnoringCase(program, ".cmd");
}

fn endsWithIgnoringCase(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return std.ascii.eqlIgnoreCase(haystack[haystack.len - suffix.len ..], suffix);
}

/// The places a search starts from, as this process finds them.
pub const Places = struct {
    /// The directory of this executable, when it could be found.
    executable_dir: ?[]const u8,
    /// The current directory, when it could be found.
    current_dir: ?[]const u8,
    /// The system directory, `GetSystemDirectoryW`'s answer.
    system_dir: []const u8,
    /// The child's `PATH`, when it has one.
    path: ?[]const u8,
};

/// The paths a bare `program` is looked for at, in the order they are tried.
/// Every slice is allocated with `arena`.
pub fn candidates(arena: Allocator, places: Places, program: []const u8) Allocator.Error![]const []const u8 {
    std.debug.assert(isBareProgram(program));
    var directories: std.ArrayList([]const u8) = .empty;
    if (places.executable_dir) |dir| try directories.append(arena, dir);
    if (places.current_dir) |dir| try directories.append(arena, dir);
    try directories.append(arena, places.system_dir);
    if (std.fs.path.dirnameWindows(places.system_dir)) |windows_dir| {
        try directories.append(arena, try join(arena, windows_dir, "System"));
        try directories.append(arena, windows_dir);
    }
    if (places.path) |path| {
        var entries = std.mem.splitScalar(u8, path, ';');
        while (entries.next()) |entry| try directories.append(arena, std.mem.trim(u8, entry, "\""));
    }

    const executable = if (std.fs.path.extension(program).len == 0)
        try std.fmt.allocPrint(arena, "{s}.exe", .{program})
    else
        program;
    const list = try arena.alloc([]const u8, directories.items.len);
    for (directories.items, list) |directory, *candidate| {
        // An empty entry is the current directory, spelled as the name alone.
        candidate.* = if (directory.len == 0) executable else try join(arena, directory, executable);
    }
    return list;
}

/// `directory` and `name` with one Windows separator between them.
fn join(arena: Allocator, directory: []const u8, name: []const u8) Allocator.Error![]const u8 {
    const ends = directory[directory.len - 1];
    const separator = if (ends == '\\' or ends == '/') "" else "\\";
    return std.fmt.allocPrint(arena, "{s}{s}{s}", .{ directory, separator, name });
}

const testing = std.testing;

test "a bare name is looked for where CreateProcessW looks, in its order, with .exe supplied" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const found = try candidates(arena_state.allocator(), .{
        .executable_dir = "C:\\tools\\app",
        .current_dir = "D:\\work\\",
        .system_dir = "C:\\Windows\\system32",
        .path = "C:\\bin;\"C:\\Program Files\\Git\\cmd\";;C:\\last\\",
    }, "git");
    const expected = [_][]const u8{
        "C:\\tools\\app\\git.exe",
        "D:\\work\\git.exe",
        "C:\\Windows\\system32\\git.exe",
        "C:\\Windows\\System\\git.exe",
        "C:\\Windows\\git.exe",
        "C:\\bin\\git.exe",
        // Quoted, as an installer writes a directory with a space in it.
        "C:\\Program Files\\Git\\cmd\\git.exe",
        // An empty entry: the name alone, relative to the current directory.
        "git.exe",
        "C:\\last\\git.exe",
    };
    try testing.expectEqual(expected.len, found.len);
    for (expected, found) |want, got| try testing.expectEqualStrings(want, got);
}

test "a name with an extension keeps it, and the places this process could not find are left out" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const found = try candidates(arena_state.allocator(), .{
        .executable_dir = null,
        .current_dir = null,
        .system_dir = "C:\\Windows\\system32",
        .path = null,
    }, "tool.com");
    const expected = [_][]const u8{
        "C:\\Windows\\system32\\tool.com",
        "C:\\Windows\\System\\tool.com",
        "C:\\Windows\\tool.com",
    };
    try testing.expectEqual(expected.len, found.len);
    for (expected, found) |want, got| try testing.expectEqualStrings(want, got);
}

test "a name with a separator or a drive is a path, not a name to search for" {
    try testing.expect(isBareProgram("git"));
    try testing.expect(isBareProgram("git.exe"));
    try testing.expect(!isBareProgram("bin\\git"));
    try testing.expect(!isBareProgram("bin/git"));
    try testing.expect(!isBareProgram("C:git"));
}

test "every PATH entry becomes one candidate, that entry and the program with one separator" {
    try testing.fuzz({}, pathEntriesKeepTheirShape, .{});
}

/// The property: after the fixed places, one candidate per entry of `PATH`,
/// in the order written, each the entry with its quotes trimmed, a separator
/// only where the entry does not already end in one, and the program, with
/// `.exe` on the end when the name has no extension. What the fuzzer is for is
/// the punctuation an entry can hold: the `;` entries are split on, the quotes
/// an installer adds, both separators and the dot an extension starts with.
fn pathEntriesKeepTheirShape(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    const alphabet: []const std.testing.Smith.Weight = &.{
        .rangeAtMost(u8, 'a', 'c', 2),
        .value(u8, '\\', 3),
        .value(u8, '/', 1),
        .value(u8, ';', 4),
        .value(u8, '"', 2),
        .value(u8, '.', 1),
    };
    const name_alphabet: []const std.testing.Smith.Weight = &.{
        .rangeAtMost(u8, 'a', 'c', 4),
        .value(u8, '.', 1),
    };

    var program_bytes: [8]u8 = undefined;
    const program = program_bytes[0..smith.sliceWeightedBytes(&program_bytes, name_alphabet)];
    if (program.len == 0) return;
    var path_bytes: [40]u8 = undefined;
    const path = path_bytes[0..smith.sliceWeightedBytes(&path_bytes, alphabet)];

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const found = try candidates(arena, .{
        .executable_dir = null,
        .current_dir = null,
        .system_dir = "C:\\W\\s",
        .path = path,
    }, program);

    const executable = if (std.fs.path.extension(program).len == 0)
        try std.fmt.allocPrint(arena, "{s}.exe", .{program})
    else
        program;
    const fixed = 3;
    try testing.expectEqual(fixed + std.mem.count(u8, path, ";") + 1, found.len);
    var entries = std.mem.splitScalar(u8, path, ';');
    for (found[fixed..]) |candidate| {
        const entry = std.mem.trim(u8, entries.next().?, "\"");
        try testing.expect(std.mem.endsWith(u8, candidate, executable));
        const head = candidate[0 .. candidate.len - executable.len];
        if (entry.len == 0) {
            try testing.expectEqualStrings("", head);
        } else if (entry[entry.len - 1] == '\\' or entry[entry.len - 1] == '/') {
            try testing.expectEqualStrings(entry, head);
        } else {
            try testing.expectEqualStrings(entry, head[0 .. head.len - 1]);
            try testing.expectEqual(@as(u8, '\\'), head[head.len - 1]);
        }
    }
    try testing.expect(entries.next() == null);
}

test "batch files are recognised whatever their case" {
    try testing.expect(isBatchFile("go.bat"));
    try testing.expect(isBatchFile("C:\\x\\GO.CMD"));
    try testing.expect(!isBatchFile("go.exe"));
    try testing.expect(!isBatchFile("bat"));
}
