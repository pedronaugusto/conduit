//! What conduit's benchmark rows share: the context a row runs against and the
//! way a table of rows becomes shakedown rows.
//!
//! A row is one of two kinds, and the kind says how its samples are taken.
//!
//! - **Batched**: `run(units)` does `units` of the operation and the runner
//!   grows the batch until it is long enough to read. A hook, if there is one,
//!   builds what all of the batch's units use.
//! - **Sampled**: a sample is one operation of its own, set up and torn down
//!   outside the timed call. The hooks run once per invocation, so the runner
//!   must never grow the batch: a sample too short to read is
//!   `error.SampleTooShort`, not a longer batch.
const std = @import("std");
const conduit = @import("conduit");
const c = std.c;

pub const Context = struct {
    init: std.process.Init,
    input: []const u8,
    path: []const u8,
    cat: []const u8,
    echo: []const u8,
    sleep: []const u8,
    sh: []const u8,
    true_: []const u8,

    /// The child a row's hooks and its run share, and whether it was reaped.
    child: conduit.Child = undefined,
    reaped: bool = false,
    pty: conduit.Pty = undefined,
    /// The descendants of a child that forked, as the tree rows find them.
    descendants: [8]std.posix.pid_t = undefined,
    descendant_count: usize = 0,
    /// What `readAvailable` reads, and how much of it arrived.
    pipe: std.Io.File = undefined,
    drained: usize = 0,
    /// A conversation with a terminal child, and the buffer it keeps.
    conversation: conduit.Expect = undefined,
    conversation_buffer: [4096]u8 = undefined,
    /// The reaper whose stop the claims time.
    reaper: conduit.Reaper = undefined,
    /// A terminal's two ends, and the child on it.
    master: std.Io.File.Handle = undefined,
    slave: std.Io.File.Handle = undefined,
    pid: std.posix.pid_t = undefined,
    /// What a lookup row found, for the others to agree with.
    found: []u8 = &.{},
    inherited: usize = 0,
    started: u64 = 0,
    /// The signal child's program, and the file it speaks on.
    signal_path: [std.Io.Dir.max_path_bytes]u8 = undefined,
    signal_out: std.posix.fd_t = undefined,
    /// The proxy row's descriptors, drain and threads.
    proxy: Proxy = .{},

    pub const Proxy = struct {
        input: [2]c.fd_t = undefined,
        output: [2]c.fd_t = undefined,
        output_open: bool = false,
        drain: Drain = undefined,
        reader: ?std.Thread = null,
        child: ?conduit.Child = null,
        reaped: bool = false,
        term: ?conduit.Term = null,
        pty: conduit.Pty = undefined,
    };

    /// A terminal in its default (cooked) mode writes each newline as CR LF,
    /// and on macOS now and then one CR more, so the drain counts what is not
    /// a CR: the file's own bytes, which must arrive exactly.
    pub const Drain = struct {
        fd: c.fd_t,
        total: usize = 0,
        returns: usize = 0,
        failed: bool = false,

        pub fn run(drain: *Drain) void {
            var buffer: [64 * 1024]u8 = undefined;
            while (true) {
                const got = c.read(drain.fd, &buffer, buffer.len);
                if (got == 0) return;
                if (got < 0) {
                    if (std.c.errno(got) == .INTR) continue;
                    drain.failed = true;
                    return;
                }
                const bytes = buffer[0..@intCast(got)];
                drain.total += bytes.len;
                drain.returns += std.mem.count(u8, bytes, "\r");
            }
        }
    };

    pub fn io(x: *const Context) std.Io {
        return x.init.io;
    }

    pub fn gpa(x: *const Context) std.mem.Allocator {
        return x.init.gpa;
    }

    /// Starts the fixture's child and marks it not yet reaped.
    pub fn spawn(x: *Context, options: conduit.Child.SpawnOptions) !void {
        x.child = try conduit.Child.spawn(x.gpa(), x.io(), options);
        x.reaped = false;
    }

    /// Waits for the fixture's child to end by itself.
    pub fn wait(x: *Context) !conduit.Term {
        const term = try x.child.wait(x.io());
        x.reaped = true;
        return term;
    }

    /// Ends and releases the fixture's child: killed first, unless a row
    /// reaped it.
    pub fn release(x: *Context) void {
        // glint-ignore: Z026 -- a teardown has no error to return and the measurement was taken before it; the child is released next
        if (!x.reaped) _ = x.child.killWait(x.io(), .zero) catch {};
        x.child.deinit(x.io());
        x.reaped = true;
    }
};
