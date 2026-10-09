const std = @import("std");
const console = @import("conduit.tty").console;

test "a key-down input record has the Windows layout" {
    const InputRecord = console.InputRecord;
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(InputRecord));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(InputRecord, "event"));
    const key: InputRecord = .{ .event_type = console.key_event, .event = .{ .key = .{
        .down = 1,
        .repeat_count = 1,
        .virtual_key = 0,
        .scan_code = 0,
        .character = 'a',
        .control_keys = 0,
    } } };
    try std.testing.expect(key.keyDown());
    var up = key;
    up.event.key.down = 0;
    try std.testing.expect(!up.keyDown());
}
