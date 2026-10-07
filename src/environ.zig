//! Building a child's environment from the calling process's own.
//!
//! `std.process.Environ.Map` is the type `Child.spawn` takes, and the standard
//! library can already turn the process's environment into one. What it has no
//! answer for is the thing every program that spawns a child actually wants:
//! *this* environment, with two or three things changed — a `TERM` for a child
//! on a pseudo-terminal, a variable removed so the child does not inherit a
//! secret. That is one function, and it is here.

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const is_windows = builtin.target.os.tag == .windows;

/// One change to make to an inherited environment.
pub const Override = struct {
    name: []const u8,
    /// `null` removes the variable, rather than setting it to the empty
    /// string. The two are different to most programs.
    value: ?[]const u8,
};

pub const InheritError = error{
    OutOfMemory,
    /// The operating system would not report its own environment. Only
    /// reachable on systems where the environment is a call rather than a
    /// block of memory.
    Unexpected,
};

/// The calling process's environment, with `overrides` applied, as a map the
/// caller owns.
///
/// Overrides are applied in order, so a later one wins. The result is
/// independent of the process's environment from here on: changing one does
/// not change the other.
///
/// The caller must `deinit` the map. It may be freed as soon as
/// `Child.spawn` returns, which copies everything it needs before it starts
/// the child.
pub fn inherit(
    allocator: Allocator,
    overrides: []const Override,
) InheritError!std.process.Environ.Map {
    var map = if (is_windows)
        try current().createMap(allocator)
    else
        try mapOfBlock(allocator, posixBlock());
    errdefer map.deinit();
    try apply(&map, overrides);
    return map;
}

/// An environment with *only* the named variables in it, as a map the caller
/// owns.
///
/// The `env -i` shape, and the other half of what a program spawning a child
/// needs: `inherit` is this process's environment with changes, and this is no
/// inheritance at all. A child started with it sees exactly what is listed and
/// nothing else -- no `PATH`, no credentials in an agent socket, nothing left
/// over from whatever started *this* process.
///
/// An override with a `null` value is skipped rather than being an error:
/// "remove it" and "it was never there" are the same thing in an environment
/// built from nothing, which makes one list usable with both functions.
///
/// With `Child.SpawnOptions.path_search` left at its default, a missing
/// `PATH` uses the POSIX default directories; Windows still checks its fixed
/// program directories. An empty `PATH` searches the child's current directory
/// on POSIX. `.parent_environ` selects the parent's `PATH` on POSIX, when a
/// scrubbed environment should still find a program installed there.
pub fn only(
    allocator: Allocator,
    variables: []const Override,
) Allocator.Error!std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(allocator);
    errdefer map.deinit();
    try apply(&map, variables);
    return map;
}

/// Applies `overrides` to a map that already exists.
///
/// The same rules as `inherit`, for a caller that built the map some other
/// way.
pub fn apply(
    map: *std.process.Environ.Map,
    overrides: []const Override,
) Allocator.Error!void {
    for (overrides) |override| {
        if (override.value) |value| {
            try map.put(override.name, value);
        } else {
            _ = map.swapRemove(override.name);
        }
    }
}

/// A POSIX environment block as a map, read the way `getenv` reads it.
///
/// The block is whatever the parent passed to `execve`, and nothing makes
/// every entry `NAME=value`. An entry with no `=`, or with nothing before
/// it, is no variable `getenv` can find, and is left out rather than
/// handed to the standard library's map -- which slices past the end of the
/// first and refuses the empty name of the second by assertion. A name given
/// twice is the first one, the value `getenv` returns to this process and so
/// the one its child should inherit.
fn mapOfBlock(allocator: Allocator, entries: []const [*:0]const u8) Allocator.Error!std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(allocator);
    errdefer map.deinit();
    for (entries) |pointer| {
        const entry = std.mem.span(pointer);
        const equals = std.mem.findScalar(u8, entry, '=') orelse continue;
        if (equals == 0) continue;
        const name = entry[0..equals];
        if (map.get(name) != null) continue;
        try map.put(name, entry[equals + 1 ..]);
    }
    return map;
}

/// This process's environment on Windows, in the shape `std.process.Environ`
/// wants. It lives in the process environment block and is read under the
/// lock the standard library takes for it, so the marker is all that is
/// needed.
fn current() std.process.Environ {
    return .{ .block = .global };
}

/// This process's `environ` array, which has no length but is
/// null-terminated.
fn posixBlock() []const [*:0]const u8 {
    var count: usize = 0;
    while (std.c.environ[count] != null) count += 1;
    return @ptrCast(std.c.environ[0..count]); // safe: the first `count` entries are not null, counted above
}

test "an environment entry without a name or an equals sign is no variable" {
    if (is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    // What a parent that calls `execve` itself can hand a child: entries
    // `getenv` never matches, and a name given twice.
    const entries = [_][*:0]const u8{ "A=1", "NOEQUALS", "=value", "B=", "A=2", "C==x" };
    var map = try mapOfBlock(gpa, &entries);
    defer map.deinit();
    try std.testing.expectEqual(@as(usize, 3), map.count());
    // The value `getenv` gives this process is the one a child inherits.
    try std.testing.expectEqualStrings("1", map.get("A").?);
    try std.testing.expectEqualStrings("", map.get("B").?);
    try std.testing.expectEqualStrings("=x", map.get("C").?);
}

/// `getenv`, over a block: the value of the first entry spelled `name=`.
fn referenceGetenv(entries: []const [*:0]const u8, name: []const u8) ?[]const u8 {
    for (entries) |pointer| {
        const entry = std.mem.span(pointer);
        if (entry.len > name.len and std.mem.startsWith(u8, entry, name) and entry[name.len] == '=')
            return entry[name.len + 1 ..];
    }
    return null;
}

fn readsAsGetenv(_: void, smith: *std.testing.Smith) !void {
    @disableInstrumentation();
    if (is_windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    // Entries out of a few names, equals signs and values, so that names
    // repeat and entries go without one.
    const pieces = [_][]const u8{ "A", "B", "AB", "=", "==", "x", "", "\xff", " " };
    var storage: [8][32:0]u8 = undefined;
    var entries: [8][*:0]const u8 = undefined;
    var count: usize = 0;
    while (count < entries.len and !smith.eosWeightedSimple(4, 1)) : (count += 1) {
        var len: usize = 0;
        while (len < 24 and !smith.eosWeightedSimple(2, 1)) {
            const piece = pieces[smith.index(pieces.len)];
            @memcpy(storage[count][len..][0..piece.len], piece);
            len += piece.len;
        }
        storage[count][len] = 0;
        entries[count] = storage[count][0..len :0].ptr;
    }
    var map = try mapOfBlock(gpa, entries[0..count]);
    defer map.deinit();
    // Every name `getenv` finds is in the map with the value it finds, and
    // nothing else is.
    var names: usize = 0;
    for (entries[0..count], 0..) |pointer, i| {
        const entry = std.mem.span(pointer);
        const equals = std.mem.findScalar(u8, entry, '=') orelse continue;
        if (equals == 0) continue;
        const name = entry[0..equals];
        const first = for (entries[0..i]) |earlier| {
            const before = std.mem.span(earlier);
            if (before.len > equals and std.mem.startsWith(u8, before, name) and before[equals] == '=') break false;
        } else true;
        if (first) names += 1;
        try std.testing.expectEqualStrings(referenceGetenv(entries[0..count], name).?, map.get(name).?);
    }
    try std.testing.expectEqual(names, map.count());
}

test "an environment block reads as getenv reads it" {
    try std.testing.fuzz({}, readsAsGetenv, .{});
}

test "an environment block reads as getenv reads it, over seeded rounds" {
    if (is_windows) return error.SkipZigTest;
    var prng: std.Random.DefaultPrng = .init(0xe4);
    var bytes: [256]u8 = undefined;
    for (0..256) |_| {
        for (&bytes) |*byte| byte.* = switch (prng.random().uintLessThan(u8, 10)) {
            0...6 => 0,
            7, 8 => prng.random().uintLessThan(u8, 16),
            else => prng.random().int(u8),
        };
        var smith: std.testing.Smith = .{ .in = &bytes };
        try readsAsGetenv({}, &smith);
    }
}

test "inherit copies the process environment" {
    const gpa = std.testing.allocator;
    var map = try inherit(gpa, &.{});
    defer map.deinit();
    // Every system this package supports puts something in an environment.
    try std.testing.expect(map.count() > 0);
}

test "an override sets, replaces and removes" {
    const gpa = std.testing.allocator;
    var map = try inherit(gpa, &.{
        .{ .name = "CONDUIT_TEST_ONE", .value = "first" },
        .{ .name = "CONDUIT_TEST_ONE", .value = "second" },
        .{ .name = "CONDUIT_TEST_TWO", .value = "here" },
        .{ .name = "CONDUIT_TEST_TWO", .value = null },
    });
    defer map.deinit();

    try std.testing.expectEqualStrings("second", map.get("CONDUIT_TEST_ONE").?);
    try std.testing.expect(!map.contains("CONDUIT_TEST_TWO"));
}

test "only builds an environment with nothing inherited" {
    const gpa = std.testing.allocator;
    var map = try only(gpa, &.{
        .{ .name = "CONDUIT_TEST_ONLY", .value = "alone" },
        .{ .name = "CONDUIT_TEST_GONE", .value = null },
    });
    defer map.deinit();

    try std.testing.expectEqual(@as(usize, 1), map.count());
    try std.testing.expectEqualStrings("alone", map.get("CONDUIT_TEST_ONLY").?);
    // Whatever this process has, the child would not: PATH is the one every
    // system sets and the one a scrubbed environment most conspicuously lacks.
    try std.testing.expect(!map.contains("PATH"));
}

test "removing something that was never there is not an error" {
    const gpa = std.testing.allocator;
    var map = try inherit(gpa, &.{.{ .name = "CONDUIT_TEST_ABSENT", .value = null }});
    defer map.deinit();
    try std.testing.expect(!map.contains("CONDUIT_TEST_ABSENT"));
}
