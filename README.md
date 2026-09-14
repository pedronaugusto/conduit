# conduit

[![CI](https://github.com/pedronaugusto/conduit/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/conduit/actions/workflows/ci.yml)

Child processes and pseudo-terminals for Zig — spawn a program on a pty or on
pipes, in its own session or process group, with a window size, raw mode,
reaping, killing and run-and-collect, on Zig 0.16's `std.Io`.

POSIX and Windows, behind one API. Pure Zig. No dependencies. One `@import`.

## Why

`std.process.spawn` already starts a child, gives it pipes, and waits for it.
What it cannot do is the part that makes a child believe it is talking to a
terminal:

- There is no pseudo-terminal in the standard library at all — no
  `posix_openpt`, no `CreatePseudoConsole`, no window-size call, no raw mode.
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
the process on to `std.process.Child.wait`, so it is a cancelation point and
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
const conduit = @import("conduit");

// The user's shell on a new pseudo-terminal, 24 rows by 80 columns, with
// `TERM` set and — on POSIX — the pair as its controlling terminal, so a
// Ctrl-C written to the master would arrive as `SIGINT`.
var shell = try conduit.spawnShell(io, gpa, .{
    .size = .{ .rows = 24, .cols = 80 },
    .args = shell_arguments,
});
defer shell.deinit(io);

// Everything it writes to its terminal, and how it ends, with a bound on
// the whole thing. A terminal is one stream, so a child on a pair has no
// separate standard error to collect.
var result = try shell.child.output(io, gpa, .{ .timeout_ms = 5000, .drain_ms = 250 });
defer result.deinit(gpa);
```
<!-- END GENERATED ci/readme_usage.sh -->

On POSIX, with `shell_arguments` asking the shell for `stty size` and
`test -t 0`, it prints:

```
the child said:
  24 80
  is this a terminal? yes
and ended: .{ .exited = 0 }
```

## Install

```sh
zig fetch --save git+https://github.com/pedronaugusto/conduit
```

```zig
const conduit = b.dependency("conduit", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("conduit", conduit.module("conduit"));
```

The module links libc on POSIX and not on Windows, and decides that itself from
the target. The POSIX pseudo-terminal interface is a libc interface on every
supported system, and Darwin has no stable system-call ABI to reach past it;
`src/conduit.zig` refuses to compile without libc there rather than failing at link
time. On Windows every call this package makes is a `kernel32` import, so no C
runtime is involved.

## Platforms, and which claims are verified where

| | Built | Suite run | How |
|---|---|---|---|
| Linux (glibc) | yes | **yes** | CI on `ubuntu-latest`; `ci/linux.sh` in Docker |
| Linux (musl) | yes | **yes** | CI and `ci/linux.sh --musl`, on Alpine |
| macOS | yes | **yes** | CI on `macos-latest` |
| Windows | yes | **yes** | CI on `windows-latest` |
| FreeBSD, NetBSD | yes | no | cross-compiled only |

The suite runs in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall on each of
the first four, and is cross-compiled for `x86_64-windows-gnu`,
`x86_64-windows-msvc`, `aarch64-windows-gnu`, both Linux libcs on two
architectures, both macOS architectures, FreeBSD and NetBSD.

Some claims are POSIX-only because the *claim* is, not because the test is
missing, and those tests say so and skip: a controlling terminal, a process
group id read back with `getpgid`, Ctrl-C becoming `SIGINT`, `stty size`
reporting the geometry. What is checked on Windows is everything else: a child
on a pseudoconsole and what it writes, pipes in both directions, exit codes,
`tryWait`, `Reaper`, `killWait`, `output` with its cap and its timeout, the
environment and working directory, the failures, the refusal to run a `.bat`,
and `spawnShell`.

Windows 10 version 1809 is the floor. `CreatePseudoConsole` arrived there and
is imported statically rather than looked up, so a binary linking this package
will not start on anything older.

## The API

### `Pty` — a pseudo-terminal pair

| | |
|---|---|
| `Pty.open(options)` | A new pair at a given geometry. `options`: `rows`, `cols`, `x_pixel`, `y_pixel`. |
| `pty.read`, `pty.write` | The master, as two handles. The same descriptor twice on POSIX; the two pipes of a pseudoconsole on Windows. `null` once closed. |
| `pty.readFile()`, `pty.writeFile()`, `pty.master()` | Either end, or both, as `std.Io.File`s sharing the handle rather than duplicating it. |
| `pty.slave` | The terminal end: a descriptor on POSIX, an `HPCON` on Windows. |
| `pty.resize(size)`, `pty.size()` | The window size. `resize` is safe to call while another task reads or writes, which is what `Proxy` relies on. |
| `pty.close(io)` | Everything. Idempotent, and correct after either of the next two. |
| `pty.closeSlave(io)`, `pty.closeMaster(io)` | One end. **Read `closeSlave`'s doc comment**: it is the one call the two systems want at different moments. |

### `Child` — a child process

| | |
|---|---|
| `Child.spawn(io, allocator, options)` | Start it. The allocator is used for the call only; nothing is retained. |
| `child.id`, `child.pgid` | The process id (POSIX) or handle (Windows), and the process group when `detach` asked for one. |
| `child.stdin`, `child.stdout`, `child.stderr` | `std.Io.File`s for the pipes `spawn` created, owned by the `Child`. |
| `child.closeStdin(io)` | Half-close: the child reading to end of file stops waiting on you. |
| `child.pty` | The master, for a child spawned on a pair. Borrowed from the `Pty`. |
| `child.stdinFile()`, `child.stdoutFile()` | The child's input and output wherever they are: the pipes, or the master. |
| `child.stdinWriter(io, buf)`, `child.stdoutReader(io, buf)` | The same, as `std.Io` reader and writer interfaces. |
| `child.output(io, allocator, options)` | Run to the end and collect it: a cap, a timeout, a bounded drain, both streams read on their own tasks. |
| `child.wait(io)` | Blocks; delegates to `std.process.Child.wait`. Read the child's output while you wait — see below. |
| `child.tryWait()` | Never blocks. `null` while the child runs. |
| `child.waitTimeout(io, ms)` | Reaps it if it ends in time; `null` if it does not, and it is still running. |
| `child.kill(signal)` | `.interrupt`, `.terminate` or `.kill`. The process group of a detached child, the child alone otherwise. |
| `child.killWait(io, grace_ms)` | `.terminate`, the grace, `.kill`, a reap. |
| `child.deinit(io)` | Closes what the `Child` owns, and nothing the caller supplied. |

| `conduit.succeeded(term)`, `exitCode(term)`, `signalName(term)` | What a `Term` says, without matching on it. `signalName` is POSIX in practice. |

`SpawnOptions`: `argv`, `cwd`, `environ` (a `*const std.process.Environ.Map`),
`stdio`, `detach`, `stderr_to`, `path_search`, `credentials`.

`stdio` is one of `.{ .pty = &pty }`, `.{ .pipes = .{ .stdin, .stdout, .stderr } }`,
`.inherit`, `.ignore`, or `.{ .streams = .{ .stdin, .stdout, .stderr } }` — each
of those three being `.inherit`, `.{ .file = f }`, `.ignore`, `.pipe` or
`.close`. `.{ .file = pty.slaveFile() }` is how a child is given the terminal
end of a pair for one stream and something else for the others, on POSIX.

`detach` puts the child out of reach of signals aimed at the parent's process
group. On POSIX with `.pty` it means `setsid` plus `TIOCSCTTY`, so the pair
becomes the child's controlling terminal; otherwise `setpgid(0, 0)`. On Windows
it is `CREATE_NEW_PROCESS_GROUP`, which means only half as much — the doc
comment says which half.

`credentials` is `uid`, `gid` and `umask`, set in the fork child between the
`fork` and the `execve` because that is the only place they can be set without
changing this process too. POSIX only: anything set there is
`error.Unsupported` on Windows. Supplementary groups are the parent's —
`setgroups` needs the group database, which a fork child may not read.

`Term` is `std.process.Child.Term`, not a parallel type of this package's own.

**Read while you wait.** A child that fills a pipe nobody is draining stops
there, and a child on a pseudo-terminal can do worse: on Darwin a process whose
terminal still holds output it has written blocks *inside exit* until the master
is read, so a parent that waits first and reads afterwards waits forever.
`child.output` reads and waits at once; `Proxy` keeps reading.

### `conduit.environ` — a child's environment

`environ.inherit(allocator, &.{ .{ .name = "TERM", .value = "xterm-256color" } })`
is this process's environment with those changes, as a map the caller owns. A
`null` value removes the variable rather than emptying it.
`environ.only(allocator, …)` takes the same list and inherits nothing — the
`env -i` shape, for a child that should not see an agent socket or a token.

A child with no `PATH` is also a child a bare `argv[0]` cannot be found for, so
`SpawnOptions.path_search` says which `PATH` resolves the program:
`.child_environ` (the default, what a shell does), `.parent_environ` (what
`std.process.spawn` does, and what a scrubbed environment usually wants) or
`.none`.

### `spawnShell` — the user's shell on a pair

`spawnShell(io, allocator, options)` returns a `Shell`: a `Pty` and a `Child`.
The defaults are a terminal emulator's — `$SHELL` or `%COMSPEC%`, 24×80, `TERM`
set, a controlling terminal on POSIX — and it absorbs the `closeSlave` timing
difference, so the same three lines are right on both systems.

### `Reaper` — a wait on a background task

`Reaper.init(&child)`, then `start(io)`, then `exit()` for `?Term` without
blocking, then `deinit(io)`. Its lifetime rules are in the doc comment and are
worth reading: the `Child` must outlive it, it must not move once started, and
`deinit` must run.

### `Proxy` — a byte pump and a size forwarder

`Proxy.run(io, .{ .master, .input, .output, .input_buffer, .output_buffer, .resize })`
moves bytes both ways until the child's end of the terminal closes, and keeps
the pair the same size as a terminal of yours. Ctrl-C and Ctrl-Z need no code:
put your own terminal in raw mode and they arrive as bytes, which this forwards
and the child's terminal turns back into signals. The module doc explains both.

### `Expect` — a conversation with a child

| | |
|---|---|
| `Expect.init(master, buffer)` | Over `Child.pty` or `Pty.master()`, with a buffer the caller owns. `child.expect(buffer)` builds one over a child's pipes too. |
| `expect.start(io)`, `expect.deinit(io)` | The reading task, which runs between calls. The lifetime rules are `Reaper`'s. |
| `expect.until(io, pattern, timeout_ms)` | Waits for a literal byte pattern and consumes through it: `Match.before` and `Match.found`. |
| `expect.bytes(io, count, timeout_ms)` | Waits for a count of bytes and consumes them. |
| `expect.send(io, reply)` | Writes the reply, as if it had been typed at the child's terminal. |
| `expect.pending(io)`, `expect.discard(io)` | What has arrived and no pattern has matched; and forgetting it. |

A wait ends in `error.Timeout`, `error.EndOfStream`, `error.BufferFull` or
`error.ReadFailed`. Patterns are bytes: there is no regular-expression engine
in the standard library and none here.

### Terminal helpers

`rawMode(handle)`, `restore(handle, saved)`, `winSize(handle)`, `isTty(handle)`,
and — POSIX only — `setWinSize(handle, size)`, `ttyName(handle, buffer)` and
`foregroundGroup(handle)`, which is the question `isTty` cannot answer: whether
anything is running *on* that terminal, and which process group the signals it
generates would reach.
They take a handle, not a `std.Io.File`, because none of these is one of the
operations `std.Io` abstracts.

On Windows a console is two handles with two unrelated sets of mode flags, so
`rawMode` is called once for each and works out which it was given; `winSize`
wants the output handle, because that is what has a size.

## What this package does not do

- **Install a signal handler.** Not ever, and no disposition in the calling
  process is touched. A library that installed a `SIGWINCH` or `SIGCHLD`
  handler would be taking process-wide state from the program that owns it.
  (The fork child is a different matter: it gets a clean slate before `execve`,
  as above.) `Proxy` forwards the window size by reading it instead, and takes
  a `ticket` a program's own handler can bump.
- **Run `.bat` or `.cmd` scripts.** `cmd.exe` re-parses their command line with
  rules no argument serialisation survives, so an argument containing the right
  characters becomes a second command. `spawn` returns
  `error.UnsupportedBatchFile` rather than offering a way to smuggle one; a
  caller who wants a script can invoke `cmd.exe /c` and take responsibility for
  what they pass it.
- **Search `PATHEXT`.** On Windows the program is resolved by `CreateProcessW`,
  which searches the application directory, the current directory, the system
  directories and `PATH`, and appends `.exe`. Anything else, name in full.
- **Terminal emulation.** Nothing here parses escape sequences or keeps a
  screen. `Proxy` moves bytes; what they mean is someone else's job.
- **`SIGPIPE`.** Writing to a pipe whose reader is gone raises it, and this
  package does not change its disposition. That is the program's decision.
- **Report which signal killed a Windows child.** There is no such notion
  there: a terminated process reports the exit code it was terminated with, and
  `killWait` uses 1. `Term.signal` is POSIX-only in practice.
- **Wait for a pattern and answer it.** There is no `expect` here yet: reading
  the master until some bytes appear, with a deadline, and then writing a reply.
  `Proxy` moves bytes and `output` collects them; a conversation is neither.
- **Set a child's credentials.** No `uid`, `gid`, `umask` or resource limit at
  spawn, and no pre-exec callback to do it with — that callback runs where only
  async-signal-safe calls are legal, and this package would rather not hand one
  out. Named options for the first four are the shape it should take.
- **Name each stream separately.** `stdio` is one choice for all three, plus
  `stderr_to` for the common exception. Giving a child the pty's slave as its
  input only, or a pipe on one stream and an open file on another, is not
  expressible yet.
- **Kill a process tree on Windows.** `detach` there is
  `CREATE_NEW_PROCESS_GROUP`, which a console control event can address; what
  it is not is a job object, so `killWait` ends the child and not what the child
  started. On POSIX the process group does reach the tree.
- **Thread safety.** One task at a time per `Child` or `Pty`, except
  `Pty.resize`, which is one call, `Reaper`, which exists precisely so a wait
  can be in flight while another task works, and `Child.output`, which reads two
  streams at once on purpose.

## Building

```sh
zig build test          # the suite, and the examples, which are run
zig build examples      # the examples alone
zig fmt --check src examples build.zig
ci/linux.sh --both      # the suite on glibc and musl Linux, in Docker
```

Zig 0.16.0. Every test spawns a real child process and reaps it; the suite runs
in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall in CI, because the code
between `fork` and `execve` is the kind an inlining decision can change.

## License

MIT. See [LICENSE](LICENSE).
