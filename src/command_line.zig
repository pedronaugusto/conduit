//! The single string a Windows child is started with.
//!
//! `CreateProcessW` takes one command line rather than an argument list, and
//! whatever the child is written in splits it again by the rules
//! `CommandLineToArgvW` parses. Serialising an argument list for those rules is
//! arithmetic on quotes and backslashes and nothing else, so it lives here
//! rather than in `child_windows.zig`: it is the same on every host, and a
//! host that cannot start a Windows child can still run its tests.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The three ways serialising can fail, each of them also a `Child.SpawnError`.
pub const Error = error{
    /// `argv[0]` holds a double quote. See `serialise`.
    InvalidArgv,
    /// A name in `argv` is not valid WTF-8, so it has no UTF-16 spelling.
    InvalidWtf8,
    OutOfMemory,
};

/// Serialises `argv` into the single string `CreateProcessW` takes, by the
/// rules `CommandLineToArgvW` parses back.
///
/// The first argument is quoted differently from the rest: a backslash in it
/// has no special meaning, which makes a double quote in it impossible to
/// escape without letting characters leak into the arguments after it. Such an
/// `argv[0]` is refused rather than mangled. Every later argument is quoted
/// whenever it is empty or holds a space, a control character or a quote, with
/// backslashes doubled where they precede a quote.
pub fn serialise(arena: Allocator, argv: []const []const u8) Error![:0]u16 {
    var buffer: std.ArrayList(u8) = .empty;

    const program = argv[0];
    var program_needs_quotes = program.len == 0;
    for (program) |byte| {
        if (byte == '"') return error.InvalidArgv;
        if (byte <= ' ') program_needs_quotes = true;
    }
    if (program_needs_quotes) {
        try buffer.append(arena, '"');
        try buffer.appendSlice(arena, program);
        try buffer.append(arena, '"');
    } else {
        try buffer.appendSlice(arena, program);
    }

    for (argv[1..]) |argument| {
        try buffer.append(arena, ' ');

        const needs_quotes = for (argument) |byte| {
            if (byte <= ' ' or byte == '"') break true;
        } else argument.len == 0;
        if (!needs_quotes) {
            try buffer.appendSlice(arena, argument);
            continue;
        }

        try buffer.append(arena, '"');
        var backslashes: usize = 0;
        for (argument) |byte| switch (byte) {
            '\\' => backslashes += 1,
            '"' => {
                try buffer.appendNTimes(arena, '\\', backslashes * 2 + 1);
                try buffer.append(arena, '"');
                backslashes = 0;
            },
            else => {
                try buffer.appendNTimes(arena, '\\', backslashes);
                try buffer.append(arena, byte);
                backslashes = 0;
            },
        };
        // The run of backslashes before the closing quote is doubled, so the
        // quote stays a quote and the backslashes stay backslashes.
        try buffer.appendNTimes(arena, '\\', backslashes * 2);
        try buffer.append(arena, '"');
    }

    return std.unicode.wtf8ToWtf16LeAllocZ(arena, buffer.items);
}

//======================================================================
// Tests.
//======================================================================

const testing = std.testing;

fn expectCommandLine(expected: []const u8, argv: []const []const u8) !void {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const line = try serialise(arena_state.allocator(), argv);
    const utf8 = try std.unicode.wtf16LeToWtf8Alloc(testing.allocator, line);
    defer testing.allocator.free(utf8);
    try testing.expectEqualStrings(expected, utf8);
}

test "a command line quotes only what has to be quoted" {
    try expectCommandLine("cmd.exe", &.{"cmd.exe"});
    try expectCommandLine("cmd.exe /c echo", &.{ "cmd.exe", "/c", "echo" });
    try expectCommandLine("\"C:\\Program Files\\x.exe\"", &.{"C:\\Program Files\\x.exe"});
    try expectCommandLine("x.exe \"two words\"", &.{ "x.exe", "two words" });
    try expectCommandLine("x.exe \"\"", &.{ "x.exe", "" });
}

test "a command line escapes quotes and the backslashes before them" {
    try expectCommandLine("x.exe \"a\\\"b\"", &.{ "x.exe", "a\"b" });
    try expectCommandLine("x.exe \"a\\\\\\\"b\"", &.{ "x.exe", "a\\\"b" });
    try expectCommandLine("x.exe \"a b\\\\\\\\\"", &.{ "x.exe", "a b\\\\" });
    // A backslash that is not before a quote is left alone.
    try expectCommandLine("x.exe a\\b", &.{ "x.exe", "a\\b" });
}

test "a first argument containing a quote is refused" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectError(
        error.InvalidArgv,
        serialise(arena_state.allocator(), &.{"a\"b.exe"}),
    );
}

//======================================================================
// The command line, against the rules that parse it back.
//======================================================================

test "an argument list survives the command line it is written into" {
    try testing.fuzz({}, argvSurvivesTheRoundTrip, .{});
}

/// The property: `CommandLineToArgvW`'s rules, applied to what `serialise`
/// wrote, give back the argument list it was given.
///
/// This is the only claim that matters about this file, and the only one a
/// reader cannot check: a quote or a backslash in the wrong place does not
/// mangle an argument, it moves the boundary between two of them, and a child
/// then receives an argument the caller never wrote. The rules are quoted in
/// `parse` below, written from the other direction, and every argument here is
/// built out of the three bytes that decide where a boundary falls.
fn argvSurvivesTheRoundTrip(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();

    // Printable ASCII only: `serialise` ends in a WTF-8 to WTF-16 conversion,
    // and what that does to bytes that spell nothing is a question about the
    // standard library rather than about quoting. The three bytes the rules
    // turn on carry most of the weight.
    const alphabet: []const std.testing.Smith.Weight = &.{
        .rangeAtMost(u8, 0x21, 0x7e, 1),
        .value(u8, '"', 8),
        .value(u8, '\\', 8),
        .value(u8, ' ', 8),
        .value(u8, '\t', 2),
    };

    var storage: [6][12]u8 = undefined;
    var argv: [6][]const u8 = undefined;
    const count = smith.valueRangeAtMost(u8, 1, argv.len);
    for (argv[0..count], storage[0..count]) |*argument, *bytes| {
        argument.* = bytes[0..smith.sliceWeightedBytes(bytes, alphabet)];
    }
    const wanted = argv[0..count];

    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const line = serialise(arena, wanted) catch |err| switch (err) {
        // The one argument list with no command line: a first argument
        // holding a quote, which is refused rather than mangled.
        error.InvalidArgv => {
            try testing.expect(std.mem.indexOfScalar(u8, wanted[0], '"') != null);
            return;
        },
        else => |e| return e,
    };

    const utf8 = try std.unicode.wtf16LeToWtf8Alloc(arena, line);
    const parsed = try parse(arena, utf8);

    try testing.expectEqual(wanted.len, parsed.len);
    for (wanted, parsed) |expected, actual| try testing.expectEqualStrings(expected, actual);
}

/// The rules `CommandLineToArgvW` splits a command line by, as a program that
/// starts a Windows child would have them applied to what it wrote.
///
/// The first argument is its own grammar: a quoted one runs to the next quote
/// and a bare one to the first space or tab, and a backslash in either is an
/// ordinary character. In every argument after it a run of backslashes means
/// something only when a quote follows: `2n` of them are `n` backslashes and
/// the quote opens or closes a quoted run, `2n + 1` are `n` backslashes and a
/// literal quote. A space or a tab outside a quoted run ends the argument.
fn parse(arena: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    var at: usize = 0;

    {
        var first: std.ArrayList(u8) = .empty;
        if (at < line.len and line[at] == '"') {
            at += 1;
            while (at < line.len and line[at] != '"') : (at += 1) try first.append(arena, line[at]);
            if (at < line.len) at += 1;
        } else {
            while (at < line.len and !isSeparator(line[at])) : (at += 1) try first.append(arena, line[at]);
        }
        try argv.append(arena, first.items);
    }

    while (true) {
        while (at < line.len and isSeparator(line[at])) at += 1;
        if (at == line.len) break;

        var argument: std.ArrayList(u8) = .empty;
        var quoted = false;
        while (at < line.len) {
            switch (line[at]) {
                '\\' => {
                    var backslashes: usize = 0;
                    while (at < line.len and line[at] == '\\') : (at += 1) backslashes += 1;
                    if (at < line.len and line[at] == '"') {
                        try argument.appendNTimes(arena, '\\', backslashes / 2);
                        if (backslashes % 2 == 1) {
                            try argument.append(arena, '"');
                        } else {
                            quoted = !quoted;
                        }
                        at += 1;
                    } else {
                        try argument.appendNTimes(arena, '\\', backslashes);
                    }
                },
                '"' => {
                    quoted = !quoted;
                    at += 1;
                },
                else => |byte| {
                    if (!quoted and isSeparator(byte)) break;
                    try argument.append(arena, byte);
                    at += 1;
                },
            }
        }
        try argv.append(arena, argument.items);
    }

    return argv.items;
}

fn isSeparator(byte: u8) bool {
    return byte == ' ' or byte == '\t';
}
