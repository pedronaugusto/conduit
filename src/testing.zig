//! conduit's simulated route, for the tests of code that starts children
//! through conduit: the module `conduit.testing`, on shakedown.
//!
//! conduit's children, terminals, signals and waits go past the `Io` they
//! are given, to the system. Over a shakedown `Sim`, a `Seam` is the `Io`
//! that sends them to the simulation instead: `Child.spawn` starts a program
//! registered on `Sim.programs()` as a simulated process, on pipes, on a
//! simulated terminal (`Pty.open`), on the null device or on files; `kill`
//! ends it as the signal would, `wait`, `waitTimeout` and `tryWait` wait for
//! it on the simulation's clock, and the run repeats from its seed.
//!
//!     try sim.programs().register("fake-git", fakeGit, .{});
//!     const seam = try conduit.testing.Seam.create(gpa, sim.io());
//!     defer seam.destroy();
//!     try code.under(seam.io()); // spawns "fake-git" through conduit
//!
//! What a simulation cannot be is refused rather than pretended: a resource
//! limit, credentials, a job object's limits and a parent-death signal are
//! `error.Unsupported`. A simulated child's own children are not ended with
//! it.
//!
//! A project's build gets this module from `conduit`'s build.zig:
//! `@import("conduit").testing(conduit_dependency)`. Only a build that asks
//! for it fetches shakedown.
const std = @import("std");
const Io = std.Io;
const shakedown = @import("shakedown");
const seam = @import("seam");

const Routed = shakedown.Layer(seam.RoutedState, .{ .processSpawn = seam.routedSpawn });

/// One test's routed `Io`. Must not move once `io` is called; `create`
/// allocates it.
pub const Seam = struct {
    gpa: std.mem.Allocator,
    programs: shakedown.Sim.Programs,
    routed: Routed,

    pub const CreateError = error{ OutOfMemory, NotASimulation };

    /// A seam over `base`, a simulation's `Io` (`Sim.io`, `Node.io`).
    pub fn create(gpa: std.mem.Allocator, base: Io) CreateError!*Seam {
        const programs = shakedown.Sim.programsOf(base) orelse return error.NotASimulation;
        const s = try gpa.create(Seam);
        s.* = .{ .gpa = gpa, .programs = programs, .routed = undefined };
        s.routed = .init(base, .{ .route = .{
            .ctx = &s.programs,
            .openTerminal = terminal,
            .readWindow = windowSize,
            .writeWindow = setWindowSize,
            .endChild = end,
            .pollChild = poll,
            .waitChild = waitFor,
        }, .base = base });
        return s;
    }

    pub fn destroy(s: *Seam) void {
        s.gpa.destroy(s);
    }

    /// The `Io` to hand the code under test.
    pub fn io(s: *Seam) Io {
        return s.routed.io();
    }
};

fn programsOf(ctx: *anyopaque) *shakedown.Sim.Programs {
    return @ptrCast(@alignCast(ctx)); // safe: `create` makes the route with the seam's own Programs as ctx
}

fn terminal(ctx: *anyopaque, size: seam.Size) seam.TerminalError!seam.Terminal {
    const t = try programsOf(ctx).terminal(.{ .rows = size.rows, .cols = size.cols });
    return .{ .master = t.master, .slave = t.slave };
}

fn windowSize(ctx: *anyopaque, file: Io.File) seam.WindowError!seam.Size {
    const size = try programsOf(ctx).windowSize(file);
    return .{ .rows = size.rows, .cols = size.cols };
}

fn setWindowSize(ctx: *anyopaque, file: Io.File, size: seam.Size) seam.WindowError!void {
    return programsOf(ctx).setWindowSize(file, .{ .rows = size.rows, .cols = size.cols });
}

fn end(ctx: *anyopaque, child: *const std.process.Child, term: seam.Term) void {
    programsOf(ctx).end(child, term);
}

fn poll(ctx: *anyopaque, child: *std.process.Child) std.process.Child.WaitError!?seam.Term {
    return programsOf(ctx).poll(child);
}

fn waitFor(ctx: *anyopaque, child: *std.process.Child, timeout: Io.Timeout) std.process.Child.WaitError!?seam.Term {
    return programsOf(ctx).waitFor(child, timeout);
}
