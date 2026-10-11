//! Keep the containment promise and the test runner's teardown diagnostic explicit.
const std = @import("std");

const log = std.log.scoped(.containment);

/// The first term of the Darwin containment promise `text` leaves out, or
/// `null` when it says all of them.
fn missingTerm(a: std.mem.Allocator, text: []const u8) !?[]const u8 {
    const lower = try std.ascii.allocLowerString(a, text);
    defer a.free(lower);
    for ([_][]const u8{ "observation", "kernel", "measured", "registration", "escape" }) |term| {
        if (std.mem.find(u8, lower, term) == null) return term;
    }
    return null;
}

fn boundary(a: std.mem.Allocator, text: []const u8) !void {
    if (try missingTerm(a, text)) |term| {
        log.err("missing '{s}' in the measured observation boundary", .{term});
        return error.MissingContainmentBoundary;
    }
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const readme = try std.Io.Dir.cwd().readFileAlloc(init.io, "README.md", a, .limited(1024 * 1024));
    var lines = std.mem.splitScalar(u8, readme, '\n');
    var row: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "| macOS |") and std.mem.find(u8, line, "lineage") != null) row = line;
    }
    try boundary(a, row orelse return error.MissingDarwinPlatformRow);
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, "src/child/contract.zig", a, .limited(1024 * 1024));
    const start = (std.mem.find(u8, source, "pub const Descendants = enum {") orelse return error.MissingDescendantsPolicy) + "pub const Descendants = enum {".len;
    const end = std.mem.findPos(u8, source, start, "contain,") orelse return error.MissingContainmentPolicy;
    try boundary(a, source[start..end]);
}

test "the boundary needs every term in the Darwin containment promise" {
    try std.testing.expectEqual(null, try missingTerm(std.testing.allocator, "MEASURED observation of registration; a kernel escape remains possible"));
    try std.testing.expectEqualStrings("observation", (try missingTerm(std.testing.allocator, "kernel enforcement")).?);
}
