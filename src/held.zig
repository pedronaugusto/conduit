//! How this package holds a file: owned, closed once by its one owner, and
//! lent by value to everyone else.
//!
//! A raw handle becomes an owner here, and nowhere else. A lent file is a plain
//! `std.Io.File`, aegis's one way to lend a handle released by value
//! (`borrow().*`): who closes it is the owner's, and glint's lending rule holds
//! a holder to never closing a file it did not open or take out of an owner.

const std = @import("std");
const aegis = @import("aegis");

/// A file its owner closes, once: `deinit(io)` closes it, `move` hands it on
/// to a new owner, and `borrow` lends the file to read or write.
pub const OwnedFile = aegis.own.OwnedIo(std.Io.File, closeFile);

fn closeFile(file: *std.Io.File, io: std.Io) void {
    file.close(io);
}

/// A raw handle this process opened, owned from here.
pub fn own(handle: std.Io.File.Handle) OwnedFile {
    return .init(.{ .handle = handle, .flags = .{ .nonblocking = false } });
}

/// A raw handle its holder keeps, lent as a file: the holder still closes it.
pub fn lend(handle: std.Io.File.Handle) std.Io.File {
    return .{ .handle = handle, .flags = .{ .nonblocking = false } };
}

/// Closes a raw handle its holder lets go of.
pub fn close(io: std.Io, handle: std.Io.File.Handle) void {
    var file = own(handle);
    file.deinit(io);
}
