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

    // The terminal primitives -- raw mode, the window size, the terminal's
    // name and its foreground group -- as a module of their own, for a
    // program that draws its own screen and runs no child. On Linux they are
    // system calls and link no C library; elsewhere the C library is the
    // system interface and is linked whatever a program does.
    const tty_module = b.addModule("conduit.tty", .{
        .root_source_file = b.path("src/tty.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = switch (target.result.os.tag) {
            .linux, .windows => null,
            else => true,
        },
    });

    const module = b.addModule("conduit", .{
        .root_source_file = b.path("src/conduit.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
        .imports = &.{.{ .name = "conduit.tty", .module = tty_module }},
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

    // The handshake between `Reaper` and the owner of a `Child` is two tasks
    // and one child, so it is the one claim here a race detector can check
    // rather than a reader: `zig build unit -Dthread-sanitizer
    // -Dtest-filter=Reaper`.
    const thread_sanitizer = b.option(
        bool,
        "thread-sanitizer",
        "Build the tests with ThreadSanitizer",
    ) orelse false;

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
        .sanitize_thread = if (thread_sanitizer) true else null,
        // Error return traces off, for `zig build test --fuzz`. The fuzzing
        // test runner hands `@errorReturnTrace()` to a function that takes the
        // other `StackTrace` of the two the standard library has, so a test
        // binary built with `-ffuzz` does not compile while they are on. With
        // them off the call is comptime-unreachable and the binary builds;
        // what is lost is the chain of return sites printed under a failure,
        // and every test here says in its own name what it was asserting.
        .error_tracing = false,
        .imports = &.{.{ .name = "conduit.tty", .module = tty_module }},
    });
    test_module.addOptions("conduit_options", conduit_options);

    // A native tree with a known descendant identity and stream lifetime.
    // Only tests depend on this executable; it is never part of the library.
    {
        const fixture = b.addExecutable(.{
            .name = "conduit-tree-fixture",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/testing/process.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = link_libc,
            }),
        });
        const test_options = b.addOptions();
        test_options.addOptionPath("tree_fixture", fixture.getEmittedBin());
        const input_fixture = b.addExecutable(.{
            .name = "conduit-input-fixture",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/testing/input_process.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = link_libc,
            }),
        });
        test_options.addOptionPath("input_fixture", input_fixture.getEmittedBin());
        const tty_fixture = b.addExecutable(.{
            .name = "conduit-tty-fixture",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/testing/tty_process.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = link_libc,
                .imports = &.{.{ .name = "conduit.tty", .module = tty_module }},
            }),
        });
        test_options.addOptionPath("tty_fixture", tty_fixture.getEmittedBin());
        // Measurements that print numbers rather than assert a behaviour, off
        // in the suite: `zig build unit -Dmeasure -Dtest-filter=measures`.
        test_options.addOption(bool, "measure", b.option(bool, "measure", "Also run the measurements, which report numbers and assert nothing") orelse false);
        // A host that cannot make a cgroup skips the tests that need one;
        // this makes that a failure, for the run that is there to hold them.
        test_options.addOption(bool, "require_cgroups", b.option(bool, "require-cgroups", "Fail, rather than skip, the cgroup tests where no cgroup can be made") orelse false);
        test_module.addOptions("conduit_test_options", test_options);
    }

    const tests = b.addTest(.{
        .name = "conduit-tests",
        .filters = test_filters,
        .root_module = test_module,
    });

    // The suite without the examples, so a run that hangs says which of the
    // two it was.
    const unit_step = b.step("unit", "Run the conduit tests, without the examples");
    unit_step.dependOn(&b.addRunArtifact(tests).step);
    b.step("check-unit", "Compile the conduit tests without running them").dependOn(&tests.step);
    // The suite as a program of its own, for a run as another user: only root
    // may make a cgroup on CI's Linux runner, so its cgroup leg runs
    // `sudo zig-out/bin/conduit-tests`.
    b.step("install-unit", "Install the test binary, to run it directly").dependOn(&b.addInstallArtifact(tests, .{}).step);

    const test_step = b.step("test", "Run the conduit tests");
    test_step.dependOn(unit_step);

    // Compiling without running is what a target this host cannot execute can
    // still be held to: a pseudo-terminal is a kernel object, so a
    // cross-compilation check says the sources are portable and nothing more.
    // The test binary is in it as well as the library and the examples,
    // because most of what is Windows-only here is reached from a test and
    // from nowhere else. It is also the default step, so a bare
    // `zig build -Dtarget=...` is the same check under another name.
    const check_step = b.step("check", "Compile the tests and the examples without running them");
    check_step.dependOn(&tests.step);
    b.getInstallStep().dependOn(check_step);

    //=====================================================================
    // Examples
    //
    // Built AND run, against the module a consumer gets. An example that is
    // only compiled proves the names still resolve; running it is what proves
    // the library works. examples/usage.zig is also where README.md's Usage
    // block comes from -- see zig build docs -- usage -- so the snippet a reader
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
        check_step.dependOn(&example.step);
    }
    test_step.dependOn(examples_step);

    //=====================================================================
    // CI wiring
    //
    // Only in conduit's own tree. preflight is a lazy dependency, and a lazy
    // package's build.zig can only be reached through `lazyImport`: a plain
    // `@import` of it fails to compile in any project that depends on
    // conduit and has not fetched preflight, which is every such project.
    //=====================================================================

    if (b.pkg_hash.len != 0) return;
    if (b.lazyImport(@This(), "preflight")) |preflight| {
        // preflight's test runner fails a test that outlasts its watchdog,
        // its Io teardown included, by name and phase. `check-runner` sets a
        // short one, to watch that happen.
        const watchdog_ms = b.option(u32, "test-watchdog-ms", "Per-test hang budget, including Io teardown; preflight's default when unset");
        preflight.addCi(b, .{
            .tests = test_step,
            .test_timeout = if (watchdog_ms) |ms| .{ .bound = .{
                .limit = .fromMilliseconds(ms),
                .reason = "asked for by -Dtest-watchdog-ms",
            } } else .default,
            // What `CONDUIT_TRACE` prints is at the info level.
            .test_log_level = .info,
        });
        const containment = preflight.addCheck(b, "check-containment", "ci/containment.zig");
        const probe = b.addRunArtifact(containment);
        probe.addArg("runner");
        b.step("check-runner", "Check the teardown watchdog diagnostic").dependOn(&probe.step);
        // The build a consumer gets: nothing conduit fetches for itself.
        preflight.addConsumerCheck(b, .{
            .package = "conduit",
            .program = b.path("ci/consumer.zig"),
            .modules = &.{ "conduit", "conduit.tty" },
        });
    }
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
};
