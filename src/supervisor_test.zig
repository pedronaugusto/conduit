//! The private supervisor (Linux's and 64-bit FreeBSD's), driven by hand: a
//! scope stop it saved before its first poll still ends the scope.
const std = @import("std");
const c = std.c;
const posix = std.posix;
const builtin = @import("builtin");
const t = std.testing;
const supervisor = @import("supervisor.zig");
const tree = @import("tree.zig");

extern "c" fn pause() c_int;
const on_linux = builtin.target.os.tag == .linux;

test "a saved scope stop before its first poll still ends the scope" {
    const ends = try supervisor.channel();
    defer _ = c.close(ends[0]);
    defer _ = c.close(ends[1]);
    const owner_pid = c.fork();
    if (owner_pid < 0) return error.SystemResources;
    if (owner_pid == 0) {
        _ = c.close(ends[0]);
        const prepared = switch (if (comptime on_linux) supervisor.prepare() else supervisor.prepareFreeBsd()) {
            .ready => |value| value,
            .failed => c._exit(1),
        };
        const root = c.fork();
        if (root < 0) c._exit(2);
        if (root == 0) while (true) {
            _ = pause();
        };
        _ = c.write(ends[1], std.mem.asBytes(&root).ptr, @sizeOf(posix.pid_t));
        var go: u8 = 0;
        if (c.read(ends[1], std.mem.asBytes(&go).ptr, 1) != 1) c._exit(3);
        // Deliver the recorded-scope stop before run can enter its poll.
        _ = c.kill(c.getpid(), .TERM);
        if (comptime on_linux) supervisor.run(root, ends[1], false, prepared, null);
        supervisor.runFreeBsd(root, ends[1], false, prepared);
    }
    var owner = (try tree.captureStarted(owner_pid, (try tree.startTime(owner_pid)).?)).?;
    defer owner.deinit();
    defer {
        _ = owner.signal(.KILL);
        var status: c_int = 0;
        while (c.waitpid(owner_pid, &status, 0) < 0 and c.errno(@as(c_int, -1)) == .INTR) {}
    }
    var root: posix.pid_t = 0;
    try t.expectEqual(@as(isize, @sizeOf(posix.pid_t)), c.read(ends[0], std.mem.asBytes(&root).ptr, @sizeOf(posix.pid_t)));
    var root_held = (try tree.captureStarted(root, (try tree.startTime(root)).?)).?;
    defer root_held.deinit();
    defer _ = root_held.signal(.KILL);
    try t.expectEqual(@as(isize, 1), c.write(ends[0], "1", 1));
    try t.expect(try owner.wait(t.io, .none));
    var answer: supervisor.Result = undefined;
    try t.expectEqual(@as(isize, @sizeOf(supervisor.Result)), c.read(ends[0], std.mem.asBytes(&answer).ptr, @sizeOf(supervisor.Result)));
    try t.expectEqual(@as(u32, 0), answer.failed);
    try t.expect(try root_held.wait(t.io, .none));
}
