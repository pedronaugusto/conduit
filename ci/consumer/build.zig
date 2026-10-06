const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const conduit = b.dependency("conduit", .{ .target = target });
    const exe = b.addExecutable(.{ .name = "consumer", .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "conduit", .module = conduit.module("conduit") },
            .{ .name = "conduit.tty", .module = conduit.module("conduit.tty") },
        },
    }) });
    b.installArtifact(exe);
}
