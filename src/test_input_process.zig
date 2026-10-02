//! A native input reader, or a child that stays alive without reading.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (std.mem.eql(u8, args[1], "exit")) return;
    if (std.mem.eql(u8, args[1], "stall")) {
        try init.io.sleep(.fromSeconds(30), .awake);
        return;
    }
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
