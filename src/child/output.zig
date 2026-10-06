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
pub const Output = enum(@Int(.unsigned, @sizeOf(Parts) * 8)) {
    _,

    // The state lives in the value's own bits and `inner` casts to it: the
    // bits must hold it and be at least as aligned.
    comptime {
        std.debug.assert(@sizeOf(Output) >= @sizeOf(Parts));
        std.debug.assert(@alignOf(Output) >= @alignOf(Parts));
    }

    fn inner(collected: *Output) *Parts {
        return @ptrCast(@alignCast(collected)); // safe: init writes inline storage of the same size and alignment.
    }

    fn value(collected: *const Output) *const Parts {
        return @ptrCast(@alignCast(collected)); // safe: borrows initialized inline state without copying ownership.
    }

    /// Takes ownership of both slices, which `deinit` frees with the
    /// allocator that made them.
    pub fn init(parts: Parts) Output {
        var collected: Output = undefined;
        collected.inner().* = parts;
        return collected;
    }

    /// Borrows retained standard output until transfer or deinit.
    pub fn stdout(collected: *const Output) []u8 {
        return collected.value().stdout;
    }

    /// Borrows retained standard error until transfer or deinit.
    pub fn stderr(collected: *const Output) []u8 {
        return collected.value().stderr;
    }

    /// Transfers retained output bytes. The caller frees them with the collecting allocator.
    pub fn takeStdout(collected: *Output) []u8 {
        const state = collected.inner();
        const taken = state.stdout;
        state.stdout = &.{};
        return taken;
    }

    /// Transfers retained error bytes. The caller frees them with the collecting allocator.
    pub fn takeStderr(collected: *Output) []u8 {
        const state = collected.inner();
        const taken = state.stderr;
        state.stderr = &.{};
        return taken;
    }

    /// Whether bytes were dropped or the stream outlived the drain budget.
    pub fn stdoutTruncated(collected: *const Output) bool {
        return collected.value().stdout_truncated;
    }

    pub fn stderrTruncated(collected: *const Output) bool {
        return collected.value().stderr_truncated;
    }

    /// How the child ended.
    pub fn term(collected: *const Output) contract.Term {
        return collected.value().term;
    }

    /// Whether the child was ended after its execution budget elapsed.
    pub fn timedOut(collected: *const Output) bool {
        return collected.value().timed_out;
    }

    /// Frees what is still retained with the collecting allocator. The
    /// `Output` is undefined afterwards.
    pub fn deinit(collected: *Output, allocator: Allocator) void {
        const state = collected.inner();
        allocator.free(state.stdout);
        allocator.free(state.stderr);
        collected.* = undefined;
    }
};

test "Output exposes no writable collection ownership" {
    try std.testing.expect(@typeInfo(Output) == .@"enum");
}

test "Output frees what was not taken and hands over what was" {
    const allocator = std.testing.allocator;
    var collected: Output = .init(.{
        .stdout = try allocator.dupe(u8, "out"),
        .stderr = try allocator.dupe(u8, "err"),
        .stdout_truncated = false,
        .stderr_truncated = true,
        .term = .{ .exited = 3 },
        .timed_out = false,
    });
    const taken = collected.takeStdout();
    defer allocator.free(taken);
    try std.testing.expectEqualStrings("out", taken);
    try std.testing.expectEqualStrings("", collected.stdout());
    try std.testing.expectEqualStrings("err", collected.stderr());
    try std.testing.expect(collected.stderrTruncated());
    try std.testing.expectEqual(contract.Term{ .exited = 3 }, collected.term());
    collected.deinit(allocator);
}
