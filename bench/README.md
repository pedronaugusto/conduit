# conduit benchmark preparation

Keep the `bench` worktree in the workspace’s `.bench/conduit`, outside `.zig-cache`; `bench/quiet.sh` resolves its files from its own directory.

Pinned before: `8adf8af91329333c2deb7db5e2b14fdbae9520d8`.
Pinned after (final main): `c7ffe5aa60b753ca194159418ddc02af56b5c3df`.

`bench/quiet.sh` is the complete pass. `bench/quiet.sh --smoke` exercises
all available workloads once on tiny fixtures, without warmups or saved timing
values. Smoke is a correctness check, and never evidence for speed. Both
modes write plain Markdown and JSON to `bench/results/<local-date>/`; generated
results and build products are ignored. Smoke writes `smoke.md` / `smoke.json`;
the quiet pass writes `report.md` / `report.json`, so smoke cannot overwrite a
real pass. `--prepare-only` and `--check-prepared` write nothing there. Use
`--output <directory>` for a separate run on the same day.

The full pass warms each workload, then repeats A (before), B (after), and the
comparison tools five times. `--runs N` changes the repetition count. Setup,
fixture generation and compilation happen before the measured work. Both
package builds use the same harness, toolchain and workloads. Compilation uses
ReleaseFast. Sources come from `git archive` of the pinned revisions, independent
of the working checkout or later main changes. `--before <revision>` and
`--after <revision>` explicitly override the pins in `revisions.json`.

The cutoff is `2026-09-30T00:00:00+01:00` (Lisbon). Use an explicit midnight:
Git's date-only `--before=2026-09-30` retains a time of day. Reports record the
full package revisions, harness revision, machine model, OS, CPU, memory and
tool versions, without a hostname or personal paths. Keep the raw samples;
these are warm-cache measurements, with no cold-disk or universal speed claim.

`PYTHON` overrides the interpreter. With it unset, the wrapper prefers an
already installed Python 3.13 found by `uv`, then falls back to `python3`; it
installs no interpreter. This avoids the host's Python 3.14 ensurepip failure.
Requires installed Zig 0.16.0, Git, Rust/Cargo, Go and Python. Build dependencies
are pinned in the existing lockfiles. `--build-dir <directory>` changes the
scratch/build location. Run the full pass only in the owner's quiet window.

Harness history stays on `bench`; never merge this branch into main.

Workloads: spawn/wait, capture, PTY lifecycle and transfer, deadline-aware wait,
fixed-tree termination, leaf termination and the PTY single-child diagnostic.
The pass also exercises the existing lifecycle wait/spawn ratios, stop/grace
completion, Reaper and Expect joins, and Orphans costs. Orphans is unavailable
on macOS and reports that fact; `linux.sh` remains the optional Linux/Docker
snapshot helper. No container comparison is added to the Mac pass.

The rest of the public API has one workload per operation (`src/coverage.zig`
and the matching file of each comparison tool). Each side checks its own result;
rows in `count` and `bytes` units must be equal on every side of a workload, or
the pass fails.

| Operation | Workload (sizes, full count) | Comparisons |
|---|---|---|
| `Child.exchange` | exchange-1k ×500, -1m ×50, -64m ×3 | Rust `wait_with_output` + writer thread, Go `cmd.Stdin`+`Output`, C posix_spawn + writer thread, Python `subprocess.run(input=)` |
| `Child.output` at size | collect-1m ×50, -64m ×3 (`cat FILE`) | Rust `output`, Go `Output`, C posix_spawn + read, Python `subprocess.run` |
| `InputWriter` queue/end/wait | input_writer-1m ×10, 64-byte pieces | Rust mpsc + writer thread, Go channel + `StdinPipe`, C writer thread (no queue), Python `SimpleQueue` + thread |
| `readAvailable` | read_available ×500 | Go/C/Python non-blocking read to EAGAIN or EOF |
| `Child.tryWait` | try_wait ×100,000 calls | Rust `try_wait`, C `waitpid(WNOHANG)`, Python `Popen.poll` |
| `Reaper` start/wait/deinit | reaper_wait ×500 | a thread or goroutine waiting, joined: Rust, Go, C, Python |
| `Expect` until/untilAny/bytes/send | expect ×2,000 round trips each | Python pexpect `expect_exact`/`read` |
| `Proxy.run` | proxy-1m ×10, -16m ×1, default (cooked) mode | Go `io.Copy` (creack/pty README), Rust `std::io::copy`, C poll loop, Python `pty.spawn` |
| `spawnShell` | shell_spawn ×200 (Python ×20) | Rust portable-pty, Go creack `StartWithSize`, C `forkpty`, Python ptyprocess |
| `Pty.open`/`close` | pty_open ×2,000 | Rust portable-pty `openpty`, Go `pty.Open`+`Setsize`, C `openpty`, Python `os.openpty` |
| `rawMode`+`restore`, `winSize`, `setWinSize`, `Pty.size`, `Pty.resize`, `isTty`, `ttyName`, `foregroundGroup` | tty_ops ×2,000 each | C termios/ioctl/`ttyname_r`/`tcgetpgrp`; Go x/term and creack; Rust portable-pty `get_size`/`resize`, std `IsTerminal`; Python tty/termios/os/ptyprocess |
| `findProgram` hit and miss | find_program ×5,000 | Go `exec.LookPath`, Python `shutil.which` |
| `environ.inherit`, `environ.only` | environ ×20,000 | Rust `vars_os` into a `HashMap`, Go `os.Environ` into a map, Python `os.environ.copy` |
| `processExists`, `startTime`, `captureStarted` | process_identity ×20,000 | exists: C `kill(pid, 0)`, Go `Signal(0)`, Python `os.kill(pid, 0)`; start time: C `proc_pidinfo` |
| `endRecorded` | end_recorded ×200, the tree_kill tree | none (tree_kill holds the killpg comparisons) |
| `Child.kill` with a signal that is not an end (`.user1`) | signal ×2,000 round trips: SIGUSR1 sent, `x` read back | C `kill`, Go `Process.Signal`, Rust `libc::kill` (std has only SIGKILL), Python `Popen.send_signal` |
| `SpawnOptions.extra_fds` | extra_fds ×500: pipe, `sh -c 'echo x >&3'` with its write end at 3, read to the end, reap | C `posix_spawn` + `adddup2`, Go `ExtraFiles`, Rust `pre_exec` + `dup2` (what command-fds does), Python `os.posix_spawn` + `POSIX_SPAWN_DUP2` |
| `Child.waitTree` (Linux) | wait_tree ×200: the answer once a contained child has ended | none; unavailable on the Mac and without a writable cgroup |

Unavailable comparisons, with the reason: Rust has no non-blocking pipe read,
expect, program search, or process-existence call in std or portable-pty; Go
has no non-blocking wait (try_wait), expect, terminal name or foreground-group
call in os/exec, creack/pty or x/term, and its one size setter is reported as
`pty_resize`; C has no expect, program search, environment map or pty object;
start time and capture have no standard-library call outside C (psutil,
gopsutil, sysinfo and the expect crates are not pinned here; adding one is the
owner's dependency call). `exchange`, `InputWriter`, `readAvailable` and
`processExists` are newer than the before pin, which reports them unavailable.

The signalled child is `c-bench signal_child` on every side (`BENCH_SIGNAL_CHILD`):
it answers each SIGUSR1 from `sigwait`, so none is lost between two answers, as a
shell's trap around `wait` loses them; its one descendant ignores the signal.
Each side's child is in a group of its own, and the teardown ends the group.
What each side does differs, by design: conduit aims the signal as `kill` aims
an end, at the child's group and every descendant the system names (on macOS a
`proc_listchildpids` walk with audit-token proofs, since the child has forked);
the others signal the one pid. That walk is the cost conduit's row pays over
theirs, and the guarantee it buys: a descendant that left the group is still
reached. Python's `subprocess` keeps a passed descriptor at its own number, so
its extra_fds side places the pipe at 3 with `os.posix_spawn`.

Not timed, with the reason: `Term` helpers (`succeeded`, `exitCode`,
`signalName`, `signalNumber`, `shellStatus`), borrowed getters (`processId`,
`stdinFile`/`stdoutFile`/`stderrFile`, `take*`, `terminalMaster`, `result`,
`containment`, `readHandle`/`writeHandle`/`readFile`/`writeFile`/`master`/
`slaveHandle`, `Expect.pending`) and reader/writer construction
(`stdinWriter`, `stdoutReader`, `child.expect`): no measurable cost of their
own. `holdReap` and `release` are timed inside `Reaper` and `deinit`.
`openControlling` needs a controlling terminal, which an idle quiet run lacks.
Windows-only (`console`, `waitTree` on a job, `Pty.consoleOptions`) and Linux-only
(`Orphans`, `Cgroup`, `bootIdentity`, `CapturedPid.wait` on a cgroup) operations
cannot run on the Mac; Orphans and `waitTree` on a cgroup keep their Linux
workloads above. `signal`, `extra_fds` and `waitTree` on Linux are newer than
both pins, which report them unavailable until the after pin moves.

Same-job tools retained: Rust std/portable-pty 0.9.0, Go os/exec/creack/pty
1.1.24, C posix_spawn/fork/openpty, Python subprocess/ptyprocess 0.7.0
(pexpect 4.9.0). Rust has no timeout-wait row. No new tool was added.
The full PTY lifecycle uses 20 Python iterations versus 500 for the other
tools, preserving the existing per-cycle metric and bounded trial size.
Node PTY was never implemented and is not presented as a comparison.

Equivalence: the Rust PTY round trip ends the child with SIGKILL and a reap,
as C and Go do; portable-pty's own `kill` sends SIGHUP and sleeps 50 ms
before looking again. The ptyprocess and pexpect sides set the libraries'
documented delays (`delayafterclose`, `delaybeforesend`, `delayafterread`) to
none: they are sleeps, not work. What remains of ptyprocess's spawn cost is
its own: it closes every descriptor number below the soft `RLIMIT_NOFILE`
in the child (1,048,576 in the owner's shell), where conduit relies on
close-on-exec. portable-pty's `openpty` also resolves the slave's name
(`ttyname`, about 0.5 ms on macOS), which conduit does only when asked.

Compatibility adapters replace direct child/output/PTY field access with
borrowing methods, and pass the allocator to PTY open where required. The
before build takes the original API paths at compile time. Process trees,
bytes transferred, grace settings and workload boundaries are unchanged.
Tiny runs have no timing assertions. Failure to build or complete a workload
fails the entry point rather than silently dropping a side.

Quiet-only planning estimate: **12–26 minutes**. See [QUIET-PREP.md](QUIET-PREP.md) for preparation, counts, sizes and assumptions. `run.sh`, `alternate.sh` and
`per-commit.sh` remain low-level helpers; use `quiet.sh` for the complete pass.

Standalone `zig build -Doptimize=Debug` compiles the pinned after harness
without running it. Snapshot builds pass `-Dsnapshot=true` to compile the
archived local revision instead; quiet runs retain ReleaseFast.
