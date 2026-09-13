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

const is_windows = builtin.os.tag == .windows;

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
    var map = try current().createMap(allocator);
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
/// With `Child.SpawnOptions.path_search` left at its default, a child with no
/// `PATH` also means a bare `argv[0]` is not found. `.parent_environ` is the
/// setting for a scrubbed environment whose program should still be looked up
/// the ordinary way.
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

/// This process's environment, in the shape `std.process.Environ` wants.
///
/// On Windows it lives in the process environment block and is read under the
/// lock the standard library takes for it, so the marker is all that is
/// needed. On POSIX with libc it is the `environ` array, which has no length
/// but is null-terminated.
fn current() std.process.Environ {
    if (is_windows) return .{ .block = .global };
    var count: usize = 0;
    while (std.c.environ[count] != null) count += 1;
    return .{ .block = .{ .slice = @ptrCast(std.c.environ[0..count :null]) } };
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
