# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- Every wait on a kernel object is [reactor](https://github.com/pedronaugusto/reactor)'s (6d41279): a child's end (`wait`, `waitTimeout`, `killWait`, `output` and `Reaper`), a held process's end (`CapturedPid.wait`) and a Windows job's emptying (`waitTree`). On a reactor runtime each is an operation of the calling task's own loop and holds no thread, so a `Reaper` and a `wait` run on a runtime with no worker beside the home thread, where the wait used to hold that thread. On any other `std.Io` it is a wait on the calling thread that looks for a cancel every few milliseconds, which is reactor's interval and no longer conduit's own five. conduit now depends on reactor, a leaf that needs only std; `conduit.tty` imports it nowhere.
- `output` waits for the child's end and its two pipes in one reactor call, and reads the streams in turn, where it polled with ten-millisecond slices. A child that has ended and cannot yet be reaped, or whose reap another task holds, is asked about again after a millisecond and then every ten, while its streams go on being read.
- A `Reaper` wakes its wait with reactor's `Wake` where it made a pipe, and `stop` and `deinit` also cancel the task, which is what ends the wait on a reactor runtime. The grace given to a group or a cgroup is slept on the caller's `Io`, so a clock under test moves it, and a cancel ends it.
- POSIX: the watch on a child's end is opened when it is spawned and held by the `Child` until `deinit`, where each wait used to open one: a pidfd on Linux and the BSDs' kqueue registration. On Darwin it is opened before the child can run, as the fork watch is, because a kqueue refuses a child that has ended with `ESRCH` and the system goes on saying it is running for a moment after. The fork watch registers forks only.
- Windows: a job reports through reactor's `Job`, attached before the child is assigned to it and detached before the job is closed. On a reactor runtime each live child holds one of the runtime's `max_jobs`, and a spawn past them is `error.SystemResources`. The runtime keeps 32 reports of a job; a tree that outruns them is asked for the processes it holds, which says what the lost reports would have.
- `wait.zig` is replaced by `exit.zig`, which holds the one wait for a child's end that `Child` and `Reaper` share and the question of whether a child has ended without reaping it.
- The benchmarks measure with shakedown's `bench` and print its JSON rows. Each row keeps its name, in `conduit-bench` the workload's (`spawn_wait`, `tree_kill`, `tty_ops/win_size`), its timing boundaries, and its unit; a row whose sample is one call has the child it needs started before the clock and ended after it. `conduit-bench` takes `--row <prefix>`, `--samples <n>` and `--input <file>` in place of its positional arguments, and `lifecycle-claims` and `orphans-cost` take `--row`. Their old tab-separated lines are gone; `lifecycle-claims` says on standard error whether each claim holds.
- Adopt aegis (a5d17d0). The Reaper's kill deadline is an `aegis.Guarded`; the `InputWriter` queue is an `aegis.BlockingGuarded` with an `aegis.Condition`, its backlog an `aegis.bounded.Budget` whose reservation travels with the batch it admitted and is released with the batch's bytes through an `aegis.own.Owned`, so the backlog comes back by the batch's release and not by a reset; `Expect` keeps what has arrived behind an `aegis.BlockingGuarded`; the serialized allocator keeps its parent behind one; `Deadline.remainingMs` converts nanoseconds to whole milliseconds with `aegis.units`.
- Pin the newest green preflight and shakedown. The console layout test now runs with the root module's tests, where before it was never reached.
- Pin shakedown's fault callbacks, spurious wakes and automatic late timers; replace the Reaper fault layer, stacked refusal wrappers and late-resume tasks while retaining their assertions.
- Pin preflight's package, test dependency and benchmark contracts. Benchmarks accept `--smoke`; `zig build bench` builds ReleaseFast programs under `zig-out/bench` and runs them with default fixtures.
- Pin the newest green aegis, reactor, shakedown and preflight. CI gates glint's A004 and Z026 through the `glint` object of `ci/preflight.json` (it ran no rule beyond the A series before); the retired exception files and `ci/glint.json` are gone. Every test child is ended through `testing.support.reap`, which fails the test when the child cannot be ended, where it dropped the error. Benchmark rows declare a shakedown `fixture` (built and released per batch, as the hooks were), and the `check-containment` program's test now runs with `unit`.

### Breaking

- `ForkGap` and the leftover-cgroup list are `aegis.Guarded`, taken with `acquireScheduling` (and `tryAcquire` for the sweep that passes over a held lock), where each was a lock of its own over an atomic. Needs the aegis revision that has `acquireScheduling`.
- `Proxy`'s `Resize.ticket` and `Resize.tick` are `Resize.wake`, a reactor `Wake` the program signals when it learns of a resize: the forwarder waits on it for the interval instead of looking at a counter every five milliseconds. Waiting for a cgroup to empty is a reactor priority-event wait on `cgroup.events`, and `console.waitInput` is a reactor wait on the console's input handle, where both sliced their waits in five milliseconds.
- `Reaper.enableSubreaper` takes the allocator the adoption scope lives in (it used the page allocator), and the Darwin lineage tracker takes the spawning allocator. `Reaper.deinit` and `Orphans.deinit` end a scope whose `stop` failed or was skipped as far as they can, where they asserted and leaked.
- Byte counts take `aegis.units.Bytes(usize)`: `InputWriter.Options.max_backlog`, `OutputOptions.max_bytes` and `ExchangeOptions.max_bytes` (was `usize`). Build them with `.fromRaw(n)`. conduit now depends on aegis, a leaf that needs only the standard library, and a build that sets these options imports it.

- Every wait with a bound takes a `std.Io.Timeout` instead of milliseconds, and every span (a grace, a drain, an interval) is a `std.Io.Duration`. `.none` waits as long as it takes; `Deadline.within(span)` is a timeout on the awake clock.

  | was | is |
  |---|---|
  | `child.waitTimeout(io, timeout_ms)`, `child.waitTree(io, timeout_ms)` | `child.waitTimeout(io, timeout)`, `child.waitTree(io, timeout)` |
  | `child.killWait(io, grace_ms)` | `child.killWait(io, grace)` |
  | `OutputOptions.timeout_ms: ?u32 = null`, `.grace_ms`, `.drain_ms` | `.timeout: std.Io.Timeout = .none`, `.grace`, `.drain` |
  | `ExchangeOptions.timeout_ms`, `.drain_ms` | `.timeout`, `.drain` |
  | `Reaper.waitTimeout(io, timeout_ms)`, `Reaper.kill(io, grace_ms)`, `Reaper.Options.tree_grace_ms` | `Reaper.waitTimeout(io, timeout)`, `Reaper.kill(io, grace)`, `Reaper.Options.tree_grace` |
  | `Orphans.killAll(io, grace_ms)` | `Orphans.killAll(io, grace)` |
  | `expect.until`, `untilAny` and `bytes` with `timeout_ms` | the same with `timeout` |
  | `CapturedPid.wait(io, timeout_ms)`, `Cgroup.waitEmpty(io, timeout_ms)`, `Cgroup.Recorded.waitEmpty(io, timeout_ms)` | the same with `timeout` |
  | `RecordedOptions.grace_ms` | `RecordedOptions.grace` |
  | `Proxy.Resize.interval_ms`, `.tick_ms` | `.interval`, `.tick` |
  | `console.waitInput(handle, milliseconds)` | `console.waitInput(io, handle, timeout)`, a cancelation point that returns `console.WaitInputError` |
  | `Deadline.in(io, milliseconds)` | `Deadline.in(io, span)` |

- `Child.release(io)` is `Child.finish(io)`, and `Child.ReleaseError` is `Child.FinishError`. It ends an unfinished contained scope as before, but leaves the Child valid whatever it returns, so `deinit` is always owed after it. `Child.deinit` no longer asserts a confirmed scope: it kills and reaps one `finish` has not confirmed, reporting nothing, which makes `errdefer child.deinit(io)` safe.

- `Orphans` keeps no `std.Io`. Every call whose look can adopt an orphan takes one, and the look that adopts sets the owner's event through it, so nothing is registered and no `std.Io` outlives the call that passed it.

  | was | is |
  |---|---|
  | `child.tryWait()` | `child.tryWait(io)` |
  | `orphans.count()`, `orphans.list(out)`, `orphans.stop()` | `orphans.count(io)`, `orphans.list(io, out)`, `orphans.stop(io)` |
  | `orphans.adoptionEvent(io)`, `reaper.adoptionEvent(io)` | `orphans.adoptionEvent()`, `reaper.adoptionEvent()` |
  | `reaper.adoptionRecords(out)` | `reaper.adoptionRecords(io, out)` |

- `Child.Output` keeps the allocator that collected it: `Output.init(gpa, parts)`, and `output.deinit()` takes no allocator.

- `Cgroup.release()` and `Cgroup.Recorded.release()` are `close()`: they close the handle and leave it empty, so they may be called again.

- Requires Zig 0.17.0.

- Renamed, so that each verb for ending something means one thing on every type: `kill` makes processes end, `close` ends a stream or handle, `stop` ends what `start` began, and `deinit` releases what a value holds and cannot fail. The old names are gone.

  | was | is | why |
  |---|---|---|
  | `Reaper.stop(io, grace_ms)` | `Reaper.kill(io, grace)` | it signals the child: terminate, then kill after the grace |
  | `Reaper.end(io)`, `Reaper.EndError` | `Reaper.stop(io)`, `Reaper.StopError` | the counterpart of `Reaper.start`: joins the task, ends the adoption scope |
  | `Orphans.end(io, grace_ms)`, `Orphans.EndError` | `Orphans.killAll(io, grace)`, `Orphans.KillError` | it ends every adoptee |
  | `InputWriter.end(io)` | `InputWriter.close(io)` | it half-closes the input stream |
  | `endRecorded(io, options)`, `EndRecordedError` | `killRecorded(io, options)`, `KillRecordedError` | it signals a recorded process and its provable descendants |

  `Orphans.stop()` and `Expect.stop(io)` keep their names: each is the counterpart of its type's `start`.

- The public types are ordinary Zig structs with private fields, no longer integer-backed enums whose state was cast out of their bits: `Child`, `Child.HeldReap`, `Child.Output`, `InputWriter`, `Reaper`, `Expect`, `Orphans`, `Orphans.Spawn`, `Pty`, `Shell`, `Cgroup`, `Cgroup.Recorded` and `CapturedPid`. Their methods are unchanged. A value can no longer be made with `@enumFromInt`; `Child` is a handle whose copies name the same child, released or deinited once. `Reaper`, `Expect` and `Orphans` assert in safe builds that they have not moved since `start`.
  - `Reaper` copies the `Child` handle at `start`, so the caller's `Child` may move afterwards; it must still not be deinited while the `Reaper` runs. `Child.HeldReap` holds the handle, not a pointer to it.

- `deinit` cannot fail and leaves its value undefined, everywhere. Teardown that can fail, and be asked again, has its own name:
  - `Reaper.stop(io)` ends the task and the adoption scope, returning `Reaper.StopError`, which replaces `Reaper.DeinitError`; a second call does nothing, and a later `start` or `enableSubreaper` is `AlreadyStarted`. `Reaper.deinit(io)` returns nothing and, with `enableSubreaper`, follows a successful `stop`.
  - `Orphans.stop()` restores the subreaper setting and releases the scope, returning `Orphans.StopError`, which replaces `Orphans.DeinitError`. `Orphans.deinit()` returns nothing and follows a successful `stop` once started.
  - `Expect.stop(io)` ends the reading task for good and can be called again; a later `start` is `AlreadyStarted`. `Expect.deinit(io)` stops and leaves the value undefined.
  - `Child.finish(io)` ends an unfinished contained scope, reports what that met and leaves the Child valid, so it can be asked again; `deinit` is still owed after it, and kills and reaps a scope `finish` has not confirmed, reporting nothing, so `errdefer child.deinit(io)` is safe. `Child.deinit` is no longer idempotent, and after it no method may be called: there is no closed Child for `processId`, `wait`, `tryWait`, `kill` or the stream accessors to answer `null` or `ReapedElsewhere` for.
  - `Child.Output.deinit` and `InputWriter.deinit` are no longer idempotent; `InputWriter.cancel` is the call that can be made again.

- The allocator comes before the `std.Io`, as in the standard library: `Child.spawn(allocator, io, options)`, `child.inputWriter(allocator, io, options)`, `child.output(allocator, io, options)`, `child.exchange(allocator, io, input, options)`, `spawnShell(allocator, io, options)` and `findProgram(allocator, io, environ, name)`. `readAvailable` takes the `std.Io` first, `readAvailable(io, file, buffer)`. `Shell.SpawnError` is what `spawnShell` fails with; `SpawnShellError` names the same set.

- `console` spells Windows' names in Zig's casing: the mode flags and `CreateFileW` arguments are `enable_line_input`, `generic_read` and the like, `SMALL_RECT` and `CONSOLE_SCREEN_BUFFER_INFO` are `SmallRect` and `ConsoleScreenBufferInfo`, and the `DWORD`, `HANDLE`, `BOOL`, `SHORT`, `WORD` and `COORD` re-exports are gone in favour of `std.os.windows`.

- `setWinSize`, `ttyName`, `foregroundGroup`, `Pty.slaveFile`, `Child.Signal.toPosix`, `Child.waitTree`, `startTime`, `captureStarted` and `endRecorded` are functions rather than constants chosen per system. On a system without them, calling one is the compile error that says why; naming one without calling it no longer is.

- Contained Windows waits publish the root status only after ending the Job and confirming that every member has ended.

- `Child.finish` reports contained cleanup failures and keeps the Child for another call; `Child.deinit` ends a scope `finish` has not confirmed without reporting.

- Reaper.deinit and Orphans.deinit report failed completion and retain their scope for retry until every direct child and adoptee is reaped.

- `Orphans.Spawn` keeps its adoption gate claim opaque; callers use `begin`, `started` and `finish`.

- `Child.Output` keeps collected allocation ownership opaque; byte slices and result flags are borrowed or copied through methods.

- `Shell` owns its child and pair in opaque storage; `child()` and `pty()` borrow them for their methods.

- `Orphans.Record` also copies group and session from the same verified adoption snapshot as its start time.

- `Cgroup.prepare` returns an opaque handoff; `joinDescriptor` borrows its descriptor and `started` or `abandon` consumes ownership.

- `Pty` keeps descriptors and Windows geometry opaque; `readHandle`, `writeHandle`, `slaveHandle` and `consoleOptions` borrow or copy observations.

- `Child` hides lifecycle and owned pipes; `stdinFile`, `stdoutFile`, `stderrFile` and `terminalMaster` borrow streams, and `takeStdin`, `takeStdout` and `takeStderr` transfer pipes.

- `InputWriter` keeps its allocated queue and pipe ownership behind an opaque value; callers construct it through its methods.

- `Orphans.list` copies `Record` values with pid and start time captured during adoption, and reports `IdentityUnavailable` instead of returning an unverified number.

- `Cgroup` and `Cgroup.Recorded` keep directory ownership opaque in fixed storage; their observation and cleanup methods retain their signatures.

- `Orphans` keeps adoption and lifecycle state opaque in fixed storage; its methods own every list and notification.

- `Expect` keeps conversation state opaque in fixed storage; construction and observations use its methods.

- `Pty.open` takes a caller allocator retained for Windows geometry until every end closes; `spawnShell` forwards its allocator.

- `HeldReap` and Reaper state are opaque; `Reaper.StartError` includes `AlreadyStarted`, and a successful start or deinit prevents another start in that lifetime.

- `CapturedPid` is opaque; `processId()` replaces its numeric field, and Darwin captures retain process identity across exec while checking refreshed audit versions for signal delivery.

- `Pty.size` borrows a pointer; Windows geometry is opaque and synchronized with the OS resize, so stream borrows never copy a changing cache.

- Child owns opaque lifecycle state until `deinit`; `processId` and `result` synchronize identity and result access, replacing public handles and mutable lifecycle fields.

- Conduit owns `Term`, whose `exited` payload and `exitCode` retain all 32 bits of a Windows exit status.

- Blocking Child waits and Reaper report `ReapedElsewhere` when another owner took the child's status.

- `conduit.signalDescendants` and `conduit.signalGroupSince` on a bare pid are
  gone: a pid can be reused during the walk. `CapturedPid.signalDescendants`,
  `CapturedPid.signalGroupSince` and `endRecorded` reach a recorded process
  through a held identity; a live child is ended with `Child.kill`.

- `Reaper.init` takes `Reaper.Options`: `.init(&child, .{})` is the
  behaviour it had.

### Added

- `Deadline.within(span)`, `Deadline.of(io, timeout)`, `Deadline.never`, `deadline.min(other)`, `deadline.remaining(io)` and `deadline.toTimeout()`, for a caller that holds its own deadline across several waits.

- `pipe(options)`, `PipeOptions`, `PipeError` and `Deadline`, in `conduit` and in `conduit.tty`, for a program that waits on its own terminal without linking libc on Linux. `pipe(.{ .nonblocking = true })` makes both ends close-on-exec and, if asked, nonblocking: one `pipe2` where the system has it, and on Darwin `pipe` and `fcntl` under `ForkGap`, the lock conduit's spawns take, so no child conduit starts inherits it. `Deadline.fromTimeout(io, timeout)` reads a `std.Io.Timeout`; `remainingMs` and `windowsMs` (never `INFINITE`) round what is left up to whole milliseconds. `conduit.tty.ForkGap.hold(function, args)` makes a call inside that lock and leaves it however the call returns, for a program that opens a descriptor of its own in two calls; `opening_is_two_calls` says whether this system does.

- `Child.Output.init(gpa, parts)` is public: an `Output` made from bytes the caller allocated with `gpa`, which keeps it and frees them at `deinit()`.

- `Child.waitTree` works on Linux for a child in a cgroup of its own: it waits for `cgroup.events` to say the cgroup has emptied, woken by the change, and is `Unsupported` for a child given no cgroup. A recorded cgroup's `waitEmpty` reads the file only when the change wakes it.

- `SpawnOptions.extra_fds` gives a child files at descriptor 3 and up, in order, placed correctly whatever numbers they have here; `.close_all` closes what is above them. On Windows they are inherited through the handle list and listed in the C runtime's table in the startup record, so a child on that runtime has them at 3 and up; with `.pty` there it is `Unsupported`.

- `Child.kill` sends any POSIX signal to the child and what it started, aimed as the three requests to end are: `.hangup`, `.quit`, `.user1`, `.user2`, `.stop`, `.@"continue"` and `.window_change` by name, any other by number with `.{ .posix = … }`. Only `.interrupt`, `.terminate` and `.kill` end the tree with the child. Windows refuses the others with `Unsupported`. `Child.Signal` is a tagged union now; `.interrupt`, `.terminate` and `.kill` are spelled as before.

- `readAvailable` reads what a pipe holds now without waiting for more, POSIX and Windows: once a child has ended, the rest of what it wrote, even while something it started still holds the pipe open.

- `tty.openControlling` opens the process's own terminal, `/dev/tty` or the console's `CONIN$` and `CONOUT$`, and `tty.console` declares `CreateFileW` and `WriteFile`, which conduit's own Windows code now takes from there.

- `Child.exchange` runs a child to its end with borrowed input written while its output is collected, under one deadline over input, run, reap and drain, with its allocator's calls serialized.

- `processExists` says whether a process has an id now, on POSIX and Windows, for a caller that wrote a pid down; pair it with `startTime` to tell a successor apart.

- `shellStatus` says how a child ended as a shell's `$?` does, and `signalNumber` gives the number of any ending signal, named or not.

- `bootIdentity` and `parseBootIdentity` are public: the checked identity of this boot, and the same check for one read back from a record, so a consumer compares boots without reading `boot_id` itself.

- Reaper exposes copied adoption records and notifications without lending its scope owner.

- `Reaper.enableSubreaper` explicitly owns Linux adoption before spawn, ends and reaps its process-wide orphan set on contained completion, and reaps adopted exits while the root waits; registered direct children keep their own statuses.

- `SpawnOptions.descendants` chooses one lifecycle policy on every platform: the default `.survive` leaves descendants alone after normal, reaped completion, including Windows daemons; `.contain` ends survivors through job kill-on-close or a private POSIX group or Linux cgroup. Timeout, output error and explicit termination retain tree cleanup.

- `InputWriter.isOpen(io)` gives adapters an uncancelable acceptance snapshot, independent of backlog space.

- `Child.containment` copies the detached group and Linux cgroup path, directory identity and boot identity for records retained through retirement.

- `Child.inputWriter` transfers stdin to a bounded `InputWriter` task, with ordered delivery and end, retained write failures, and cancellation that joins before closure.

- `Orphans.list` names the adopted processes still running after a look, so
  a program can write them down for a later one to end.

- `Cgroup.openRecorded` returns a separate, allocation-free `Cgroup.Recorded`
  handle. It holds the cgroup and its parent by descriptor, checks the saved
  inode through that parent, and removes the empty directory with `unlinkat`.
  A record must also carry the boot id. POSIX process snapshots now use
  bounded stack storage and report `error.OutOfMemory` when it is exhausted.

- `conduit.console` exposes typed Windows console input records and waits,
  peeks and reads through a small API.

- `CapturedPid.wait` and `Cgroup.waitEmpty` wait on kernel events with clock
  deadlines. `endRecorded` asks and then forces a recorded process and the
  descendants it can prove, using a verified cgroup for a complete Linux tree.

- `Orphans`: on Linux, opt-in, this process as the parent of every orphan
  below it (`PR_SET_CHILD_SUBREAPER`), for a program that starts every child
  through conduit. No task and no timer: when conduit reaps a child or a
  spawn returns one, and in `count()`, it reads this process's children,
  takes in the new orphans (a pidfd each) and reaps the ended ones, so an
  orphan that ends while nothing of conduit's happens stays a zombie until
  the next such moment or `end`. `end(io, grace_ms)` ends them all
  through their pidfds, `SIGTERM`, the grace, then `SIGKILL`, with what
  each started. A `Child`'s own status is never taken: every Linux spawn
  holds a lock from before its fork until the child is on the list of
  conduit's own, and the children this process had at `start` are on it
  too. `Child.kill` does not reach an adopted process on a child's account
  (nothing says which child it came from) except through the child's
  cgroup. Off unless started; `error.Unsupported` outside Linux and before
  5.4.
- On Linux, a cgroup of its own for every child, where this process may make
  one below its own (a delegated subtree, or a container with a writable
  cgroup mount): `spawn` makes it and the fork child joins it before it does
  anything else, so nothing the child starts is outside it, and
  `Child.kill(.kill)` ends the whole of it with one write to `cgroup.kill` --
  a grandchild that double-forked and called `setsid` included, which no
  group signal or walk reaches. `.terminate` and `.interrupt` go to each
  member through a pidfd, and `Reaper.Options.end_tree` ends what is left in
  the cgroup, detached child or not. Found out at the first spawn from
  `/proc/self/cgroup`, `/proc/self/mountinfo`, `cgroup.kill` (Linux 5.14) and
  the first `mkdir`, never assumed; where it is refused every child is
  started and reached as before. `Child.cgroup` says which a child has. A
  contained spawn always forks (there is no `posix_spawn` file action that
  writes), holds one more descriptor, and makes one directory,
  `conduit-<pid>-<n>`, which `deinit` removes -- or, while processes the
  child left still run in it, a later spawn or `deinit` removes once they
  have ended.
- `captureStarted`: open a pidfd before checking a recorded process's start
  time on Linux, and on Darwin take the start time and the pid's version in
  one `proc_pidinfo` lookup and hold an audit token made from it; then
  signal only through that captured identity. `CapturedPid.alive` says
  whether the process has ended, which a signal 0 cannot on Darwin (the
  kernel refuses it through a token).
- `signalGroupSince`: on Linux, end members of a detached child's group
  after its leader has gone, checking each member's group and start time
  through a captured pidfd before signalling it through that descriptor.
- `Reaper.wait` and `Reaper.waitTimeout`: the answer waited for on an event
  the task sets, rather than asked of `exit` again and again. Any number of
  tasks may wait at once, and none of them asks the operating system
  anything.
- `Reaper.stop(io, grace_ms)`: `.terminate` now and `.kill` once the grace
  has passed, each reaching what `Child.kill` reaches, and it returns at
  once -- the grace is spent on the `Reaper`'s task and ends the moment the
  child does. So a program holding a lock can stop a child without waiting
  for it. A grace of zero is `.kill` now.
- `Reaper.Options.end_tree`: what a child leaves running ends with it. On
  POSIX, for a detached child, what is left in its process group once it has
  ended is sent `SIGTERM`, given `tree_grace_ms` and then `SIGKILL`, all
  before the child is reaped, so the group's id is still the child's and the
  signal cannot reach a group given the same number since. Linux and Darwin
  are asked whether the group has emptied; elsewhere what is left is sent
  `SIGKILL` at once. On Windows the job is ended as soon as the child is
  reaped. The term published is the child's own.
- `findProgram`: where `spawn` would find a program for a child given an
  environment, by the same rules, for a program that asks whether something
  is installed. Windows resolves it the way a spawn with a custom
  environment already did, now in one place for both.
- `Child.holdReap` and `HeldReap`: the right to reap a child, taken and held
  by a caller that waits for the end in a way of its own and does something
  between the end and the reap.
- `startTime`: when a running process started, a number no later process
  given the same pid shares, so a pid written down with it can be told from
  a stranger given the number since. `/proc/<pid>/stat` field 22 on Linux,
  `proc_pidinfo` on Darwin; `null` for a process that is gone or a zombie.
- `signalDescendants`: what `Child.kill` sends beside the process group,
  for a process no `Child` is held for — one a crashed run of the program
  started, found again by its pid and start time.
- `SpawnOptions.parent_death_signal`: on Linux, the signal the child is sent
  when the thread that spawned it ends, a crash included
  (`PR_SET_PDEATHSIG`, set in the fork child, so such a spawn never takes
  `posix_spawn`). A parent gone before it is set is caught, and the child
  signals itself. `error.Unsupported` elsewhere.

- `conduit.tty`, the terminal primitives -- `rawMode`, `restore`, `winSize`,
  `setWinSize`, `isTty`, `ttyName`, `foregroundGroup` -- as a module of their
  own, for a program that draws its own screen and runs no child. On Linux
  it makes no call through libc: the primitives are ioctls, and a
  descriptor's device name is read from `/proc`. `conduit` imports it, and
  the names it exported are unchanged.

### Changed

- A spawn `posix_spawn` starts passes over the places on the search path where the program is not, without starting a child for each: a bare name found ten directories down `PATH` no longer costs ten children made and ended first.

- On Linux with glibc 2.39 or later, a child given a cgroup of its own is started with `posix_spawn` and born in that cgroup (`CLONE_INTO_CGROUP`, Linux 5.7), instead of forked and moved into it: no copy of the parent's page tables and no move between cgroups. With musl, an older glibc, or a kernel that refuses, it is forked and joins its cgroup as before. Which glibc counts is the one the program is built for.

- Windows whole writes report `BrokenPipe` for a pipe whose reader has closed, including the closing state Zig 0.16 reported as `Unexpected`. The standard library now maps that state itself, so conduit no longer asks the pipe before and after each write.

- Named error sets, the same on every POSIX target: `StartTimeError`, `CaptureError`, `EndRecordedError` and `SignalGroupError`, returned by `startTime`, `captureStarted`, `endRecorded` and `CapturedPid.signalGroupSince`. `Child.FinishError` is `Child.KillWaitError`; `finish` never returns a `waitTree` error.

- `Child.kill` signals the child, or its group, even when the descendant walk cannot hold the tree, and reports `OutOfMemory` after; `killWait` then reaps the child before returning that error. On Linux the walk holds the tree rather than the whole process table, so it no longer fails on a host with a few thousand processes.

- `Child.output` takes any allocator on every system, as `exchange` does: where it reads on tasks, their allocations are serialized.

- `Proxy.run` keeps carrying the child's output after `input` reaches end of file; only the output ending, or either direction failing, ends the call.

- `CONDUIT_TRACE` lines go through `std.log` at the info level under the `conduit` scope, and the `GetLastError` number behind an `error.Unexpected` on Windows at the warning level, so the program's log function and level decide where they go, instead of standard error.

- `tty.openControlling` on macOS opens the terminal under the device name a standard stream has open on it, when one has, so `poll` can wait on it (`/dev/tty` answers `POLLNVAL` there).

- Collect Darwin output with the retained exit watcher, including when the child exited before collection began.

- Skip the final Darwin group enumeration when the held root exited without ever forking.

- Retain Darwin exit events from before spawn so a killed tree does not fall back to a sleeping wait.

- Private Linux supervisors have their own sessions and process groups, and end their scopes on catchable stops.

- Contained Linux children have independent private subreaper supervisors, exact root status and saved scope identities, with orphan cleanup and reaping even without writable cgroups.

- A subreaper Reaper observes and reaps adopted exits even while another task owns the root wait.

- Contained macOS children retain observed fork, exec and exit lineage across double-forks and session changes, with identity-safe ending and an explicitly measured registration race.

| Platform | Containment after normal exit |
| --- | --- |
| Linux with a writable cgroup | Ends all members before reaping, including detached orphans; a process permitted to leave the cgroup can escape. |
| Linux without a writable cgroup, with a Reaper subreaper scope | Reaper completion ends and reaps the process-wide adopted set, including detached orphans; direct children keep their own waits. |
| Linux without either | Ends the private group before reaping; an orphan that left the group can escape. |
| macOS | Ends the private group and observed lineage before reaping; a fork followed by parent exit before enumeration or registration can escape. |
| Windows | Job Objects retain descendants across separate consoles and intermediate exits; deinit ends the members. |
| Other POSIX systems | Ends the private group before reaping; descendants that leave it can escape. |

The subreaper scope requires conduit for every new direct child, no outside global reaper, and all direct children ended and reaped before teardown; it does not assign adopted orphans to individual children.

- Force delivery retains group cleanup through the final held reap, catching a late fork before identity retirement; Reaper stop spends one grace on its owned tree.

- Expect waits for a buffer-space event when full, with discard and consumption waking the reader instead of an interval timer.

- Expect deinit closes its lifetime before canceling, so even a never-started reader cannot be started afterwards.

- `Child.output` reads a published result before opening an exit watch, draining an already reaped child without watching its retired process number.

- Proxy resize forwarding checks cancellation even when tickets keep changing, yields for zero intervals, and measures each refresh interval by one deadline.

- Whole writes check cancellation after zero progress, through one file helper shared by `InputWriter`, `Expect`, and `Proxy`.

- Windows program lookup refuses directories and batch scripts as spawn does, sharing the same batch-file policy.

- Forked children reset ignored real-time signals as well as named signals, while leaving numbers reserved by libc alone.

- Fork handshakes keep their control pipes above standard descriptors, so placing streams cannot overwrite an exec failure report when the parent's streams were closed.

- Descendant signalling proves ancestry through held process identities before delivery, so a recycled pid in a snapshot cannot authorize a signal to a stranger.

- Reaper tree cleanup and task-based output draining measure their remaining budgets against clock deadlines, including interrupted polls and delayed wakes.

- Signalling and final reaping share the child's identity, so a concurrent wait cannot release its pid or close its Windows handles during delivery.

- A detached child on a pseudo-terminal is started by `posix_spawn` on Linux:
  `POSIX_SPAWN_SETSID` gives it a session, and the terminal opened by name in
  that session becomes its controlling terminal, so its process group, its
  window size and the end of what it started are those of a forked one.
  macOS and the BSDs keep the fork for it, since a terminal becomes
  controlling there only through the `TIOCSCTTY` ioctl.

- Bounded waits on every platform now use one clock-based deadline type.

- `CapturedPid.signalDescendants` checks the captured root again after the
  descendant walk, before signalling, including its audit token on Darwin.

- `CapturedPid.signalGroupSince` anchors a Linux group reach to its captured
  leader. Darwin reaches a captured session leader's group through audit
  tokens; an ordinary group remains `error.Unsupported` because another
  process in that session can join it.

- On Darwin a child that has never forked is stopped with its signal alone,
  without the descendant walk: `Child.kill` walked with `proc_listchildpids`,
  a pass over the whole process table, twice for `.kill`, and a child with no
  descendants has nothing for it to name. `spawn` registers a kqueue
  `NOTE_FORK` watch before the child runs a single instruction of its program
  -- a `posix_spawn` child is started with `POSIX_SPAWN_START_SUSPENDED` and
  resumed with `SIGCONT` once the watch is in, and a fork child waits on a
  pipe before its `execve` until the parent has registered it -- so no fork
  can come before the watch. A child that has forked, even once, is walked as
  before, and `.kill` looks again after its signal for a first fork made
  while it was being sent. Each child holds one more descriptor on Darwin,
  closed by `deinit`.
- On Linux a child with no child of its own is stopped with its signal alone,
  without the descendant walk: before the pass over every process's `/proc`
  record, `Child.kill` reads the child's `/proc/<pid>/task/<tid>/children`,
  one small file per thread, and a child they name nobody in is signalled
  alone. `.kill` reads them again after the signal and walks if a child was
  made while it was being sent. A kernel without those files walks as
  before.
- The Windows search for a bare program name — the order of its places and
  how each path is spelled — is worked out apart from the file system
  (`windows_search`) and tested on every system; `Child.spawn` and
  `findProgram` both use it. `findProgram` and `Reaper.end_tree` have tests
  that run on Windows, where before they were only compiled for it.
- On POSIX a `Reaper` waits on the child's `pidfd` or kqueue registration
  beside a pipe that `deinit` writes to, rather than in the standard
  library's blocking wait, so `deinit` ends the task at once whatever the
  `std.Io` can cancel. Where there is no such handle it waits as before.
- `rawMode` on a Windows input handle also turns quick edit off, so the
  mouse is the program's rather than a selection that pauses the console.
- `Pty.closeMaster` and `Pty.close` no longer say to close the master under a
  task that is reading it and join the task afterwards. Closing a descriptor
  another thread is reading is a race: the number is free for the next open,
  and a read started after the close reads that file. Stop the reader
  (cancel it, or let it read to the end) and join it, then close. The suite's
  own readers now do, and the Linux ThreadSanitizer run of the whole suite,
  which reported six such races, reports none.
- `Pty.open` opens the master close-on-exec in the `posix_openpt` call
  itself, on the systems that take `O_CLOEXEC` there (glibc, musl, Darwin,
  FreeBSD). The master no longer spends a moment without the flag, in which
  a `fork` on another thread could copy it, and the open is one system call
  shorter. A system that refuses the flag gets the second call as before.

### Fixed

- On Linux, `rawMode`, `restore` and `isTty` read and set a terminal's attributes with the kernel's own `TCGETS` and `TCSETS`, whichever C library is linked. On Zig 0.17 the standard library's `termios` has the kernel's layout, smaller than glibc's `struct termios`, and glibc's `tcgetattr` wrote past the end of it.

- `Pty.open` on musl reports a failed `ptsname_r` by the error number musl returns. It read `errno`, which musl leaves as it was, so the error was whatever an earlier call had left there.

- `Child.exchange` refuses input for a child with no stdin pipe (`NoStdinPipe`) before it starts, and leaves the child running instead of killing and reaping it.

- `Expect.until`, `untilAny` and `bytes` return `EndOfStream` once reading has stopped, instead of waiting out their timeout.

- A spawn with `descendants = .contain` on Linux no longer hangs when the root's note that it could not join its cgroup arrives before its supervisor's report.

- `output` no longer reaps a child whose reap a `Reaper` or `HeldReap` holds.

- A project that depends on conduit builds: build.zig reaches its CI dependency only in conduit's own tree.

- `spawn` refuses an argument holding a NUL with `InvalidArgv`. It ended the argument where it stood, and on Windows ended the command line there, so the child received fewer arguments than it was given.

- A wait status is decoded from its sixteen bits, so a word with higher bits set cannot panic in Darwin's `EXITSTATUS`.

- A `/proc/self/cgroup` line the read stopped in the middle of is no longer taken as this process's cgroup.

- `environ.inherit` reads this process's environment as `getenv` does: an entry with no `=` or no name is left out instead of crashing the map, and a name given twice keeps its first value.

- Contained Windows completion also consumes the Job termination notification, retaining the pending wait after accounting reaches zero.

- A recorded private scope stop stays pending until its supervisor observes it, including before the first poll.

- Adoption spawn handoffs reject registration after success or finish, so a released gate cannot authorize later ownership.

- Forked PTY children preserve standard streams that replaced a master descriptor in a standard slot.

- Cgroup handoffs consume their join descriptor and directory ownership once, so repeated cleanup cannot close a recycled descriptor or release the transferred cgroup.

- Deferred cgroup cleanup retains owned directory handles and verifies their identity before removal, leaving replacement directories alone.

- Orphan identity capture verifies pidfd reap ownership after reading start time, refusing a process number recycled during the lookup.

- Orphans refuses new reap ownership when pidfd waitid cannot verify it, while retaining existing holds until retirement is known.

- A refused group signal addresses the still-held child directly before reporting permission denial, covering Darwin's exit-to-wait observation gap.

- A Reaper started after observed status loss reports `ReapedElsewhere` before watching or addressing the retired process identity.

- A rejected Reaper start closes its wake pipe before returning, so retrying cannot overwrite and leak its descriptors.

- A deadline keeps its final fraction of a millisecond until it has actually elapsed, so tree cleanup cannot cut a grace short by rounding it down.

- A Reaper started after the child was reaped returns its published term before opening a watch or addressing the old process group.

- `Expect.deinit` on Windows did not return within thirty seconds when the
  console was still open. It asked the read to stop with `CancelIoEx`, and
  `std.Io.Threaded` issues a synchronous read that was aborted that way
  again unless its own task was cancelled, so the ask was never answered;
  the loop around it counted two-millisecond sleeps that each take at least
  a timer tick on Windows, so its two-second budget ran far longer before it
  fell through to the join. It now cancels the task and nothing else, which
  the Io delivers with `NtCancelSynchronousIoFile`, and returns at once.
- A `Reaper` with `end_tree` whose child had already ended when its task
  first looked reaped the child and left what it had started running.
  Darwin refuses a kqueue watch on a process that has ended and not been
  reaped, and the `Reaper` took the refusal for "nothing to watch" and fell
  back to the plain wait. It now asks whether the child has ended without
  reaping it (`waitid` with `WNOWAIT`), ends the group, and reaps. A slow
  start of the task, as under ThreadSanitizer, made the end_tree test fail
  one full-suite run in ten.
- `Child.output` left the child running when the call was cancelled or
  failed partway, so a caller whose task was cancelled had a process it could
  no longer wait for. A run abandoned is now a run ended: the child and what
  it started are killed and reaped before the error is returned.
- `restore` could wait for ever. It set the saved mode with `TCSAFLUSH`,
  which waits for every byte written to be transmitted, so restoring a
  terminal that had stopped reading -- suspended, gone, or the terminal of a
  program on its way out of a panic -- never returned. It and `rawMode` now
  discard unread input and take effect at once.

## [0.5.1] - 2026-09-20

Collecting a child's output no longer wakes a thread to do it.

### Changed

- `Child.output` on POSIX reads both pipes and watches the child's end from the calling task with one `poll`, starting no task and waking no thread; the promises are unchanged. Windows keeps the readers on tasks. Spawn and collect over a 1 KiB output: 1036 µs to 880 µs, within four percent of a C loop doing the same.

## [0.5.0] - 2026-09-20

Two rows of a private head-to-head brought level, a handful of faults the
suite had not reached, and the errors a caller can now be told instead of
being left with a child in a state the type did not name.

### Breaking

- `Expect.StartError` has a new member, `AlreadyStarted`: `Expect.start` now
  reports it instead of putting a second reader over the same buffer.
- `Proxy.RunError` has a new member, `BufferTooSmall`, which an empty buffer
  returns.
- `Child.SpawnError` has a new member, `InvalidJobLimit`: Windows `cpu_rate`
  is documented and validated as 1–10,000 hundredths of the whole machine's
  CPU.
- `Child.kill` can return `error.OutOfMemory` where before it sent a partial
  tree signal in silence.
- `Reaper.exit` returns `Child.WaitError!?Term`, so a terminal wait failure is
  preserved instead of being reported as `null` forever.

### Changed

- `Child.output` reads directly into geometrically grown collection storage,
  with no copy and no steady-state allocation while it drains each stream.
- POSIX tree signals keep their ordinary in-group path on stack storage and
  retain separate stable identities only for descendants that left the group.
- Descendant signals use stable process identities, so PID reuse cannot send
  a child's signal to an unrelated process, and the descendant walk no longer
  stops after 512 processes.

### Fixed

- A deadline wait on Darwin and the BSDs reaps a child whose exit note arrived a moment before `waitpid` would hand it over, instead of reporting the timeout it was not. Under a busy process table that moment was long enough to report about one child in fifteen hundred as still running.
- Windows children with closed or console streams no longer inherit
  unrelated inheritable process handles.
- Concurrent Windows spawns use private inheritable handle copies instead of
  racing while changing flags on caller-owned handles.
- POSIX `.close_all` spawns still report a pre-exec failure instead of
  returning a child that exits 127.
- `Child.output` keeps draining after allocation failure, returns
  `error.OutOfMemory`, and ends a child promptly when a stream cannot be read.
- Streaming readers retry permitted zero-byte results instead of treating
  them as EOF.
- Windows resolves a bare program against the selected child environment's
  `PATH` instead of the parent's.
- Concurrent Windows `spawnShell` calls retain separate `%COMSPEC%` values
  instead of racing on shared environment buffers.
- `Proxy.run` returns an input-side failure promptly even while a silent
  child keeps the output side blocked.
- A canceled Windows `Expect` reader publishes completion immediately, so
  `deinit` does not spend its full cancellation budget after the read ended.

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
  system call at all, so it now lives in `src/Child/command_line.zig` and is compiled
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

[Unreleased]: https://github.com/pedronaugusto/conduit/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/pedronaugusto/conduit/releases/tag/v0.5.1
[0.5.0]: https://github.com/pedronaugusto/conduit/releases/tag/v0.5.0
[0.4.0]: https://github.com/pedronaugusto/conduit/releases/tag/v0.4.0
[0.3.2]: https://github.com/pedronaugusto/conduit/releases/tag/v0.3.2
[0.3.1]: https://github.com/pedronaugusto/conduit/releases/tag/v0.3.1
[0.3.0]: https://github.com/pedronaugusto/conduit/releases/tag/v0.3.0
[0.2.0]: https://github.com/pedronaugusto/conduit/releases/tag/v0.2.0
[0.1.0]: https://github.com/pedronaugusto/conduit/releases/tag/v0.1.0
