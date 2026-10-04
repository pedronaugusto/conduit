//! Keep the containment promise and the test runner's teardown diagnostic explicit.
const std = @import("std");

fn boundary(a: std.mem.Allocator, text: []const u8) !void {
    const lower = try std.ascii.allocLowerString(a, text);
    defer a.free(lower);
    for ([_][]const u8{ "observation", "kernel", "measured", "registration", "escape" }) |term| {
        if (std.mem.indexOf(u8, lower, term) == null) {
            std.debug.print("containment docs: missing '{s}' in the measured observation boundary\n", .{term});
            return error.MissingContainmentBoundary;
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    if (args.len == 2 and std.mem.eql(u8, args[1], "runner")) return probe(a, init);
    const readme = try std.Io.Dir.cwd().readFileAlloc(init.io, "README.md", a, .limited(1024 * 1024));
    var lines = std.mem.splitScalar(u8, readme, '\n');
    var row: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "| macOS |") and std.mem.indexOf(u8, line, "lineage") != null) row = line;
    }
    try boundary(a, row orelse return error.MissingDarwinPlatformRow);
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, "src/Child/child_types.zig", a, .limited(1024 * 1024));
    const start = (std.mem.indexOf(u8, source, "pub const Descendants = enum {") orelse return error.MissingDescendantsPolicy) + "pub const Descendants = enum {".len;
    const end = std.mem.indexOfPos(u8, source, start, "contain,") orelse return error.MissingContainmentPolicy;
    try boundary(a, source[start..end]);
}

fn probe(a: std.mem.Allocator, init: std.process.Init) !void {
    const io = init.io;
    const root = try std.process.currentPathAlloc(io, a);
    const stamp = std.Io.Clock.awake.now(io).nanoseconds;
    const scratch = try std.fmt.allocPrint(a, ".zig-cache/runner-probe-{d}", .{stamp});
    try std.Io.Dir.cwd().createDirPath(io, scratch);
    defer std.Io.Dir.cwd().deleteTree(io, scratch) catch |err| std.debug.print("runner scratch cleanup: {t}\n", .{err});
    var env = try init.environ_map.clone(a);
    defer env.deinit();
    for ([_][]const u8{ "SSH_AUTH_SOCK", "SSH_AGENT_PID", "GPG_AGENT_INFO" }) |key| _ = env.swapRemove(key);
    for ([_][]const u8{ "HOME", "XDG_CONFIG_HOME", "TMPDIR" }) |key| {
        const path = try std.fs.path.join(a, &.{ root, scratch, key });
        try std.Io.Dir.cwd().createDirPath(io, path);
        try env.put(key, path);
    }
    try env.put("ZIG_GLOBAL_CACHE_DIR", try std.fs.path.join(a, &.{ root, ".zig-cache", "runner-global" }));
    try env.put("CONDUIT_TEARDOWN_PROBE", "1");
    // Compiler work precedes the probe's execution deadline. Its source
    // checks already run in the source gate; the probe verifies teardown.
    const compiled = try std.process.run(a, io, .{
        .argv = &.{ "zig", "build", "check-unit", "-Dci-lint=false", "-Dtest-filter=runner teardown probe", "-Dtest-watchdog-ms=200" },
        .environ_map = &env,
    });
    if (compiled.term != .exited or compiled.term.exited != 0) {
        std.debug.print("runner probe did not compile:\n{s}{s}\n", .{ compiled.stdout, compiled.stderr });
        return error.RunnerProbeCompileFailed;
    }
    const result = try std.process.run(a, io, .{
        .argv = &.{ "zig", "build", "unit", "-Dci-lint=false", "-Dtest-filter=runner teardown probe", "-Dtest-watchdog-ms=200", "--test-timeout", "45s" },
        .environ_map = &env,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(60), .clock = .awake } },
    });
    const output = try std.mem.concat(a, u8, &.{ result.stdout, result.stderr });
    const expected = "conduit: watchdog: src/testing/test_support.zig: testing.test_support.test.runner teardown probe; phase=io_teardown";
    if ((result.term == .exited and result.term.exited == 0) or std.mem.indexOf(u8, output, expected) == null) {
        std.debug.print("runner probe did not identify backend teardown:\n{s}\n", .{output});
        return error.RunnerProbeFailed;
    }
    std.debug.print("runner probe: stuck backend teardown names its test and source\n", .{});
}

test "the boundary needs every term in the Darwin containment promise" {
    try boundary(std.testing.allocator, "MEASURED observation of registration; a kernel escape remains possible");
    try std.testing.expectError(error.MissingContainmentBoundary, boundary(std.testing.allocator, "kernel enforcement"));
}
