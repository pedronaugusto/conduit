# conduit's design

The design as built: what conduit does where std or the system leaves a choice, and why. The API is
in the README; this is the reasoning behind it.

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
a task, and takes an optional reactor `Wake` a program's own handler can signal.
`SIGPIPE` too — writing to a pipe whose reader is gone raises it, and what to
do about that is the program's.

**Waits are made on the system's own handle, and every one is a cancelation
point.** A child's end is a `pidfd` on Linux, a kqueue registration on Darwin
and the BSDs and the process handle on Windows; `output` waits on that and the
two pipes in one call; a held process is its `pidfd` or the same registration;
a Windows job says in its own messages that it holds nothing.
[reactor](https://github.com/pedronaugusto/reactor) makes each wait. On a
reactor runtime it is an operation of the calling task's loop and holds no
thread. On `std.Io.Threaded`, or any other `Io`, it holds the calling thread
and looks for a cancel every few milliseconds. What the system gives nothing to
wait on is asked about on an interval: whether a group or a cgroup has emptied
during a `Reaper`'s grace, and the adoptees of `Orphans` on Linux. Two waits
are conduit's own for a reason each: `cgroup.events` is waited on for an urgent
event, and the Windows console wait lives in `conduit.tty`, which imports
nothing.

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
job's reports are attached before the child is assigned to it, and
the wait ends when the job says it holds nothing; on Linux the child's cgroup
(below) says the same in `cgroup.events`, whose change wakes a `poll`. So a
program can watch the whole tree go rather than only the child — and it has
to ask before `deinit`, which is what closes the job and removes the cgroup. POSIX, for a child with no cgroup of its own, has nothing to ask. A process group is an address to send
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
the child is born in it (`CLONE_INTO_CGROUP`, through glibc 2.39's
`posix_spawn`) or, where that is not to be had, joins it as a fork child before
it does anything else, so nothing the child ever starts is outside it. `kill(.kill)` is then one write to `cgroup.kill`
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
contained spawn takes `posix_spawn` only where the C library can start a child
in a cgroup — glibc 2.39 and later, as built for — and the fork otherwise,
since joining a cgroup is a write and there is no file action for one; this
process holds one more descriptor per child, and makes and removes one directory per child
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
`proc_listchildpids` on Darwin, one `sysctl kern.proc` copy of the table on
64-bit FreeBSD, and on the other BSDs and illumos none, where the process group
is the whole of the reach. Descendants are signalled deepest
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
`cwd` on Linux (Darwin's `posix_spawn_file_actions_addchdir_np` is a file
action that can be trusted, glibc's has a history), `Stream.close`, a
caller's file at descriptor 0, 1 or 2, an `extra_fds` file at a number one of
them is placed at, and on Linux a C library without
`posix_spawn_file_actions_addclosefrom_np` (glibc before 2.34, musl). A detached child on a pseudo-terminal takes `posix_spawn` on
Linux: `POSIX_SPAWN_SETSID` makes the session, and the terminal's name opened
without `O_NOCTTY` in that session makes it the controlling one, as a session
leader's first terminal open does there. On macOS and the BSDs it keeps the
fork: a terminal becomes controlling there only through `TIOCSCTTY`, an ioctl
no file action can make. The fast path runs on Linux and macOS, which are the
systems the suite runs on; the BSDs number the attribute flags differently and
keep the fork. A child put in a
cgroup of its own on Linux is forked too, unless the C library can start it in
the cgroup (above). `bay test
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
master in a second call only where the system refuses it.

**A child receives its three standard streams and `extra_fds`, and nothing
else**, whatever a descriptor's flag says, because the flag is not always
there: the standard library's own sockets on Darwin are made with `socket` or
`accept` and marked with a second call, and no lock of this package's reaches
that gap. The child is told which descriptors it gets. `posix_spawn` on Darwin
takes `POSIX_SPAWN_CLOEXEC_DEFAULT`, with `addinherit_np` naming an inherited
standard stream; with glibc 2.34 and later, `addclosefrom_np` closes everything
above the extras. A fork child on Linux closes them with `close_range`, one
call; one on Darwin does not `execve` but calls `posix_spawn` with
`POSIX_SPAWN_SETEXEC` and `POSIX_SPAWN_CLOEXEC_DEFAULT`, the attribute and
actions made in the parent before the fork, so no loop over every number a
process may hold is run on either system. The BSDs, cross-compiled here, use
`closefrom`.

**Allocation.** `Child.spawn` and `spawnShell` take an allocator and retain the
child's lifecycle until `deinit`; that allocator must outlive the child. The
argument, environment and search-path arrays exist only for the spawn call.
`InputWriter` keeps its state and queue until `deinit`. `Child.output` allocates
the bytes
it collects and `environ` the map it returns; both say whose they are.
`Child.exchange` allocates what `output` does, one call at a time, and copies
none of its input. `Child.exchangeInto` allocates nothing of its own: each read
lands in the caller's writer's buffer, which grows only as that writer does.
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
Output collection borrows that watcher too, waited on beside the two streams from the calling task on every system: on Windows each stream's read is an overlapped call waited on beside the process, so `output` starts no task on any `std.Io`.

## Expect: literal patterns, or the caller's matcher

std has no regular-expression engine, and a pattern language inside a process package would be a
second, worse one, so conduit ships none. `until` and `untilAny` wait for literal byte patterns
(the earliest match wins, the rest stay pending), and a caller with a language of its own (a regex,
a glob, a prompt with a counter in it) brings it as an `Expect.Matcher` to `untilMatch`. There is
one wait: `until` and `untilAny` are `untilMatch` over a literal matcher.

- `Matcher` is `context` plus `findFn(context, said, ended) ?Found`: the earliest match in `said`,
  which pattern and where. `ended` says nothing more will arrive, so a matcher can take what is
  left at the end (pexpect's `EOF`, expectrl's `Eof`). A `Found` outside `said` is the caller's
  bug, asserted in safe builds.
- `window` is how far back from the newest byte a match can begin (pexpect's `searchwindowsize`).
  With it the matcher is shown only that tail; with none it is shown everything pending on each
  arrival, which costs the length of what the child said, squared, for a match that never comes.
- The literal matcher keeps its incremental search: each arrival searches only the tail the
  longest pattern could straddle. The one cost a matcher adds per arrival is an indirect call.
  `bench/expect_match.zig` (`expect-match`) times a 1 MiB stream with the match at its end through
  the literal, windowed and unwindowed matchers.
- `untilMatch` has `until`'s results and errors: `BufferFull` when the buffer is full and nothing
  matched, `EndOfStream` when the stream ends and the matcher, asked once more with `ended`,
  found nothing.
