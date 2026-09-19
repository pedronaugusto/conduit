const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // libc is linked here rather than left to the consumer, and only where it
    // is needed: the POSIX pseudo-terminal interface is a libc interface, and
    // src/conduit.zig refuses to compile without it there. On Windows every call
    // this package makes is a kernel32 import, so linking a C runtime would
    // only be a dependency to explain.
    const link_libc = target.result.os.tag != .windows;

    //=====================================================================
    // The module.
    //=====================================================================

    // The one build-time decision this package has. `Child.spawn` hands a
    // spawn that needs nothing done between the fork and the exec to
    // `posix_spawn`, which is a second implementation of the same contract;
    // this turns it off, so that CI can run the whole suite down both paths
    // and prove they produce the same child.
    const fork_spawn = b.option(
        bool,
        "fork-spawn",
        "Always fork and exec, never posix_spawn",
    ) orelse false;
    const conduit_options = b.addOptions();
    conduit_options.addOption(bool, "force_fork_spawn", fork_spawn);

    const module = b.addModule("conduit", .{
        .root_source_file = b.path("src/conduit.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    module.addOptions("conduit_options", conduit_options);

    //=====================================================================
    // Tests.
    //
    // Every test here starts a real child process, so the suite is run in all
    // four optimization modes in CI rather than only in Debug: the code that
    // runs between `fork` and `execve` is the kind that a different inlining
    // decision can change.
    //=====================================================================

    // A filter runs part of the suite: `zig build unit -Dtest-filter=Pty.test`.
    // Every test's fully qualified name begins with the file it is in, so one
    // filter per file splits the suite the way it is written -- which is how
    // CI finds out where a run that produces no output at all stopped.
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Run only the tests whose fully qualified name contains one of these",
    ) orelse &[0][]const u8{};

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/conduit.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
    });
    test_module.addOptions("conduit_options", conduit_options);

    const tests = b.addTest(.{
        .name = "conduit-tests",
        .filters = test_filters,
        .root_module = test_module,
    });

    // The suite without the examples, so a run that hangs says which of the
    // two it was.
    const unit_step = b.step("unit", "Run the conduit tests, without the examples");
    unit_step.dependOn(&b.addRunArtifact(tests).step);

    const test_step = b.step("test", "Run the conduit tests");
    test_step.dependOn(unit_step);

    //=====================================================================
    // Examples
    //
    // Built AND run, against the module a consumer gets. An example that is
    // only compiled proves the names still resolve; running it is what proves
    // the library works. examples/usage.zig is also where README.md's Usage
    // block comes from -- see ci/readme_usage.sh -- so the snippet a reader
    // copies cannot drift from code CI executes.
    //=====================================================================

    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.fs.path.stem(source),
            .root_module = b.createModule(.{
                .root_source_file = b.path(source),
                .target = target,
                .optimize = optimize,
                .link_libc = link_libc,
                .imports = &.{.{ .name = "conduit", .module = module }},
            }),
        });
        const run = b.addRunArtifact(example);
        examples_step.dependOn(&run.step);
        // Compiled by a bare `zig build` too, so a cross-compilation check
        // covers the examples and not only the library.
        b.getInstallStep().dependOn(&example.step);
    }
    test_step.dependOn(examples_step);

    // `zig build` with no step compiles everything, so a cross-compilation
    // check needs no step name of its own.
    b.getInstallStep().dependOn(&tests.step);
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
};
