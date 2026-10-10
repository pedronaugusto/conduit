//! Bytes drawn from a shakedown `Source`, for the properties that read text
//! and records: a prefix of a buffer of any length, filled with any bytes or
//! with bytes of weighted ranges.

const shakedown = @import("shakedown");

/// A range of bytes, drawn in proportion to its weight, a byte of it evenly.
pub const Pick = struct { lo: u8, hi: u8, weight: u32 };

/// Fills `out` with bytes of `picks`.
pub fn fillWeighted(s: *shakedown.Source, out: []u8, comptime picks: []const Pick) void {
    const weights = comptime blk: {
        var list: [picks.len]u32 = undefined;
        for (picks, &list) |pick, *weight| weight.* = pick.weight;
        break :blk list;
    };
    for (out) |*byte| {
        const pick = picks[shakedown.gen.weighted(s, &weights)];
        byte.* = shakedown.gen.intRange(s, u8, pick.lo, pick.hi);
    }
}

/// A prefix of `out`, of any length, filled with bytes of `picks`.
pub fn weightedBytes(s: *shakedown.Source, out: []u8, comptime picks: []const Pick) []u8 {
    const len = shakedown.gen.intRange(s, usize, 0, out.len);
    fillWeighted(s, out[0..len], picks);
    return out[0..len];
}

/// A prefix of `out`, of any length, filled with any bytes.
pub fn bytesInto(s: *shakedown.Source, out: []u8) []u8 {
    const len = shakedown.gen.intRange(s, usize, 0, out.len);
    s.bytes(out[0..len]);
    return out[0..len];
}
