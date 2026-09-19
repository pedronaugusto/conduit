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
