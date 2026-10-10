//! Production source layers, lowest first. Every production source has one
//! place; test code is in no layer.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "seam", .patterns = &.{
        "src/seam.zig",
    } },
    .{ .name = "primitives", .patterns = &.{
        "src/orphans/**",
        "src/child/command_line.zig",
        "src/console.zig",
        "src/deadline.zig",
        "src/close_on_exec.zig",
        "src/spin.zig",
        "src/pin.zig",
        "src/environ.zig",
        "src/handles.zig",
        "src/serial_allocator.zig",
        "src/child/windows/search.zig",
    } },
    .{ .name = "platform handles", .patterns = &.{
        "src/cgroup.zig",
        "src/tty.zig",
        "src/exit.zig",
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
    .{ .name = "child contracts and conversations", .patterns = &.{
        "src/expect.zig",
        "src/proxy.zig",
        "src/child/contract.zig",
        "src/supervisor.zig",
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
    } },
    .{ .name = "lifecycle storage", .patterns = &.{
        "src/child/State.zig",
    } },
    .{ .name = "spawn and input policy", .patterns = &.{
        "src/child/posix.zig",
        "src/child/windows.zig",
        "src/child/simulated.zig",
        "src/input_writer.zig",
    } },
    .{ .name = "child owner", .patterns = &.{
        "src/child.zig",
        "src/find.zig",
    } },
    .{ .name = "reaping and shells", .patterns = &.{
        "src/reaper.zig",
        "src/shell.zig",
    } },
    .{ .name = "public", .patterns = &.{
        "src/conduit.zig",
    } },
};

pub const entries: []const []const u8 = &.{};

/// The seam is a module of its own, so conduit and `conduit.testing` share it
/// without either exporting it.
pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "conduit.tty", .path = "src/tty.zig" },
    .{ .name = "seam", .path = "src/seam.zig" },
    .{ .name = "conduit.testing", .path = "src/testing.zig" },
};
pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "aegis",
        "builtin",
        "conduit_options",
        "conduit_test_options",
        "reactor",
        "shakedown",
        "std",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = [_][]const u8{
    "src/seam.zig",
    "src/child/simulated.zig",
    "src/orphans/adoption_record.zig",
    "src/child/command_line.zig",
    "src/console.zig",
    "src/deadline.zig",
    "src/close_on_exec.zig",
    "src/spin.zig",
    "src/pin.zig",
    "src/environ.zig",
    "src/handles.zig",
    "src/serial_allocator.zig",
    "src/child/windows/search.zig",
    "src/cgroup.zig",
    "src/tty.zig",
    "src/exit.zig",
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
    "src/shell.zig",
    "src/conduit.zig",
    "src/tests.zig",
};

/// Tokens only their owners may spell: Windows declarations, the terminal's
/// modes, pseudoterminals, exec and cgroups each have their files.
pub const owned: []const gantry.rules.TokenRule = &.{
    .{ .name = "windows declarations", .kind = .string, .tokens = &.{"kernel32"}, .owners = &.{ "src/win32.zig", "src/console.zig", "src/testing/process.zig", "src/testing/input_process.zig" } },
    .{ .name = "terminal mode owner", .tokens = &.{ "tcgetattr", "tcsetattr" }, .owners = &.{ "src/tty.zig", "src/pty.zig" } },
    .{ .name = "pseudoterminal owner", .tokens = &.{"posix_openpt"}, .owners = &.{"src/pty.zig"} },
    .{ .name = "pseudoterminal owner", .tokens = &.{"CreatePseudoConsole"}, .owners = &.{ "src/pty.zig", "src/win32.zig" } },
    .{ .name = "exec owner", .tokens = &.{"execve"}, .owners = &.{"src/child/posix.zig"} },
    .{ .name = "exec owner", .tokens = &.{"posix_spawn"}, .owners = &.{ "src/child/posix.zig", "src/child/posix/spawn.zig" } },
    .{ .name = "cgroup owner", .kind = .string, .tokens = &.{"/sys/fs/cgroup*"}, .owners = &.{"src/cgroup.zig"} },
    // A test double is a shakedown `Clock`, `FaultIo` or `Layer`, never a
    // copied `Io` vtable with a slot replaced: such a copy keeps its state in
    // globals and cannot be stacked. The one vtable here is an allocator's,
    // and the seam reads the slot its layer replaces, as airlock's does.
    .{ .name = "test doubles on shakedown", .tokens = &.{ "vtable", "VTable" }, .owners = &.{ "src/serial_allocator.zig", "src/seam.zig" } },
};
