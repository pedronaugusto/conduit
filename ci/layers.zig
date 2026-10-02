//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/adoption_record.zig",
        "src/command_line.zig",
        "src/console.zig",
        "src/deadline.zig",
        "src/environ.zig",
        "src/handles.zig",
        "src/test_input_process.zig",
        "src/test_process.zig",
        "src/test_runner.zig",
        "src/windows_search.zig",
    } },
    .{ .name = "platform handles", .patterns = &.{
        "src/cgroup.zig",
        "src/test_support.zig",
        "src/tty.zig",
        "src/wait.zig",
    } },
    .{ .name = "Windows calls", .patterns = &.{
        "src/win32.zig",
    } },
    .{ .name = "tracing", .patterns = &.{
        "src/trace.zig",
    } },
    .{ .name = "terminals", .patterns = &.{
        "src/Pty.zig",
    } },
    .{ .name = "child contracts", .patterns = &.{
        "src/Expect.zig",
        "src/child_types.zig",
    } },
    .{ .name = "process policy", .patterns = &.{
        "src/stdio_plan.zig",
        "src/tree.zig",
        "src/windows_completion.zig",
    } },
    .{ .name = "descendant owners", .patterns = &.{
        "src/Orphans.zig",
        "src/lineage.zig",
        "src/posix_spawn.zig",
        "src/supervisor.zig",
    } },
    .{ .name = "lifecycle storage", .patterns = &.{
        "src/child_state.zig",
    } },
    .{ .name = "spawn and input policy", .patterns = &.{
        "src/child_posix.zig",
        "src/child_windows.zig",
        "src/input_writer_impl.zig",
    } },
    .{ .name = "child owner", .patterns = &.{
        "src/Child.zig",
        "src/find.zig",
    } },
    .{ .name = "conversations and reaping", .patterns = &.{
        "src/InputWriter.zig",
        "src/Proxy.zig",
        "src/Reaper.zig",
        "src/expect_test.zig",
        "src/handles_test.zig",
        "src/lineage_test.zig",
        "src/shell.zig",
        "src/tree_test.zig",
        "src/wait_test.zig",
    } },
    .{ .name = "public and identity scenarios", .patterns = &.{
        "src/child_reaper_test.zig",
        "src/conduit.zig",
        "src/descendants_test.zig",
    } },
    .{ .name = "public scenarios", .patterns = &.{
        "src/input_writer_test.zig",
        "src/spawn_test.zig",
    } },
    .{ .name = "tests", .patterns = &.{
        "src/test_root.zig",
    } },
};

pub const modules: []const gantry.NamedModule = &.{.{ .name = "conduit.tty", .path = "src/tty.zig" }};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = blk: {
    var count: usize = 0;
    for (layers) |layer| count += layer.patterns.len;
    var paths: [count][]const u8 = undefined;
    var i: usize = 0;
    for (layers) |layer| for (layer.patterns) |path| {
        paths[i] = path;
        i += 1;
    };
    break :blk paths;
};
