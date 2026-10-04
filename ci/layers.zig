//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/Orphans/**",
        "src/Child/command_line.zig",
        "src/console.zig",
        "src/deadline.zig",
        "src/environ.zig",
        "src/handles.zig",
        "src/serial_allocator.zig",
        "src/testing/test_input_process.zig",
        "src/testing/test_process.zig",
        "src/testing/test_runner.zig",
        "src/Child/windows_search.zig",
    } },
    .{ .name = "platform handles", .patterns = &.{
        "src/cgroup.zig",
        "src/testing/test_support.zig",
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
        "src/Child/child_types.zig",
    } },
    .{ .name = "process policy", .patterns = &.{
        "src/process_exists.zig",
        "src/Child/stdio_plan.zig",
        "src/tree.zig",
        "src/Child/windows_completion.zig",
    } },
    .{ .name = "descendant owners", .patterns = &.{
        "src/Orphans.zig",
        "src/lineage.zig",
        "src/Child/posix_spawn.zig",
        "src/supervisor.zig",
    } },
    .{ .name = "lifecycle storage", .patterns = &.{
        "src/Child/child_state.zig",
    } },
    .{ .name = "spawn and input policy", .patterns = &.{
        "src/Child/child_posix.zig",
        "src/Child/child_windows.zig",
        "src/InputWriter/input_writer_impl.zig",
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
        "src/Child/child_reaper_test.zig",
        "src/conduit.zig",
        "src/Child/descendants_test.zig",
    } },
    .{ .name = "public scenarios", .patterns = &.{
        "src/Child/exchange_test.zig",
        "src/InputWriter/input_writer_test.zig",
        "src/Child/spawn_test.zig",
    } },
    .{ .name = "tests", .patterns = &.{
        "src/test_root.zig",
        "src/testing/test_tty_process.zig",
    } },
};

pub const entries: []const []const u8 = &.{
    "src/testing/test_input_process.zig",
    "src/testing/test_process.zig",
    "src/testing/test_tty_process.zig",
    "src/testing/test_runner.zig",
};

pub const modules: []const gantry.NamedModule = &.{.{ .name = "conduit.tty", .path = "src/tty.zig" }};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "builtin",
        "conduit_options",
        "conduit_runner_options",
        "conduit_test_options",
        "standard_test_runner",
        "std",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = [_][]const u8{
    "src/Orphans/adoption_record.zig",
    "src/Child/command_line.zig",
    "src/console.zig",
    "src/deadline.zig",
    "src/environ.zig",
    "src/handles.zig",
    "src/serial_allocator.zig",
    "src/testing/test_input_process.zig",
    "src/testing/test_process.zig",
    "src/testing/test_runner.zig",
    "src/Child/windows_search.zig",
    "src/cgroup.zig",
    "src/testing/test_support.zig",
    "src/tty.zig",
    "src/wait.zig",
    "src/win32.zig",
    "src/trace.zig",
    "src/Pty.zig",
    "src/Expect.zig",
    "src/Child/child_types.zig",
    "src/process_exists.zig",
    "src/Child/stdio_plan.zig",
    "src/tree.zig",
    "src/Child/windows_completion.zig",
    "src/Orphans.zig",
    "src/lineage.zig",
    "src/Child/posix_spawn.zig",
    "src/supervisor.zig",
    "src/Child/child_state.zig",
    "src/Child/child_posix.zig",
    "src/Child/child_windows.zig",
    "src/InputWriter/input_writer_impl.zig",
    "src/Child.zig",
    "src/find.zig",
    "src/InputWriter.zig",
    "src/Proxy.zig",
    "src/Reaper.zig",
    "src/expect_test.zig",
    "src/handles_test.zig",
    "src/lineage_test.zig",
    "src/shell.zig",
    "src/tree_test.zig",
    "src/wait_test.zig",
    "src/Child/child_reaper_test.zig",
    "src/conduit.zig",
    "src/Child/descendants_test.zig",
    "src/Child/exchange_test.zig",
    "src/InputWriter/input_writer_test.zig",
    "src/Child/spawn_test.zig",
    "src/test_root.zig",
    "src/testing/test_tty_process.zig",
};

/// Tokens only their owners may spell: Windows declarations, the terminal's
/// modes, pseudoterminals, exec and cgroups each have their files.
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "windows declarations", .kind = .string, .token = "kernel32", .owners = &.{ "src/win32.zig", "src/console.zig", "src/testing/test_process.zig", "src/testing/test_input_process.zig" } },
    .{ .name = "terminal mode owner", .token = "tcgetattr", .owners = &.{ "src/tty.zig", "src/Pty.zig" } },
    .{ .name = "terminal mode owner", .token = "tcsetattr", .owners = &.{ "src/tty.zig", "src/Pty.zig" } },
    .{ .name = "pseudoterminal owner", .token = "posix_openpt", .owners = &.{"src/Pty.zig"} },
    .{ .name = "pseudoterminal owner", .token = "CreatePseudoConsole", .owners = &.{ "src/Pty.zig", "src/win32.zig" } },
    .{ .name = "exec owner", .token = "execve", .owners = &.{"src/Child/child_posix.zig"} },
    .{ .name = "exec owner", .token = "posix_spawn", .owners = &.{ "src/Child/child_posix.zig", "src/Child/posix_spawn.zig" } },
    .{ .name = "cgroup owner", .kind = .string, .token = "/sys/fs/cgroup*", .owners = &.{"src/cgroup.zig"} },
};
