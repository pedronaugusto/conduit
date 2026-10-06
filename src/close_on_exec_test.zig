const builtin = @import("builtin");
const std = @import("std");
const tty = @import("conduit.tty");
const posix = std.posix;
const testing = std.testing;

const is_windows = builtin.os.tag == .windows;

fn closeOnExec(fd: posix.fd_t) bool {
    const flags = posix.system.fcntl(fd, posix.F.GETFD, @as(usize, 0));
    std.debug.assert(posix.errno(flags) == .SUCCESS);
    return @as(usize, @intCast(flags)) & posix.FD_CLOEXEC != 0;
}

fn nonblocking(fd: posix.fd_t) bool {
    const flags = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    std.debug.assert(posix.errno(flags) == .SUCCESS);
    const nonblock: u32 = @bitCast(posix.O{ .NONBLOCK = true });
    return @as(usize, @intCast(flags)) & nonblock != 0;
}

test "a pipe is close-on-exec at both ends, and nonblocking only when asked" {
    if (is_windows) return error.SkipZigTest;
    inline for (.{ false, true }) |asked| {
        const ends = try tty.pipe(.{ .nonblocking = asked });
        defer for (ends) |fd| {
            _ = posix.system.close(fd);
        };
        for (ends) |fd| {
            try testing.expect(closeOnExec(fd));
            try testing.expectEqual(asked, nonblocking(fd));
        }
    }
}

/// A pipe asked for on another thread, and whether it is made yet.
const Made = struct {
    ends: tty.PipeError![2]posix.fd_t = undefined,
    done: std.atomic.Value(bool) = .init(false),

    fn open(made: *Made) void {
        made.ends = tty.pipe(.{});
        made.done.store(true, .release);
    }

    /// In the lock, as a child being started is: a pipe asked for on
    /// another thread meanwhile, and whether it was made. The opener is
    /// given ample time to get it wrong, and can only be joined once the
    /// lock is left, so the wait's own result comes back with it.
    fn whileStarting(made: *Made) std.Thread.SpawnError!struct { std.Thread, bool, std.Io.Cancelable!void } {
        const opener = try std.Thread.spawn(.{}, open, .{made});
        const waited = std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
        return .{ opener, made.done.load(.acquire), waited };
    }
};

test "a pipe opened in two calls waits for a child being started" {
    if (is_windows or !tty.opening_is_two_calls) return error.SkipZigTest;

    var made: Made = .{};
    const opener, const made_while_starting, const waited = try tty.ForkGap.hold(Made.whileStarting, .{&made});
    opener.join();
    try waited;
    const fds = try made.ends;
    for (fds) |fd| {
        _ = posix.system.close(fd);
    }
    try testing.expect(!made_while_starting);
}

test "the fork gap is left however the call inside it returns" {
    const Failing = struct {
        fn call() error{TestFailedInside}!void {
            return error.TestFailedInside;
        }
    };
    try testing.expectError(error.TestFailedInside, tty.ForkGap.hold(Failing.call, .{}));
    if (is_windows) return;
    // Taken again, which would spin for ever had the failure kept it.
    const ends = try tty.pipe(.{});
    for (ends) |fd| {
        _ = posix.system.close(fd);
    }
}
