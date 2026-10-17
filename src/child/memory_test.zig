//! `Child.memory`: what a live child holds, asked by its identity.
const std = @import("std");
const conduit = @import("../conduit.zig");
const Child = conduit.Child;
const reap = @import("../testing/support.zig").reap;
const testing = std.testing;
const test_options = @import("conduit_test_options");
const io = testing.io;

test "a child's memory reads its peak above what it touched and gave back, until it ends" {
    var child = try Child.spawn(testing.allocator, io, .{
        .argv = &.{ test_options.input_fixture, "hold", "64" },
        .stdio = .{ .streams = .{ .stdin = .pipe, .stdout = .pipe, .stderr = .ignore } },
    });
    defer child.deinit(io);
    defer reap(&child, io);
    // The fixture says `held` once its 64 MiB are touched and given back; a
    // fixture that fails ends its output instead, so the read cannot hang.
    var buffer: [64]u8 = undefined;
    var stdout = child.stdoutReader(io, &buffer).?;
    try testing.expectEqualStrings("held", try stdout.interface.takeDelimiterExclusive('\n'));
    const memory = try child.memory();
    try testing.expect(memory.current > 0);
    try testing.expect(memory.peak >= 64 << 20);
    try testing.expect(memory.current < memory.peak);
    child.closeStdin(io);
    try testing.expect(Child.succeeded(try child.wait(io)));
    try testing.expectError(error.ProcessEnded, child.memory());
}

const shakedown = @import("shakedown");
const gen = shakedown.gen;
const parseLinuxStatus = @import("../memory.zig").parseLinuxStatus;

/// A Linux status file with its two lines among others, in any order, reads
/// back both; any bytes at all are an answer or an error, never a crash.
fn statusReadsBack(_: void, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = testing.allocator;
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    const current = gen.int(s, u32);
    const peak = gen.int(s, u32);
    const others = [_][]const u8{ "Name:\tserver\n", "VmPeak:\t  999 kB\n", "Threads:\t4\n", "VmRSSx\n", "\n" };
    var placed: u2 = 0;
    while (placed != 3) {
        if (gen.boolean(s)) {
            try text.appendSlice(gpa, gen.oneOf(s, []const u8, &others));
        } else if (placed == 0 and gen.boolean(s) or placed == 2) {
            try text.print(gpa, "VmRSS:\t{d} kB\n", .{current});
            placed |= 1;
        } else {
            try text.print(gpa, "VmHWM:\t {d} kB\n", .{peak});
            placed |= 2;
        }
    }
    const memory = try parseLinuxStatus(text.items);
    try testing.expectEqual(@as(u64, current) * 1024, memory.current);
    try testing.expectEqual(@as(u64, peak) * 1024, memory.peak);

    var junk: [96]u8 = undefined;
    if (parseLinuxStatus(gen.bytesInto(s, &junk))) |_| {} else |err| switch (err) {
        error.ProcessEnded, error.Unexpected => {},
        error.Unsupported => return error.TestUnexpectedResult,
    }
}

test "a Linux status reads back its resident set and peak, whatever surrounds them" {
    try shakedown.check(testing.allocator, {}, statusReadsBack, .{});
}
