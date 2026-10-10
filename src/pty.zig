//! A pseudo-terminal pair: a master end a program reads and writes, and a
//! terminal end that behaves like a terminal to whatever is connected to it.
//!
//! # One shape, two systems
//!
//! The master is *two handles*, because on Windows it genuinely is two. POSIX
//! gives one bidirectional descriptor for the master; ConPTY gives a
//! pseudoconsole object plus a pair of pipes, one carrying what the program
//! types in and one carrying what the child draws. So `read` and `write` are
//! separate fields on both platforms — the same handle twice on POSIX, the two
//! ends of two different pipes on Windows — and no caller has to know which it
//! is holding.
//!
//! The terminal end is `slave`: a file descriptor on POSIX, an `HPCON` on
//! Windows. It is not a stream on Windows, which is why `slaveFile` is POSIX
//! only.
//!
//! On POSIX the pair is opened through the POSIX 98 interface
//! (`posix_openpt`, `grantpt`, `unlockpt`, `ptsname_r`), which is available on
//! Linux, the BSDs and Darwin. On Windows it is `CreatePseudoConsole`, which
//! needs Windows 10 version 1809 or newer.
//!
//! Over an `Io` that carries conduit's simulated route (`conduit.testing`),
//! `open` makes the pair in the simulation instead: a master and a terminal
//! end, one handle each, which a child spawned on it gets as its streams.
//!
//! Every end is owned by the `Pty` until `close`, `closeSlave` or
//! `closeMaster` is called; see the ownership note on `Child.spawn` for which
//! end a parent should keep, and `closeSlave` for the one place the two
//! systems ask for different timing.

const builtin = @import("builtin");
const std = @import("std");
const spin = @import("spin.zig");
const posix = std.posix;
const c = std.c;
const windows = std.os.windows;
const trace = @import("trace.zig");
const handles = @import("handles.zig");
const tty = @import("conduit.tty");

const is_windows = builtin.target.os.tag == .windows;
const win32 = @import("win32.zig");
const seam = @import("seam");

const Size = tty.Size;
const file = handles.file;

pub const Pty = struct {
    /// Private: the master's reading handle, or null once closed.
    read: ?std.Io.File.Handle,
    /// Private: the master's writing handle, or null once closed.
    write: ?std.Io.File.Handle,
    /// Private: the terminal end, or null once closed.
    slave: ?Pty.Slave,
    /// Private: on Windows, the console's size, shared with its resize.
    geometry: if (is_windows) ?*Pty.Geometry else void,
    /// Private: on Windows, how the pseudo console was made.
    console: if (is_windows) Pty.ConsoleOptions else void,
    /// Private: a simulated pair's terminal end, a stream on every system,
    /// where `slave` is null; null once closed.
    simulated_slave: ?Handle = null,
    /// Private: whether the pair is a simulation's.
    simulated: bool = false,

    /// Borrows the reading handle, or null after the master closes.
    pub fn readHandle(pty: Pty) ?Handle {
        return pty.read;
    }
    /// Borrows the writing handle, or null after the master closes.
    pub fn writeHandle(pty: Pty) ?Handle {
        return pty.write;
    }
    /// Borrows the terminal end, or null after it closes.
    pub fn slaveHandle(pty: Pty) ?Slave {
        return pty.slave;
    }
    /// The console options granted on Windows; empty on POSIX.
    pub fn consoleOptions(pty: Pty) ConsoleOptions {
        return if (is_windows) pty.console else .{};
    }

    /// A stream handle. `std.posix.fd_t` on POSIX, `HANDLE` on Windows.
    pub const Handle = std.Io.File.Handle;

    /// The terminal end of a pair.
    ///
    /// POSIX: the slave file descriptor, which a child gets as its standard
    /// input, output and error. Windows: the pseudoconsole, which a child is
    /// attached to rather than handed.
    pub const Slave = if (is_windows) win32.Hpcon else posix.fd_t;

    /// The master end as two `std.Io.File`s.
    pub const Master = struct {
        /// What the child wrote to its terminal.
        read: std.Io.File,
        /// What the child will see as typed at its terminal.
        write: std.Io.File,
    };

    /// The initial terminal geometry of a new pair, and what the console on the
    /// far side of it is asked to do.
    ///
    /// The defaults are the historical terminal size, which is what a program
    /// assumes when nothing tells it otherwise. Pixel dimensions default to zero,
    /// which terminals read as "not reported" and Windows ignores entirely.
    pub const OpenOptions = struct {
        rows: u16 = 24,
        cols: u16 = 80,
        x_pixel: u16 = 0,
        y_pixel: u16 = 0,
        /// Windows only. `Pty.consoleOptions()` says which of these the system granted.
        console: ConsoleOptions = .{},

        fn size(options: OpenOptions) Size {
            return .{
                .rows = options.rows,
                .cols = options.cols,
                .x_pixel = options.x_pixel,
                .y_pixel = options.y_pixel,
            };
        }
    };

    /// What a Windows pseudoconsole is asked to do with what passes through it.
    ///
    /// All three are off by default, which is the behaviour every version of
    /// ConPTY has had: the console host interprets what the child writes and
    /// redraws it, and what reaches the master is that redraw rather than the
    /// child's own bytes.
    ///
    /// Each arrived in a different Windows, and a version that does not know one
    /// refuses the whole call rather than ignoring the flag. So `open` asks again
    /// without it, and `Pty.consoleOptions()` is what it ended up with — an option asked
    /// for and not granted is a fact about the machine, not an error.
    ///
    /// POSIX has none of this: a pseudo-terminal pair is a pipe with a line
    /// discipline on it, and nothing between the two ends is rewriting anything.
    /// These fields are read only on Windows.
    pub const ConsoleOptions = struct {
        /// `PSEUDOCONSOLE_WIN32_INPUT_MODE`. What is written to the master is read
        /// as Windows input records rather than as a terminal's character stream,
        /// which is the only way to express a key the terminal encoding has no
        /// sequence for — a modified arrow, a key released, Ctrl with a digit.
        win32_input: bool = false,
        /// `PSEUDOCONSOLE_PASSTHROUGH_MODE`. The child's output reaches the master
        /// as the child wrote it, instead of as the console host's redraw of it.
        /// Without this a sequence the host does not model is lost — the cursor
        /// shape, `DECSCUSR`, is the one people notice.
        ///
        /// Windows 11 22H2 and newer. Older systems refuse it and `open` asks
        /// again without it.
        passthrough: bool = false,
        /// `PSEUDOCONSOLE_RESIZE_QUIRK`. A resize does not reflow what the child
        /// has already written, which is what a program that keeps its own screen
        /// wants: it is going to repaint anyway, and a reflow it did not ask for
        /// arrives as a screenful of bytes it has to discard.
        resize_quirk: bool = false,
    };

    pub const OpenError = error{
        /// The per-process handle limit was reached.
        ProcessFdQuotaExceeded,
        /// The system-wide handle limit was reached.
        SystemFdQuotaExceeded,
        /// POSIX: no pseudo-terminal is available.
        NoDevice,
        /// POSIX: the slave device could not be opened with the current
        /// credentials.
        PermissionDenied,
        /// The system could not spare the memory for the pair. On Windows this is
        /// also what an operating system too old for `CreatePseudoConsole` to
        /// succeed reports, since the call itself is resolved at load time.
        SystemResources,
    } || tty.UnexpectedError || std.mem.Allocator.Error;

    /// Opens a new pseudo-terminal pair with the given geometry.
    ///
    /// On success the caller owns every end and must eventually call `close`, or
    /// `closeSlave` and `closeMaster` separately. On failure nothing is leaked.
    /// Windows geometry uses `gpa` until every end closes; it must outlive
    /// the pair. POSIX uses no allocation.
    ///
    /// On POSIX both ends are close-on-exec, so a pair held open while some
    /// unrelated child is spawned is not handed to it. `Child.spawn` puts the
    /// slave on the child's standard streams with `dup2`, which clears the flag on
    /// the copies, so the child it *is* for still gets its terminal.
    pub fn open(gpa: std.mem.Allocator, io: std.Io, options: OpenOptions) OpenError!Pty {
        if (seam.routeOf(io)) |route| return openSimulated(route, options);
        if (is_windows) return openWindows(gpa, options);
        return openPosix(options);
    }

    /// A pair the route makes: the master one handle, read and written, and
    /// the terminal end one stream.
    fn openSimulated(route: *const seam.Route, options: OpenOptions) OpenError!Pty {
        const t = route.terminal(.{ .rows = options.rows, .cols = options.cols }) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.SystemResources => error.SystemResources,
        };
        return .{
            .read = t.master.handle,
            .write = t.master.handle,
            .slave = null,
            .geometry = if (is_windows) null else {},
            .console = if (is_windows) options.console else {},
            .simulated_slave = t.slave.handle,
            .simulated = true,
        };
    }

    /// The terminal end a child spawned on a simulated pair is given.
    pub fn simulatedSlave(pty: Pty) ?std.Io.File {
        return if (pty.simulated_slave) |h| file(h) else null;
    }

    pub const ResizeError = error{
        /// POSIX: the master is not a terminal, which cannot happen for a `Pty`
        /// this package opened.
        NotATerminal,
    } || tty.UnexpectedError;

    /// Changes the geometry of the pair.
    ///
    /// On POSIX both ends see the new size and the kernel sends `SIGWINCH` to the
    /// terminal's foreground process group. A child that was spawned without a
    /// controlling terminal has no foreground process group here and will not be
    /// signalled, though it still reads the new size if it asks.
    ///
    /// On Windows the pseudoconsole is resized and the attached client learns
    /// through the console API it already uses; there is no signal to miss. The
    /// console host repaints its viewport into the output pipe as part of it, so
    /// **a program that has stopped reading the master can block here**: a resize
    /// is not a small write, and a pipe nobody drains fills up.
    ///
    /// Safe to call from another task while the master is being read or written.
    /// That is what makes window-size forwarding possible at all — see `Proxy`.
    pub fn resize(pty: *Pty, io: std.Io, new_size: tty.Size) ResizeError!void {
        if (pty.simulated) {
            const route = seam.routeOf(io) orelse return error.Unexpected;
            const read = pty.read orelse return error.Unexpected;
            return route.setWindowSize(file(read), .{ .rows = new_size.rows, .cols = new_size.cols }) catch |err| switch (err) {
                error.NotTerminalDevice => error.NotATerminal,
                error.BadHandle => error.Unexpected,
            };
        }
        if (is_windows) {
            const geometry = pty.geometryState() orelse return error.Unexpected;
            geometry.lock();
            defer geometry.mutex.unlock();
            const slave = pty.slave orelse return error.Unexpected;
            if (win32.ResizePseudoConsole(slave, new_size.toCoord()) != win32.ok) {
                return error.Unexpected;
            }
            geometry.size = new_size;
            return;
        }
        const read = pty.read orelse return error.Unexpected;
        return tty.setWinSize(read, new_size);
    }

    pub const SizeError = ResizeError;

    /// Reads the geometry of the pair.
    ///
    /// On POSIX this asks the kernel, so it reflects a resize done by anyone. On
    /// Windows a pseudoconsole cannot be asked, so this answers with what `open`
    /// or `resize` last set. Safe to read while resize is in flight; the OS
    /// change and cached geometry are serialized together on Windows.
    pub fn size(pty: *const Pty, io: std.Io) SizeError!tty.Size {
        if (pty.simulated) {
            const route = seam.routeOf(io) orelse return error.Unexpected;
            const read = pty.read orelse return error.Unexpected;
            const got = route.windowSize(file(read)) catch |err| return switch (err) {
                error.NotTerminalDevice => error.NotATerminal,
                error.BadHandle => error.Unexpected,
            };
            return .{ .rows = got.rows, .cols = got.cols };
        }
        if (is_windows) {
            const geometry = pty.geometryState() orelse return error.Unexpected;
            geometry.lock();
            defer geometry.mutex.unlock();
            return geometry.size;
        }
        const read = pty.read orelse return error.Unexpected;
        return tty.winSize(read);
    }

    /// Both master ends as `std.Io.File`s.
    ///
    /// The files share the handles rather than duplicating them: closing one
    /// closes that end of the pair, and so does `close`. Pick one.
    ///
    /// Asserts the master is still open.
    pub fn master(pty: Pty) Master {
        return .{ .read = pty.readFile(), .write = pty.writeFile() };
    }

    /// The end to read, as a `std.Io.File`. Asserts it is still open.
    pub fn readFile(pty: Pty) std.Io.File {
        return file(pty.read.?);
    }

    /// The end to write, as a `std.Io.File`. Asserts it is still open.
    pub fn writeFile(pty: Pty) std.Io.File {
        return file(pty.write.?);
    }

    /// The terminal end as a `std.Io.File`. POSIX only, and asserts it is still
    /// open.
    ///
    /// The same sharing rule as `master` applies. A parent that has spawned a
    /// child on this pair rarely wants this file; it wants `closeSlave`.
    ///
    /// Calling this on Windows is a compile error: a
    /// pseudoconsole is an object a process is attached to, not a stream anything
    /// reads or writes.
    pub fn slaveFile(pty: Pty) std.Io.File {
        if (is_windows) @compileError("Pty.slaveFile is POSIX-only: a pseudoconsole is not a stream");
        if (pty.simulated) return file(pty.simulated_slave.?);
        return slaveFilePosix(pty);
    }

    fn slaveFilePosix(pty: Pty) std.Io.File {
        return file(pty.slave.?);
    }

    /// Closes whichever ends are still open.
    ///
    /// Idempotent, and correct after `closeSlave` or `closeMaster`: a closed end
    /// is `null` and is not closed twice.
    ///
    /// The terminal end goes first on both systems, which is the order that lets a
    /// reader of the master see the stream finish.
    ///
    /// On Windows that order needs something the caller should not have to supply.
    /// `ClosePseudoConsole` does not return until the console host has gone, and
    /// the host does not go until it has flushed what the client last wrote into a
    /// pipe this process holds the reading end of — so if nothing is reading, the
    /// host waits on a write that cannot complete and this call waits on the host.
    /// It has no deadline of its own; a run of this package's own suite met it
    /// about one time in two.
    ///
    /// So `close` reads the master itself: a drain that throws away what it gets,
    /// started before the console is closed and joined after, which the host's own
    /// exit ends by closing its end of the pipe.
    ///
    /// A reader of the caller's is stopped and joined before this, not left
    /// running across it: see `closeMaster`. A caller that wants the last of the
    /// output reads until it has it — on POSIX, `closeSlave` first and read to the
    /// end — and then stops its reader and calls this.
    pub fn close(pty: *Pty, io: std.Io) void {
        if (is_windows and !pty.simulated) return pty.closeWindows(io);
        pty.closeSlave(io);
        pty.closeMaster(io);
    }

    fn closeWindows(pty: *Pty, io: std.Io) void {
        const read_handle = pty.read;
        if (pty.slave == null or read_handle == null) {
            // Nothing to drain, or nothing to drain it with.
            pty.closeMaster(io);
            pty.closeSlave(io);
            return;
        }

        var drain: std.Io.Group = .init;
        drain.concurrent(io, drainMaster, .{ io, read_handle.? }) catch {
            // No task to be had. Dropping the master ends first is then the only
            // way the host's last write can fail rather than wait, and a `std.Io`
            // with no concurrency to offer would have nowhere to put a reader
            // either.
            trace.print("pty: no task to drain with; closing the master first", .{});
            pty.closeMaster(io);
            pty.closeSlave(io);
            return;
        };
        trace.print("pty: draining the master across the close", .{});
        pty.closeSlave(io);
        // The host has gone, so its end of the pipe is closed and the drain has
        // finished; this joins it.
        drain.cancel(io);
        trace.print("pty: drain joined", .{});
        pty.closeMaster(io);
    }

    /// Reads the master and throws it away, so the console host has somewhere to
    /// put what it flushes on its way out.
    fn drainMaster(io: std.Io, handle: Handle) std.Io.Cancelable!void {
        const f = file(handle);
        var buffer: [4096]u8 = undefined;
        while (true) {
            _ = handles.readStreaming(io, f, &.{&buffer}) catch return;
        }
    }

    /// Closes the terminal end only.
    ///
    /// **The two platforms want this at different moments, and it is the one place
    /// in this package where that is true.**
    ///
    /// On POSIX a parent that has spawned a child on this pair should call this as
    /// soon as the child exists. While any descriptor for the slave remains open
    /// in the parent, a read of the master blocks instead of reporting end of file
    /// when the child exits, because the terminal still has a reader.
    ///
    /// On Windows the pseudoconsole is not a descriptor the child inherited a copy
    /// of — it is the console, and `ClosePseudoConsole` ends the client attached
    /// to it. So this is called when the program is finished with the child, not
    /// straight after spawning it.
    ///
    /// **On Windows, reap the child first and keep reading the master.** The call
    /// does not return until the client attached to the pseudoconsole has gone and
    /// the console host has flushed what it last wrote, and the host flushes into
    /// a pipe this process holds the reading end of. So a program that has stopped
    /// reading waits for a write that cannot complete, and a program whose child
    /// is still running waits for the child. `close` supplies the reading itself
    /// and is the call to prefer; the child is the caller's, and `Child.killWait`
    /// is how it is done.
    pub fn closeSlave(pty: *Pty, io: std.Io) void {
        defer if (is_windows) pty.releaseGeometry();
        if (pty.simulated_slave) |handle| {
            file(handle).close(io);
            pty.simulated_slave = null;
        }
        const slave = pty.slave orelse return;
        pty.slave = null;
        if (is_windows) {
            if (trace.enabled()) {
                trace.print("pty: ClosePseudoConsole(0x{x})", .{@intFromPtr(slave)}); // safe: printed, never dereferenced
            }
            win32.ClosePseudoConsole(slave);
            trace.print("pty: ClosePseudoConsole returned", .{});
            return;
        }
        file(slave).close(io);
    }

    /// Closes both master ends.
    ///
    /// **On POSIX this hangs the terminal up.** Dropping the last master descriptor
    /// is the pseudo-terminal spelling of a modem dropping the line: the kernel
    /// sends `SIGHUP` to the session leader of the terminal's session, which for a
    /// child spawned with `detach` and `.pty` is the child itself. Its default
    /// action ends the process, so a child that does not handle the signal is gone
    /// shortly after this returns -- and a child that does handle it sees a read of
    /// its terminal report end of file, and a write fail with `EIO`. A child
    /// spawned without `detach` has no controlling terminal here and so is not
    /// signalled; it only meets the closed stream.
    ///
    /// On Windows the child's console loses the pipes behind it; the client learns
    /// when it next reads or writes.
    ///
    /// **Stop a task that is reading the master before calling this.** Closing a
    /// descriptor another thread is reading is a race: the number is free as soon
    /// as the close returns, the next file this process opens can take it, and a
    /// read the task starts after that reads the other file. ThreadSanitizer
    /// reports it as a race on the descriptor. Cancel the task and join it, or let
    /// its read end and join it — on POSIX a read of the master ends once
    /// `closeSlave` has been called and every process on the terminal is gone —
    /// and close afterwards. On Windows `close` reads the master itself while the
    /// console host goes, so no reader of the caller's has to stay for it.
    pub fn closeMaster(pty: *Pty, io: std.Io) void {
        defer if (is_windows) pty.releaseGeometry();
        trace.print("pty: closing the master ends", .{});
        defer trace.print("pty: master ends closed", .{});
        // The same handle twice on POSIX, so it is closed once.
        const same = pty.read != null and pty.write != null and pty.read.? == pty.write.?;
        if (pty.read) |handle| {
            file(handle).close(io);
            pty.read = null;
        }
        if (pty.write) |handle| {
            if (!same) file(handle).close(io);
            pty.write = null;
        }
    }

    /// One owner for the Windows resize operation and the size it accepted.
    ///
    /// Not an `aegis.Guarded`: the lock is held across `ResizePseudoConsole`, an
    /// operating-system call that can block while the output pipe is undrained,
    /// and a guard's sections are bounded. `resize` and `size` take no `std.Io`
    /// to wait with, so a blocking guard would be a public change of its own
    /// (an OS boundary).
    const Geometry = struct {
        mutex: std.atomic.Mutex = .unlocked,
        size: Size,
        gpa: std.mem.Allocator,

        fn lock(geometry: *Geometry) void {
            spin.lock(&geometry.mutex);
        }
    };

    fn geometryState(pty: *const Pty) ?*Geometry {
        return pty.geometry;
    }

    fn releaseGeometry(pty: *Pty) void {
        if (pty.slave != null or pty.read != null or pty.write != null) return;
        const geometry = pty.geometryState() orelse return;
        pty.geometry = null;
        geometry.gpa.destroy(geometry);
    }

    //======================================================================
    // POSIX.
    //======================================================================

    fn openPosix(options: OpenOptions) OpenError!Pty {
        const master_fd = try openMaster();
        // Raw closes: `open` has no `std.Io` to hand, because nothing it does is
        // an operation `std.Io` abstracts.
        errdefer _ = c.close(master_fd);

        // `grantpt` fixes the ownership and mode of the slave device and
        // `unlockpt` clears the lock that keeps it unopenable until then. Both are
        // required before the slave path may be opened, and both are no-ops on
        // systems that do not need them.
        if (grantpt(master_fd) != 0) return openErrno();
        if (unlockpt(master_fd) != 0) return openErrno();

        var name_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const name = switch (slaveName(master_fd, &name_buffer)) {
            .name => |name| name,
            .failed => |err| return openError(err),
        };

        // NOCTTY: opening the slave here must not make it this process's
        // controlling terminal. The child asks for that explicitly, after `setsid`.
        const slave_fd = c.open(name, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true });
        if (slave_fd < 0) return openErrno();
        errdefer _ = c.close(slave_fd);

        // The descriptor is a pseudo-terminal master, opened two calls ago, so the
        // only failure this can report is one no caller could tell apart from the
        // open itself failing.
        tty.setWinSize(master_fd, options.size()) catch return error.Unexpected;

        return .{
            .read = master_fd,
            .write = master_fd,
            .slave = slave_fd,
            .geometry = {},
            .console = {},
        };
    }

    /// Opens the master end, close-on-exec from the moment it exists.
    ///
    /// Close-on-exec, and not as an afterthought: a master this process is
    /// holding while it spawns some unrelated child would otherwise be inherited
    /// by that child, which would then be keeping the terminal open -- so a read
    /// of the master never finishes even after the child that was meant to have
    /// it exits. POSIX names only `O_RDWR` and `O_NOCTTY` for `posix_openpt`, but
    /// glibc, musl, Darwin and FreeBSD all take `O_CLOEXEC` as well, which makes
    /// the flag part of the open: no window in which a `fork` on another thread
    /// copies a master without it, and one system call fewer. A system that
    /// refuses the flag says `EINVAL`, and there the flag is a second call, held
    /// inside `ForkGap` where this system has one, with the window between the
    /// two that `ForkGap` documents. The slave has no such window anywhere:
    /// `open` takes the flag.
    fn openMaster() OpenError!posix.fd_t {
        const fd = posix_openpt(.{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true });
        if (fd >= 0) return fd;
        if (c.errno(@as(c_int, -1)) != .INVAL) return openErrno();

        return tty.ForkGap.hold(openMasterMarked, .{});
    }

    fn openMasterMarked() OpenError!posix.fd_t {
        const plain_fd = posix_openpt(.{ .ACCMODE = .RDWR, .NOCTTY = true });
        if (plain_fd < 0) return openErrno();
        handles.setCloseOnExec(plain_fd);
        return plain_fd;
    }

    /// The slave's path, or why there is none.
    const SlaveName = union(enum) { name: [:0]const u8, failed: posix.E };

    fn slaveName(master_fd: posix.fd_t, buffer: []u8) SlaveName {
        // `ptsname_r` does not agree with itself across libcs: glibc and musl
        // return the error number, and musl leaves `errno` as it was; Darwin
        // returns -1 and sets `errno`.
        const rc = ptsname_r(master_fd, buffer.ptr, buffer.len);
        if (rc > 0) return .{ .failed = @fromBackingInt(@intCast(rc)) };
        if (rc < 0) return .{ .failed = c.errno(rc) };
        const len = std.mem.findScalar(u8, buffer, 0) orelse return .{ .failed = .NAMETOOLONG };
        return .{ .name = buffer[0..len :0] };
    }

    /// The current `errno`, as one of `OpenError`. Everything else `openPosix`
    /// calls reports failure there.
    fn openErrno() OpenError {
        return openError(c.errno(@as(c_int, -1)));
    }

    fn openError(number: posix.E) OpenError {
        return switch (number) {
            .MFILE => error.ProcessFdQuotaExceeded,
            .NFILE => error.SystemFdQuotaExceeded,
            .AGAIN, .NOSPC, .NXIO => error.NoDevice,
            .ACCES, .PERM => error.PermissionDenied,
            .NOMEM => error.SystemResources,
            else => |err| posix.unexpectedErrno(err),
        };
    }

    // These four are the POSIX 98 pseudo-terminal interface. None of them is
    // declared in `std.c`.
    extern "c" fn posix_openpt(oflag: c.O) posix.fd_t;
    extern "c" fn grantpt(fd: posix.fd_t) c_int;
    extern "c" fn unlockpt(fd: posix.fd_t) c_int;
    extern "c" fn ptsname_r(fd: posix.fd_t, buf: [*]u8, buflen: usize) c_int;

    //======================================================================
    // Windows.
    //======================================================================

    /// How much the console host may get ahead of a program reading the master.
    ///
    /// A hint, not a limit: the system rounds it and a write larger than it still
    /// succeeds in pieces. The default is a few kilobytes, which is less than one
    /// repaint of a large window — and a console host blocked on a full pipe
    /// blocks `ResizePseudoConsole` and `ClosePseudoConsole` with it. This is
    /// enough for a repaint of a window far larger than anyone runs.
    const pipe_bytes: windows.DWORD = 256 * 1024;

    fn openWindows(gpa: std.mem.Allocator, options: OpenOptions) OpenError!Pty {
        const remembered = try gpa.create(Geometry);
        errdefer gpa.destroy(remembered);
        remembered.* = .{ .size = options.size(), .gpa = gpa };
        // Two pipes. Each has an end for the console and an end for this program,
        // and neither end is inheritable -- `null` security attributes is what
        // says so -- which is the Windows counterpart of the close-on-exec the
        // POSIX side sets on both ends: a pair held open while some unrelated
        // child is started is not handed to it. The console duplicates what it is
        // given, and a child reaches the console through the attribute list rather
        // than through an inherited handle.
        var input_read: windows.HANDLE = undefined;
        var input_write: windows.HANDLE = undefined;
        if (win32.CreatePipe(&input_read, &input_write, null, pipe_bytes) == .FALSE) return lastError();
        errdefer windows.CloseHandle(input_write);
        errdefer windows.CloseHandle(input_read);

        var output_read: windows.HANDLE = undefined;
        var output_write: windows.HANDLE = undefined;
        if (win32.CreatePipe(&output_read, &output_write, null, pipe_bytes) == .FALSE) return lastError();
        errdefer windows.CloseHandle(output_write);
        errdefer windows.CloseHandle(output_read);

        const geometry = options.size();
        var console: win32.Hpcon = undefined;
        // Each of the three console options arrived in a different Windows, and a
        // version that does not know one refuses the whole call with
        // `E_INVALIDARG` rather than ignoring the flag. So the ask is narrowed
        // until it is one this system will take: passthrough first, which is the
        // newest of them, then the other two. Asking for nothing always works --
        // that is what every version of this package before this one asked for.
        var granted = options.console;
        while (true) {
            switch (win32.CreatePseudoConsole(
                geometry.toCoord(),
                input_read,
                output_write,
                consoleFlags(granted),
                &console,
            )) {
                win32.ok => break,
                // `E_INVALIDARG`: one of the flags. Which one is not said, so they
                // go one at a time, newest first.
                @as(win32.Hresult, @bitCast(@as(u32, 0x80070057))) => {
                    if (granted.passthrough) {
                        granted.passthrough = false;
                    } else if (granted.win32_input) {
                        granted.win32_input = false;
                    } else if (granted.resize_quirk) {
                        granted.resize_quirk = false;
                    } else return error.Unexpected;
                    trace.print("pty: CreatePseudoConsole refused a console option; asking again", .{});
                },
                // `HRESULT_FROM_WIN32(ERROR_NOT_ENOUGH_MEMORY)`. Every other
                // failure here is a bug in this package's arguments rather than a
                // condition a caller can do anything about.
                @as(win32.Hresult, @bitCast(@as(u32, 0x8007000E))) => return error.SystemResources,
                else => return error.Unexpected,
            }
        }

        if (trace.enabled()) {
            trace.print("pty: CreatePseudoConsole gave hpcon=0x{x}, {d}x{d}, flags=0x{x}", .{
                @intFromPtr(console), // safe: printed, never dereferenced
                geometry.rows,
                geometry.cols,
                consoleFlags(granted),
            });
        }

        // The console duplicated both of its ends, so this program's copies of
        // them are now only a way to keep the pipes from ever reporting end of
        // file.
        windows.CloseHandle(input_read);
        windows.CloseHandle(output_write);

        return .{
            .read = output_read,
            .write = input_write,
            .slave = console,
            .geometry = remembered,
            .console = granted,
        };
    }

    fn consoleFlags(options: ConsoleOptions) windows.DWORD {
        var flags: windows.DWORD = 0;
        if (options.resize_quirk) flags |= win32.pseudoconsole_resize_quirk;
        if (options.win32_input) flags |= win32.pseudoconsole_win32_input_mode;
        if (options.passthrough) flags |= win32.pseudoconsole_passthrough_mode;
        return flags;
    }

    fn lastError() OpenError {
        return switch (windows.GetLastError()) {
            .TOO_MANY_OPEN_FILES => error.ProcessFdQuotaExceeded,
            .NOT_ENOUGH_MEMORY, .OUTOFMEMORY => error.SystemResources,
            .ACCESS_DENIED => error.PermissionDenied,
            else => |err| win32.unexpected(err),
        };
    }

    //======================================================================
    // Tests.
    //======================================================================

    const testing = std.testing;

    test "a slave name that does not fit says so, wherever the C library put the error" {
        if (is_windows) return error.SkipZigTest;
        const master_fd = try openMaster();
        defer _ = c.close(master_fd);
        // Nothing left over in `errno` to be mistaken for the answer.
        c._errno().* = 0;
        // Shorter than any slave's path: `/dev/pts/0`, `/dev/ttys000`.
        var small: [4]u8 = undefined;
        switch (slaveName(master_fd, &small)) {
            .name => return error.TestNameFitWhereItCannot,
            .failed => |err| try testing.expectEqual(posix.E.RANGE, err),
        }
    }

    test "open gives a pair at the requested size, and resize changes it" {
        const io = testing.io;

        var pty = try Pty.open(std.testing.allocator, std.testing.io, .{ .rows = 30, .cols = 100 });
        defer pty.close(io);
        // Registered after the close, so it runs before it: the reader is stopped
        // before the file it reads is closed (see `closeMaster`), and `close`
        // reads the master itself on Windows while the console host goes.
        var drain: Drain = .{};
        defer drain.deinit(io);
        try drain.start(io, pty.readFile());

        const opened = try pty.size(std.testing.io);
        try testing.expectEqual(@as(u16, 30), opened.rows);
        try testing.expectEqual(@as(u16, 100), opened.cols);

        try pty.resize(std.testing.io, .{ .rows = 41, .cols = 121 });
        const resized = try pty.size(std.testing.io);
        try testing.expectEqual(@as(u16, 41), resized.rows);
        try testing.expectEqual(@as(u16, 121), resized.cols);
    }

    test "close is idempotent and correct after closing one end" {
        const io = testing.io;

        var pty = try Pty.open(std.testing.allocator, std.testing.io, .{});
        // The master ends go first here, which is what makes the terminal end safe
        // to close on Windows with nothing reading: see `close`.
        pty.closeMaster(io);
        pty.closeSlave(io);
        try testing.expectEqual(@as(?Slave, null), pty.slave);
        pty.close(io);
        try testing.expectEqual(@as(?Handle, null), pty.read);
        try testing.expectEqual(@as(?Handle, null), pty.write);
        pty.close(io);
    }

    test "both ends of a POSIX pair are the same terminal" {
        if (is_windows) return error.SkipZigTest;
        const io = testing.io;
        var pty = try Pty.open(std.testing.allocator, std.testing.io, .{ .rows = 30, .cols = 100 });
        defer pty.close(io);

        try testing.expect(tty.isTty(pty.read.?));
        try testing.expect(tty.isTty(pty.slave.?));
        // The size belongs to the terminal, so the slave reports the same one.
        try testing.expectEqual(try pty.size(std.testing.io), try tty.winSize(pty.slave.?));

        try pty.resize(std.testing.io, .{ .rows = 40, .cols = 132, .x_pixel = 1320, .y_pixel = 800 });
        try testing.expectEqual(Size{
            .rows = 40,
            .cols = 132,
            .x_pixel = 1320,
            .y_pixel = 800,
        }, try tty.winSize(pty.slave.?));
    }

    test "a pair opened with a pixel size reports it at both ends" {
        if (is_windows) return error.SkipZigTest;
        const io = testing.io;
        // What a terminal embedding a program passes through: the cells it gave
        // the program, and those cells in pixels, so a program that sizes
        // pictures by the cell does not have to guess.
        var pty = try Pty.open(std.testing.allocator, std.testing.io, .{ .rows = 38, .cols = 118, .x_pixel = 1062, .y_pixel = 760 });
        defer pty.close(io);
        const want: Size = .{ .rows = 38, .cols = 118, .x_pixel = 1062, .y_pixel = 760 };
        try testing.expectEqual(want, try pty.size(std.testing.io));
        try testing.expectEqual(want, try tty.winSize(pty.slave.?));
    }

    test "the terminal end of a POSIX pair has a name under /dev" {
        if (is_windows) return error.SkipZigTest;
        const io = testing.io;
        var pty = try Pty.open(std.testing.allocator, std.testing.io, .{});
        defer pty.close(io);

        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const name = try tty.ttyName(pty.slave.?, &buffer);
        try testing.expect(std.mem.startsWith(u8, name, "/dev/"));
    }

    test "raw mode round-trips on the terminal end of a POSIX pair" {
        if (is_windows) return error.SkipZigTest;
        const io = testing.io;
        var pty = try Pty.open(std.testing.allocator, std.testing.io, .{});
        defer pty.close(io);

        // `rawMode` answers what the attributes were when it was called, so
        // calling it again, and restoring what that answered, reads them.
        const saved = try tty.rawMode(pty.slave.?);
        const before = saved.termios;
        try testing.expect(before.lflag.ECHO);

        const again = try tty.rawMode(pty.slave.?);
        const during = again.termios;
        try testing.expect(!during.lflag.ECHO);
        try testing.expect(!during.lflag.ICANON);
        try testing.expect(!during.oflag.OPOST);

        try tty.restore(pty.slave.?, saved);
        const restored = try tty.rawMode(pty.slave.?);
        try tty.restore(pty.slave.?, restored);
        var after = restored.termios;
        // A BSD kernel marks input for retyping whenever canonical mode comes
        // back without a flush that waits on the output, which `restore` never
        // does; the mark clears on the next read and is not part of the mode
        // that was saved.
        if (@hasField(@TypeOf(after.lflag), "PENDIN")) after.lflag.PENDIN = before.lflag.PENDIN;
        try testing.expectEqual(before.lflag, after.lflag);
        try testing.expectEqual(before.iflag, after.iflag);
        try testing.expectEqual(before.oflag, after.oflag);
    }

    test "both ends of a POSIX pair are close-on-exec" {
        // The claim is about what an unrelated child does *not* inherit. A pair
        // held open while some other program is started must not reach it: a
        // grandchild holding the slave keeps the terminal open, and a read of the
        // master then never finishes even after the child it was opened for has
        // gone.
        if (is_windows) return error.SkipZigTest;
        const io = testing.io;
        var pty = try Pty.open(std.testing.allocator, std.testing.io, .{});
        defer pty.close(io);

        const cloexec: c_int = c.FD_CLOEXEC;
        try testing.expectEqual(cloexec, c.fcntl(pty.read.?, c.F.GETFD, @as(c_int, 0)) & cloexec);
        try testing.expectEqual(cloexec, c.fcntl(pty.slave.?, c.F.GETFD, @as(c_int, 0)) & cloexec);
    }

    test "a pseudoconsole is opened with the console options this system will take" {
        // Windows only: POSIX has no such switches, and `ConsoleOptions` is not
        // read there.
        if (!is_windows) return error.SkipZigTest;
        const io = testing.io;

        // All three asked for. `passthrough` needs Windows 11 22H2 and the others
        // are older, so what comes back depends on the machine — but it is always
        // a subset of the ask, and the open never fails for want of a flag.
        var pty = try Pty.open(std.testing.allocator, std.testing.io, .{
            .rows = 24,
            .cols = 80,
            .console = .{ .win32_input = true, .passthrough = true, .resize_quirk = true },
        });
        defer pty.close(io);

        try testing.expect(pty.slave != null);

        // And a pair that still works: the size it was given is the size it says.
        try testing.expectEqual(@as(u16, 24), (try pty.size(std.testing.io)).rows);
    }

    test "a pair asked for no console options gets none" {
        if (!is_windows) return error.SkipZigTest;
        const io = testing.io;
        var pty = try Pty.open(std.testing.allocator, std.testing.io, .{ .rows = 24, .cols = 80 });
        defer pty.close(io);
        try testing.expectEqual(ConsoleOptions{}, pty.console);
    }

    test "restoring a terminal nobody reads does not wait for its output" {
        // Output written to the terminal end with nothing reading the other,
        // more than the pair holds: a restore that waited for it to drain, as
        // TCSAFLUSH does, would never return.
        if (is_windows) return error.SkipZigTest;
        const io = testing.io;
        var pty = try Pty.open(std.testing.allocator, std.testing.io, .{});
        defer pty.close(io);
        const saved = try tty.rawMode(pty.slave.?);
        // Not blocking, so filling the pair cannot hang the test either.
        const flags = posix.system.fcntl(pty.slave.?, posix.F.GETFL, @as(usize, 0));
        try testing.expect(flags >= 0);
        const nonblock: u32 = @bitCast(posix.O{ .NONBLOCK = true });
        try testing.expectEqual(@as(@TypeOf(flags), 0), posix.system.fcntl(pty.slave.?, posix.F.SETFL, @as(usize, @intCast(flags)) | nonblock));
        const chunk: [4096]u8 = @splat('x');
        var written: usize = 0;
        while (written < 1 << 20) {
            const rc = posix.system.write(pty.slave.?, &chunk, chunk.len);
            if (posix.errno(rc) != .SUCCESS) break;
            written += @intCast(rc);
        }
        try testing.expect(written > 0);
        try tty.restore(pty.slave.?, saved);
    }

    test "size borrows the pair instead of copying its mutable Windows geometry" {
        const receiver = @typeInfo(@TypeOf(Pty.size)).@"fn".param_types[0].?;
        try testing.expect(receiver == *const Pty);
    }

    test "Windows size and stream borrows stay coherent while another task resizes" {
        if (!is_windows) return error.SkipZigTest;
        const io = testing.io;
        const a: Size = .{ .rows = 24, .cols = 80, .x_pixel = 640, .y_pixel = 480 };
        const b: Size = .{ .rows = 30, .cols = 100, .x_pixel = 1000, .y_pixel = 600 };
        var pty = try Pty.open(std.testing.allocator, std.testing.io, .{ .rows = a.rows, .cols = a.cols, .x_pixel = a.x_pixel, .y_pixel = a.y_pixel });
        defer pty.close(io);
        var drain: Drain = .{};
        try drain.start(io, pty.readFile());
        defer drain.deinit(io);
        const Resize = struct {
            fn run(pair: *Pty, first: Size, second: Size) !void {
                for (0..64) |_| {
                    try pair.resize(std.testing.io, second);
                    try pair.resize(std.testing.io, first);
                }
            }
        };
        var resizing = try std.Io.concurrent(io, Resize.run, .{ &pty, a, b });
        // glint-ignore: Z026 -- this runs for a test that has already failed; the passing path awaits the task and takes its error
        defer resizing.cancel(io) catch {};
        for (0..1024) |_| {
            const borrowed = pty.master();
            try testing.expectEqual(pty.read.?, borrowed.read.handle);
            const got = try pty.size(std.testing.io);
            try testing.expect(std.meta.eql(got, a) or std.meta.eql(got, b));
            try std.Io.sleep(io, .fromNanoseconds(1), .awake);
        }
        try resizing.await(io);
        try testing.expectEqual(a, try pty.size(std.testing.io));
    }

    test "open uses the caller allocator until every end closes" {
        var failing: testing.FailingAllocator = .init(testing.allocator, .{});
        var pty = try Pty.open(failing.allocator(), std.testing.io, .{});
        defer pty.close(testing.io);
        try testing.expectEqual(@as(usize, if (is_windows) 1 else 0), failing.allocations);
        pty.closeSlave(testing.io);
        try testing.expectEqual(@as(usize, 0), failing.deallocations);
        pty.closeMaster(testing.io);
        try testing.expectEqual(failing.allocations, failing.deallocations);
        pty.close(testing.io);
        try testing.expectEqual(failing.allocations, failing.deallocations);
    }

    test "open reports caller allocation refusal before opening a Windows pair" {
        if (!is_windows) return error.SkipZigTest;
        var failing: testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
        try testing.expectError(error.OutOfMemory, Pty.open(failing.allocator(), std.testing.io, .{}));
    }
};

/// Test-only placement of an already duplicated POSIX master.
pub fn placeMasterForTest(pty: *Pty, descriptor: posix.fd_t) void {
    if (!builtin.is_test) @compileError("test-only descriptor placement");
    const state = pty;
    _ = c.close(state.read.?);
    state.read = descriptor;
    state.write = descriptor;
}

/// Reads the master and throws it away, on a task of its own.
///
/// A pseudoconsole's host writes into a pipe this process holds the other end
/// of, and a resize is a repaint. With nobody reading, a large enough one
/// fills the pipe and the host stops there — taking `ResizePseudoConsole` and
/// `ClosePseudoConsole` with it. A program that resizes a pair it is not
/// reading is making a mistake; a test that does it hangs, so this is here.
const Drain = struct {
    group: std.Io.Group = .init,

    fn start(drain: *Drain, io: std.Io, f: std.Io.File) !void {
        try drain.group.concurrent(io, run, .{ io, f });
    }

    fn deinit(drain: *Drain, io: std.Io) void {
        drain.group.cancel(io);
        drain.* = undefined;
    }

    fn run(io: std.Io, f: std.Io.File) std.Io.Cancelable!void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            _ = handles.readStreaming(io, f, &.{&buffer}) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => return,
            };
        }
    }
};
