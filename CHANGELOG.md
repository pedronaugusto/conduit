# Changelog

Each entry says what the release makes possible, so a reader has the reason and
not only the diff. Versions follow [semantic versioning](https://semver.org);
before 1.0 the minor is the breaking one.

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
