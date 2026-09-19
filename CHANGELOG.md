# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-09-19

Three faults a caller could not have seen coming, two waits that were a clock
rather than the operating system, and the options the two systems each have
that the other has not.

### Breaking

- `Child.TryWaitError` has a new member, `ReapedElsewhere`. A caller that
  switched over it exhaustively has one more arm to write.
- `Expect.Match` has a new field, `index`, which `untilAny` sets and `until`
  leaves at zero. A caller constructing one by literal has one more field.
- `Child` has four new fields: `reaped` and `reaping`, which have defaults, and
  `job_port` and `tree_ended`, which do not and are `void` off Windows. A
  `Child` comes from `spawn`, so this reaches only code that built one by hand.
- `Pty` has a new field, `console`, which is `void` on POSIX.

### Added

- **`Expect.untilAny`** waits for any of several patterns and says which one
  came. One pattern per call cannot express the shape every program driving
  another program has — the child will say one of three things — because three
  `until` calls race each other and whichever is asked for first eats the bytes
  the others were looking for. The earliest match wins rather than the first in
  the list, and only the bytes up to and including it are consumed, so a
  pattern that also arrived, later, is still pending for the next call.
- **`SpawnOptions.fd_policy`.** `.close_all` closes every descriptor above 2 in
  the child, whatever its flags say — `close_range` on Linux, a loop elsewhere
  — for a program that opened a socket or a lock file without close-on-exec and
  would otherwise hand a copy to every child it starts. The default,
  `.close_on_exec`, is what it always did. On Windows a child is given the
  handles named in an attribute list and nothing else, so both mean the same
  thing there.
- **`SpawnOptions.job_limits`.** `resource_limits` is a pair of POSIX types
  with no Windows counterpart and is still refused there; what was missing was
  the other half. The job object that makes `kill` reach the tree on Windows is
  where that system puts a limit, and it bounds the whole set of processes
  rather than the one: `process_memory_bytes`, `job_memory_bytes`,
  `active_processes` and a hard cap on the job's share of the processors.
  POSIX-side it is `error.Unsupported`, which is what `resource_limits` is on
  Windows; the two are different answers and neither pretends to be the other.
- **`Child.waitTree`**, on Windows: a wait with a deadline that ends when
  everything the child started has ended. `wait` answers about the child, and a
  child that exits having started a server is a tree that is still running —
  the job object every child there is put in is what knows the difference. It
  reports to an I/O completion port, associated with the job before the child
  is assigned to it, because the message that says the job is empty is posted
  on the transition and a port attached afterwards would hear nothing. `true`
  means the job holds no process any more, `false` that the time ran out, and
  it has to be asked before `deinit`, which closes both. POSIX gets a compile
  error rather than a second answer: a process group is an address to send
  signals to and nothing is accounted to it, and the descendant walk `kill` uses
  goes down from the child, where a grandchild whose parent has already exited
  belongs to `init` and is related to the child by nothing the system will say.
- **`Pty.OpenOptions.console`** asks a pseudoconsole for the three things it
  can be asked for: `passthrough`, so the child's own bytes reach the master
  rather than the console host's redraw of them — without it a cursor-shape
  sequence is simply lost; `win32_input`, so a key the terminal encoding cannot
  spell can be written to it; and `resize_quirk`, so a resize does not reflow
  what the child has already drawn. Each arrived in a different Windows and a
  version that does not know one refuses the whole call, so `open` narrows the
  ask until the system takes it and `Pty.console` is what it ended up with.
  `spawnShell` passes them through.
- **`error.ReapedElsewhere`.** `tryWait` reported `ECHILD` as
  `error.Unexpected`, which is a program with a `SIGCHLD` handler of its own,
  or `SIGCHLD` set to `SIG_IGN`, getting an unnamed error for a named
  situation: something outside this package reaped the child and there is no
  status left for anyone to report.

### Changed

- **`waitTimeout` and `killWait`'s grace wait on the operating system.** Both
  used to ask again on a growing interval — one millisecond, then two, then
  four — so a child that had ended was noticed a millisecond and a half later,
  every time, whatever the machine. Both now wait on a handle the system makes
  ready the moment the process ends: a `pidfd` on Linux, a kqueue registration
  for `EVFILT_PROC`/`NOTE_EXIT` on Darwin and the BSDs. An old kernel that has
  neither says so and the interval is asked again as before. Measured here on
  `/bin/sh -c 'exit 0'`: a blocking `wait` 2.80 ms, `waitTimeout` 4.34 ms
  before and 2.71 ms after.
- **A spawn that needs nothing done between the fork and the exec is handed to
  `posix_spawn`.** `fork` copies a process's page tables and the cost grows
  with what the parent has mapped; `posix_spawn` describes the child with file
  actions and attributes instead. Measured here over a thousand spawns of
  `/usr/bin/true` on the null device: 1336 µs a spawn through `fork` and
  `execve`, 946 µs through `posix_spawn`. Everything that can only be done in
  a fork child sends the spawn back to it — a pseudo-terminal, `credentials`,
  `resource_limits`, `cwd`, `Stream.close`, a caller's file at descriptor 0, 1
  or 2, and `fd_policy = .close_all` — and the child is the same child either
  way, down to the signal dispositions it starts with. Linux and macOS take
  the fast path; the BSDs number the attribute flags differently, are
  cross-compiled rather than tested here, and keep the fork. `zig build test
  -Dfork-spawn` runs the whole suite with it turned off, and CI does that too.
- **`tryWait` answers `null` while another task holds the wait.** A `Reaper` is
  the one that reaps then, and taking the status out from under it is the thing
  that must not happen. A `null` was always a snapshot; that is the one case
  where it can be a moment out of date.
- **`Child.term` is read through `tryWait`.** It is written once, by whichever
  call reaps the child, and published through an atomic — so a plain read of
  the field from another task is a race, and `tryWait` is the read that is not.
- **Two build flags, both for saying the same thing twice.**
  `-Dfork-spawn` runs the suite with the `posix_spawn` path turned off, because
  that path is a second implementation of one contract and running both is what
  says they make the same child. `-Dthread-sanitizer` builds the tests with
  ThreadSanitizer; the handshake between a `Reaper` and the owner of a `Child`
  is the one thing here a race detector can check rather than a reader, and the
  suite runs clean under it.
- **Three properties, under a fuzzer.** `zig build test --fuzz` runs the three
  things here that read bytes this package did not write: the search behind
  `until` and `untilAny`, which has to report what a search of the whole buffer
  would however the child's output is cut into arrivals; the `PATH` search,
  whose every candidate is an entry of it with the program on the end; and the
  Windows command line, which an argument list has to survive by the rules that
  parse it back. That last one is arithmetic on quotes and backslashes and no
  system call at all, so it now lives in `src/command_line.zig` and is compiled
  and tested on every host rather than on Windows alone.

### Fixed

- **A caller's file could arrive on the wrong stream, silently.** The child's
  descriptors were placed at 0, 1 and 2 in that order, with no check that one
  of them was also a number a later placement would read — so
  `.stdout = .{ .file = <the file at 2> }` beside
  `.stderr = .{ .file = <the file at 1> }` gave the child the same stream
  twice, and nothing anywhere said so. Any source below the slot it serves is
  copied out of the way first, close-on-exec, before a single placement
  happens.
- **A `Reaper` and the owner's `killWait` raced for one child.** `Reaper` waits
  through `Child.wait` and `killWait` reaps through `tryWait`, and both wrote
  `Child.term`: a data race on a value that is not a single word, and two
  `wait4` calls on one child, which is one status and one `ECHILD`. The
  sequence a `Reaper` exists for — ask `exit`, get `null`, decide the child has
  had long enough — ended a Debug build every time. The right to be inside the
  system's wait is now taken with an atomic and the term is published with a
  release store that every read acquires; a caller who does not get the wait
  reads the answer instead. `killWait`, `kill`, `wait` and `tryWait` are all
  legal while a `Reaper` runs, and the child is reaped once.
- **A grandchild could survive `kill` and `killWait` on POSIX.** A signal to a
  process group misses a descendant that gave itself a group of its own with
  `setsid` or `setpgid`, and `kill(-pgid)` is not atomic against a `fork`
  inside the group — a scratch grandchild survived a `killWait` with no grace. `kill` now asks the system who the descendants of
  the child are and signals them deepest first, before the child itself, so
  that nothing is orphaned on the way down; `.kill` asks again until a pass
  names nothing, which is what catches a process started while the first signal
  was landing. `Child.kill` and the README state the guarantee per system: the
  children of a process are named by `/proc/<pid>/task/<tid>/children` on Linux
  and by `proc_listchildpids` on Darwin, and on the BSDs and illumos, which
  name them only through the whole process table, the process group is the
  reach it always was. A process that has *both* left the group and been
  orphaned before anything looked is reached by no system.
- **Two close-on-exec windows closed.** A pipe and the null device were opened
  and then marked close-on-exec by a second call, and in the gap between the
  two a `fork` on another thread hands the descriptor to a child that has
  nothing to do with it — which then holds it open for as long as it lives,
  with whatever is reading the far end waiting for an end of file that will not
  come. `pipe2` carries the flag where the system has it and `O_CLOEXEC`
  carries it in the null device's open everywhere. Darwin has no `pipe2`, so
  there this package holds its own pipe-making and its own spawning apart
  instead; a `fork` elsewhere in the program can still land in that gap, and
  nothing a library holds would stop it. The master of a pair keeps its own
  window, which `posix_openpt` has no flag to close and which `Pty.open`
  already documented.
- **Windows left the caller's handles inheritable.** A handle a child is to
  inherit has to be marked inheritable, which is the only way to say so about
  one somebody else opened, and the flag was never cleared again — so a
  concurrent spawn elsewhere in the process inherited the caller's files and
  the parent's own standard handles. What each handle had is remembered and put
  back, on the success path and on every failure path alike.

## [0.3.2] - 2026-09-14

Four Windows faults that 0.3.1 shipped, and three of them the same one: a wait
with no end.

### Fixed

- **Stopping a reader could wait on the reader.** The wait that asks a task
  inside a read to stop took the lock that task takes to put away what it read,
  so a stop that had not yet asked for anything was waiting on the thing it was
  trying to stop. Nothing in that path takes the lock now: whether the task has
  finished is an atomic, stored last and outside it. `Expect.deinit` and this
  package's own tests had the same shape and both changed.
- **`Pty.close` could never return on Windows.** `ClosePseudoConsole` waits for
  the console host to go, and the host does not go until it has flushed what
  the client last wrote into a pipe this process holds the reading end of — so
  with nothing reading, the host waits on a write that cannot complete and the
  caller waits on the host. `close` now reads the master itself while the
  console closes: a drain started before and joined after, ended by the host's
  own exit. The terminal end goes first on both systems again. Closing the pair
  is also what ends a reader of the caller's, which is the order that needs no
  cancelling at all.
- **`Expect.deinit` could never return on Windows**, after a child on a
  pseudoconsole had exited on its own. The task is inside a read, and that read
  ends when the far end finishes, when the handle goes away, or when the
  operating system is told to abandon it — and for a pseudoconsole none of the
  first two happen while the console host holds the pipe. The asking was
  `CancelIoEx`, which reaches only the reads pending at the moment it is
  called, so it landed when the task was inside one and missed when the task
  was between two. It is asked again now until the task says it has stopped, a
  flag tells a reader between reads not to start another, and the doc comment
  says which order needs neither.
- **`spawnShell` wrote past a buffer for a long `COMSPEC` or `SHELL`.** The
  value was read into an array of WTF-16 units and then converted into an array
  of the same length in bytes, and one unit is worth up to three bytes of
  WTF-8: a value longer than a third of the path limit overran the second
  array. Both are sized in units now, the byte one three times over, and a
  value longer than that is declined rather than truncated — the fall-back
  shell is used instead.

## [0.3.1] - 2026-09-14

### Added

- **A Windows child and everything it starts are one job object, so `kill` and
  `killWait` reach the tree.** This was the last thing `detach` meant less of
  there: `CREATE_NEW_PROCESS_GROUP` is an address for a console control event
  and nothing more, so ending a child left what the child started running,
  where on POSIX a signal to the process group reaches all of it. `spawn` now
  creates a job, starts the child suspended, assigns it, and resumes it, so
  there is no instant in which the child exists outside its job and could put
  something beyond it. `.kill` ends the job. The job is created with
  `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`, so `Child.deinit` also ends whatever
  the child started and left behind — a difference from POSIX, where `deinit`
  signals nothing and a grandchild of a reaped child keeps running, and it is
  written down on `deinit` rather than left to be discovered. A child that
  cannot be put in its job is `error.JobAssignmentFailed`: jobs have nested
  since Windows 8 and this package's floor is Windows 10, so the way to reach
  it is a job that forbids nesting, and a child whose tree `kill` could not
  reach is not a child this package will hand back.
- `CONDUIT_TRACE` in the environment turns on a handful of diagnostic lines
  about what this package asked the operating system for: which spawn path
  ran, the flag word and structure size `CreateProcessW` was given, the
  pseudoconsole handle at the two places it appears, this process's own
  standard handles and whether they are consoles, and how long a close took to
  come back. Some of what this package does can only be watched on a machine
  nobody can attach a debugger to, where the log is the whole instrument. Off
  costs one environment lookup, once; nothing is part of the API and nothing a
  program does depends on it.
- `Child.SpawnOptions.stdio` has a `.streams` shape: each of standard input,
  output and error named on its own as `.inherit`, `.{ .file = f }`, `.ignore`,
  `.pipe` or `.close`. Before this the choice was one choice for all three plus
  `stderr_to` for the one exception that came up, so a pipe on one stream and
  the null device on another was not expressible, and neither was the thing a
  pair makes possible on POSIX: `.{ .file = pty.slaveFile() }` gives a child a
  terminal for one stream and a pipe or a file for the others. `.close` is new
  as well — no descriptor at that number at all, which is the one of the five a
  caller should think twice about and whose doc comment says why. The five
  names are the standard library's.
- `Child.SpawnOptions.resource_limits` sets a child's `setrlimit` limits, in
  order, before the `execve`. The other thing that can only happen between a
  `fork` and an `exec`: a limit belongs to a process, so a parent that set it
  on itself would be setting it on everything it went on to do, and `execve`
  carries what the child had into the program it becomes. Both halves of a pair
  are the operating system's own types — there is no portable set of resources
  to enumerate, and inventing one would hide what a system offers. Applied
  before `credentials`, so a privileged parent can still raise a hard limit for
  a child it is about to hand to somebody else. A limit the system refuses is
  `error.ResourceLimitsFailed` from `spawn`. POSIX only: a non-empty list is
  `error.Unsupported` on Windows, which has no `setrlimit`.
- `Child.SpawnOptions.credentials` sets a child's `uid`, `gid` and `umask`.
  They can only be set between `fork` and `execve` — this process changing its
  own user before a spawn would change it for everything else this process goes
  on to do — so a library that forks is the only place they can be offered, and
  this one forks. The group is set before the user, because after the user has
  been lowered there may be no privilege left to change the group with. A
  change the process is not allowed to make is `error.CredentialsFailed` from
  `spawn` rather than a child that started anyway. POSIX only:
  `error.Unsupported` on Windows, where a process runs as the token it was
  created with. Supplementary groups are still the parent's, and the doc
  comment says so: `setgroups` needs the group database, which a fork child may
  not read.
- `Child.Stdio.perStream` is what the older shapes lower to, so `.inherit`,
  `.ignore` and `.pipes` are now definitions rather than separate code paths.
- `Expect` is the conversation `Proxy` and `Child.output` are not: `until` waits
  for a literal byte pattern on the master, `bytes` waits for a count of them,
  `send` writes the reply, and every wait takes a deadline, because a program
  waiting for a line a child will never print should fail rather than stop. The
  buffer is the caller's and nothing here allocates; a match hands back slices
  into it, and a buffer that fills with bytes no pattern matched is
  `error.BufferFull` rather than bytes quietly dropped. A pattern is bytes
  rather than a pattern language: the standard library has no
  regular-expression engine, and a second, worse one does not belong in a
  process package. Reading runs on an `std.Io.Group` task from `start`, so what
  a child says while the parent is busy elsewhere is there when the parent
  comes back for it. `Child.expect` builds one over a child's pipes as well as
  over a pair.

### Changed

- **Closing the master is how a task reading it is released, and
  `Pty.closeMaster` says so.** A read of a pseudo-terminal master ends when the
  far end finishes or the handle goes away, and for a pair whose console host
  is still running only the second happens — so a program with a reader on a
  task should close the master and then join it, not the other way round.
  `Pty.closeSlave` also says that a Windows pseudoconsole waits for its client,
  so the child is reaped first.
- **What `killWait` reports on Windows is written down.** `.kill` there is
  `TerminateProcess` with an exit code of 1, so a child that had to be killed
  reports `.exited = 1` — that number is this package's. `.terminate` is a
  console control event, so a child that obeys it ends on its own terms and
  reports the status *it* chose; for one that does not handle the event that is
  the system's control-exit status, which reaches `Term.exited` as its low byte
  because `Term.exited` is a byte and a Windows exit code is a `DWORD`. The
  truncation is `std.process.Child.wait`'s and `tryWait` matches it, so the two
  calls never report a child differently. `Term`, `Signal.terminate` and
  `killWait` each say the part that belongs to them.

### Fixed

- **Three places asked a Windows value for a name it did not have.** A
  non-exhaustive enum holding a number nobody named has no name to give, and
  asking for one ends the process rather than returning an answer. A Windows
  `BOOL` names only `FALSE` — `TRUE` is a declaration, not a tag — so the
  trace naming one crashed every spawn that was not on a pseudoconsole, with
  the trace switched off, because a call's arguments are worked out before the
  call. `conduit.signalName` had the same shape for a real-time signal, which
  is a number and nothing else; it answers `null` there now, and the number is
  in the `Term` either way. And an unmapped `GetLastError` went to the standard
  library's reporter, which prints the code by name in a Debug build: a library
  must not end a program over a failure it was about to return, so the number
  is printed instead.
- **A child on a pseudoconsole wrote to the parent's pipes instead of its
  terminal**, everywhere the parent's own standard streams were pipes rather
  than console handles — which is every program a build system, a service or a
  test harness starts. `CreateProcessW` duplicates the parent's standard
  handles into the child as a special case when they are not console handles,
  even with `bInheritHandles` false, so the child was attached to the
  pseudoconsole and talking past it. From a terminal it looked right, because
  console handles are not duplicated and the child falls back to the console it
  has. A `.pty` spawn now sets `STARTF_USESTDHANDLES` with all three handles
  null, which is how a child is given none and made to use the console it is
  attached to. Naming a real handle beside a pseudoconsole is still refused —
  that is the combination Windows documents as unsupported, and it is why
  `stderr_to` with `.pty` is `error.Unsupported`.
- **`spawnShell` read the environment by walking the process environment block
  under the loader's lock.** The standard library's Windows lookup asserts
  something about every entry it passes on the way, so a single odd entry in a
  large environment would end the process from inside a lock, where the panic
  itself has nowhere to go. It is `GetEnvironmentVariableW` now: one call,
  which is also what the trace uses.
- **`error.BadWorkingDirectory` meant what it says only on POSIX.**
  `CreateProcessW` reports a working directory that is not there with an error
  code it also uses for a program at a path that is not there, so the two were
  indistinguishable afterwards and one of them could come back as the other's
  error. `spawn` looks at the directory before it starts the child, which is
  what the fork child's `chdir` does for the same reason on POSIX.
- **A Windows child inherited every inheritable handle this process held**, not
  only the three it was being given. `bInheritHandles` is all or nothing, and
  `STARTF_USESTDHANDLES` names the child's standard handles without limiting
  what else comes with them — so on a machine where this program's own standard
  streams are inheritable pipes, as they are under a build or test harness, the
  child and anything the child started kept those pipes open for as long as
  they lived. Whatever is reading the other end then waits for an end of file
  that never comes. `spawn` now passes a `PROC_THREAD_ATTRIBUTE_HANDLE_LIST`
  naming exactly the handles the child is given. A plan that hands the child a
  console handle gets no list, because a console is not inherited through the
  handle table and naming one is how `CreateProcessW` fails.
- **A pseudoconsole nobody is reading could block the program that owns it.**
  The console host writes into a pipe this process holds the reading end of,
  and both `ResizePseudoConsole` and `ClosePseudoConsole` wait for the host: a
  resize repaints the viewport, which for a window of any size is more than the
  few kilobytes a pipe holds by default, so a program that had stopped reading
  the master stopped there too, with no deadline anywhere to end it. The pipes
  are now created with room for a repaint of a window far larger than anyone
  runs, `Pty.close` drops the master ends before the terminal end on Windows so
  the host's last write fails rather than blocks, and `Pty.resize` and
  `Pty.closeSlave` say in their doc comments that the master has to be read.
  The whole suite ran to the end on macOS, Linux and Alpine and hung on
  Windows; this is what it hung on.

## [0.3.0] - 2026-09-14

A pass over the package asking, feature by feature, what a caller of a process
and pseudo-terminal library expects to find here — and the small things that
pass found missing.

### Added

- `Child.closeStdin` is the half-close a child reading to end of file is waiting
  for. Closing the pipe was possible before, in two steps that had to agree with
  `deinit`.
- `Child.waitTimeout` reaps the child if it ends in time and leaves it alone if
  it does not — the wait that does not also kill, which is what a policy is
  built on. It was already here behind `output`.
- `succeeded`, `exitCode` and `signalName` answer what a `Term` says. `Term` is
  the standard library's type rather than a parallel one, so nothing can be a
  method on it. `signalName` is null on Windows, where a terminated process
  reports the code it was terminated with.
- `foregroundGroup` is the question `isTty` cannot answer: not whether a handle
  is a terminal, but whether anything is running *on* it, and which process
  group the signals it generates would reach. POSIX only, and a compile error on
  Windows that says why. A terminal nobody has claimed is
  `error.NoForegroundGroup`, worked out from whether a signal sent there would
  reach anything rather than from each system's sentinel.
- `environ.only` is the `env -i` shape: exactly the named variables and nothing
  inherited, for a child that should not see an agent socket or a token.
- `Child.SpawnOptions.path_search` says which `PATH` resolves a bare `argv[0]`:
  the child's (the default, and what a shell does), the parent's (what
  `std.process.spawn` does, and what a scrubbed environment usually wants), or
  none. It was a silent choice before. On Windows the program is resolved inside
  `CreateProcessW` from the child's environment, so the other two are
  `error.Unsupported` there rather than accepted and not honoured.
- `Pty.closeMaster` documents what it has always done and now has a test for:
  dropping the last master descriptor hangs the terminal up, and the session
  leader — the child, when `detach` and `.pty` made it one — gets `SIGHUP`.

### Fixed

- **Neither end of a pseudo-terminal was close-on-exec.** A program holding a
  pair open while it spawned some unrelated child handed both ends to it, and a
  grandchild that has no idea it is holding a terminal keeps that terminal open
  — so a read of the master never reports end of file, even after the child the
  pair was for has exited. It is the failure `Pty.closeSlave` exists to prevent
  in the parent, arriving by a route the parent cannot see. The slave takes the
  flag in its `open`; the master takes it in a second call, because
  `posix_openpt` portably accepts nothing else.
- **`.pipes` meant two different things on the two systems.** A stream that was
  not piped inherited the parent's on POSIX and gave the child *nothing* on
  Windows, because `STARTF_USESTDHANDLES` is all or nothing and a null slot is
  not "leave it alone". It inherits on both now.


## [0.2.0] - 2026-09-13

Windows, through pseudoconsoles, behind the same API, which changed shape to
say so. Requires Zig 0.16.0.

### Breaking

- `Pty` no longer has one `master` descriptor. It has `read` and `write`, which
  are the same descriptor on POSIX and the two ends of two different pipes on
  Windows, because that is what a pseudoconsole is. `masterFile()` is gone;
  `readFile()`, `writeFile()` and `master()` replace it. Every end is now an
  optional and is `null` once closed, rather than a `-1` sentinel a `HANDLE`
  cannot hold.
- `Pty.slave` is a descriptor on POSIX and an `HPCON` on Windows, and
  `Pty.slaveFile` is a compile error on Windows: a pseudoconsole is an object a
  process is attached to, not a stream. `setWinSize` and `ttyName` are compile
  errors there too, for the same kind of reason, and each says which.
- `Child.pid` is `Child.id`: a process id on POSIX, a process `HANDLE` on
  Windows. `Child.pty` is now both master files rather than one.
- `Child.kill` takes a `Child.Signal` — `.interrupt`, `.terminate`, `.kill` —
  instead of a POSIX signal number. Those three are what both systems can
  honour; a program wanting another POSIX signal can send it with
  `std.posix.kill` and `child.id`.
- The module no longer refuses to compile on Windows, and no longer requires
  libc there. `build.zig` decides from the target.

### Added

- `Child.output` runs a child to the end and collects what it wrote, with a
  size cap, a timeout, and a bounded drain for the case where something the
  child started still holds its pipe. Both streams are read on their own tasks,
  because a child that fills one pipe while the parent reads the other
  deadlocks — and because, on Darwin, a child on a pseudo-terminal whose output
  nobody reads can block inside its own exit. `Child.wait` now says so.
- `Child.stdinFile`, `Child.stdoutFile`, `Child.stdinWriter` and
  `Child.stdoutReader` find the child's streams wherever they are: the pipes
  for a child on pipes, the master for a child on a pair.
- `conduit.environ.inherit` builds a child's environment from this process's own
  with overrides applied; a `null` value removes a variable rather than
  emptying it.
- `spawnShell` starts the user's shell on a new pair with a terminal emulator's
  defaults, and absorbs the one place POSIX and Windows want different timing.
- `Proxy` forwards the window size. It installs no signal handler — it reads
  the size on a task of its own, and takes an optional `ticket` a program's own
  `SIGWINCH` handler can bump so a change is picked up at once. The module doc
  also explains why Ctrl-C and Ctrl-Z need no code at all: in raw mode they are
  bytes, and the child's terminal turns them back into signals.
- `ci/linux.sh` runs the whole suite on Linux in Docker, on glibc and on musl,
  in Debug and ReleaseSafe. musl is there because `ptsname_r` reports failure
  differently on the three libcs this package supports, and that deserves an
  image rather than a comment.

- Windows 10 version 1809 or newer: `CreatePseudoConsole` is imported
  statically rather than looked up.
- `detach` is `CREATE_NEW_PROCESS_GROUP` and means only half what it means on
  POSIX: a pseudoconsole is the child's console either way, and Windows starts
  a new process group with Ctrl-C disabled. `spawnShell` therefore does not
  detach on Windows.
- `.bat` and `.cmd` are refused with `error.UnsupportedBatchFile` rather than
  handed to the command interpreter, whose re-parsing makes any argument
  serialisation unsafe.
- `stderr_to` together with `.pty` is `error.Unsupported`: a pseudoconsole is
  attached through an attribute list, which Windows documents as incompatible
  with naming the child's standard handles. On POSIX the two compose.

## [0.1.0] - 2026-09-13

First release. Requires Zig 0.16.0. POSIX only: Linux, macOS, the BSDs.

### Added

- `Pty` opens a pseudo-terminal pair through the POSIX 98 interface
  (`posix_openpt`, `grantpt`, `unlockpt`, `ptsname_r`) rather than through
  `openpty`, which lives in a different library on each system. It reads and
  sets the window size, and closes either end on its own so a parent can
  release the slave and still see end of file on the master.
- `Child` spawns a program on that pair, on pipes, on the parent's own streams,
  or on `/dev/null`, with a working directory, an environment, and a redirected
  standard error. With `detach` and a pseudo-terminal the child calls `setsid`
  and claims the pair as its controlling terminal, which is what the standard
  library's `std.process.spawn` has no hook for and what makes the line
  discipline's signals — Ctrl-C as `SIGINT` — reach the child at all.
- The child starts with an empty signal mask and every signal at its default
  action. `execve` resets neither a blocked signal nor an ignored one, so
  without this a program started from a shell's background job inherits an
  ignored `SIGINT` and cannot be interrupted from its own terminal.
- A program that cannot be executed is an error from `spawn`, not a child that
  exits 127: the fork child reports the failure over a close-on-exec pipe.
- `Child.wait` delegates to `std.process.Child.wait`, so it is a cancelation
  point and uses whatever the `std.Io` implementation has for waiting on a
  process. `Child.tryWait` never blocks, `Child.kill` addresses the process
  group of a detached child, and `Child.killWait` is `SIGTERM`, a grace period,
  `SIGKILL` and a reap.
- `Reaper` runs a wait on an `std.Io.Group` task and publishes the result
  through an atomic, so a program can poll for a child's death without
  blocking.
- `Proxy` pumps bytes both ways between a pseudo-terminal master and a pair of
  `std.Io.File`s until the child's end closes.
- `rawMode`, `restore`, `winSize`, `setWinSize`, `isTty` and `ttyName` are the
  terminal ioctls on a descriptor, for either end of a pair or for the
  program's own standard input.

[0.4.0]: https://github.com/pedronaugusto/conduit/releases/tag/v0.4.0
[0.3.2]: https://github.com/pedronaugusto/conduit/releases/tag/v0.3.2
[0.3.1]: https://github.com/pedronaugusto/conduit/releases/tag/v0.3.1
[0.3.0]: https://github.com/pedronaugusto/conduit/releases/tag/v0.3.0
[0.2.0]: https://github.com/pedronaugusto/conduit/releases/tag/v0.2.0
[0.1.0]: https://github.com/pedronaugusto/conduit/releases/tag/v0.1.0
