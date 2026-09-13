# zpty

[![CI](https://github.com/pedronaugusto/zpty/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/zpty/actions/workflows/ci.yml)

Child processes and pseudo-terminals for Zig, on POSIX — spawn a program on a
pty or on pipes, in its own session or process group, with a window size, raw
mode, reaping and killing, on Zig 0.16's `std.Io`.

Pure Zig. No dependencies. One `@import`.

## Why

`std.process.spawn` already starts a child, gives it pipes, and waits for it.
What it cannot do is the part that makes a child believe it is talking to a
terminal:

- There is no pseudo-terminal in the standard library at all — no
  `posix_openpt`, no window-size ioctl, no raw mode.
- There is no hook between `fork` and `execve`, which is the only place
  `setsid` and `TIOCSCTTY` can be called. Without them a child handed the slave
  end of a pty passes `isatty` and can read the window size, but has no
  controlling terminal: no foreground process group, so nothing typed at the
  master ever becomes a signal. Ctrl-C does nothing. That is the difference
  between a descriptor that is a terminal and a program that is *running on*
  one, and it is the reason this package forks itself instead of wrapping
  `std.process.spawn`.

There is also what a correct `fork` child has to do before `execve` and what
nothing in the standard library does for you: the child starts with an empty
signal mask and every signal at its default action. `execve` resets neither a
blocked signal nor an ignored one, so a program started from a shell's
background job inherits an ignored `SIGINT` — and is then deaf to the Ctrl-C on
its own terminal no matter how correctly the pty is wired. That was a real bug
found by a test in this repository, and the test is still there.

Everything that the standard library does do is left to it. `Child.wait` hands
the process id to `std.process.Child.wait`, so it is a cancelation point and
uses whatever the `std.Io` implementation has for the job — `WAITID` through
io_uring where that is what is running.

## Usage

The block below is not written here: it is a region of
[`examples/usage.zig`](examples/usage.zig), which `zig build examples` builds
and RUNS, extracted by `ci/readme_usage.sh` and compared by CI. A snippet in a
README is a claim about how the library is used, and this one is a claim
something executes.

<!-- BEGIN GENERATED ci/readme_usage.sh -->
```zig
const zpty = @import("zpty");

// A pseudo-terminal pair, 24 rows by 80 columns.
var pty = try zpty.Pty.open(.{ .rows = 24, .cols = 80 });
defer pty.close(io);

// A child on it, in its own session, with the pair as its controlling
// terminal. `stty size` reports what the terminal says, which is proof the
// child is talking to one.
var child = try zpty.Child.spawn(io, gpa, .{
    .argv = &.{ "/bin/sh", "-c", "stty size; echo 'is this a terminal? '$(test -t 0 && echo yes || echo no)" },
    .stdio = .{ .pty = &pty },
    .detach = true,
});
defer child.deinit(io);

// The parent's copy of the slave end has to go, or reading the master will
// never report end of file.
pty.closeSlave(io);

// Everything the child wrote to its terminal, read from the master end.
var buffer: [1024]u8 = undefined;
var reader = pty.masterFile().readerStreaming(io, &buffer);
const output = reader.interface.allocRemaining(gpa, .unlimited) catch |err| switch (err) {
    // A pseudo-terminal whose child is gone reports this on some systems
    // where a pipe reports end of file.
    error.ReadFailed => try gpa.dupe(u8, reader.interface.buffered()),
    else => |e| return e,
};
defer gpa.free(output);

// And how it ended: `SIGTERM` after a two-second grace if it is still
// running, which this one is not.
const term = try child.killWait(io, 2000);
```
<!-- END GENERATED ci/readme_usage.sh -->

It prints:

```
the child said:
  24 80
  is this a terminal? yes
and ended: .{ .exited = 0 }
```

## Install

```sh
zig fetch --save git+https://github.com/pedronaugusto/zpty
```

```zig
const zpty = b.dependency("zpty", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("zpty", zpty.module("zpty"));
```

The module links libc: the POSIX pseudo-terminal interface is a libc interface
on every supported system, and Darwin has no stable system-call ABI to reach
past it. `src/zpty.zig` refuses to compile without libc rather than failing at
link time.

## The API

### `Pty` — a pseudo-terminal pair

| | |
|---|---|
| `Pty.open(options)` | A new pair at a given geometry. `options`: `rows`, `cols`, `x_pixel`, `y_pixel`. |
| `pty.master`, `pty.slave` | The two descriptors, as `std.posix.fd_t`. `Pty.closed` once closed. |
| `pty.masterFile()`, `pty.slaveFile()` | Either end as a `std.Io.File`, sharing the descriptor rather than duplicating it. |
| `pty.resize(size)`, `pty.size()` | The window size, from the master end. `resize` is safe to call while another task reads or writes. |
| `pty.close(io)` | Both ends. Idempotent, and correct after either of the next two. |
| `pty.closeSlave(io)`, `pty.closeMaster(io)` | One end. A parent that has spawned a child **must** `closeSlave`, or reading the master never reports end of file. |

### `Child` — a child process

| | |
|---|---|
| `Child.spawn(io, allocator, options)` | Fork and execute. The allocator is used for the call only; nothing is retained. |
| `child.pid`, `child.pgid` | The process id, and the process group when `detach` asked for one. |
| `child.stdin`, `child.stdout`, `child.stderr` | `std.Io.File`s for the pipes `spawn` created, owned by the `Child`. |
| `child.pty` | The master end, for a child spawned on a pair. Borrowed from the `Pty`. |
| `child.wait(io)` | Blocks; delegates to `std.process.Child.wait`. |
| `child.tryWait()` | Never blocks. `null` while the child runs. |
| `child.kill(signal)` | The process group of a detached child, the process id otherwise. |
| `child.killWait(io, grace_ms)` | `SIGTERM`, the grace, `SIGKILL`, a reap. |
| `child.deinit(io)` | Closes the pipes the `Child` owns, and nothing the caller supplied. |

`SpawnOptions`: `argv`, `cwd`, `environ` (a `*const std.process.Environ.Map`),
`stdio`, `detach`, `stderr_to`.

`stdio` is one of `.{ .pty = &pty }`, `.{ .pipes = .{ .stdin, .stdout, .stderr } }`,
`.inherit` or `.ignore`.

`detach` puts the child out of reach of signals aimed at the parent's process
group. With `.pty` it means `setsid` plus `TIOCSCTTY`, so the pair becomes the
child's controlling terminal; otherwise it means `setpgid(0, 0)`.

`Term` is `std.process.Child.Term`, not a parallel type of this package's own.

### `Reaper` — a wait on a background task

`Reaper.init(&child)`, then `start(io)`, then `exit()` for `?Term` without
blocking, then `deinit(io)`. Its lifetime rules are in the doc comment and are
worth reading: the `Child` must outlive it, it must not move once started, and
`deinit` must run.

### `Proxy` — a byte pump

`Proxy.run(io, .{ .master, .input, .output, .input_buffer, .output_buffer })`
moves bytes both ways until the child's end of the terminal closes.

### Terminal helpers

`rawMode(fd)`, `restore(fd, saved)`, `winSize(fd)`, `setWinSize(fd, size)`,
`isTty(fd)`, `ttyName(fd, buffer)`. They take a descriptor, not a `std.Io.File`,
because a terminal ioctl is not one of the operations `std.Io` abstracts.

## What this package does not do

- **Windows.** There is no ConPTY implementation, and `src/zpty.zig` is a
  compile error on Windows rather than a silently degraded build. The module
  doc comment carries the seam: what `CreatePseudoConsole` and
  `ResizePseudoConsole` map onto, why `detach` would mean only half as much
  there, and the one declaration whose shape would have to change — `Pty` holds
  a single descriptor for the master, and ConPTY's master is two handles.
- **Signal handling in your process.** No handler is installed, ever, and no
  disposition in the calling process is touched. A library that installed a
  `SIGWINCH` or `SIGCHLD` handler would be taking process-wide state from the
  program that owns it. (The fork child is a different matter: it gets a clean
  slate before `execve`, as above.) Forwarding a window size is three lines in
  your own handler: `pty.resize(try zpty.winSize(stdin))`.
- **Terminal emulation.** Nothing here parses escape sequences or keeps a
  screen. `Proxy` moves bytes; what they mean is someone else's job.
- **`SIGPIPE`.** Writing to a pipe whose reader is gone raises it, and this
  package does not change its disposition. That is the program's decision.
- **Thread safety.** One task at a time per `Child` or `Pty`, except
  `Pty.resize`, which is a single ioctl, and `Reaper`, which exists precisely so
  a wait can be in flight while another task works.

## Building

```sh
zig build test      # the suite, and the examples, which are run
zig build examples  # the examples alone
zig fmt --check src examples build.zig
```

Zig 0.16.0. Every test spawns a real child process and reaps it; the suite runs
in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall in CI, because the code
between `fork` and `execve` is the kind an inlining decision can change.

## License

MIT. See [LICENSE](LICENSE).
