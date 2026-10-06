//! Source layers, lowest first. Every source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "primitives", .patterns = &.{
        "src/orphans/**",
        "src/child/command_line.zig",
        "src/console.zig",
        "src/deadline.zig",
        "src/spin.zig",
        "src/environ.zig",
        "src/handles.zig",
        "src/serial_allocator.zig",
        "src/testing/input_process.zig",
        "src/testing/process.zig",
        "src/testing/runner.zig",
        "src/child/windows/search.zig",
    } },
    .{ .name = "platform handles", .patterns = &.{
        "src/cgroup.zig",
        "src/testing/support.zig",
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
        "src/pty.zig",
    } },
    .{ .name = "child contracts", .patterns = &.{
        "src/expect.zig",
        "src/child/contract.zig",
    } },
    .{ .name = "process policy", .patterns = &.{
        "src/process_exists.zig",
        "src/child/output.zig",
        "src/child/stdio_plan.zig",
        "src/tree.zig",
        "src/child/windows/completion.zig",
    } },
    .{ .name = "descendant owners", .patterns = &.{
        "src/orphans.zig",
        "src/lineage.zig",
        "src/child/posix/spawn.zig",
        "src/supervisor.zig",
    } },
    .{ .name = "lifecycle storage", .patterns = &.{
        "src/child/State.zig",
    } },
    .{ .name = "spawn and input policy", .patterns = &.{
        "src/child/posix.zig",
        "src/child/windows.zig",
        "src/input_writer.zig",
    } },
    .{ .name = "child owner", .patterns = &.{
        "src/child.zig",
        "src/find.zig",
    } },
    .{ .name = "conversations and reaping", .patterns = &.{
        "src/proxy.zig",
        "src/reaper.zig",
        "src/expect_test.zig",
        "src/handles_test.zig",
        "src/lineage_test.zig",
        "src/shell.zig",
        "src/tree_test.zig",
        "src/wait_test.zig",
    } },
    .{ .name = "public and identity scenarios", .patterns = &.{
        "src/child/reaper_test.zig",
        "src/conduit.zig",
        "src/child/descendants_test.zig",
    } },
    .{ .name = "public scenarios", .patterns = &.{
        "src/child/exchange_test.zig",
        "src/input_writer_test.zig",
        "src/child/spawn_test.zig",
    } },
    .{ .name = "tests", .patterns = &.{
        "src/tests.zig",
        "src/testing/tty_process.zig",
    } },
};

pub const entries: []const []const u8 = &.{
    "src/testing/input_process.zig",
    "src/testing/process.zig",
    "src/testing/tty_process.zig",
    "src/testing/runner.zig",
};

pub const modules: []const gantry.NamedModule = &.{.{ .name = "conduit.tty", .path = "src/tty.zig" }};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "builtin",
        "conduit_options",
        "conduit_runner_options",
        "conduit_test_options",
        "standard_test_runner",
        "preflight_timings",
        "preflight_order",
        "std",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = [_][]const u8{
    "src/orphans/adoption_record.zig",
    "src/child/command_line.zig",
    "src/console.zig",
    "src/deadline.zig",
    "src/spin.zig",
    "src/environ.zig",
    "src/handles.zig",
    "src/serial_allocator.zig",
    "src/testing/input_process.zig",
    "src/testing/process.zig",
    "src/testing/runner.zig",
    "src/child/windows/search.zig",
    "src/cgroup.zig",
    "src/testing/support.zig",
    "src/tty.zig",
    "src/wait.zig",
    "src/win32.zig",
    "src/trace.zig",
    "src/pty.zig",
    "src/expect.zig",
    "src/child/contract.zig",
    "src/process_exists.zig",
    "src/child/output.zig",
    "src/child/stdio_plan.zig",
    "src/tree.zig",
    "src/child/windows/completion.zig",
    "src/orphans.zig",
    "src/lineage.zig",
    "src/child/posix/spawn.zig",
    "src/supervisor.zig",
    "src/child/State.zig",
    "src/child/posix.zig",
    "src/child/windows.zig",
    "src/input_writer.zig",
    "src/child.zig",
    "src/find.zig",
    "src/proxy.zig",
    "src/reaper.zig",
    "src/expect_test.zig",
    "src/handles_test.zig",
    "src/lineage_test.zig",
    "src/shell.zig",
    "src/tree_test.zig",
    "src/wait_test.zig",
    "src/child/reaper_test.zig",
    "src/conduit.zig",
    "src/child/descendants_test.zig",
    "src/child/exchange_test.zig",
    "src/input_writer_test.zig",
    "src/child/spawn_test.zig",
    "src/tests.zig",
    "src/testing/tty_process.zig",
};

/// Tokens only their owners may spell: Windows declarations, the terminal's
/// modes, pseudoterminals, exec and cgroups each have their files.
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "windows declarations", .kind = .string, .token = "kernel32", .owners = &.{ "src/win32.zig", "src/console.zig", "src/testing/process.zig", "src/testing/input_process.zig" } },
    .{ .name = "terminal mode owner", .token = "tcgetattr", .owners = &.{ "src/tty.zig", "src/pty.zig" } },
    .{ .name = "terminal mode owner", .token = "tcsetattr", .owners = &.{ "src/tty.zig", "src/pty.zig" } },
    .{ .name = "pseudoterminal owner", .token = "posix_openpt", .owners = &.{"src/pty.zig"} },
    .{ .name = "pseudoterminal owner", .token = "CreatePseudoConsole", .owners = &.{ "src/pty.zig", "src/win32.zig" } },
    .{ .name = "exec owner", .token = "execve", .owners = &.{"src/child/posix.zig"} },
    .{ .name = "exec owner", .token = "posix_spawn", .owners = &.{ "src/child/posix.zig", "src/child/posix/spawn.zig" } },
    .{ .name = "cgroup owner", .kind = .string, .token = "/sys/fs/cgroup*", .owners = &.{"src/cgroup.zig"} },
};
