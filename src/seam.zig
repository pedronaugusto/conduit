//! The seam in front of the process calls conduit makes past `std.Io`: where
//! a child is started, signalled and waited for, and where a terminal pair
//! comes from, when they are not the system's.
//!
//! A module of its own, imported by conduit and by `conduit.testing` and
//! exported by neither: production conduit asks only whether an `Io` carries
//! a route, one function-pointer compare, and the test module is the one
//! place that builds one. The `Io` carries it as a layer whose
//! `processSpawn` is `routedSpawn` and whose state is a `RoutedState`; a
//! child spawned through such an `Io` is started by `std.process` on the
//! route's `Io`, a simulation's, and everything conduit then does to it
//! (a signal, a wait with a deadline, a wait that does not wait) and every
//! terminal it opens goes to the route instead of the system.
const std = @import("std");
const Io = std.Io;

/// A terminal's window, in character cells.
pub const Size = struct { rows: u16, cols: u16 };

/// A terminal pair, one file each side: what the master writes the slave
/// reads, and the other way.
pub const Terminal = struct { master: Io.File, slave: Io.File };

/// How a child ended, as `std.process` reports it.
pub const Term = std.process.Child.Term;

pub const TerminalError = error{ OutOfMemory, SystemResources };
pub const WindowError = error{ BadHandle, NotTerminalDevice };

/// Where conduit's own process calls are made instead of on the system.
pub const Route = struct {
    ctx: *anyopaque,
    openTerminal: *const fn (ctx: *anyopaque, size: Size) TerminalError!Terminal,
    readWindow: *const fn (ctx: *anyopaque, file: Io.File) WindowError!Size,
    writeWindow: *const fn (ctx: *anyopaque, file: Io.File, size: Size) WindowError!void,
    /// Ends the child as `term` at once, as a signal it does not catch.
    endChild: *const fn (ctx: *anyopaque, child: *const std.process.Child, term: Term) void,
    /// How the child ended, reaping it, or null while it runs.
    pollChild: *const fn (ctx: *anyopaque, child: *std.process.Child) std.process.Child.WaitError!?Term,
    /// The child's end, reaping it, or null once `timeout` passes.
    waitChild: *const fn (ctx: *anyopaque, child: *std.process.Child, timeout: Io.Timeout) std.process.Child.WaitError!?Term,

    pub fn terminal(r: *const Route, size: Size) TerminalError!Terminal {
        return r.openTerminal(r.ctx, size);
    }
    pub fn windowSize(r: *const Route, file: Io.File) WindowError!Size {
        return r.readWindow(r.ctx, file);
    }
    pub fn setWindowSize(r: *const Route, file: Io.File, size: Size) WindowError!void {
        return r.writeWindow(r.ctx, file, size);
    }
    pub fn end(r: *const Route, child: *const std.process.Child, term: Term) void {
        r.endChild(r.ctx, child, term);
    }
    pub fn poll(r: *const Route, child: *std.process.Child) std.process.Child.WaitError!?Term {
        return r.pollChild(r.ctx, child);
    }
    pub fn waitFor(r: *const Route, child: *std.process.Child, timeout: Io.Timeout) std.process.Child.WaitError!?Term {
        return r.waitChild(r.ctx, child, timeout);
    }
};

/// The state of the layer that carries a route: the route, and the `Io` the
/// layer is over, which a spawn goes to.
pub const RoutedState = struct { route: Route, base: Io };

/// The routed layer's `processSpawn`: `std.process.spawn` on the base, the
/// simulation's.
pub fn routedSpawn(userdata: ?*anyopaque, options: std.process.SpawnOptions) std.process.SpawnError!std.process.Child {
    const state: *RoutedState = @ptrCast(@alignCast(userdata.?)); // safe: an Io whose processSpawn is routedSpawn carries a RoutedState as userdata
    return std.process.spawn(state.base, options);
}

/// Whether `io`'s spawn is the routed layer's.
fn isRouted(io: Io) bool {
    return io.vtable.processSpawn == &routedSpawn;
}

/// The route `io` carries, if it carries one: one compare.
pub fn routeOf(io: Io) ?*const Route {
    if (!isRouted(io)) return null;
    const state: *const RoutedState = @ptrCast(@alignCast(io.userdata.?)); // safe: an Io whose processSpawn is routedSpawn carries a RoutedState as userdata
    return &state.route;
}
