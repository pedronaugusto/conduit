# conduit

[![CI](https://github.com/pedronaugusto/conduit/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/conduit/actions/workflows/ci.yml)

conduit starts child processes and gives them pseudo-terminals. It is for
programs that run another program the way a terminal emulator does — on a pty,
in its own session, with a window size and a way to talk to it — and for
programs that only need a child on pipes, killed and reaped with a deadline on
it.

## Usage

The block below is a region of [`examples/usage.zig`](examples/usage.zig),
which `zig build examples` builds and runs; CI compares the two.

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

On POSIX, with `shell_arguments` asking for `stty size` and `test -t 0`, that
prints `24 80` and `is this a terminal? yes`, and ends `.{ .exited = 0 }`.

## Install

```sh
zig fetch --save git+https://github.com/pedronaugusto/conduit
```

```zig
const conduit = b.dependency("conduit", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("conduit", conduit.module("conduit"));
```

One import, and no dependencies beyond the standard library. The module links
libc on POSIX and not on Windows, and decides that from the target: the POSIX
pseudo-terminal interface is a libc interface everywhere, and Darwin has no
stable ABI to reach past it. Every Windows call is a `kernel32` import.

## The API

### `Pty` — a pseudo-terminal pair

| | |
|---|---|
| `Pty.open(options)` | A new pair. `options`: `rows`, `cols`, `x_pixel`, `y_pixel`, and on Windows `console`. |
| `pty.read`, `pty.write` | The master, as two handles: the same descriptor twice on POSIX, the two pipes of a pseudoconsole on Windows. `null` once closed. |
| `pty.readFile()`, `pty.writeFile()`, `pty.master()` | Either end, or both, as `std.Io.File`s sharing the handle rather than duplicating it. |
| `pty.slave` | The terminal end: a descriptor on POSIX, an `HPCON` on Windows. `pty.slaveFile()` is POSIX only. |
| `pty.resize(size)`, `pty.size()` | The window size. `resize` is safe to call while another task reads or writes. |
| `pty.console` | Windows only: which of `OpenOptions.console` the system granted. `win32_input` for keys a terminal encoding cannot spell, `passthrough` for the child's own bytes rather than the console host's redraw of them, `resize_quirk` for a resize that does not reflow. A Windows too old for one of them refuses the whole call, so `open` asks again without it. |
| `pty.close(io)` | Everything. Idempotent, and correct after either of the next two. |
| `pty.closeSlave(io)`, `pty.closeMaster(io)` | One end. The two systems want `closeSlave` at different moments — see Design. |

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
| `child.expect(buf)` | An `Expect` over both directions, or `null` if this process holds only one. |
| `child.output(io, allocator, options)` | Run to the end and collect it: a cap, a timeout, a bounded drain, both streams read on their own tasks. |
| `child.wait(io)` | Blocks; delegates to `std.process.Child.wait`. |
| `child.term` | How it ended, once something reaped it. Written by whichever call did and published through an atomic, so `tryWait` is how to read it while a `Reaper` runs. |
| `child.tryWait()` | Never blocks. `null` while the child runs. |
| `child.waitTimeout(io, ms)` | Reaps it if it ends in time; `null` if it does not, and it is still running. Waits on a handle the system makes ready the moment the child ends — a `pidfd`, a kqueue registration — and asks again on a growing interval where there is neither. |
| `child.kill(signal)` | `.interrupt`, `.terminate` or `.kill`, aimed at what the child started and not only at the child: on POSIX the process group of a detached child and a walk of its descendants; on Windows a console control event to a detached child's group, and for `.kill` — or `.terminate` with no group — the job object. On Windows, `.interrupt` without a group is `error.Unsupported`, there being nothing to fall back to that would mean the same thing. |
| `child.killWait(io, grace_ms)` | `.terminate`, the grace, `.kill`, a reap. |
| `child.waitTree(io, ms)` | Windows only: waits for the job the child was put in to hold no process at all, which is the question `wait` does not answer — a child that exits having started something is a tree that is still running. A compile error on POSIX, which has nothing to ask. |
| `child.deinit(io)` | Closes what the `Child` owns, and nothing the caller supplied. |

`conduit.succeeded(term)`, `exitCode(term)` and `signalName(term)` say what a
`Term` holds without matching on it. `Term` is `std.process.Child.Term`, not a
parallel type of this package's own. `signalName` is `null` on Windows, where a
process reports an exit code however it ended: 1 when `killWait` had to
terminate it, and otherwise whatever the child itself exited with — the low
byte of it, since `Term.exited` is a byte and a Windows exit code is a `DWORD`.

`SpawnOptions`: `argv`, `cwd`, `environ` (a `*const std.process.Environ.Map`),
`stdio`, `detach`, `stderr_to`, `path_search`, `credentials`,
`resource_limits`, `fd_policy`, `job_limits`.

`stdio` is `.{ .pty = &pty }`, `.{ .pipes = .{ .stdin, .stdout, .stderr } }`,
`.inherit`, `.ignore`, or `.{ .streams = .{ .stdin, .stdout, .stderr } }` —
each of those three being `.inherit`, `.{ .file = f }`, `.ignore`, `.pipe` or
`.close`. `.{ .file = pty.slaveFile() }` gives a child the terminal end of a
pair for one stream and something else for the others, on POSIX.

`detach` puts the child out of reach of signals aimed at the parent's process
group. On POSIX with `.pty` it is `setsid` plus `TIOCSCTTY`, so the pair
becomes the child's controlling terminal; otherwise `setpgid(0, 0)`. On Windows
it is `CREATE_NEW_PROCESS_GROUP`, which is what a console control event can be
addressed to and nothing more — reaching the tree there is the job object's
doing, not `detach`'s.

`fd_policy` is what the child is given of the descriptors above 2 that this
process holds: `.close_on_exec`, the default, which is whatever close-on-exec
allows, or `.close_all`, which closes every one of them in the child whatever
its flags say — `close_range` on Linux, a loop elsewhere. On Windows a child is
given the handles named in an attribute list and nothing else, so both values
mean the same thing there. Console handles are supplied through the shared
console rather than named in the list; ordinary handles beside them remain
restricted to the ones the child was given.

`credentials` is `uid`, `gid` and `umask`, and `resource_limits` a list of
`std.posix.rlimit_resource` and `std.posix.rlimit` pairs. Both are set in the
fork child, limits first, so a privileged parent can still raise a hard limit
for a child it is handing on. POSIX only: either on Windows is
`error.Unsupported`. Supplementary groups stay the parent's, since `setgroups`
needs the group database a fork child may not read.

`job_limits` is the Windows answer, and a different one: `process_memory_bytes`,
`job_memory_bytes`, `active_processes` and `cpu_rate` go on the job object
every child there already has, so they bound the child *and everything it
starts* rather than the one process. Windows only; anywhere else it is
`error.Unsupported`.

### `Expect` — a conversation with a child

| | |
|---|---|
| `Expect.init(master, buffer)` | Over `Child.pty` or `Pty.master()`, with a buffer the caller owns. |
| `expect.start(io)`, `expect.deinit(io)` | The one reading task, which runs between calls. A second `start` is `error.AlreadyStarted`. |
| `expect.until(io, pattern, timeout_ms)` | Waits for a literal byte pattern and consumes through it: `Match.before` and `Match.found`. |
| `expect.untilAny(io, patterns, timeout_ms)` | Waits for any of several. The earliest match wins, whatever order they were listed in; `Match.index` says which, and the ones that lost stay pending. |
| `expect.bytes(io, count, timeout_ms)` | Waits for a count of bytes and consumes them. |
| `expect.send(io, reply)` | Writes the reply, as if it had been typed at the child's terminal. |
| `expect.pending(io)`, `expect.discard(io)` | What has arrived and no pattern has matched; and forgetting it. |

A wait ends in `error.Timeout`, `error.EndOfStream`, `error.BufferFull` or
`error.ReadFailed`, and — like every call here that can be in flight — in
`error.Canceled`.

### `conduit.environ` — a child's environment

`environ.inherit(allocator, &.{ .{ .name = "TERM", .value = "xterm-256color" } })`
is this process's environment with those changes, as a map the caller owns; a
`null` value removes the variable rather than emptying it.
`environ.only(allocator, …)` takes the same list and inherits nothing, for a
child that should not see an agent socket or a token. A child with no `PATH` is
also one a bare `argv[0]` cannot be found for, so `path_search` says which
`PATH` resolves the program: `.child_environ` (the default, what a shell does),
`.parent_environ` (what `std.process.spawn` does, and what a scrubbed
environment wants) or `.none`. Windows resolves the program inside
`CreateProcessW`, from the environment the child is being given, so
`.child_environ` is the only one of the three it can honour and the other two
are `error.Unsupported` there.

### `spawnShell`, `Reaper`, `Proxy`

`spawnShell(io, allocator, options)` returns a `Shell`: a `Pty` and a `Child`,
with a terminal emulator's defaults — `$SHELL` or `%COMSPEC%`, 24×80, `TERM`
set, a controlling terminal on POSIX — absorbing the `closeSlave` timing
difference below.

`Reaper.init(&child)`, `start(io)`, `exit()` for a `?Term` without blocking,
`deinit(io)`. The `Child` must outlive it, it must not move once started.

`Proxy.run(io, .{ .master, .input, .output, .input_buffer, .output_buffer, .resize })`
moves bytes both ways until the child's end of the terminal closes, and keeps
the pair the size of a terminal of yours. Both buffers must be non-empty;
otherwise it returns `error.BufferTooSmall`.

### Terminal helpers

`rawMode(handle)`, `restore(handle, saved)`, `winSize(handle)`, `isTty(handle)`,
and — POSIX only — `setWinSize(handle, size)`, `ttyName(handle, buffer)` and
`foregroundGroup(handle)`, which asks not whether a handle is a terminal but
whether anything is running *on* it. They take a handle rather than a
`std.Io.File`: none of them is an operation `std.Io` abstracts. A Windows
console is two handles with two unrelated sets of mode flags, so `rawMode` is
called once for each and works out which it was given, and `winSize` wants the
output one.

## Design

**Why this forks rather than wrapping `std.process.spawn`.** The standard
library has no hook between `fork` and `execve`, the only place `setsid` and
`TIOCSCTTY` can be called. Without them a child handed the slave end of a pty
passes `isatty` and can read the window size but has no controlling terminal,
so nothing typed at the master becomes a signal and Ctrl-C does nothing.
Credentials and resource limits sit there for the same reason: a process can
only set them on itself.

**The child gets a clean slate before `execve`.** An empty signal mask, and
every ignored signal back at its default action. `execve` resets neither, so a
program started from a shell's background job would otherwise inherit an
ignored `SIGINT` and be deaf to Ctrl-C on its own terminal.

**No signal handler is installed, ever**, and no disposition in the calling
process is touched: a `SIGWINCH` or `SIGCHLD` handler is process-wide state
that belongs to the program. `Proxy` forwards the window size by reading it on
a task, and takes an optional `ticket` a program's own handler can bump.
`SIGPIPE` too — writing to a pipe whose reader is gone raises it, and what to
do about that is the program's.

**Read the child's output while you wait for it.** A child that fills a pipe
nobody drains stops there, and on Darwin a process whose terminal still holds
output blocks *inside exit* until the master is read — so a parent that waits
first and reads afterwards waits forever. It is any unread byte that does it,
not a full buffer. `child.output` reads and waits at once, `Proxy` keeps
reading, and `Expect` reads on a task from `start`.

**`Pty.closeSlave` is wanted at different moments.** On POSIX, right after
`Child.spawn`: until then the terminal still has a reader in this process, so a
read of the master blocks instead of reporting end of file when the child
exits. On Windows it is `ClosePseudoConsole`, which ends the child, so it is
called when the program is done. `spawnShell` absorbs that.

**On Windows the master has to be read.** The console host writes into a pipe
this process holds the other end of, and both `ResizePseudoConsole` and
`ClosePseudoConsole` wait for the host, so a program that has stopped reading
can block in either. The pipes have room for a repaint of a large window, and
`Pty.close` reads the master itself: a drain on a task of its own, started
before the console is closed and joined after, which the host's exit ends. The
terminal end goes first either way; only a `std.Io` with no task to give drops
the master ends first instead, so that the host's last write fails rather than
waits.

**`kill` and `killWait` reach what the child started.** On Windows every child
goes in a job object of its own before it runs — started suspended, assigned,
resumed, so nothing is ever outside it — and `.kill` ends the job. The job ends
what is left in it when its last handle closes, so `deinit` there also ends
what the child started and left behind. A child that cannot be put in its job
is `error.JobAssignmentFailed`, not a child whose tree `kill` would miss.

A container the system keeps can also be asked about, which is `waitTree`: the
job reports to a completion port from before the child is assigned to it, and
the wait ends when the job says it holds nothing. So a program can watch the
whole tree go rather than only the child — and it has to ask before `deinit`,
which is what closes the job and the port. POSIX has nothing to ask. A process
group is an address to send signals to and the system accounts nothing to it,
and the walk `kill` uses goes down from the child, where a grandchild whose
parent has exited belongs to `init` and is related to the child by nothing that
can be looked up; a walk that named nothing would mean "ended" and "orphaned"
in the same breath. `waitTree` is a compile error there, with a message that
says so.

POSIX has no container for a tree, so `kill` reaches three things: the child,
the child's process group when `detach` made one, and every descendant the
system will name — `/proc/<pid>/task/<tid>/children` on Linux,
`proc_listchildpids` on Darwin, and on the BSDs and illumos neither, where the
process group is the whole of the reach. Descendants are signalled deepest
first and before the child, because a process signalled before the ones below
it leaves them orphaned and an orphan is related to nothing. A descendant that
gave itself a process group with `setsid` or `setpgid` is reached, and for
`.kill` so is one started while the first signal was being delivered: the group
and the walk are asked again until a pass names nothing. A process that has
both left the group and been orphaned before anything looked is reached by no
system, and a grandchild of a child that was already reaped keeps running. The
walk signals stable process identities — pidfds on Linux and audit tokens on
Darwin — so a descendant that exits cannot turn a recycled PID into a signal
for an unrelated process.

**Two ways to start a child on POSIX, and the same child either way.** A spawn
that needs nothing done between the fork and the exec is handed to
`posix_spawn`, which does not copy the parent's page tables: measured here over
1000 spawns of `/usr/bin/true` on the null device, 946 µs a spawn against 1336.
Everything that can only be done in a fork child sends the spawn back to the
fork — a pseudo-terminal, which needs `setsid` and an ioctl; `credentials` and
`resource_limits`, which a process sets on itself; `cwd`, `Stream.close`, a
caller's file at descriptor 0, 1 or 2, and `fd_policy = .close_all`. The fast
path runs on Linux and macOS, which are the systems the suite runs on; the BSDs
number the attribute flags differently and keep the fork. `zig build test
-Dfork-spawn` runs the whole suite with it turned off.

**A spawn that cannot run the program is an error**, not a child that exits
127: the fork child reports the failure over a close-on-exec pipe before
`spawn` returns, and `CreateProcessW` fails outright. Both ends of a pair are
close-on-exec, so a pair held open while an unrelated child starts is not
handed to it.

**A descriptor this package opens is close-on-exec from the call that opens
it**, where the system has a call that says so — `pipe2`, `O_CLOEXEC`,
`F_DUPFD_CLOEXEC`. Where it has not, the flag is a second call, and between the
two a child started on another thread would inherit a descriptor that has
nothing to do with it; on Darwin, which has no `pipe2`, this package's own
spawns and its own pipe-making are held apart so that they cannot overlap. A
`fork` elsewhere in the program still can, and `Pty.open` marks the master in a
second call for want of a flag to pass `posix_openpt`. A descriptor the
*caller* opened without the flag is the caller's, and `fd_policy` is how to
say the child should not have it.

**Allocation.** `Child.spawn` and `spawnShell` take an allocator, use it for the
call only — the argument, environment and search-path arrays that must exist
before the child does — and retain nothing. `Child.output` allocates the bytes
it collects and `environ` the map it returns; both say whose they are.
Everything else works in buffers the caller passes, `Expect` included.

**Thread safety.** One task at a time per `Child` or `Pty`, except `Pty.resize`,
which is one call; `Reaper`, which exists so a wait can be in flight while
another task works; and `Child.output`, which reads two streams at once. A
child is reaped once however many tasks ask: the right to be inside the
system's wait is taken with an atomic, and whoever has it publishes the term to
the rest — so `killWait` is legal while a `Reaper` runs, which is the sequence
the `Reaper` exists for.

## Scope

- **No terminal emulation.** `Proxy` moves bytes; nothing here parses an escape sequence or keeps a screen.
- **No command splitting.** `argv` is a list, and turning one string into several is a shell's grammar.
- **No job control.** `foregroundGroup` answers the question; `tcsetpgrp` is the caller's call to make with `child.pgid`.
- **No pattern language.** `Expect` matches byte strings.
- **No pre-exec callback.** Only async-signal-safe calls are legal there, so the uses people reach for one for are named options instead.
- **No `.bat` or `.cmd`.** `spawn` returns `error.UnsupportedBatchFile`, because the command interpreter re-parses their command line with rules no serialisation survives.

## Platforms

| | Mechanism | Suite |
|---|---|---|
| Linux (glibc) | `posix_openpt`, `posix_spawn` or `fork` and `execve` | `ubuntu-latest`, and in Docker with `ci/linux.sh` |
| Linux (musl) | the same | Alpine, in CI and with `ci/linux.sh --musl` |
| macOS | the same | `macos-latest` |
| Windows | `CreatePseudoConsole` and `CreateProcessW` | `windows-latest` |
| FreeBSD, NetBSD | as Linux | cross-compiled only |

Windows 10 version 1809 is the floor: `CreatePseudoConsole` is imported
statically rather than looked up. FreeBSD and NetBSD are compiled and never
run, so what holds there is what the sources say and not what a suite has
shown.

Cross-compiled in CI for `x86_64-windows-gnu`, `x86_64-windows-msvc`,
`aarch64-windows-gnu`, glibc on two architectures and musl on one, both macOS
architectures, FreeBSD and NetBSD. `zig build check -Dtarget=...` is what
those jobs run: it compiles the library, the suite and the examples for the
target and runs none of them, so a Windows-only path reached from a test and
from nowhere else is still held to compiling.

A test that is about POSIX alone — a controlling terminal, `getpgid`, Ctrl-C
becoming `SIGINT`, `stty size` — says so and skips elsewhere, and so does a
Windows-only one: a job object holding a tree, a handle's inheritance flag, a
console option the system may decline. On Windows the
program is resolved by `CreateProcessW`, which searches the application
directory, the current directory, the system directories and `PATH` and appends
`.exe`; `PATHEXT` is not searched.

## Testing

```sh
zig build test                   # the suite, and the examples, which are run
zig build test -Dfork-spawn      # the same, with the posix_spawn path off
zig build test --fuzz            # the three properties, under the fuzzer
zig build unit -Dthread-sanitizer   # the suite under ThreadSanitizer
zig build examples               # the examples alone
zig fmt --check src examples build.zig
ci/linux.sh --both               # the suite on glibc and musl Linux, in Docker
```

Most of the suite starts a real child process and reaps it, and CI runs it on
Linux and macOS in Debug, ReleaseSafe, ReleaseFast and ReleaseSmall: the code
between `fork` and `execve` is the kind an inlining decision can change. On
Windows the three release modes run whole and Debug runs in filtered pieces,
each its own step, so a step that hangs names what it was running. CI passes
`--test-timeout 45s`, which ends the run and names the test that did not
finish, and a test that starts a child or opens a pair carries a watchdog that
panics with its own name after thirty seconds. The suite also runs with the
`posix_spawn` path turned off, because that path is a second implementation of
one contract and running both is what says they make the same child.

Three things here read bytes the package did not write, and each is a property
`zig build test --fuzz` puts a fuzzer on: that the search behind `until` and
`untilAny` reports what a search of the whole buffer would, however the child's
output is cut into arrivals; that every candidate a `PATH` produces is an entry
of it with the program on the end; and that an argument list survives the
Windows command line it is written into, by the rules that parse it back. Each
keeps a corpus of its own under `.zig-cache/f`. The test module is built with
error return traces off, which is what lets the fuzzing test runner compile.

`zig build unit` is the suite without the examples, `-Dtest-filter` runs part
of it, and `CONDUIT_TRACE` in the environment prints what this package asked
the operating system for.

## Requirements

Zig 0.16.0. libc on POSIX; none on Windows.

## Licence

MIT. See [LICENSE](LICENSE).
