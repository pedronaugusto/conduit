//! A conversation with a child: wait for what it says, then say something
//! back.
//!
//! `Proxy` moves bytes and `Child.output` collects them. Neither is a
//! conversation, which is the thing a program driving another program
//! actually does: wait for the prompt, answer it, wait for the next one.
//! `until` waits for a byte pattern to appear on the master, `untilAny` for
//! any of several, `bytes` for a count of them, and `send` writes the reply.
//! Every wait takes a deadline, because a program waiting for a line the child
//! will never print should fail rather than stop.
//!
//! # The buffer is the caller's
//!
//! Nothing here allocates. `init` takes a buffer, and that buffer is where
//! everything the child says is kept until a match accounts for it. A match
//! hands back two slices *into* that buffer — what arrived before the pattern
//! and the pattern itself — and they stay readable until the next call on the
//! same `Expect`.
//!
//! A buffer that fills with bytes no pattern has matched is
//! `error.BufferFull`. Nothing is dropped behind the caller's back: the
//! reading stops, the child's own terminal fills up instead, and the caller
//! decides — a larger buffer, or `discard` to say the pending bytes do not
//! matter.
//!
//! # Patterns are bytes
//!
//! A pattern is a byte string, matched literally. Zig's standard library has
//! no regular-expression engine, and a pattern language shipped inside a
//! process package would be a second, worse one.
//!
//! # The reading runs on a task
//!
//! A child writes when it wants to, not when the parent asks. So the reading
//! begins at `start` and continues between calls: the prompt a child printed
//! while the parent was busy elsewhere is already in the buffer when the
//! parent comes back for it, and a deadline stays a deadline instead of
//! becoming a blocked read nobody can interrupt. No signal handler and no
//! thread of this package's own is involved; the task is an `std.Io.Group`
//! task and the `std.Io` implementation decides what it runs on.
//!
//! That task holds a pointer to the `Expect`, which makes the lifetime rules
//! the same ones `Reaper` has:
//!
//! * the files in `master` must outlive the `Expect`;
//! * an `Expect` must not be copied or moved once `start` has been called,
//!   which safe builds assert on each call;
//! * `deinit` must run before it goes out of scope, including on the path
//!   where the child never says anything.

const builtin = @import("builtin");
const std = @import("std");
const Pin = @import("pin.zig").Pin;
const Deadline = @import("conduit.tty").Deadline;

const Pty = @import("pty.zig").Pty;
const handles = @import("handles.zig");

const is_windows = builtin.target.os.tag == .windows;

pub const Expect = struct {
    // Fields are private: read and change them only through the methods.
    /// What the child says, and where a reply goes.
    ///
    /// `Child.pty` is already this shape, and `Child.expect` builds one for a
    /// child on pipes out of its standard output and standard input. Borrowed:
    /// `deinit` closes neither file.
    master: Pty.Master,
    /// Where what the child says is kept. The caller's, and borrowed: nothing
    /// here frees it, and it must outlive the `Expect`.
    buffer: []u8,
    /// How much of `buffer` has arrived.
    filled: usize,
    /// How much of `buffer[0..filled]` a match has already accounted for.
    ///
    /// Those bytes are not dropped when the match is returned but at the start of
    /// the next call, which is what keeps the slices in a `Match` readable after
    /// the call that produced them.
    consumed: usize,
    /// The reading task reached the end of the stream.
    ended: bool,
    /// The reading task could not read, for a reason other than the end.
    failed: bool,
    /// The reading task has stopped, for any reason, cancellation included.
    /// Atomic and not under `mutex`, so it can be read without taking anything
    /// the task holds.
    finished: std.atomic.Value(bool),
    /// Guards the four fields above: the reading task appends to them, and the
    /// caller's task consumes from them.
    mutex: std.Io.Mutex,
    /// Set by the reading task whenever one of those fields changes, so a wait
    /// ends the moment the child speaks rather than at the end of a poll
    /// interval.
    arrived: std.Io.Event,
    /// Set when consuming or discarding bytes makes buffer space available.
    space: std.Io.Event,
    /// The task doing the reading.
    group: std.Io.Group,
    /// One claim for initialization, task ownership and stopping. Stop ends
    /// even a lifetime whose task has never been started.
    lifetime: std.atomic.Value(enum(u8) { ready, started, stopped }),
    /// Safe builds: where this was when `start` began to hold a pointer to it.
    pin: Pin = .{},

    /// Where a pattern was found, in the bytes that had arrived when it was.
    ///
    /// Both slices point into the caller's buffer and are valid until the next
    /// call on the same `Expect`.
    pub const Match = struct {
        /// Which pattern this was: an index into what `untilAny` was given, and
        /// always zero from `until`, which is given one.
        index: usize,
        /// Everything that arrived before the pattern, in the order it arrived.
        /// Empty when the pattern was the next thing the child said.
        before: []const u8,
        /// The pattern, as it was found. The same bytes that were asked for; it
        /// is here so that `before.ptr + before.len` needs no arithmetic and a
        /// caller keeping the whole exchange can print the two together.
        found: []const u8,
    };

    /// An `Expect` that is not reading yet. `start` puts the reading task in
    /// flight.
    ///
    /// The buffer should be at least as large as the longest pattern that will be
    /// waited for plus whatever the child may say before it; a few kilobytes is
    /// generous for a line-oriented conversation.
    pub fn init(master: Pty.Master, buffer: []u8) Expect {
        return .{
            .master = master,
            .buffer = buffer,
            .filled = 0,
            .consumed = 0,
            .ended = false,
            .failed = false,
            .mutex = .init,
            .arrived = .unset,
            .space = .unset,
            .group = .init,
            .lifetime = .init(.ready),
            .finished = .init(false),
        };
    }

    pub const StartError = error{
        /// This `Expect` already has, or had, its one reading task, or was stopped.
        AlreadyStarted,
    } || std.Io.ConcurrentError;

    /// Begins reading.
    ///
    /// The task must be able to run alongside the caller, so an `std.Io`
    /// implementation with no concurrency to offer fails here rather than
    /// deadlocking at the first `until`. Everything the child says from this
    /// moment is kept; anything it said before it is not. An `Expect` has one
    /// reading task for its lifetime; a second successful-start attempt is
    /// `error.AlreadyStarted`, including after `stop`. A failed task submission
    /// may be retried before `stop`.
    pub fn start(expect: *Expect, io: std.Io) StartError!void {
        if (expect.lifetime.cmpxchgStrong(.ready, .started, .acq_rel, .acquire) != null) {
            return error.AlreadyStarted;
        }
        expect.pin.set(expect);
        expect.group.concurrent(io, read, .{ expect, io }) catch |err| {
            _ = expect.lifetime.cmpxchgStrong(.started, .ready, .release, .monotonic);
            return err;
        };
    }

    /// Stops reading and releases the task, and ends the conversation: a
    /// later `start` is `error.AlreadyStarted`, whether or not one ran before.
    ///
    /// Calling it again does nothing, and it is safe after the child has gone.
    /// The buffer is the caller's and is untouched.
    ///
    /// The task is inside a read, and a read ends when the far end finishes, when
    /// the handle goes away, or when the task is cancelled. For a pseudo-terminal
    /// master whose console is still open the first two do not happen, so this
    /// cancels: the `std.Io` implementation interrupts the read and keeps at it
    /// until the task has seen the request (on Windows `std.Io.Threaded` does it
    /// with `NtCancelSynchronousIoFile`, on POSIX with a signal). A reader between
    /// reads observes the stopped lifetime and starts no further read.
    ///
    /// Cancelling is the only request a read here answers. `CancelIoEx` from
    /// another thread does abort the pending read on Windows, but `std.Io.Threaded`
    /// issues it again straight away unless its own task was cancelled, so a
    /// reader asked that way never stops.
    pub fn stop(expect: *Expect, io: std.Io) void {
        expect.pin.check(expect);
        expect.lifetime.store(.stopped, .release);
        expect.group.cancel(io);
    }

    /// Stops reading, as `stop` does, and leaves the `Expect` undefined.
    pub fn deinit(expect: *Expect, io: std.Io) void {
        expect.pin.check(expect);
        expect.stop(io);
        expect.* = undefined;
    }

    pub const WaitError = error{
        /// The deadline passed with the pattern still not there. The bytes that
        /// did arrive are still pending, and `pending` is where to look at them.
        Timeout,
        /// The child's end of the stream closed, or reading was stopped, with
        /// the pattern still not there. Final: nothing more will ever arrive.
        EndOfStream,
        /// The buffer is full of bytes the pattern does not match, or the pattern
        /// — or the count — is longer than the buffer could ever hold. Nothing
        /// was dropped; `discard` is how to make room.
        BufferFull,
        /// The stream could not be read, for a reason other than ending.
        ReadFailed,
    } || std.Io.Cancelable;

    /// Waits for `pattern` to appear in what the child says, and consumes
    /// everything up to and including it.
    ///
    /// The match is literal and the first one wins. Bytes that arrived before it
    /// come back in `Match.before`; bytes that arrived after it stay pending for
    /// the next call, which is what makes a sequence of `until` calls a
    /// conversation rather than a series of races.
    ///
    /// An empty pattern matches at once, before anything has arrived.
    pub fn until(
        expect: *Expect,
        io: std.Io,
        pattern: []const u8,
        timeout: std.Io.Timeout,
    ) WaitError!Match {
        return expect.untilAny(io, &.{pattern}, timeout);
    }

    /// Waits for any of `patterns` to appear, and consumes everything up to and
    /// including the one that did.
    ///
    /// This is the prompt-or-error shape, which one pattern at a time cannot
    /// express: three `until` calls for three possible answers race each other,
    /// and whichever is asked for first eats the bytes the others were looking
    /// for.
    ///
    /// **The earliest match wins**, not the first pattern in the list: whichever
    /// of them appears soonest in what the child has said is the one reported, and
    /// two that match at the same place are settled by their order in `patterns`.
    /// So a caller may list them in whatever order reads best.
    ///
    /// **The others are left where they are.** Only the bytes up to and including
    /// the winner are consumed, so a pattern that had also arrived, later, is
    /// still pending and the next call finds it. That is what makes a sequence of
    /// these a conversation.
    ///
    /// `Match.index` says which one it was. An empty pattern matches at once,
    /// before anything has arrived; a pattern longer than the buffer could ever
    /// hold is `error.BufferFull`, since no wait could satisfy it; and an empty
    /// list matches nothing, so it ends the way a pattern that never comes does.
    pub fn untilAny(
        expect: *Expect,
        io: std.Io,
        patterns: []const []const u8,
        timeout: std.Io.Timeout,
    ) WaitError!Match {
        expect.pin.check(expect);
        expect.compact(io);

        for (patterns, 0..) |pattern, index| {
            if (pattern.len == 0) return .{
                .index = index,
                .before = expect.buffer[0..0],
                .found = expect.buffer[0..0],
            };
            if (pattern.len > expect.buffer.len) return error.BufferFull;
        }

        const deadline = Deadline.of(io, timeout);
        var search: Search = .init(patterns);
        while (true) {
            expect.arrived.reset();
            // Read before the buffer: a reader seen finished here has appended
            // everything it ever will, so a search that fails now fails for good.
            const finished = expect.finished.load(.acquire);

            var winner: ?Match = null;
            var full = false;
            var ended = false;
            var failed = false;
            {
                expect.mutex.lockUncancelable(io);
                defer expect.mutex.unlock(io);

                if (search.find(expect.buffer[0..expect.filled], patterns)) |found| {
                    const pattern = patterns[found.index];
                    winner = .{
                        .index = found.index,
                        .before = expect.buffer[0..found.at],
                        .found = expect.buffer[found.at..][0..pattern.len],
                    };
                    expect.consumed = found.at + pattern.len;
                } else {
                    full = expect.filled == expect.buffer.len;
                    ended = expect.ended;
                    failed = expect.failed;
                }
            }

            if (winner) |match| return match;
            if (failed) return error.ReadFailed;
            if (ended or finished) return error.EndOfStream;
            if (full) return error.BufferFull;
            try expect.sleepUntil(io, deadline);
        }
    }

    /// The search `untilAny` runs again every time more bytes arrive.
    ///
    /// A call asks repeatedly as the child says more, and the bytes it has already
    /// looked at cannot become a match on their own: only the tail a pattern could
    /// still straddle is searched again, and with several patterns that tail is the
    /// longest one's. That is what keeps a wait for a pattern that never comes from
    /// costing the length of everything the child said, squared.
    ///
    /// The bound is exact rather than generous. A match beginning before `from`
    /// would have ended before the previous search's last byte, so that search
    /// would have found it and the call would already have returned.
    const Search = struct {
        /// Where the next search starts.
        from: usize,
        /// The longest pattern, which is how much of the tail a later byte could
        /// still complete.
        longest: usize,

        const Found = struct { index: usize, at: usize };

        fn init(patterns: []const []const u8) Search {
            var longest: usize = 0;
            for (patterns) |pattern| longest = @max(longest, pattern.len);
            return .{ .from = 0, .longest = longest };
        }

        /// The earliest of `patterns` in `said`, or `null`, in which case the next
        /// search starts where a pattern could still straddle what arrives next.
        ///
        /// **The earliest match wins**, whatever order the patterns were listed
        /// in; two that begin at the same byte are settled by that order.
        fn find(search: *Search, said: []const u8, patterns: []const []const u8) ?Found {
            var winner: ?Found = null;
            var earliest: usize = said.len;
            for (patterns, 0..) |pattern, index| {
                const at = std.mem.findPos(u8, said, search.from, pattern) orelse continue;
                if (at >= earliest) continue;
                earliest = at;
                winner = .{ .index = index, .at = at };
            }
            if (winner == null) search.from = said.len -| (search.longest -| 1);
            return winner;
        }
    };

    /// Waits for `count` bytes to arrive, and consumes them.
    ///
    /// The counterpart of `until` for a child whose output has a length rather
    /// than a shape — a fixed-width record, or the body a header just announced.
    /// A count larger than the buffer is `error.BufferFull`, because no wait
    /// could ever satisfy it.
    pub fn bytes(
        expect: *Expect,
        io: std.Io,
        count: usize,
        timeout: std.Io.Timeout,
    ) WaitError![]const u8 {
        expect.pin.check(expect);
        expect.compact(io);
        if (count > expect.buffer.len) return error.BufferFull;

        const deadline = Deadline.of(io, timeout);
        while (true) {
            expect.arrived.reset();
            // As in `untilAny`: before the buffer.
            const finished = expect.finished.load(.acquire);

            var enough = false;
            var ended = false;
            var failed = false;
            {
                expect.mutex.lockUncancelable(io);
                defer expect.mutex.unlock(io);
                enough = expect.filled >= count;
                if (enough) {
                    expect.consumed = count;
                } else {
                    ended = expect.ended;
                    failed = expect.failed;
                }
            }

            if (enough) return expect.buffer[0..count];
            if (failed) return error.ReadFailed;
            if (ended or finished) return error.EndOfStream;
            try expect.sleepUntil(io, deadline);
        }
    }

    pub const SendError = error{
        /// Nothing is reading the other end any more: the child has gone, or
        /// closed its terminal.
        BrokenPipe,
        /// The reply could not be written, for another reason.
        WriteFailed,
    } || std.Io.Cancelable;

    /// Writes `reply` to the child, as if it had been typed at its terminal.
    ///
    /// Whole or not at all, as far as the operating system allows: this returns
    /// once every byte has been handed over. A terminal in its default mode ends
    /// a line on `"\n"`, and the end-of-file the line discipline makes is
    /// `"\x04"`.
    pub fn send(expect: *Expect, io: std.Io, reply: []const u8) SendError!void {
        expect.pin.check(expect);
        handles.writeStreamingAll(io, expect.master.write, reply) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.BrokenPipe => return error.BrokenPipe,
            else => return error.WriteFailed,
        };
    }

    /// What has arrived and no match has accounted for yet.
    ///
    /// A snapshot: more may arrive the moment it returns, and the slice is valid
    /// only until the next call on this `Expect`. This is what to print when a
    /// wait fails — a `Timeout` whose message says what the child said instead is
    /// worth a great deal more than one that does not.
    pub fn pending(expect: *Expect, io: std.Io) []const u8 {
        expect.pin.check(expect);
        expect.mutex.lockUncancelable(io);
        defer expect.mutex.unlock(io);
        return expect.buffer[expect.consumed..expect.filled];
    }

    /// Forgets everything pending, and starts the buffer again from empty.
    ///
    /// The answer to `error.BufferFull` for a caller who does not need what
    /// filled it — a child that paints a screen before it asks a question, say.
    /// Reading resumes at once.
    pub fn discard(expect: *Expect, io: std.Io) void {
        expect.pin.check(expect);
        expect.mutex.lockUncancelable(io);
        defer expect.mutex.unlock(io);
        expect.filled = 0;
        expect.consumed = 0;
        expect.space.set(io);
    }

    //======================================================================
    // The reading task.
    //======================================================================

    /// Reads the master into the caller's buffer until the stream ends, the read
    /// fails, or the task is cancelled.
    fn read(expect: *Expect, io: std.Io) std.Io.Cancelable!void {
        defer expect.markFinished(io);
        var chunk: [512]u8 = undefined;
        while (true) {
            if (expect.lifetime.load(.acquire) == .stopped) return expect.finish(io, .ended);
            // Reset before checking the buffer under the consumer mutex. A
            // consumer before this check leaves room; one after it sets space.
            expect.space.reset();
            const room = room: {
                expect.mutex.lockUncancelable(io);
                defer expect.mutex.unlock(io);
                break :room expect.buffer.len - expect.filled;
            };
            if (room == 0) {
                // Full means backpressure until the consumer makes room.
                try expect.space.wait(io);
                continue;
            }

            const n = handles.readStreaming(io, expect.master.read, &.{chunk[0..@min(room, chunk.len)]}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return expect.finish(io, if (handles.finished(err)) .ended else .failed),
            };
            {
                expect.mutex.lockUncancelable(io);
                defer expect.mutex.unlock(io);
                // Only this reader grows `filled`, and the room it saw can
                // only have grown since: a consumer frees space, never takes it.
                std.debug.assert(n <= expect.buffer.len - expect.filled);
                @memcpy(expect.buffer[expect.filled..][0..n], chunk[0..n]);
                expect.filled += n;
            }
            expect.arrived.set(io);
        }
    }

    /// Records why an ordinary read end stopped. The task defer publishes that it
    /// has finished, including when cancellation bypasses this function.
    fn finish(expect: *Expect, io: std.Io, why: enum { ended, failed }) void {
        {
            expect.mutex.lockUncancelable(io);
            defer expect.mutex.unlock(io);
            switch (why) {
                .ended => expect.ended = true,
                .failed => expect.failed = true,
            }
        }
        expect.arrived.set(io);
    }

    /// Published on every exit from the reading task. Stored outside the mutex so
    /// it can be observed without taking anything the task might hold.
    fn markFinished(expect: *Expect, io: std.Io) void {
        expect.finished.store(true, .release);
        expect.arrived.set(io);
    }

    //======================================================================
    // Waiting, and the buffer.
    //======================================================================

    /// Waits for the reading task to say something has changed, or for the
    /// deadline.
    fn sleepUntil(expect: *Expect, io: std.Io, deadline: Deadline) WaitError!void {
        expect.arrived.waitTimeout(io, deadline.toTimeout()) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            // A wakeup is allowed to be spurious and to report itself as a
            // timeout, so the clock decides whether there is time left rather
            // than the return value.
            error.Timeout => {
                if (deadline.remainingMs(io) == 0) return error.Timeout;
            },
        };
    }

    /// Drops the bytes a previous match accounted for, moving what is left to the
    /// front of the buffer.
    ///
    /// Called at the start of a wait rather than at the end of the one before it,
    /// which is what keeps a `Match`'s slices readable until the caller asks for
    /// something else.
    fn compact(expect: *Expect, io: std.Io) void {
        expect.mutex.lockUncancelable(io);
        defer expect.mutex.unlock(io);
        if (expect.consumed == 0) return;
        std.debug.assert(expect.consumed <= expect.filled);
        std.debug.assert(expect.filled <= expect.buffer.len);
        const rest = expect.filled - expect.consumed;
        @memmove(expect.buffer[0..rest], expect.buffer[expect.consumed..expect.filled]);
        expect.filled = rest;
        expect.consumed = 0;
        expect.space.set(io);
    }

    //======================================================================
    // Tests.
    //======================================================================

};

pub const test_access = if (builtin.is_test) struct {
    pub const Search = Expect.Search;
    pub const Found = Expect.Search.Found;
    pub const searchInit = Expect.Search.init;
    pub const searchFind = Expect.Search.find;
    pub const read = Expect.read;
    pub fn compact(io: std.Io, value: anytype) void {
        Expect.compact(if (@TypeOf(value) == *Expect) value else value.*, io);
    }
} else struct {};
