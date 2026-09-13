# Changelog

Each entry says what the release makes possible, so a reader has the reason and
not only the diff. Versions follow [semantic versioning](https://semver.org);
before 1.0 the minor is the breaking one.

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
