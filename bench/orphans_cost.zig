//! What `Orphans` costs, as shakedown rows: spawn and wait of `true` with
//! `Orphans` off and on, and one look (`Orphans.count`) with 0, 10 and 100 live
//! children of conduit's own. Linux only: elsewhere it says so and ends.
//!
//!     orphans-cost [--smoke] [--row <name prefix>] [--samples <n>]
const std = @import("std");
const conduit = @import("conduit");
const rowset = @import("rows.zig");
const bench = @import("shakedown").bench;

const Context = struct {
    init: std.process.Init,
    true_: []const u8,
    sleep: []const u8,
    orphans: conduit.Orphans = undefined,
    children: [100]conduit.Child = undefined,
    live: usize = 0,

    fn io(x: *const Context) std.Io {
        return x.init.io;
    }

    fn gpa(x: *const Context) std.mem.Allocator {
        return x.init.gpa;
    }
};

const table = .{
    .{ .name = "spawn_wait/off", .unit = "spawn", .run = spawnWait },
    .{ .name = "spawn_wait/on", .unit = "spawn", .setup = tracking, .run = spawnWait, .teardown = untracking },
    .{ .name = "look/0", .unit = "look", .setup = tracking, .run = look, .teardown = untracking },
    .{ .name = "look/10", .unit = "look", .setup = look10, .run = look, .teardown = untracking },
    .{ .name = "look/100", .unit = "look", .setup = look100, .run = look, .teardown = untracking },
};
const WorkloadError = rowset.ErrorOf(table);
comptime {
    std.debug.assert(WorkloadError != anyerror);
}
const rows = rowset.of(Context, WorkloadError, table);

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var smoke = false;
    var prefix: []const u8 = "";
    var samples: usize = 31;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--smoke")) {
            smoke = true;
        } else if (i + 1 < args.len and std.mem.eql(u8, args[i], "--row")) {
            i += 1;
            prefix = args[i];
        } else if (i + 1 < args.len and std.mem.eql(u8, args[i], "--samples")) {
            i += 1;
            samples = try std.fmt.parseInt(usize, args[i], 10);
        } else {
            try std.Io.File.stderr().writeStreamingAll(init.io, "usage: orphans-cost [--smoke] [--row <name prefix>] [--samples <n>]\n");
            return error.Usage;
        }
    }
    if (!conduit.Orphans.supported) {
        try std.Io.File.stderr().writeStreamingAll(init.io, "Orphans tracking unavailable: requires Linux\n");
        return;
    }
    var selected = false;
    for (rows) |row| selected = selected or std.mem.startsWith(u8, row.name, prefix);
    if (!selected) return error.UnknownRow;
    var context: Context = .{
        .init = init,
        .true_ = init.environ_map.get("BENCH_TRUE") orelse "true",
        .sleep = init.environ_map.get("BENCH_SLEEP") orelse "sleep",
    };
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    try bench.run(WorkloadError, init.gpa, init.io, &stdout.interface, &context, &rows, .{ .commit = @import("preflight_bench_options").commit }, .{ .smoke = smoke, .prefix = prefix, .samples = samples });
    try stdout.interface.flush();
}

fn spawnWait(x: *Context, units: u64) !void {
    for (0..units) |_| {
        var child = try conduit.Child.spawn(x.gpa(), x.io(), .{ .argv = &.{x.true_}, .stdio = .ignore });
        defer child.deinit(x.io());
        _ = try child.wait(x.io());
    }
}

/// `Orphans` started, and with `children` live children of conduit's own.
fn start(x: *Context, children: usize) !void {
    x.orphans = .init(x.gpa());
    errdefer x.orphans.deinit();
    try x.orphans.start();
    errdefer x.orphans.stop(x.io()) catch {};
    x.live = 0;
    errdefer end(x);
    for (x.children[0..children]) |*child| {
        child.* = try conduit.Child.spawn(x.gpa(), x.io(), .{ .argv = &.{ x.sleep, "100" }, .stdio = .ignore });
        x.live += 1;
    }
}

/// Every child ended, then `Orphans` stopped.
fn end(x: *Context) void {
    for (x.children[0..x.live]) |*child| {
        _ = child.killWait(x.io(), .zero) catch {};
        child.deinit(x.io());
    }
    x.live = 0;
}

fn tracking(x: *Context) !void {
    try start(x, 0);
}

fn look10(x: *Context) !void {
    try start(x, 10);
}

fn look100(x: *Context) !void {
    try start(x, 100);
}

fn untracking(x: *Context) !void {
    end(x);
    defer x.orphans.deinit();
    try x.orphans.stop(x.io());
}

fn look(x: *Context, units: u64) !void {
    for (0..units) |_| _ = try x.orphans.count(x.io());
}
