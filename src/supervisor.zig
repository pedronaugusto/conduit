//! A private Linux adoption owner. Runs only raw system calls after fork,
//! owns one root and its adoptees, and exits only when that scope is empty.
//! The caller waits for this process but receives the root's exact wait status.
const std = @import("std");
const aegis = @import("aegis");
const c = std.c;
const posix = std.posix;
const linux = std.os.linux;
const Child = @import("child/contract.zig");
const builtin = @import("builtin");

pub const testing_hook = struct {
    pub var fail_request = false;
};

pub const Supervisor = struct {
    channel: posix.fd_t,
    record: Child.SupervisorRecord,

    /// Any signal Linux has fits the low seven bits: it numbers them below 65.
    pub fn request(self: Supervisor, sig: posix.SIG, cgroup_signalled: bool) Child.KillError!void {
        if (builtin.is_test and testing_hook.fail_request) return error.Unexpected;
        const byte: u8 = @as(u8, @intCast(@backingInt(sig))) | (if (cgroup_signalled) @as(u8, 128) else 0);
        while (true) {
            const rc = linux.sendto(self.channel, std.mem.asBytes(&byte).ptr, 1, linux.MSG.NOSIGNAL | linux.MSG.DONTWAIT, null, 0);
            switch (linux.errno(rc)) {
                .SUCCESS, .PIPE, .CONNRESET => return,
                .INTR => continue,
                else => return error.Unexpected,
            }
        }
    }

    pub fn result(self: Supervisor) Child.TryWaitError!u32 {
        var result_record: Result = undefined;
        const bytes = std.mem.asBytes(&result_record);
        var filled: usize = 0;
        while (filled < bytes.len) {
            const n = c.read(self.channel, bytes[filled..].ptr, bytes.len - filled);
            if (n < 0 and c.errno(@as(c_int, -1)) == .INTR) continue;
            if (n <= 0) return error.Unexpected;
            filled += @intCast(n);
        }
        if (result_record.failed != 0) return error.Unexpected;
        return result_record.status;
    }

    pub fn close(self: Supervisor) void {
        _ = c.close(self.channel);
    }
};

/// What the supervisor writes on its channel once its scope is empty.
pub const Result = extern struct { status: u32, failed: u32 };

pub fn channel() Child.SpawnError![2]posix.fd_t {
    var ends: [2]posix.fd_t = undefined;
    const rc = linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &ends);
    return switch (linux.errno(rc)) {
        .SUCCESS => ends,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        .NOMEM, .NOBUFS => error.SystemResources,
        else => error.Unexpected,
    };
}

/// Before the root is forked. The attribute belongs to this private process,
/// never to the calling application, and the root does not inherit it.
pub const Prepared = struct { signals: posix.fd_t, children: posix.fd_t };

pub const Preparation = union(enum) { ready: Prepared, failed: posix.E };

pub fn prepare() Preparation {
    // Leave the application's signal group before starting anything it owns.
    const session_error = linux.errno(linux.setsid());
    if (session_error != .SUCCESS) return .{ .failed = session_error };
    // Every catchable asynchronous stop is consumed through signalfd. Keep
    // harmless notifications at their default disposition; KILL and STOP
    // cannot be caught. This mask is installed before resetting handlers.
    var mask = linux.sigfillset();
    inline for (.{ linux.SIG.KILL, linux.SIG.STOP, linux.SIG.CONT, linux.SIG.WINCH, linux.SIG.URG }) |sig| linux.sigdelset(&mask, sig);
    const mask_error = linux.errno(linux.sigprocmask(linux.SIG.SETMASK, &mask, null));
    if (mask_error != .SUCCESS) return .{ .failed = mask_error };
    // A supervisor never execs: inherited handlers must be reset here too.
    var number: u32 = 1;
    while (number < linux.NSIG) : (number += 1) {
        const sig: posix.SIG = @fromBackingInt(@intCast(number));
        if (sig == .KILL or sig == .STOP) continue;
        const action: posix.Sigaction = .{ .handler = .{ .handler = posix.SIG.DFL }, .mask = posix.sigemptyset(), .flags = 0 };
        _ = c.sigaction(sig, &action, null);
    }
    const attribute_error = linux.errno(linux.prctl(@backingInt(linux.PR.SET_CHILD_SUBREAPER), 1, 0, 0, 0));
    if (attribute_error != .SUCCESS) return .{ .failed = attribute_error };
    const signals = linux.signalfd(-1, &mask, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK);
    if (linux.errno(signals) != .SUCCESS) return .{ .failed = linux.errno(signals) };
    const children = c.open("/proc/thread-self/children", .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    if (children < 0) return .{ .failed = c.errno(@as(c_int, -1)) };
    return .{ .ready = .{ .signals = @intCast(signals), .children = children } };
}

/// Retain only this scope's channels. No caller stream or unrelated child
/// channel stays open here. All descriptors are reserved before the root runs.
pub fn isolate(commands: posix.fd_t, prepared: Prepared, scope_kill: ?posix.fd_t) void {
    var storage = [_]posix.fd_t{ commands, prepared.signals, prepared.children, scope_kill orelse -1 };
    const kept = storage[0..if (scope_kill != null) @as(usize, 4) else 3];
    std.mem.sort(posix.fd_t, kept, {}, std.sort.asc(posix.fd_t));
    var first: posix.fd_t = 0;
    var closed = true;
    for (kept) |fd| {
        if (fd > first) if (linux.errno(linux.close_range(first, fd - 1, .{ .UNSHARE = false, .CLOEXEC = false })) != .SUCCESS) {
            closed = false;
        };
        first = fd + 1;
    }
    if (linux.errno(linux.close_range(first, std.math.maxInt(i32), .{ .UNSHARE = false, .CLOEXEC = false })) != .SUCCESS) closed = false;
    if (closed) return;
    var limit: posix.rlimit = undefined;
    const ceiling: posix.fd_t = if (c.getrlimit(.NOFILE, &limit) == 0) std.math.lossyCast(posix.fd_t, limit.cur) else 4096;
    var fd: posix.fd_t = 0;
    while (fd < ceiling) : (fd += 1) if (fd != commands and fd != prepared.signals and fd != prepared.children and fd != (scope_kill orelse -1)) {
        _ = c.close(fd);
    };
}

pub fn run(root: posix.pid_t, commands: posix.fd_t, detached: bool, prepared: Prepared, scope_kill: ?posix.fd_t) noreturn {
    isolate(commands, prepared, scope_kill);
    var ending = false;
    var root_ended = false;
    var failed = false;
    var empty_looks: u8 = 0;
    while (true) {
        var command: ?posix.SIG = null;
        var cgroup_signalled = false;
        var pollfds = [_]linux.pollfd{
            .{ .fd = commands, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = prepared.signals, .events = linux.POLL.IN, .revents = 0 },
        };
        const ready = linux.poll(&pollfds, pollfds.len, if (ending) 5 else -1);
        if (pollfds[1].revents & linux.POLL.IN != 0) {
            var notices: [8]linux.signalfd_siginfo = undefined;
            const n = c.read(prepared.signals, std.mem.asBytes(&notices).ptr, @sizeOf(@TypeOf(notices)));
            if (n > 0) for (notices[0 .. @as(usize, @intCast(n)) / @sizeOf(linux.signalfd_siginfo)]) |notice| {
                if (notice.signo != @backingInt(posix.SIG.CHLD)) ending = true;
            };
        }
        if (linux.errno(ready) == .SUCCESS and pollfds[0].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            var byte: u8 = 0;
            const n = c.read(commands, std.mem.asBytes(&byte).ptr, 1);
            if (n == 0) ending = true else if (n == 1) {
                command = @fromBackingInt(@intCast(byte & 127));
                cgroup_signalled = byte & 128 != 0;
                if (command.? == .KILL) ending = true;
            }
        }
        var info = std.mem.zeroes(linux.siginfo_t);
        const rc = linux.waitid(.PID, root, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null);
        if (linux.errno(rc) == .SUCCESS) {
            if (info.fields.common.first.piduid.pid == root) {
                root_ended = true;
                ending = true;
            }
        } else if (linux.errno(rc) != .INTR) {
            failed = true;
            ending = true;
        }
        // The unreaped root reserves both its pid and group through the last
        // signal. Only this process reaps it, after every adoptee has gone.
        if (!root_ended) if (if (ending) @as(?posix.SIG, .KILL) else command) |sig| {
            if (c.kill(if (detached) -root else root, sig) < 0 and c.errno(@as(c_int, -1)) != .SRCH) failed = true;
        };
        if (ending) if (scope_kill) |fd| {
            _ = c.write(fd, "1", 1);
        };
        const adopted_signal = if (ending) @as(?posix.SIG, .KILL) else if (cgroup_signalled) null else command;
        const left = visitChildren(prepared.children, root, adopted_signal, if (detached and !root_ended and !ending) root else null) catch {
            failed = true;
            ending = true;
            continue;
        };
        if (root_ended and left == 0) {
            empty_looks += 1;
            if (empty_looks == 2) break;
        } else empty_looks = 0;
    }
    var status: c_int = 0;
    while (c.waitpid(root, &status, 0) < 0) {
        if (c.errno(@as(c_int, -1)) == .INTR) continue;
        failed = true;
        break;
    }
    const answer: Result = .{ .status = @bitCast(status), .failed = @intFromBool(failed) };
    _ = linux.sendto(commands, std.mem.asBytes(&answer).ptr, @sizeOf(Result), linux.MSG.NOSIGNAL, null, 0);
    c._exit(0);
}

/// This supervisor has exactly one thread and one reap owner. A listed direct
/// child keeps its identity until this pass reaps it; no pid can be recycled
/// between the signal and wait. Streaming parsing places no limit on tree size.
fn visitChildren(fd: posix.fd_t, root: posix.pid_t, signal: ?posix.SIG, signalled_group: ?posix.pid_t) error{Unexpected}!usize {
    if (c.lseek(fd, 0, c.SEEK.SET) < 0) return error.Unexpected;
    var buffer: [4096]u8 = undefined;
    var number: posix.pid_t = 0;
    var left: usize = 0;
    while (true) {
        const n = c.read(fd, &buffer, buffer.len);
        if (n < 0) {
            if (c.errno(@as(c_int, -1)) == .INTR) continue;
            return error.Unexpected;
        }
        if (n == 0) break;
        for (buffer[0..@intCast(n)]) |byte| {
            if (byte >= '0' and byte <= '9') {
                const scaled = aegis.int.Checked(posix.pid_t).init(number).mul(10) catch return error.Unexpected;
                number = (scaled.add(byte - '0') catch return error.Unexpected).raw();
            } else if (number != 0) {
                if (number != root) left += try visit(number, signal, signalled_group);
                number = 0;
            }
        }
    }
    if (number != 0 and number != root) left += try visit(number, signal, signalled_group);
    return left;
}

extern "c" fn getpgid(pid: posix.pid_t) posix.pid_t;

fn visit(pid: posix.pid_t, signal: ?posix.SIG, signalled_group: ?posix.pid_t) error{Unexpected}!usize {
    const already_signalled = if (signalled_group) |group| getpgid(pid) == group else false;
    if (signal) |sig| if (!already_signalled and c.kill(pid, sig) < 0 and c.errno(@as(c_int, -1)) != .SRCH) return error.Unexpected;
    var status: c_int = 0;
    while (true) {
        const rc = c.waitpid(pid, &status, c.W.NOHANG);
        if (rc == 0) return 1;
        if (rc > 0) return 0;
        switch (c.errno(rc)) {
            .INTR => continue,
            .CHILD => return 0,
            else => return error.Unexpected,
        }
    }
}
