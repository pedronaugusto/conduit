const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const options = b.addOptions();
    options.addOption(bool, "smoke", b.option(bool, "smoke", "Run one tiny iteration") orelse false);
    const optimize = b.standardOptimizeOption(.{});
    const conduit_dep = b.dependency("conduit", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "conduit-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/conduit_bench.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "conduit", .module = conduit_dep.module("conduit") }},
        }),
    });
    exe.root_module.addOptions("bench_options", options);
    b.installArtifact(exe);
    const orphans = b.addExecutable(.{
        .name = "orphans-cost",
        .root_module = b.createModule(.{
            .root_source_file = b.path("orphans-cost-2026-09-28.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "conduit", .module = conduit_dep.module("conduit") }},
        }),
    });
    orphans.root_module.addOptions("bench_options", options);
    b.installArtifact(orphans);
}
