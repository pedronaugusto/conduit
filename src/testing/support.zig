//! What the tests in this package need and the package itself does not.
//!
//! Only test blocks refer to anything here, so nothing in it reaches a program
//! that imports `conduit`.

const std = @import("std");
const Deadline = @import("conduit.tty").Deadline;

/// Bounds one step a test promises returns promptly: a stop that must not
/// wait out a read, a wait that must say at once that nothing more will come.
///
/// A hang anywhere in a test is the shared test runner's: `zig build` passes
/// it the package's `test_timeout`, and it fails the test by name and phase,
/// its Io teardown included. This is the tighter bound a test asserts about
/// one call, so it ends the process from inside, after whatever the test has
/// printed, and names the test function and file.
///
/// The bark is a panic rather than a test failure: the point is to interrupt a
/// task that is not going to return, and only the process going down does
/// that.
///
/// The same lifetime rules as `Reaper`: it holds a pointer to itself, so it
/// must not move once started, and `deinit` must run.
pub const Watchdog = struct {
    source: std.builtin.SourceLocation,
    limit_ms: u32,
    group: std.Io.Group,
    finished: std.atomic.Value(bool),

    pub fn init(source: std.builtin.SourceLocation, limit_ms: u32) Watchdog {
        return .{
            .source = source,
            .limit_ms = limit_ms,
            .group = .init,
            .finished = .init(false),
        };
    }

    pub fn start(watchdog: *Watchdog, io: std.Io) std.Io.ConcurrentError!void {
        return watchdog.group.concurrent(io, watch, .{ watchdog, io });
    }

    pub fn deinit(watchdog: *Watchdog, io: std.Io) void {
        watchdog.finished.store(true, .release);
        watchdog.group.cancel(io);
        watchdog.* = undefined;
    }

    fn watch(watchdog: *Watchdog, io: std.Io) std.Io.Cancelable!void {
        const deadline: Deadline = .in(io, watchdog.limit_ms);
        while (deadline.remainingMs(io) > 0) {
            if (watchdog.finished.load(.acquire)) return;
            try std.Io.sleep(io, .fromMilliseconds(@min(50, deadline.remainingMs(io))), .awake);
        }
        if (watchdog.finished.load(.acquire)) return;
        std.debug.panic("conduit: {s} in {s} did not finish within {d} ms", .{
            watchdog.source.fn_name,
            watchdog.source.file,
            watchdog.limit_ms,
        });
    }
};

/// Counts only the parent's fork and posix_spawn calls, never wall time.
pub const SpawnCalls = struct {
    pub var forks: usize = 0;
    pub var file_actions: usize = 0;
};

var teardown_probe_group: std.Io.Group = .init;
test "runner teardown probe" {
    if (!try std.testing.environ.contains(std.testing.allocator, "CONDUIT_TEARDOWN_PROBE")) return error.SkipZigTest;
    const Task = struct {
        fn run() void {
            // The probe is a task that outlives teardown, so it outlives
            // cancelation too.
            while (true) std.Io.sleep(std.testing.io, .fromSeconds(1), .awake) catch |err| switch (err) {
                error.Canceled => {},
            };
        }
    };
    // Intentionally leave a backend task alive after the test body returns.
    // Only zig build check-runner enables this probe, in its own disposable process.
    try teardown_probe_group.concurrent(std.testing.io, Task.run, .{});
}
