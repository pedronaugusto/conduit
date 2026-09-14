//! What the tests in this package need and the package itself does not.
//!
//! Only test blocks refer to anything here, so nothing in it reaches a program
//! that imports `conduit`.

const std = @import("std");

/// Turns a hang into a failure that says which test hung.
///
/// Every wait a test makes should have a bound, and the ones this package
/// writes do. Not every call it makes is one of those: closing a pseudoconsole
/// waits for the console host to flush and go, a read of a handle another task
/// is closing is the operating system's business, and a child that inherits
/// something it should not can hold a stream open with no deadline attached to
/// it at all. A test that stops in one of those reports nothing and takes the
/// whole run with it, which is the one failure mode a suite cannot recover
/// from — so the bound goes around the test as well.
///
/// The bark is a panic rather than a test failure: the point is to interrupt a
/// task that is not going to return, and only the process going down does
/// that. The message names the test, which is what a run that shows no output
/// at all is missing.
///
/// The same lifetime rules as `Reaper`: it holds a pointer to itself, so it
/// must not move once started, and `deinit` must run.
pub const Watchdog = struct {
    source: std.builtin.SourceLocation,
    limit_ms: u32,
    group: std.Io.Group,
    finished: std.atomic.Value(bool),

    /// Generous: this is a failure budget and not a timing assertion. Nothing
    /// in this suite should come within an order of magnitude of it, and a
    /// loaded continuous-integration machine should not either.
    ///
    /// Under the build runner's own `--test-timeout`, which CI sets to 45
    /// seconds, this has to be the shorter of the two or it never fires: the
    /// runner's bound names the test but ends the process from outside, and
    /// this one ends it from inside, after whatever the test has printed.
    pub const default_ms = 30_000;

    pub fn init(source: std.builtin.SourceLocation) Watchdog {
        return .{
            .source = source,
            .limit_ms = default_ms,
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
    }

    fn watch(watchdog: *Watchdog, io: std.Io) std.Io.Cancelable!void {
        var waited_ms: u32 = 0;
        while (waited_ms < watchdog.limit_ms) : (waited_ms += 50) {
            if (watchdog.finished.load(.acquire)) return;
            try std.Io.sleep(io, .fromMilliseconds(50), .awake);
        }
        if (watchdog.finished.load(.acquire)) return;
        std.debug.panic("conduit: {s} in {s} did not finish within {d} ms", .{
            watchdog.source.fn_name,
            watchdog.source.file,
            watchdog.limit_ms,
        });
    }
};
