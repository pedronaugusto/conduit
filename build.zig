const std = @import("std");

/// What a project that depends on conduit builds: the `conduit` module, the
/// `conduit.tty` module, and the build-time option `fork-spawn`. The tests, the
/// examples and the gate are `dev`'s.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // libc is linked here rather than left to the consumer, and only where it
    // is needed: the POSIX pseudo-terminal interface is a libc interface, and
    // src/conduit.zig refuses to compile without it there. On Windows every call
    // this package makes is a kernel32 import, so linking a C runtime would
    // only be a dependency to explain.
    const link_libc = target.result.os.tag != .windows;

    // The runtime dependencies, both leaves that need only std: aegis, and
    // reactor, which owns every wait on a kernel object here (a process
    // ending, a descriptor ready, a job object's messages).
    const aegis = b.dependency("aegis", .{ .target = target, .optimize = optimize }).module("aegis");
    const reactor = b.dependency("reactor", .{ .target = target, .optimize = optimize }).module("reactor");

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
        .imports = &.{.{ .name = "aegis", .module = aegis }},
    });

    // The seam in front of the process calls conduit makes past `std.Io`: a
    // module of its own that only conduit and `conduit.testing` import, so
    // neither exports it.
    const seam = b.createModule(.{
        .root_source_file = b.path("src/seam.zig"),
        .target = target,
        .optimize = optimize,
    });

    const module = b.addModule("conduit", .{
        .root_source_file = b.path("src/conduit.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
        .imports = &.{
            .{ .name = "aegis", .module = aegis },
            .{ .name = "reactor", .module = reactor },
            .{ .name = "conduit.tty", .module = tty_module },
            .{ .name = "seam", .module = seam },
        },
    });
    module.addOptions("conduit_options", conduit_options);
}

/// conduit's development: its tests, examples, checks and benchmarks, under
/// preflight's gate. Run through bay.
pub fn dev(b: *std.Build, tools: type) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const link_libc = target.result.os.tag != .windows;
    // See `build`: the one build-time option of the package, passed through.
    forked = b.option(
        bool,
        "fork-spawn",
        "Always fork and exec, never posix_spawn",
    ) orelse false;
    const package = conduitPackage(b, target, optimize);
    const p = package.builder;
    const preflight = tools.preflight;
    use_aegis = tools.shakedown.useAegis;
    const module = package.module("conduit");
    const tty_module = package.module("conduit.tty");
    const aegis_package = p.dependency("aegis", .{ .target = target, .optimize = optimize });
    const reactor_package = p.dependency("reactor", .{ .target = target, .optimize = optimize });

    //=====================================================================
    // Tests.
    //
    // Every test here starts a real child process, so the suite is run in all
    // four optimization modes in CI rather than only in Debug: the code that
    // runs between `fork` and `execve` is the kind that a different inlining
    // decision can change.
    //=====================================================================

    // A filter runs part of the suite: `bay unit -Dtest-filter=Pty.test`.
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
    // rather than a reader: `bay unit -Dthread-sanitizer
    // -Dtest-filter=Reaper`.
    const thread_sanitizer = b.option(
        bool,
        "thread-sanitizer",
        "Build the tests with ThreadSanitizer",
    ) orelse false;

    const test_module = b.createModule(.{
        .root_source_file = p.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
        .sanitize_thread = if (thread_sanitizer) true else null,
        .imports = &.{
            .{ .name = "aegis", .module = aegis_package.module("aegis") },
            .{ .name = "reactor", .module = reactor_package.module("reactor") },
            .{ .name = "conduit.tty", .module = tty_module },
            .{ .name = "seam", .module = module.import_table.get("seam").? },
            .{ .name = "conduit_options", .module = module.import_table.get("conduit_options").? },
        },
    });
    // The tests' clocks, fault plans and counts, and the simulated route: the
    // module `conduit.testing`, on shakedown, which conduit ships as a lazy
    // dependency for it.
    const testing_module = testingModule(p, module) catch return;
    test_module.addImport("conduit.testing", testing_module);
    test_module.addImport("shakedown", testing_module.import_table.get("shakedown").?);

    // A native tree with a known descendant identity and stream lifetime.
    // Only tests depend on this executable; it is never part of the library.
    {
        const fixture = b.addExecutable(.{
            .name = "conduit-tree-fixture",
            .root_module = b.createModule(.{
                .root_source_file = p.path("src/testing/process.zig"),
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
                .root_source_file = p.path("src/testing/input_process.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = link_libc,
            }),
        });
        test_options.addOptionPath("input_fixture", input_fixture.getEmittedBin());
        const tty_fixture = b.addExecutable(.{
            .name = "conduit-tty-fixture",
            .root_module = b.createModule(.{
                .root_source_file = p.path("src/testing/tty_process.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = link_libc,
                .imports = &.{.{ .name = "conduit.tty", .module = tty_module }},
            }),
        });
        test_options.addOptionPath("tty_fixture", tty_fixture.getEmittedBin());
        // Measurements that print numbers rather than assert a behaviour, off
        // in the suite: `bay unit -Dmeasure -Dtest-filter=measures`.
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
    // from nowhere else.
    const check_step = b.step("check", "Compile the tests and the examples without running them");
    check_step.dependOn(&tests.step);
    b.getInstallStep().dependOn(check_step);

    //=====================================================================
    // Examples
    //
    // Built AND run, against the module a consumer gets. An example that is
    // only compiled proves the names still resolve; running it is what proves
    // the library works. examples/usage.zig is also where README.md's Usage
    // block comes from -- see bay docs -- usage -- so the snippet a reader
    // copies cannot drift from code CI executes.
    //=====================================================================

    const examples_step = b.step("examples", "Build and run the examples");
    for (example_sources) |source| {
        const example = b.addExecutable(.{
            .name = std.Io.Dir.path.stem(source),
            .root_module = b.createModule(.{
                .root_source_file = p.path(source),
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
    //=====================================================================

    // preflight's test runner fails a test that outlasts its watchdog,
    // its Io teardown included, by name and phase. `check-runner` sets a
    // short one, to watch that happen.
    const watchdog_ms = b.option(u32, "test-watchdog-ms", "Per-test hang budget, including Io teardown; preflight's default when unset");
    const programs: []const preflight.Bench.Program = if (target.result.os.tag == .windows) &.{} else &.{
        .{ .name = "lifecycle-claims", .source = "bench/lifecycle_claims.zig" },
        .{ .name = "orphans-cost", .source = "bench/orphans_cost.zig" },
        .{ .name = "conduit-bench", .source = "bench/conduit_bench.zig" },
    };
    preflight.addCi(b, p, .{
        .tests = test_step,
        .bench = .{
            .programs = programs,
            .imports = benchImports,
            .target = target,
            .optimize = optimize,
            .link_libc = link_libc,
        },
        .test_timeout = if (watchdog_ms) |ms| .{ .bound = .{
            .limit = .fromMilliseconds(ms),
            .reason = "asked for by -Dtest-watchdog-ms",
        } } else .default,
        // What `CONDUIT_TRACE` prints is at the info level.
        .test_log_level = .info,
    });
    const containment = preflight.addCheck(b, p, "check-containment", "ci/containment.zig");
    // The check program has tests of its own; they run with the rest.
    const containment_tests = b.addTest(.{
        .name = "containment-tests",
        .root_module = b.createModule(.{ .root_source_file = p.path("ci/containment.zig"), .target = target, .optimize = optimize }),
    });
    unit_step.dependOn(&b.addRunArtifact(containment_tests).step);
    const probe = b.addRunArtifact(containment);
    probe.addArg("runner");
    b.step("check-runner", "Check the teardown watchdog diagnostic").dependOn(&probe.step);
    // The build a consumer gets: nothing conduit fetches for itself.
    preflight.addConsumerCheck(b, p, .{
        .package = "conduit",
        .program = p.path("ci/consumer.zig"),
        .modules = &.{ "conduit", "conduit.tty" },
        .packages = &.{ aegis_package, reactor_package },
    });
}

/// Every example, listed rather than globbed: a build graph that scans a
/// directory is not reproducible from the manifest alone.
const example_sources = [_][]const u8{
    "examples/usage.zig",
};

/// `tools.shakedown.useAegis`, set by `dev` for the benchmark imports, which are built without `tools`.
var use_aegis: *const fn (*std.Build.Dependency, *std.Build.Module) void = undefined;

/// `-Dfork-spawn`, as `dev` read it, for the benchmarks' imports.
var forked: bool = false;

/// conduit as the development build has it: the package, with the option passed on.
fn conduitPackage(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Dependency {
    return b.dependency("conduit", .{ .target = target, .optimize = optimize, .@"fork-spawn" = forked });
}

/// Build each benchmark's imports in its own optimization mode.
fn benchImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) []const std.Build.Module.Import {
    const package = conduitPackage(b, target, optimize);
    // shakedown bound to conduit's aegis, so a binary links one aegis.
    const shakedown = b.dependency("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer });
    use_aegis(shakedown, package.module("conduit").import_table.get("aegis").?);
    const imports = b.allocator.alloc(std.Build.Module.Import, 2) catch @panic("OOM");
    imports[0] = .{ .name = "conduit", .module = package.module("conduit") };
    imports[1] = .{ .name = "shakedown", .module = shakedown.module("shakedown") };
    return imports;
}

/// The simulated route for a project's tests: the module `conduit.testing`,
/// on shakedown, for `conduit`'s dependency in that project's build.
///
///     const conduit_build = @import("conduit"); // at the top of the build.zig
///
///     const conduit = b.dependency("conduit", .{ .target = target, .optimize = optimize });
///     tests.root_module.addImport("conduit.testing", try conduit_build.testing(conduit));
///
/// Only a build that calls this fetches shakedown: while it is being
/// fetched this returns `error.LazyDependencyNeeded`, as
/// `std.Build.dependencyLazy` does, for the build function to return.
pub fn testing(conduit: *std.Build.Dependency) error{LazyDependencyNeeded}!*std.Build.Module {
    return testingModule(conduit.builder, conduit.module("conduit"));
}

/// The published `conduit.testing`, made once per build of the package, on
/// shakedown bound to conduit's own aegis.
fn testingModule(b: *std.Build, conduit: *std.Build.Module) error{LazyDependencyNeeded}!*std.Build.Module {
    if (b.modules.get("conduit.testing")) |made| return made;
    const target = conduit.resolved_target.?;
    const optimize = conduit.optimize.?;
    const shakedown = try b.dependencyLazy("shakedown", .{ .target = target, .optimize = optimize, .aegis = .consumer });
    // What shakedown's `useAegis` does: its aegis is conduit's, so a binary links one.
    shakedown.module("shakedown").addImport("aegis", conduit.import_table.get("aegis").?);
    const module = b.createModule(.{
        .root_source_file = b.path("src/testing.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "seam", .module = conduit.import_table.get("seam").? },
            .{ .name = "shakedown", .module = shakedown.module("shakedown") },
        },
    });
    b.modules.put(b.graph.arena, "conduit.testing", module) catch @panic("OOM");
    return module;
}
