//! The machine's host name, on every system this package supports.
const builtin = @import("builtin");
const std = @import("std");
const windows = std.os.windows;
const win32 = @import("win32");

/// The longest name `hostName` gives, in bytes: above every POSIX system's
/// `HOST_NAME_MAX` (64 on Linux, 255 on Darwin and the BSDs), and a Windows
/// DNS host name of up to 85 UTF-16 units as WTF-8.
pub const max_len = 256;

pub const Error = error{
    /// Windows: the name is longer than 85 UTF-16 units (a DNS host name
    /// has at most 63 characters).
    NameTooLong,
    Unexpected,
};

/// The name this machine goes by, in `buf`: POSIX `gethostname`'s, and on
/// Windows the DNS host name without its domain (`GetComputerNameExW`'s
/// `ComputerNameDnsHostname`, what Winsock's `gethostname` returns) as WTF-8.
pub fn hostName(buf: *[max_len]u8) Error![]const u8 {
    if (comptime builtin.target.os.tag == .windows) return windowsName(buf);
    return switch (std.posix.errno(std.c.gethostname(buf, buf.len))) {
        // A name is shorter than the buffer, so it ends in its zero.
        .SUCCESS => std.mem.sliceTo(buf, 0),
        else => |err| std.posix.unexpectedErrno(err),
    };
}

fn windowsName(buf: *[max_len]u8) Error![]const u8 {
    // Every unit takes at most three bytes as WTF-8: these fit `buf`.
    var wide: [max_len / 3]u16 = undefined;
    var len: windows.DWORD = wide.len;
    // aegis: boundary(A019): GetComputerNameExW writes the name and its length where it answers TRUE
    if (win32.GetComputerNameExW(win32.computer_name_dns_hostname, &wide, &len) == .FALSE) return switch (windows.GetLastError()) {
        .MORE_DATA => error.NameTooLong,
        else => |err| win32.unexpected(err),
    };
    return buf[0..std.unicode.wtf16LeToWtf8(buf, wide[0..len])];
}
