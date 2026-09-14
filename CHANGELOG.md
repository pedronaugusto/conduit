# Changelog

Each entry says what the release makes possible, so a reader has the reason and
not only the diff. Versions follow [semantic versioning](https://semver.org);
before 1.0 the minor is the breaking one.

## Unreleased

### Fixed

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

### Added

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

## 0.3.0

A pass over the package asking, feature by feature, what a caller of a process
and pseudo-terminal library expects to find here — and the small things that
pass found missing.

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

### Known gaps

Named in README.md's "What this package does not do", each of them real and
none of them small: an `expect` helper, per-stream stdio, per-child credentials
and `setrlimit` at spawn, and Windows job objects so `detach` there kills a
tree.

## 0.2.0

Windows, through ConPTY, behind the same API — and the API changed shape to be
honest about it. Requires Zig 0.16.0.

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
  differently on the three libcs this package supports, and that claim deserves
  an image rather than a comment.

### Windows notes

- Windows 10 version 1809 or newer: `CreatePseudoConsole` is imported
  statically rather than looked up.
- `detach` is `CREATE_NEW_PROCESS_GROUP` and means only half what it means on
  POSIX: a pseudoconsole is the child's console either way, and Windows starts
  a new process group with Ctrl-C disabled. `spawnShell` therefore does not
  detach on Windows.
- `.bat` and `.cmd` are refused with `error.UnsupportedBatchFile` rather than
  handed to `cmd.exe`, whose re-parsing makes any argument serialisation
  unsafe.
- `stderr_to` together with `.pty` is `error.Unsupported`: a pseudoconsole is
  attached through an attribute list, which Windows documents as incompatible
  with naming the child's standard handles. On POSIX the two compose.

## 0.1.0

First release. Requires Zig 0.16.0. POSIX only: Linux, macOS, the BSDs.

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
