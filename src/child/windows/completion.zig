//! The nonblocking Windows publication decision, shared by every reap path.
const std = @import("std");
const Child = @import("../contract.zig");

/// `System.ended` reads what the job has reported, which takes the `io` the
/// reports come through.
pub fn poll(comptime System: type, io: std.Io, context: anytype, term: Child.Term, policy: Child.Descendants, ending: bool) Child.TryWaitError!?Child.Term {
    if (policy == .survive and !ending and term == .exited) {
        try System.releaseSurvivors(context);
    } else {
        try System.end(context);
        if (!try System.empty(context) or !try System.ended(context, io)) return null;
    }
    return term;
}

test "Windows completion keeps the root status unpublished while Job members remain" {
    const Backend = struct {
        const Self = @This();
        members: usize = 1,
        stops: usize = 0,
        fn releaseSurvivors(_: *Self) !void {}
        fn end(self: *Self) !void {
            self.stops += 1;
        }
        fn ended(_: *Self, _: std.Io) !bool {
            return true;
        }
        fn empty(self: *Self) !bool {
            return self.members == 0;
        }
    };
    var backend: Backend = .{};
    const term: Child.Term = .{ .exited = 7 };
    try std.testing.expectEqual(@as(?Child.Term, null), try poll(Backend, std.testing.io, &backend, term, .contain, false));
    try std.testing.expectEqual(@as(usize, 1), backend.stops);
    backend.members = 0;
    try std.testing.expectEqual(@as(?Child.Term, term), try poll(Backend, std.testing.io, &backend, term, .contain, false));
}

test "Windows completion reports a failed Job stop or accounting query" {
    const Backend = struct {
        const Self = @This();
        fail_stop: bool = true,
        fail_query: bool = false,
        fn releaseSurvivors(_: *Self) !void {}
        fn end(self: *Self) !void {
            if (self.fail_stop) return error.Unexpected;
        }
        fn ended(_: *Self, _: std.Io) !bool {
            return true;
        }
        fn empty(self: *Self) !bool {
            if (self.fail_query) return error.Unexpected;
            return true;
        }
    };
    var backend: Backend = .{};
    const term: Child.Term = .{ .exited = 7 };
    try std.testing.expectError(error.Unexpected, poll(Backend, std.testing.io, &backend, term, .contain, false));
    backend.fail_stop = false;
    backend.fail_query = true;
    try std.testing.expectError(error.Unexpected, poll(Backend, std.testing.io, &backend, term, .contain, false));
    backend.fail_query = false;
    try std.testing.expectEqual(@as(?Child.Term, term), try poll(Backend, std.testing.io, &backend, term, .contain, false));
}

test "Windows completion waits for the Job termination notification after accounting reaches zero" {
    const Backend = struct {
        const Self = @This();
        notified: bool = false,
        fn releaseSurvivors(_: *Self) !void {}
        fn end(_: *Self) !void {}
        fn empty(_: *Self) !bool {
            return true;
        }
        fn ended(self: *Self, _: std.Io) !bool {
            return self.notified;
        }
    };
    var backend: Backend = .{};
    const term: Child.Term = .{ .exited = 7 };
    try std.testing.expectEqual(@as(?Child.Term, null), try poll(Backend, std.testing.io, &backend, term, .contain, false));
    backend.notified = true;
    try std.testing.expectEqual(@as(?Child.Term, term), try poll(Backend, std.testing.io, &backend, term, .contain, false));
}
