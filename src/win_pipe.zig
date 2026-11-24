//! A pipe on the named-pipe device, as Windows makes an anonymous one, with
//! each end's mode and inheritance the caller's: the one way this package
//! makes a Windows pipe it reads with an overlapped call.
//!
//! `CreatePipe` makes both ends for synchronous calls, and a synchronous read
//! holds its thread until bytes come; a read this process waits on beside
//! other things (a child's two streams and its exit, `Child.output`) is
//! overlapped, so the end this process reads is opened so. The other end is
//! the caller's choice: a child or a console is given one for synchronous
//! calls, which is what every program expects of its standard streams.
//! Windows only.

const std = @import("std");
const windows = std.os.windows;

pub const End = struct {
    /// A child started with handle inheritance gets this end.
    inherit: bool = false,
    /// Opened for overlapped calls; otherwise for synchronous ones, which
    /// a thread waits in.
    overlapped: bool,
};

pub const Options = struct {
    /// The end created first, the pipe's server.
    server: End,
    /// The end opened on it, the pipe's client.
    client: End,
    /// The server reads what the client writes.
    inbound: bool = false,
    /// The server writes what the client reads.
    outbound: bool = false,
    /// What each direction holds before a write waits.
    quota: u32 = 64 * 1024,
};

pub const Error = error{SystemResources} || std.Io.UnexpectedError;

/// The two ends, server first; both the caller's to close.
pub fn create(options: Options) Error![2]windows.HANDLE {
    const device = try namedPipeDevice();
    defer windows.CloseHandle(device);

    var server: windows.HANDLE = undefined;
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    // 120 s in NT's 100 ns units, negative for a time relative to now.
    const timeout: windows.LARGE_INTEGER = -1_200_000_000;
    switch (windows.ntdll.NtCreateNamedPipeFile(
        &server,
        .{
            .SPECIFIC = .{ .FILE_PIPE = .{ .READ_DATA = options.inbound, .WRITE_DATA = options.outbound, .WRITE_ATTRIBUTES = true } },
            .STANDARD = .{ .SYNCHRONIZE = true },
        },
        &.{ .RootDirectory = device, .Attributes = .{ .INHERIT = options.server.inherit } },
        &status_block,
        .{ .READ = true, .WRITE = true },
        .CREATE,
        mode(options.server),
        .{ .TYPE = .BYTE_STREAM },
        .{ .MODE = .BYTE_STREAM },
        .{ .OPERATION = .QUEUE },
        1,
        if (options.inbound) options.quota else 0,
        if (options.outbound) options.quota else 0,
        &timeout,
    )) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => |status| return windows.unexpectedStatus(status),
    }
    errdefer windows.CloseHandle(server);

    var client: windows.HANDLE = undefined;
    switch (windows.ntdll.NtOpenFile(
        &client,
        .{
            .SPECIFIC = .{ .FILE_PIPE = .{ .READ_DATA = options.outbound, .WRITE_DATA = options.inbound, .WRITE_ATTRIBUTES = true } },
            .STANDARD = .{ .SYNCHRONIZE = true },
        },
        &.{ .RootDirectory = server, .Attributes = .{ .INHERIT = options.client.inherit } },
        &status_block,
        .{ .READ = true, .WRITE = true },
        mode(options.client),
    )) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => |status| return windows.unexpectedStatus(status),
    }
    return .{ server, client };
}

fn mode(end: End) windows.FILE.MODE {
    return .{ .IO = if (end.overlapped) .ASYNCHRONOUS else .SYNCHRONOUS_NONALERT };
}

/// The named-pipe device, `\Device\NamedPipe\`, which a pipe with no name is
/// made relative to.
fn namedPipeDevice() Error!windows.HANDLE {
    var device: windows.HANDLE = undefined;
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    const name = std.unicode.wtf8ToWtf16LeStringLiteral("\\Device\\NamedPipe\\");
    var object_name = windows.UNICODE_STRING.init(name);
    switch (windows.ntdll.NtOpenFile(
        &device,
        .{ .STANDARD = .{ .SYNCHRONIZE = true } },
        &.{ .ObjectName = &object_name },
        &status_block,
        .VALID_FLAGS,
        .{ .IO = .SYNCHRONOUS_NONALERT },
    )) {
        .SUCCESS => return device,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => |status| return windows.unexpectedStatus(status),
    }
}
