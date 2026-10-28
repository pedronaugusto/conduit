//! The two ways this package holds a file: owned, closed once by its one
//! owner, or lent by the owner that closes it.
//!
//! A raw handle becomes one or the other here, and nowhere else, so the type
//! a file is held in says who closes it.

const std = @import("std");
const aegis = @import("aegis");

/// A file its owner closes, once: `deinit(io)` closes it, `move` hands it on
/// to a new owner, and `borrow` or `lend` reach the file to read or write.
pub const OwnedFile = aegis.own.OwnedIo(std.Io.File, closeFile);

/// A file another owner closes, lent out: `get` is the file to read or write,
/// never to close. It ends when its owner closes the file or hands it on.
pub const LentFile = aegis.own.Lent(std.Io.File);

fn closeFile(file: *std.Io.File, io: std.Io) void {
    file.close(io);
}

/// A raw handle this process opened, owned from here.
pub fn own(handle: std.Io.File.Handle) OwnedFile {
    return .init(.{ .handle = handle, .flags = .{ .nonblocking = false } });
}

/// A raw handle its holder keeps, lent: the holder still closes it.
pub fn lend(handle: std.Io.File.Handle) LentFile {
    return .{ .data = .{ .handle = handle, .flags = .{ .nonblocking = false } } };
}

/// Closes a raw handle its holder lets go of.
pub fn close(io: std.Io, handle: std.Io.File.Handle) void {
    var file = own(handle);
    file.deinit(io);
}
