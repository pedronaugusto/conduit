//! A table of benchmark rows as shakedown rows. An entry is
//! `.{ .name, .unit, .run }` with an optional `.initial`, `.setup` and
//! `.teardown`; its callbacks return inferred error sets, which `ErrorOf`
//! joins into the one set the runner is given.
const bench = @import("shakedown").bench;

/// A sampled row's run: one operation, or the batch was too short to read.
pub fn single(units: u64) error{SampleTooShort}!void {
    if (units != 1) return error.SampleTooShort;
}

/// The error set every callback in `entries` can return, joined.
pub fn ErrorOf(comptime entries: anytype) type {
    var set: type = error{};
    inline for (entries) |entry| {
        inline for (.{ "run", "setup", "teardown" }) |hook| {
            if (@hasField(@TypeOf(entry), hook)) {
                set = set || @typeInfo(@typeInfo(@TypeOf(@field(entry, hook))).@"fn".return_type.?).error_union.error_set;
            }
        }
    }
    return set;
}

/// `table`, a tuple of `.{ .name, .unit, .run }` with an optional `.initial`,
/// `.setup` and `.teardown`, as shakedown rows.
pub fn of(comptime Context: type, comptime Error: type, comptime table: anytype) [table.len]bench.Row(Context, Error) {
    var out: [table.len]bench.Row(Context, Error) = undefined;
    inline for (table, 0..) |entry, i| {
        const has = struct {
            fn field(comptime name: []const u8) bool {
                return @hasField(@TypeOf(entry), name);
            }
        };
        out[i] = .{
            .name = entry.name,
            .unit = entry.unit,
            .initial = if (has.field("initial")) entry.initial else 1,
            .run = entry.run,
            .setup = if (has.field("setup")) entry.setup else null,
            .teardown = if (has.field("teardown")) entry.teardown else null,
        };
    }
    return out;
}
