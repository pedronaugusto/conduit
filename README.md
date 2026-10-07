# conduit

[![CI](https://github.com/pedronaugusto/conduit/actions/workflows/ci.yml/badge.svg)](https://github.com/pedronaugusto/conduit/actions/workflows/ci.yml)

conduit starts child processes and gives them pseudo-terminals. It is for
programs that run another program the way a terminal emulator does — on a pty,
in its own session, with a window size and a way to talk to it — and for
programs that only need a child on pipes, killed and reaped with a deadline on
it.

## Install

Requires Zig 0.17.0.

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

## Usage

The block below is a region of [`examples/usage.zig`](examples/usage.zig),
which `zig build examples` builds and runs; CI compares the two.

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const conduit = @import("conduit");

// The user's shell on a new pseudo-terminal, 24 rows by 80 columns, with
// `TERM` set and — on POSIX — the pair as its controlling terminal, so a
// Ctrl-C written to the master would arrive as `SIGINT`.
var shell = try conduit.spawnShell(gpa, io, .{
    .size = .{ .rows = 24, .cols = 80 },
    .args = shell_arguments,
});
defer shell.deinit(io);

// Everything it writes to its terminal, and how it ends, with a bound on
// the whole thing. A terminal is one stream, so a child on a pair has no
// separate standard error to collect.
var result = try shell.child().output(gpa, io, .{
    .timeout = conduit.Deadline.within(.fromSeconds(5)),
    .drain = .fromMilliseconds(250),
});
defer result.deinit();
```
<!-- END GENERATED -->

On POSIX, with `shell_arguments` asking for `stty size` and `test -t 0`, that
prints `24 80` and `is this a terminal? yes`, and ends `.{ .exited = 0 }`.

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

**Stop a reader before closing what it reads.** A task reading the master or a
child's pipe is cancelled, or reads to the end, and is joined before
`Pty.close`, `closeMaster` or `Child.deinit` closes that file. A descriptor
closed under a read is free for the next open in the process, and a read that
starts after the close reads that file instead.

**`kill` and `killWait` reach what the child started.** On Windows every child
goes in a job object of its own before it runs — started suspended, assigned,
resumed, so nothing is ever outside it — and `.kill` ends the job. A child
that cannot be put in its job is `error.JobAssignmentFailed`, not a child
whose tree `kill` would miss.

A container the system keeps can also be asked about, which is `waitTree`: the
job reports to a completion port from before the child is assigned to it, and
the wait ends when the job says it holds nothing; on Linux the child's cgroup
(below) says the same in `cgroup.events`, whose change wakes a `poll`. So a
program can watch the whole tree go rather than only the child — and it has
to ask before `deinit`, which is what closes the job and the port and removes
the cgroup. POSIX, for a child with no cgroup of its own, has nothing to ask. A process group is an address to send
signals to and the system accounts nothing to it, and the walk `kill` uses goes
down from the child, where a grandchild whose parent has exited belongs to
`init` and is related to the child by nothing that can be looked up; a walk
that named nothing would mean "ended" and "orphaned" in the same breath. `waitTree` is a compile error there, with a message that
says so, and `error.Unsupported` for a Linux child that was given no cgroup.

**On Linux a child gets a cgroup of its own, where the system allows one.**
A cgroup v2 is a set the kernel keeps: a process is born into its parent's
and stays there whatever it does with its group, its session or its parent.
So where this process may make a cgroup below its own — a subtree delegated to
it, as systemd does for a user's session manager and for `Delegate=yes` units,
or a container with a writable cgroup mount — `spawn` makes one per child and
the fork child joins it before it does anything else, so nothing the child
ever starts is outside it. `kill(.kill)` is then one write to `cgroup.kill`
(Linux 5.14), which ends everything in it and is safe against a fork while it
is being delivered; `.terminate` and `.interrupt` go to each member through a
pidfd, the member confirmed still in the cgroup after the pidfd was opened. A
grandchild that forked twice and called `setsid` is reached like any other.
Whether this process may is found out at the first spawn, from
`/proc/self/cgroup`, `/proc/self/mountinfo` and the first `mkdir`, never
assumed; a refusal (a read-only cgroup mount, as in a default container; a
cgroup owned by root, as in an SSH session; a cgroup v1 system; a kernel
before 5.14) is remembered, and every child is started as before and reached
as below. The cgroup is owned by the child's lifecycle; a
contained spawn always takes the fork, never `posix_spawn`, since joining a
cgroup is a write and there is no file action for one; this process holds
one more descriptor per child, and makes and removes one directory per child
under its own cgroup, named `conduit-<pid>-<n>`; `deinit` removes it, and
one whose processes outlive the child is left to them and removed by a later
spawn or `deinit` once they have ended. Up to sixteen such cgroups retain
their directory handles so later cleanup verifies the identity before removal.
A descendant that moves itself to another cgroup it may write to — asks
systemd for a scope of its own — has left the reach.

**On Linux, orphans can be made this process's own, beneath the cgroup and
the walk.** A process whose parent ends goes to `init`, or to the nearest
ancestor that asked for orphans, and is then related to nothing a walk can
name. `Orphans.start` makes this process that ancestor, so every orphan
below it becomes its child, and conduit reaps each one that has ended at
its next event and ends them all with `Orphans.killAll`. The kernel does not say which children
were adopted — an orphan and a child this process started are both its
children, and nothing records the parent one had before — so conduit
takes the children it started, and the ones this process had at `start`,
as its own and everything else as adopted. **The contract is that every
child is started through conduit while it runs:** a child started some
other way, or a `SIGCHLD` handler that reaps with `waitpid(-1)`, would be
taken for an orphan and reaped, and its owner's wait would find nothing. A
`Child`'s own status is never taken: every spawn holds the shared side of a
lock from before its fork until the child is on conduit's list, and a look
holds it alone. What a caller may observe: the subreaper attribute is set
from `start` to `stop`; a process below this one reports this one as its
parent once its own has gone, and this process gets a `SIGCHLD` when it
ends. Nothing wakes an idle program for it: a look — a read of
`/proc/self/task/<tid>/children` per thread and a `waitid` per child, a
bounded process scan — runs when a child of conduit's is reaped (the moment
what it left has become this process's), when a spawn returns, and in
`count` and `killAll`, so an orphan that ends while none of those happens
stays a zombie until the next one; each adopted process holds a pidfd
until it is reaped; each child conduit starts while it runs holds one more
descriptor until it has been reaped, and every Linux spawn takes that lock,
running or not. `Child.kill` does not reach an adopted process on the
child's account unless the child's cgroup holds it: nothing else says which
child it came from, and it does not guess. A contained Linux child instead
has its private adoption supervisor. `Orphans.deinit` signals nothing and
refuses to release a scope that still owns a direct child or adoptee.

Otherwise POSIX has no container for a tree, so `kill` reaches three things:
the child, the child's process group when `detach` made one, and every
descendant the system will name — one `/proc` process-table pass on Linux,
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
for an unrelated process. Each candidate's ancestry is proved through held
identities before delivery. The walk holds the tree, never the whole process
table, in a 64 KiB stack workspace: about two thousand descendants of one child. A
tree larger than that is not walked; `kill` still signals the child or its
group, then reports `error.OutOfMemory`. On
Darwin, where the walk is a pass over the whole process table each time it
is asked, a child that has never forked is not walked at all: `spawn` watches
its forks with a kqueue registered before the child runs anything — a
`posix_spawn` child starts suspended until then, a fork child waits before its
`execve` — so its stop is the signal alone, and one fork, however early, puts
it back on the walk. After exit, that same proof skips the final group enumeration for a leaf; a forked tree still pays the held exit check and repeated group force to catch a late fork. The watch is one descriptor per child, closed by `deinit`.
On Linux the pass reads every process's `/proc` record, and before it `kill`
reads the child's own `/proc/<pid>/task/<tid>/children`, one small file per
thread: a child with no child of its own is signalled alone. Either way a
`.kill` looks again after the signal, and a child made while it was being
sent puts the stop back on the walk.

**Two ways to start a child on POSIX, and the same child either way.** A spawn
that needs nothing done between the fork and the exec is handed to
`posix_spawn`, which does not copy the parent's page tables.
Everything that can only be done in a fork child sends the spawn back to the
fork — `credentials` and `resource_limits`, which a process sets on itself;
`cwd`, `Stream.close`, a caller's file at descriptor 0, 1 or 2, an
`extra_fds` file at a number one of them is placed at, and `fd_policy =
.close_all`. A detached child on a pseudo-terminal takes `posix_spawn` on
Linux: `POSIX_SPAWN_SETSID` makes the session, and the terminal's name opened
without `O_NOCTTY` in that session makes it the controlling one, as a session
leader's first terminal open does there. On macOS and the BSDs it keeps the
fork: a terminal becomes controlling there only through `TIOCSCTTY`, an ioctl
no file action can make. The fast path runs on Linux and macOS, which are the
systems the suite runs on; the BSDs number the attribute flags differently and
keep the fork. A child put in a
cgroup of its own on Linux is forked too (above). `zig build test
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
`fork` elsewhere in the program still can. `Pty.open` passes `O_CLOEXEC` to
`posix_openpt`, which glibc, musl, Darwin and FreeBSD take, and marks the
master in a second call only where the system refuses it. A descriptor the
*caller* opened without the flag is the caller's, and `fd_policy` is how to
say the child should not have it.

**Allocation.** `Child.spawn` and `spawnShell` take an allocator and retain the
child's lifecycle until `deinit`; that allocator must outlive the child. The
argument, environment and search-path arrays exist only for the spawn call.
`InputWriter` keeps its state and queue until `deinit`. `Child.output` allocates
the bytes
it collects and `environ` the map it returns; both say whose they are.
`Child.exchange` allocates what `output` does, one call at a time, and copies
none of its input.
The descendant walks of POSIX signalling and `killRecorded` use the bounded
workspace the kill section describes. Recorded
cgroup handles use fixed storage and allocate nothing. `Orphans` keeps its
lists with the allocator it is given until `deinit`, from spawns on any
thread, so that one must be thread-safe. Every other heap allocation made by
the package uses an allocator the caller passed, with two exceptions that run
on tasks of their own: `Reaper.enableSubreaper` makes its `Orphans` and their
lists from `std.heap.page_allocator`, and so does the Darwin lineage observer
of a contained spawn. `Pty.open` retains its allocator
for Windows geometry until every end of the pair closes; POSIX uses no
allocation. `spawnShell` forwards its allocator, which must outlive the
Shell on Windows. Other operations use
fixed or caller supplied buffers, `Expect` included.

**Thread safety.** One task at a time per `Child` or `Pty`, except `Pty.resize`,
which is one call; `Reaper`, which exists so a wait can be in flight while
another task works; and `Child.output`, which reads two streams at once. An
`InputWriter` serializes its queue and writes on one task of its own. A child
is reaped once however many tasks ask: the right to be inside the
system's wait is taken with an atomic, and whoever has it publishes the term to
the rest — so `killWait` is legal while a `Reaper` runs, which is the sequence
the `Reaper` exists for. A separate identity claim covers the whole descendant
walk and signal delivery, and the final reap and Windows handle closure. A
wait observes the exit without holding that claim, so it can still be stopped;
once reaped, its process or group id is never used for signalling again.
Darwin waits retain exit notes on the fork watcher registered before the child runs, avoiding a sleeping retry when a later registration would be refused.
Output collection borrows that watcher too; it keeps the identity check and owned bytes while avoiding another registration or reader tasks for an already-exited child.

## API

Every wait with a bound takes a `std.Io.Timeout`, and `.none` waits as long as
it takes; `conduit.Deadline.within(span)` is a timeout of `span` on the awake
clock, the one conduit's own waits count on. A grace, a drain or an interval
is a `std.Io.Duration`. Each function that allocates takes the allocator as
`gpa`, and a value that keeps it frees with it in `deinit`.

### `Pty` — a pseudo-terminal pair

| | |
|---|---|
| `Pty.open(gpa, options)` | A new pair. `options`: `rows`, `cols`, `x_pixel`, `y_pixel`, and on Windows `console`. |
| `pty.readHandle()`, `pty.writeHandle()` | The master, as two handles: the same descriptor twice on POSIX, the two pipes of a pseudoconsole on Windows. `null` once closed. |
| `pty.readFile()`, `pty.writeFile()`, `pty.master()` | Either end, or both, as `std.Io.File`s sharing the handle rather than duplicating it. |
| `pty.slaveHandle()` | The terminal end: a descriptor on POSIX, an `HPCON` on Windows. `pty.slaveFile()` is POSIX only. |
| `pty.resize(size)`, `pty.size()` | The window size. `size` borrows the pair; it and `resize` share the Windows geometry owner and are safe while another task reads or writes. |
| `pty.consoleOptions()` | Windows only: which of `OpenOptions.console` the system granted. `win32_input` for keys a terminal encoding cannot spell, `passthrough` for the child's own bytes rather than the console host's redraw of them, `resize_quirk` for a resize that does not reflow. A Windows too old for one of them refuses the whole call, so `open` asks again without it. |
| `pty.close(io)` | Everything. Idempotent, and correct after either of the next two. |
| `pty.closeSlave(io)`, `pty.closeMaster(io)` | One end. The two systems want `closeSlave` at different moments — see Design. |

### `Child` — a child process

A `Child` is a handle to its lifecycle: its fields are private, copies name
the same child, and exactly one of them is deinited, never while
another task uses it. `processId` and `result` are safe
to read while a wait or Reaper runs.

| | |
|---|---|
| `Child.spawn(gpa, io, options)` | Start it. `gpa` owns the lifecycle until `deinit` and must outlive the child. |
| `child.processId()` | A numeric process id on either platform, or `null` after retirement. A snapshot; `kill` holds the identity through signalling. |
| `child.stdinFile()`, `child.stdoutFile()`, `child.stderrFile()` | Borrowed `std.Io.File`s: the pipes, or for input and output the master of a child on a pair. The `Child` keeps owning its pipes, and the `Pty` its master. |
| `child.takeStdin()`, `child.takeStdout()`, `child.takeStderr()` | Transfer a created pipe to the caller, who closes it. A pair has no pipe to transfer. |
| `conduit.readAvailable(io, file, buffer)` | What a taken pipe holds now, without waiting for more; 0 once nothing is left at this moment. After the child ends, reading until 0 takes the rest of what it wrote, even while something it started still holds the pipe open. |
| `child.closeStdin(io)` | Half-close: the child reading to end of file stops waiting on you. |
| `child.inputWriter(gpa, io, options)` | Transfer stdin to an `InputWriter` on its own task. `options.max_backlog` bounds queued and in-flight bytes together. |
| `child.terminalMaster()` | The master, for a child spawned on a pair. Borrowed from the `Pty`. |
| `child.stdinWriter(io, buf)`, `child.stdoutReader(io, buf)` | The same, as `std.Io` reader and writer interfaces. |
| `child.expect(buf)` | An `Expect` over both directions, or `null` if this process holds only one. |
| `child.output(gpa, io, options)` | Run to the end and collect it: a cap, a timeout, a bounded drain, both streams read on their own tasks. |
| `child.exchange(gpa, io, input, options)` | `output` with `input` written alongside and then closed, under one deadline over the input, the run, the reap and the drain. `input` is borrowed and never copied; input the child does not read is not an error; the allocator need not be thread-safe. |
| `child.wait(io)` | Blocks on the child's exit handle, then reaps when signalling has let go of its identity. |
| `child.result()` | The synchronized result without reaping: `null` before publication, the term afterwards, or `ReapedElsewhere` if the status was taken outside conduit. |
| `child.tryWait()` | Never blocks. `null` while the child runs. |
| `child.finish(io)` | Ends an unfinished contained scope and confirms it ended, reporting what the cleanup met. The child stays valid either way, so a failed call can be made again, and `deinit` is still owed. |
| `child.containment(buffer)` | Copies the detached group, private Linux supervisor identity and optional cgroup path, inode and boot id. The path borrows your buffer; the record owns no handles and survives retirement and deinit. |
| `child.holdReap()` | The right to reap the child, taken and held — `null` if another task has it — for a caller that waits for the end its own way and reaps afterwards, as `Reaper` does. `HeldReap.wait(io)` reaps; `release()` gives it back. |
| `child.waitTimeout(io, ms)` | Reaps it if it ends in time; `null` if it does not, and it is still running. Waits on a handle the system makes ready the moment the child ends — a `pidfd`, a kqueue registration — and asks again on a growing interval where there is neither. |
| `child.kill(signal)` | `.interrupt`, `.terminate` or `.kill`, aimed at what the child started and not only at the child: on POSIX the process group of a detached child and a walk of its descendants; on Windows a console control event to a detached child's group, and for `.kill` — or `.terminate` with no group — the job object. On Windows, `.interrupt` without a group is `error.Unsupported`, there being nothing to fall back to that would mean the same thing. On POSIX any other signal goes the same way: `.hangup`, `.quit`, `.user1`, `.user2`, `.stop`, `.@"continue"`, `.window_change`, or `.{ .posix = .ALRM }` for one by number. Only the first three end the tree with the child; the rest leave it to `descendants`. Windows refuses each of the others with `error.Unsupported`, as POSIX does a number it does not define. |
| `child.killWait(io, grace)` | `.terminate`, the grace, `.kill`, a reap. |
| `child.waitTree(io, ms)` | Waits for the container the child was put in to hold no process at all, which is the question `wait` does not answer — a child that exits having started something is a tree that is still running. Windows: the job object. Linux: the child's own cgroup, woken by `cgroup.events` rather than asking again; a child given none is `error.Unsupported`. A compile error on the other POSIX systems, which have nothing to ask. |
| `child.deinit(io)` | Closes owned resources and leaves the child undefined. A contained scope `finish` has not confirmed is killed and reaped first, with nothing reported. Supplied streams stay open. |

`Child.Output` owns the collected bytes until `deinit()`. `stdout()`
and `stderr()` borrow them; `takeStdout()` and `takeStderr()` transfer them
for the caller to free with the allocator that collected them. `term()`, `timedOut()`,
`stdoutTruncated()` and `stderrTruncated()` copy the result facts. `deinit`
frees what was not taken and leaves the value undefined. `Output.init(gpa, parts)`
makes one from bytes the caller allocated.

`conduit.Cgroup` is the cgroup a Linux child holds. Both cgroup handle types
keep their descriptors in private fields and allocate nothing. `cgroup.id()` gives its
directory identity. `Cgroup.openRecorded(path, id)` returns a separate
`Cgroup.Recorded` handle only when the saved inode matches. It holds both the
cgroup and its parent by descriptor, and copies only the final name into a
fixed buffer; it allocates nothing. `recorded.remove()` checks the name's
inode through that parent and removes an empty cgroup with `unlinkat`;
`recorded.close()` tries removal and closes both descriptors. A replacement
between the inode check and `unlinkat` can still change the final entry.
The caller must also compare the boot id saved with the inode:
`conduit.bootIdentity()` is this boot's, read whole and checked, and
`conduit.parseBootIdentity(bytes)` checks one read back from a record; a record
whose boot is not exactly a UUID proves no boot. On systems without cgroups,
`openRecorded` returns `null`, and `bootIdentity` is `null` everywhere but Linux.

`conduit.succeeded(term)`, `exitCode(term)`, `signalName(term)` and
`signalNumber(term)` say what a `Term` holds without matching on it;
`shellStatus(term)` says it as a shell's `$?` does, the exit status's low byte
or 128 and the signal's number. `Term` belongs to conduit: `exited` is
`u32`, preserving the full Windows exit code and the POSIX exit byte.
`signalName` is `null` on Windows, where a process reports an exit code however
it ended: 1 when `killWait` had to terminate it, and otherwise whatever the
child itself exited with, including the system's control-exit status.

`SpawnOptions`: `argv`, `cwd`, `environ` (a `*const std.process.Environ.Map`),
`stdio`, `detach`, `stderr_to`, `path_search`, `credentials`,
`resource_limits`, `fd_policy`, `extra_fds`, `job_limits`, `parent_death_signal`, `descendants`.

`descendants = .survive` is the default on every platform. Once the child
exits normally and is reaped, `deinit` leaves what it started alone. This
includes a nonzero exit status: it is still a normal exit. A git helper can
start a credential-cache daemon, return, and release its `Child` while the
daemon keeps serving later invocations. Windows clears only the job's
kill-on-close flag at the reap, retaining its resource limits; if that call
fails, the wait reports the error and can be retried. Reap before deinit.

Set `descendants = .contain` when the descendants belong to the child's
lifetime. POSIX makes a private process group even with `detach = false`,
isolating the child from the parent's terminal signals. Every wait path,
including `output` and `Reaper`, follows the same policy.

| Platform | Containment after normal exit |
| --- | --- |
| Linux with a writable cgroup | A private supervisor ends the cgroup and reaps its root and adoptees before completion. It also contains descendants that leave the cgroup. |
| Linux without a writable cgroup | A private supervisor is the subreaper of this child alone. Normal exit, force and loss of the caller end and reap its tree, including detached orphans. |
| macOS | Observation of lineage, without kernel enforcement. Ends the private group and observed descendants before reaping. The measured fork/registration window can let a fork followed by parent exit escape: 0/100 escapes with no added delay and 100/100 with a 20 ms observer delay in one run; counts depend on scheduling. |
| Windows | The Job Object retains descendants across separate consoles and intermediate exits; every contained wait ends its members and confirms zero active processes and the Job termination notification before returning the root status. |
| Other POSIX systems | Ends the private group before reaping; descendants that leave it can escape. |

On Linux, each contained child has a private supervisor process. It becomes a
subreaper before starting the root; neither the caller's process setting nor
another child's ownership changes. The root's pid remains `processId`, and
its exact exit code or signal remains the wait result. Its parent is the
supervisor, in its own session and process group. Application group signals
cannot stop it; a catchable stop sent directly to it ends its scope. The
supervisor holds the root unreaped while ending and reaping
all adoptees, including each new generation adopted during cleanup. It uses
signalfd and the caller's command socket while idle, without a polling timer.
All cleanup descriptors are reserved before the root runs; cleanup allocates
nothing. Startup failure refuses the spawn. Lost supervisor status is
`Unexpected`, never an invented root exit.

A force ends the cgroup first where one is writable, then the adoption scope.
An interrupt or termination request reaches the root's group and adoptees,
and the other cgroup members where available. `Reaper.kill` supplies the
root's grace. Once the root exits, remaining descendants are forced at once;
`tree_grace` governs `end_tree` on children with the survival policy.
The caller holds one socket, closed on exec and closed in the root. Loss of
that socket ends the scope even if the caller crashes. The root watches its
supervisor with a parent death `SIGKILL`; this contained policy takes precedence
over `parent_death_signal`. `Child.finish(io)` ends and reaps an unfinished contained scope and
reports what that met; failure retains ownership for another call. `Child.deinit(io)`
does the same for a scope not yet confirmed, and reports nothing.

The supervisor has [tini's](https://github.com/krallin/tini) single-root signal
forwarding and zombie ownership, with scope completion like
[systemd's mixed kill policy](https://github.com/systemd/systemd/blob/main/man/systemd.kill.xml):
a root exit also ends the remaining members. It needs readable procfs,
subreaping and signalfd, but no cgroup delegation or PID namespace. Deliberately
killing the supervisor from outside the library can defeat its adoption scope;
a writable cgroup remains the kernel containment reach in that case.

`containment` copies the supervisor's pid, start time and boot in `supervisor`,
beside the root's group and optional cgroup facts. Save that complete record.
`killRecorded` with its `supervisor` field verifies this identity through a
pidfd and asks it to empty its scope. It never kills the adoption owner before
the tree is reaped, and reports `UnableToEnd` if that completion cannot be
established. A missing recorded supervisor does not authorize a root-group
sweep; a separately verified cgroup can still be ended and removed.

On macOS, a contained spawn holds the root before exec until its lineage
observer is running. One task owns a kqueue with `NOTE_FORK`, `NOTE_EXEC`
and `NOTE_EXIT` on every known descendant. Fork notes give no child id:
the task promptly asks `proc_listchildpids`, captures and proves each edge
through process unique ids, registers the child before expanding it, and
retains that identity across exec and reparenting. Final cleanup uses audit
tokens, so a recycled pid never authorizes a signal. The observer allocates
from its own page allocator; it does not use the caller's allocator from
another thread. Startup failure refuses the spawn; an observation failure
ends the held root and makes the wait fail with `Unexpected`.

This is observed lineage, not a kernel container. A parent can fork and
exit before the observer discovers or registers its child, including while
cleanup runs. That child and an unobserved branch below it may escape.
No names or scans of init's children are used to guess the lost edge.
The native test measures immediate double-forks and repeats them with a
controlled observer delay; successful runs do not prove the race absent.

Linux subreaping is explicit: call `reaper.enableSubreaper()` before spawning
into the Child address passed to `Reaper.init`, then call `start`. It needs
Linux 5.4 or later and readable procfs. One Reaper owns the process setting;
a second owner, including `Orphans.start`, is refused with `AlreadyStarted`.
Cgroups remain the first reach where writable. With containment, Reaper ends
and reaps all adopted orphans before publishing its completion. While waiting,
an independent task collects and reaps exited adoptees every 5 ms, including
while another task owns the root wait; scheduling and procfs access can extend
that interval. Adoption lookup failure makes
Reaper fail with `Unexpected` rather than report complete containment.

The scope is process-wide, not per child: Linux records no former parent
for an adopted orphan. Every orphan below this process belongs to this one
owner, including orphans from other direct children. Existing direct children
and new conduit children retain their independent waits. Every new direct
child must use conduit while the scope runs; an outside spawn or a
`SIGCHLD` handler using `waitpid(-1)` breaks that ownership. End and reap
all direct children before the owner's `stop`, which ends remaining
adoptees and restores the previous subreaper setting. `Reaper.stop` and
`Orphans.stop` are fallible. Cancellation, lookup or restoration failure
retains the scope for another call; `DirectChildrenRemain` refuses to restore the
attribute while another direct child still owns a wait. Handle these failures
before `deinit`, which cannot fail and leaves the owner undefined. This explicit process-wide scope is
separate from each contained child's private supervisor.

`reaper.adoptionRecords(out)` copies the explicit scope's `Orphans.Record`
values without lending its owner. `reaper.adoptionEvent(io)` and
`reaper.adoptionCount()` provide the same notification and reset handshake as
Orphans. Register before start, snapshot, reset and compare the count to avoid
losing a concurrent adoption. These records belong to the scope as a whole;
they never claim a former child as their parent.

Timeouts in `output`, output errors, `kill` and `killWait` still end the tree
in either mode, within that same reach. `waitTimeout` remains an observation:
a null answer does not end the child. Explicit `Reaper.end_tree` still ends
survivors. A signal request followed by a normal exit does not release the
survivors as though the child had completed on its own.

`stdio` is `.{ .pty = &pty }`, `.{ .pipes = .{ .stdin, .stdout, .stderr } }`,
`.inherit`, `.ignore`, or `.{ .streams = .{ .stdin, .stdout, .stderr } }` —
each of those three being `.inherit`, `.{ .file = f }`, `.ignore`, `.pipe` or
`.close`. `.{ .file = pty.slaveFile() }` gives a child the terminal end of a
pair for one stream and something else for the others, on POSIX.

`detach` puts the child out of reach of signals aimed at the parent's process
group. On POSIX with `.pty` it is a session of its own with the pair as its
controlling terminal — `setsid` plus `TIOCSCTTY` in a fork child, or on Linux
`POSIX_SPAWN_SETSID` plus the terminal opened by name — otherwise
`setpgid(0, 0)`. On Windows
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

`extra_fds` gives the child more files than its standard three, in order:
the first at descriptor 3, the next at 4, as Go's `ExtraFiles` does — a
listening socket handed over the way a service manager hands one, or a pipe
for a status protocol. They are borrowed, given whatever their close-on-exec
flag, and placed correctly whatever numbers they already have, including the
numbers they are placed at. `.close_all` closes what is above them. Windows
numbers no descriptors: each file goes to the child as an inheritable
duplicate named in the handle list, and in the table of inherited
descriptors the Microsoft C runtime reads from the startup record
(`lpReserved2`), so a child on that runtime — `cmd.exe`, Python, Node — has
them at 3 and up, as libuv arranges for Node's extra stdio. A child on no C
runtime finds them with `GetStartupInfoW`. With `.pty` it is
`error.Unsupported` there, as `stderr_to` is.

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
`error.Unsupported`. `cpu_rate` is hundredths of a percent of the whole
machine's processor time, from 1 through 10,000; an out-of-range value is
`error.InvalidJobLimit`.

### `InputWriter` — bounded input for a child

`writer.isOpen(io)` takes an uncancelable snapshot of whether input is still
accepted, even when the backlog is full. A later `queue` checks again.

```zig
var input = try child.inputWriter(gpa, io, .{ .max_backlog = 1024 * 1024 });
defer input.deinit(io);
try input.queue(io, "first\n");
try input.queue(io, "second\n");
try input.close(io);
// Read output while the input task writes, so neither pipe waits on the other.
var result = try child.output(gpa, io, .{ .timeout = conduit.Deadline.within(.fromSeconds(5)) });
defer result.deinit();
try input.wait(io);
```

| | |
|---|---|
| `input.queue(io, bytes)` | Copy all bytes in order, or accept none. `BacklogFull` refuses the write without waiting for the child to read. |
| `input.close(io)` | Refuse further input with `InputClosed`, then close the pipe after everything already queued. Idempotent. |
| `input.wait(io)` | Wait for pipe closure and return its delivery result. Canceling a waiter leaves delivery running. |
| `input.cancel(io)` | Abandon pending bytes, interrupt a blocked write and join the task. Later calls return `Canceled`; an earlier failure or completed delivery stays final. |
| `input.deinit(io)` | Cancel, join and free. Stop the other callers first. Idempotent. |

The writer owns the stdin pipe after successful construction; `child.stdinFile()`
is then null. Startup failure leaves it with the child. Only a separate pipe
can be transferred: a child on a terminal is `NoStdinPipe`. The writer does
not borrow the child. Its allocator and Io must outlive it, and an earlier
copy of stdin must no longer be used. Move it before sharing and never copy
it. Queue, close and wait may run on several tasks; cancel has one caller at a
time. The writing task alone writes and closes the pipe, with no mutex held
across a write. The first write failure is returned to later callers too.

The bound counts accepted bytes until their whole batch is written to the
pipe, including the batch the task has taken. It does not count bytes already
in the operating system's pipe or say when the child consumed them. Allocation
metadata is additional. A zero bound accepts only empty writes. Calls using
the writer's allocator are serialized.

[Tokio's `ChildStdin`](https://docs.rs/tokio/latest/tokio/process/struct.ChildStdin.html)
is an asynchronous pipe writer; [Go's `StdinPipe`](https://pkg.go.dev/os/exec#Cmd.StdinPipe)
returns an `io.WriteCloser`. Both leave queueing to the caller. `InputWriter`
adds a byte bound, a task that delivers the queue, and a close ordered after
the accepted bytes, so a caller can answer a CLI while holding its own lock
without waiting for that CLI to read.

### `Expect` — a conversation with a child

Its fields are private; create it with `init` and observe bytes through
`pending`, `until`, `untilAny` and `bytes`. A lifetime permits one successful
start; a start after `stop` is `AlreadyStarted`, even if no reader ran.

| | |
|---|---|
| `Expect.init(master, buffer)` | Over `Child.terminalMaster()` or `Pty.master()`, with a buffer the caller owns. |
| `expect.start(io)`, `expect.stop(io)`, `expect.deinit(io)` | The one reading task, which runs between calls. `stop` ends it for good and can be called again; `deinit` stops and leaves the value undefined. A second `start` is `error.AlreadyStarted`. |
| `expect.until(io, pattern, timeout)` | Waits for a literal byte pattern and consumes through it: `Match.before` and `Match.found`. |
| `expect.untilAny(io, patterns, timeout)` | Waits for any of several. The earliest match wins, whatever order they were listed in; `Match.index` says which, and the ones that lost stay pending. |
| `expect.bytes(io, count, timeout)` | Waits for a count of bytes and consumes them. |
| `expect.send(io, reply)` | Writes the reply, as if it had been typed at the child's terminal. |
| `expect.pending(io)`, `expect.discard(io)` | What has arrived and no pattern has matched; and forgetting it. |

A wait ends in `error.Timeout`, `error.EndOfStream`, `error.BufferFull` or
`error.ReadFailed`, and — like every call here that can be in flight — in
`error.Canceled`.

### `conduit.environ` — a child's environment

`environ.inherit(gpa, &.{ .{ .name = "TERM", .value = "xterm-256color" } })`
is this process's environment with those changes, as a map the caller owns; a
`null` value removes the variable rather than emptying it.
`environ.only(gpa, …)` takes the same list and inherits nothing, for a
child that should not see an agent socket or a token. `path_search` says
which `PATH` resolves the program: `.child_environ` (the default, what a shell
does), `.parent_environ` (what `std.process.spawn` does) or `.none` (the path
as supplied, relative to the child's working directory when relative).
On POSIX a missing `PATH` uses the default directories; an empty `PATH`
searches the child's current directory. Windows still checks its fixed
program directories without a `PATH`. On Windows conduit resolves a bare program
against the child environment before `CreateProcessW`, whose own search would
otherwise use the parent's `PATH`; the other two modes are `error.Unsupported`
there.

`parent_death_signal` (`.interrupt`, `.terminate` or `.kill`) is sent to the
child when the thread that spawned it ends, however it ends: Linux's
`PR_SET_PDEATHSIG`, and `error.Unsupported` anywhere else. Where there is no
such thing, a program that must not leave children running behind a crash
writes down each child's pid and `conduit.startTime(pid)`, and the next time
it runs uses `conduit.killRecorded` to end what it can still prove belongs to
that process. A recorded cgroup reaches the complete Linux tree.
`conduit.captureStarted(pid, start)` holds such a process by a pidfd on Linux
and a stable unique process id on Darwin, taken before the start time is checked (Linux)
or with it in one lookup (Darwin), so the signal it sends reaches that
process or nothing; it is `null` for a start time that does not match.
`conduit.processExists(pid)` says whether any process has an id now, on POSIX
and Windows; one that has ended but is not yet reaped still has it, and a
reused id is told apart only by the start time written down beside it.
`CapturedPid` exposes no token or handle. `captured.processId()` reads its
number for reports. Release it exactly once with `deinit`; do not copy an
owning capture. Darwin checks the stable unique id on every lookup, so exec
keeps the identity while a reused PID cannot provide a new audit token.
`captured.signalDescendants(sig, in_group)` walks its descendants only while
the captured root is still the same process, including after the walk.
`captured.signalGroupSince(group, start, sig)` reaches a recorded Linux
leader's group while that leader is still held. On Darwin it reaches a
captured session leader's group through audit tokens: no process outside a
new session can join it. For an ordinary group in an existing session it
returns `error.Unsupported`, since another process there can join the group.
`captured.wait(io, timeout)` waits for its process to end without reaping
it. `recorded.waitEmpty(io, timeout)` waits for a recorded Linux cgroup to
empty. Both return `true` when done and `false` at the deadline.
`conduit.killRecorded(io, .{ .pid, .start, .group, .cgroup, .grace })`
asks a recorded process and its provable descendants to end, waits the grace,
then forces survivors. Pass `&recorded`, from `Cgroup.openRecorded`, for a
complete Linux tree, including orphans. Without one, an unproven group member is left
alone and reported as `error.Unproven` on Linux; Darwin reports
`error.Unsupported` for a requested group after ending provable processes,
since a member cannot be held after the leader's exit by this call.

`conduit.findProgram(gpa, io, environ, name)` is where `spawn` would
find `name` for a child given `environ`, by the same rules, or `null`: for a
program that asks whether something is installed, to say so. `spawn` does not
need it and searches for itself — resolving a name and then starting what it
resolved to is two steps, with room between them for the answer to change.

### `spawnShell`, `Reaper`, `Proxy`

`spawnShell(gpa, io, options)` returns a `Shell`: a `Pty` and a `Child`,
with a terminal emulator's defaults — `$SHELL` or `%COMSPEC%`, 24×80, `TERM`
set, a controlling terminal on POSIX — absorbing the `closeSlave` timing
difference below.

A survivor ledger saves `child.processId().?` as its key and
`try child.containment(&path_buffer)` as its containment record before starting
Reaper. Keep that key, record and path buffer independently of the Child,
through retirement; remove the ledger entry with the saved key. A numeric key
never authorizes a signal.

`Reaper.init(&child, options)` and `start(io)` put the wait for a child on a
task of its own; `exit()` answers a `Child.WaitError!?Term` without blocking,
and `wait(io)` and `waitTimeout(io, timeout)` wait for the answer on an event the
task sets, so nothing asks the system again and again. `kill(io, grace)`
asks the child and what it started to end and makes them once the grace has
passed, and returns at once: the grace is spent on the `Reaper`'s task, so a
caller holding a lock can kill a child. On POSIX its held reap ends the
remaining owned group or cgroup before releasing the root identity, spending
the remainder of that same grace. `stop(io)` and `deinit(io)` end the task; on POSIX
the wait is on the child's `pidfd` or kqueue registration beside a pipe
they write to, so it goes at once whether or not the `std.Io` can cancel
a system call. The `Child` must not be deinited while it runs, the `Reaper` must not move
once started (safe builds assert it on each call), and a wait error is final
and returned by every later `exit()`. Its fields are private.
Only one successful start is allowed per lifetime; another start, including
after `stop`, returns `AlreadyStarted`. A concurrency failure releases
its resources and may be retried before `stop`. Release every HeldReap
exactly once, and join Reaper before destroying its Child.

`Options.end_tree` ends what the child leaves running when it ends by itself,
before it is reaped. On Linux, for a child in a cgroup of its own (below),
detached or not: what is still running in the cgroup is sent `SIGTERM`, given
`tree_grace`, then ended with `cgroup.kill`, wherever its group and session
went. On POSIX otherwise, for a detached child: what is left in its
process group is sent `SIGTERM`, given `tree_grace`, then `SIGKILL` — while
the ended child, not yet reaped, still holds the group's id, so the signal
cannot reach a group that has been given the same number since. On Windows the
job is ended as soon as the child is reaped. The term published is the
child's own.

`Orphans` keeps its fields private; `init`, `count`, `list`, `adoptionEvent` and
`adoptionCount` provide construction and observations. It must not move once
started, which safe builds assert on each call.

`Orphans.init(gpa)` and `start()` make this process, on Linux, the
parent of every orphan below it (`PR_SET_CHILD_SUBREAPER`): a daemon a
child left, a grandchild that forked twice and called `setsid`. Nothing
runs for it — no task, no timer: whenever conduit reaps a child or spawns
one, it also takes in the new orphans and reaps the ended ones. `count()`
does the same on demand and says how many are left. `list(out)` copies
`Orphans.Record` values with `pid`, `start`, `group` and `session`, copied from
one process snapshot under pidfd and reap ownership during adoption. It
reports `IdentityUnavailable` if that snapshot could not be read. Retain
these facts and the boot identity for a later `captureStarted` or
`killRecorded`; records own no handles. `killAll(io, grace)` ends them all through a pidfd
each — `SIGTERM`, the grace, then
`SIGKILL` — for the end of a program. `try stop()` restores the attribute
after every direct child and adoptee has been reaped; failure retains ownership for another call, and `deinit()` follows success.
Opt-in, and only for a program that starts every child through conduit
(below). `error.Unsupported` elsewhere.

`Proxy.run(io, .{ .master, .input, .output, .input_buffer, .output_buffer, .resize })`
moves bytes both ways until the child's end of the terminal closes, and keeps
the pair the size of a terminal of yours. Both buffers must be non-empty;
otherwise it returns `error.BufferTooSmall`.

### Terminal helpers

`conduit.console` exposes Windows `InputRecord` and `KeyEvent`, with
`keyDown()`, `waitInput(io, handle, timeout)`, `peekInput(handle, buffer)` and
`readInput(handle, buffer)` for programs reading console input records.

`rawMode(handle)`, `restore(handle, saved)`, `winSize(handle)`, `isTty(handle)`,
and — POSIX only — `setWinSize(handle, size)`, `ttyName(handle, buffer)` and
`foregroundGroup(handle)`, which asks not whether a handle is a terminal but
whether anything is running *on* it. They take a handle rather than a
`std.Io.File`: none of them is an operation `std.Io` abstracts. A Windows
console is two handles with two unrelated sets of mode flags, so `rawMode` is
called once for each and works out which it was given, and `winSize` wants the
output one.

`openControlling(io)` opens the process's own terminal rather than its standard
streams: `/dev/tty` on POSIX, `CONIN$` and `CONOUT$` on Windows, as one
`Controlling` with an `input` and an `output` file. `conduit.console` also
carries `CreateFileW` and `WriteFile` for Windows code that writes to the
console with no `std.Io` to hand, a panic handler among it.

`rawMode` and `restore` take effect at once and throw away input nobody read;
neither waits for the output to drain, so a terminal that has stopped reading
cannot hold a program there, on its way out or in a panic.

For a program's own wait on its terminal, POSIX only: `pipe(.{ .nonblocking = true })`
is a pipe with both ends close-on-exec, for a wake such as a resize. Darwin
has no `pipe2`, so there it is two calls, made under the lock conduit's own
spawns take, and no child conduit starts is handed it unmarked. A program
gets that only if it and its dependencies build one conduit.

`Deadline.fromTimeout(io, timeout)` turns a `std.Io.Timeout` into a deadline (`Deadline.of` makes `.none` one that never comes, and `Deadline.in(io, span)` is one `span` from now),
and `remainingMs(io)` or `windowsMs(io)` (never `INFINITE`) says what is left
for a system wait that counts whole milliseconds, rounded up, so the wait does
not end with time still left.

These are also a module of their own, `conduit.tty`, for a program that draws
its own screen and runs no child:

```zig
exe.root_module.addImport("conduit.tty", conduit.module("conduit.tty"));
```

On Linux it makes no call through libc, so importing it alone links no C
library; `conduit` itself imports it.

## Scope

- **No terminal emulation.** `Proxy` moves bytes; nothing here parses an escape sequence or keeps a screen.
- **No command splitting.** `argv` is a list, and turning one string into several is a shell's grammar.
- **No job control.** `foregroundGroup` answers the question; `tcsetpgrp` is the caller's call to make with the group id saved from `child.processId()` for a detached child.
- **No pattern language.** `Expect` matches byte strings.
- **No pre-exec callback.** Only async-signal-safe calls are legal there, so the uses people reach for one for are named options instead.
- **No `.bat` or `.cmd`.** `spawn` returns `error.UnsupportedBatchFile`, because the command interpreter re-parses their command line with rules no serialisation survives.

## Platforms

| | Mechanism | Suite |
|---|---|---|
| Linux (glibc) | `posix_openpt`, `posix_spawn` or `fork` and `execve`; a cgroup v2 where writable and a private supervisor per contained child; opt-in process subreaper (`Orphans`, 5.4) | `ubuntu-latest`, and once more as root, where a cgroup can be made |
| Linux (musl) | the same | `ubuntu-latest`, built for `x86_64-linux-musl` against Zig's own musl |
| macOS | the same | `macos-latest` |
| Windows | `CreatePseudoConsole` and `CreateProcessW` | `windows-latest` |
| FreeBSD, NetBSD | as Linux | cross-compiled only |

Windows 10 version 1809 is the floor: `CreatePseudoConsole` is imported
statically rather than looked up. FreeBSD and NetBSD are compiled and never
run, so what holds there is what the sources say and not what a suite has
shown.

Windows runs nowhere but the `windows-latest` runner: there is no local
Windows or emulator run. What only Windows can answer — which directory on
the search holds a program, a job ended when `Reaper.end_tree` reaps — is
shown there alone. The order that search goes in, which `findProgram` and a
spawn share, is worked out without the file system and tested on every
system.

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
program search checks the application directory, the current directory, the
system directories and `PATH`, appending `.exe`; `PATHEXT` is not searched.
With a supplied environment, conduit resolves the name against its `PATH`
before `CreateProcessW`; otherwise Windows resolves it.

## Testing

Local build scripts clear `.zig-cache/{o,h,z,tmp}` above the measured cap through preflight; run `zig build cache` before direct Zig builds (only a rebuild is lost).

```sh
zig build test                   # the suite, and the examples, which are run
zig build test -Dfork-spawn      # the same, with the posix_spawn path off
zig build test --fuzz            # the three properties, under the fuzzer
zig build unit -Dthread-sanitizer   # the suite under ThreadSanitizer
zig build examples               # the examples alone
zig fmt --check src examples build.zig
zig build test -Dtarget=x86_64-linux-musl  # on Linux: the suite on musl, linked statically
zig build install-unit -Drequire-cgroups && sudo zig-out/bin/conduit-tests
                                 # on Linux, as root: the cgroup tests, which fail
                                 # rather than skip where no cgroup can be made
```

Most of the suite starts a real child process and reaps it, and CI runs it in
Debug and ReleaseSafe on Linux, macOS and Windows, and in ReleaseFast on
Linux: the code between `fork` and `execve` is the kind an inlining decision
can change. preflight's test runner fails a test that runs past its bound,
its Io teardown included, by name and phase: preflight's default, or what
`-Dtest-watchdog-ms` sets. The suite also runs with the
`posix_spawn` path turned off, because that path is a second implementation of
one contract and running both is what says they make the same child.

Three things here read bytes the package did not write, and each is a property
`zig build test --fuzz` puts a fuzzer on: that the search behind `until` and
`untilAny` reports what a search of the whole buffer would, however the child's
output is cut into arrivals; that every candidate a `PATH` produces is an entry
of it with the program on the end; and that an argument list survives the
Windows command line it is written into, by the rules that parse it back. Each
keeps a corpus of its own under `.zig-cache/f`.

The package's own benchmarks are in `bench/`: `zig build bench` builds them,
and [bench/README.md](bench/README.md) says how to run them. CI only compiles
them.

`zig build unit` is the suite without the examples, `-Dtest-filter` runs part
of it, and `CONDUIT_TRACE` in the environment logs what this package asked
the operating system for, through `std.log` at the info level under the
`conduit` scope, which the suite prints.

## Built with

- tycho, a terminal station for coding agents (in development).

## Licence

MIT. See [LICENSE](LICENSE).
