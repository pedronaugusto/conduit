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

test "a pipe opened in two calls waits for a child being started" {
    if (is_windows or !tty.opening_is_two_calls) return error.SkipZigTest;
    tty.ForkGap.startingAChild();
    var starting = true;
    defer if (starting) tty.ForkGap.release();

    var made: std.atomic.Value(bool) = .init(false);
    var ends: tty.PipeError![2]posix.fd_t = undefined;
    const opener = try std.Thread.spawn(.{}, struct {
        fn run(result: *tty.PipeError![2]posix.fd_t, done: *std.atomic.Value(bool)) void {
            result.* = tty.pipe(.{});
            done.store(true, .release);
        }
    }.run, .{ &ends, &made });

    // A pipe made while the child is being started is one it could inherit.
    // The opener is given ample time to get it wrong.
    try std.Io.sleep(testing.io, .fromMilliseconds(50), .awake);
    const made_while_starting = made.load(.acquire);
    tty.ForkGap.release();
    starting = false;
    opener.join();
    const fds = try ends;
    for (fds) |fd| {
        _ = posix.system.close(fd);
    }
    try testing.expect(!made_while_starting);
}
