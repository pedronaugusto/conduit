//! A native input reader, a child that stays alive without reading, one
//! that says its number into each descriptor it was given above the
//! standard three, one that answers over the channel its parent named, or
//! one that held some memory and stays until its input ends.
const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const tty = @import("conduit.tty");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (std.mem.eql(u8, args[1], "exit")) return;
    if (std.mem.eql(u8, args[1], "stall")) {
        try init.io.sleep(.fromSeconds(30), .awake);
        return;
    }
    if (std.mem.eql(u8, args[1], "channel")) return channel(init, args[2]);
    if (std.mem.eql(u8, args[1], "inherited")) return inherited(try std.fmt.parseInt(usize, args[2], 10));
    if (std.mem.eql(u8, args[1], "hold")) return hold(init.io, try std.fmt.parseInt(usize, args[2], 10));
    const input = std.Io.File.stdin();
    const output = std.Io.File.stdout();
    var buffer: [4096]u8 = undefined;
    while (true) {
        const n = input.readStreaming(init.io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n != 0) try output.writeStreamingAll(init.io, buffer[0..n]);
    }
    if (std.mem.eql(u8, args[1], "end")) try output.writeStreamingAll(init.io, "EOF");
}

/// Reads a line from the channel `variable` names and answers it with the
/// variable's value and the line, then closes its end.
fn channel(init: std.process.Init, variable: []const u8) !void {
    const value = init.environ_map.get(variable) orelse return error.FixtureNoChannel;
    var end = (try tty.Channel.inherited(init.environ_map, variable)).?;
    defer end.deinit(init.io);
    var line: [256]u8 = undefined;
    var got: usize = 0;
    while (std.mem.findScalar(u8, line[0..got], '\n') == null) {
        if (got == line.len) return error.FixtureLineTooLong;
        got += try end.borrow().readStreaming(init.io, &.{line[got..]});
    }
    var answer: [512]u8 = undefined;
    try end.borrow().writeStreamingAll(init.io, try std.mem.print(&answer, "{s} {s}", .{ value, line[0..got] }));
}

/// Touches every page of `mib` MiB, gives them back, says `held`, and stays
/// until its input ends: its peak memory is above `mib`, its current below.
fn hold(io: std.Io, mib: usize) !void {
    const block = try std.heap.page_allocator.alloc(u8, mib << 20);
    @memset(block, 0xa5);
    std.mem.doNotOptimizeAway(block.ptr);
    std.heap.page_allocator.free(block);
    try std.Io.File.stdout().writeStreamingAll(io, "held\n");
    var buffer: [64]u8 = undefined;
    while (true) _ = std.Io.File.stdin().readStreaming(io, &.{&buffer}) catch |err| switch (err) {
        error.EndOfStream => return,
        else => return err,
    };
}

/// Writes `fd <n>\n` into descriptors 3 through `2 + count`. On Windows the
/// handles come from the C runtime's table in the startup record, read the
/// way that runtime reads it: a count, a flag byte per descriptor, then the
/// handles, none of it aligned.
fn inherited(count: usize) !void {
    var line: [32]u8 = undefined;
    if (builtin.target.os.tag != .windows) {
        for (3..3 + count) |fd| {
            const text = try std.mem.print(&line, "fd {d}\n", .{fd});
            if (std.c.write(@intCast(fd), text.ptr, text.len) != @as(isize, @intCast(text.len))) return error.FixtureWriteFailed;
        }
        return;
    }
    var startup: windows.STARTUPINFOW = undefined;
    GetStartupInfoW(&startup);
    const table: [*]const u8 = @ptrCast(startup.lpReserved2 orelse return error.FixtureNoTable); // safe: the startup record supplies cbReserved2 bytes; byte alignment is sufficient.
    const listed: usize = @intCast(std.mem.readInt(i32, table[0..4], .little));
    if (listed < 3 + count) return error.FixtureTableTooShort;
    const flags = table[4..][0..listed];
    const handles = table[4 + listed ..];
    for (3..3 + count) |fd| {
        // FOPEN: the runtime takes no entry without it.
        if (flags[fd] & 0x01 == 0) return error.FixtureNotOpen;
        const value = std.mem.readInt(usize, handles[fd * @sizeOf(usize) ..][0..@sizeOf(usize)], .little);
        const handle: windows.HANDLE = @ptrFromInt(value);
        const text = try std.mem.print(&line, "fd {d}\n", .{fd});
        var written: windows.DWORD = 0;
        if (WriteFile(handle, text.ptr, @intCast(text.len), &written, null) == .FALSE or written != text.len)
            return error.FixtureWriteFailed;
    }
}

extern "kernel32" fn GetStartupInfoW(info: *windows.STARTUPINFOW) callconv(.winapi) void;
extern "kernel32" fn WriteFile(
    handle: windows.HANDLE,
    buffer: [*]const u8,
    size: windows.DWORD,
    written: *windows.DWORD,
    overlapped: ?*anyopaque,
) callconv(.winapi) windows.BOOL;
