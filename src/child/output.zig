//! What a run collected: both streams, whether either was cut short, and how
//! the child ended. `Child.output` and `Child.exchange` return one.

const std = @import("std");
const contract = @import("contract.zig");
const Allocator = std.mem.Allocator;

/// Everything the child wrote, and how it ended.
pub const Parts = struct {
    stdout: []u8,
    stderr: []u8,
    stdout_truncated: bool,
    stderr_truncated: bool,
    term: contract.Term,
    timed_out: bool,
};

/// Owns collected bytes; move before sharing and never copy an owner.
pub const Output = struct {
    /// Private: read it through the methods.
    parts: Parts,
    /// Private: the allocator that made both slices, which `deinit` frees
    /// them with.
    gpa: Allocator,

    /// Takes ownership of both slices, which `gpa` made.
    pub fn init(gpa: Allocator, parts: Parts) Output {
        return .{ .parts = parts, .gpa = gpa };
    }

    /// Borrows retained standard output until transfer or deinit.
    pub fn stdout(collected: *const Output) []u8 {
        return collected.parts.stdout;
    }

    /// Borrows retained standard error until transfer or deinit.
    pub fn stderr(collected: *const Output) []u8 {
        return collected.parts.stderr;
    }

    /// Transfers retained output bytes. The caller frees them with the collecting allocator.
    pub fn takeStdout(collected: *Output) []u8 {
        const state = &collected.parts;
        const taken = state.stdout;
        state.stdout = &.{};
        return taken;
    }

    /// Transfers retained error bytes. The caller frees them with the collecting allocator.
    pub fn takeStderr(collected: *Output) []u8 {
        const state = &collected.parts;
        const taken = state.stderr;
        state.stderr = &.{};
        return taken;
    }

    /// Whether bytes were dropped or the stream outlived the drain budget.
    pub fn stdoutTruncated(collected: *const Output) bool {
        return collected.parts.stdout_truncated;
    }

    pub fn stderrTruncated(collected: *const Output) bool {
        return collected.parts.stderr_truncated;
    }

    /// How the child ended.
    pub fn term(collected: *const Output) contract.Term {
        return collected.parts.term;
    }

    /// Whether the child was ended after its execution budget elapsed.
    pub fn timedOut(collected: *const Output) bool {
        return collected.parts.timed_out;
    }

    /// Frees what is still retained. The `Output` is undefined afterwards.
    pub fn deinit(collected: *Output) void {
        const state = &collected.parts;
        collected.gpa.free(state.stdout);
        collected.gpa.free(state.stderr);
        collected.* = undefined;
    }
};

test "Output frees what was not taken and hands over what was" {
    const gpa = std.testing.allocator;
    var collected: Output = .init(gpa, .{
        .stdout = try gpa.dupe(u8, "out"),
        .stderr = try gpa.dupe(u8, "err"),
        .stdout_truncated = false,
        .stderr_truncated = true,
        .term = .{ .exited = 3 },
        .timed_out = false,
    });
    const taken = collected.takeStdout();
    defer gpa.free(taken);
    try std.testing.expectEqualStrings("out", taken);
    try std.testing.expectEqualStrings("", collected.stdout());
    try std.testing.expectEqualStrings("err", collected.stderr());
    try std.testing.expect(collected.stderrTruncated());
    try std.testing.expectEqual(contract.Term{ .exited = 3 }, collected.term());
    collected.deinit();
}
