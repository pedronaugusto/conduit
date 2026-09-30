# conduit benchmarks

Compares spawn/wait/capture, PTYs, timed wait and tree termination with
Rust std/portable-pty, Go os/exec/creack/pty, C posix_spawn/fork/openpty,
and Python subprocess/ptyprocess. Rust lacks timed wait. Orphans tracking
is Linux-only; `linux.sh` runs optional conduit snapshots in Docker.

From `bench/`, run `./run.sh` on a quiet machine. `SMOKE=1 ./run.sh` uses one
iteration and 1 KiB fixtures without warm-up; `BENCH_BUILD_ONLY=1` builds
only. The package is this repository at `..`. Build Orphans with
`zig build -Doptimize=ReleaseFast` and run `zig-out/bin/orphans-cost`;
`-Dsmoke=true` selects its tiny mode.

portable-pty 0.9.0/libc 0.2.189 are exact in `src/rust/Cargo.toml` and
`Cargo.lock`. Go creack/pty v1.1.24/x/term v0.35.0 are pinned in
`src/go/go.mod`/`go.sum`. Python pexpect 4.9.0/ptyprocess 0.7.0 are in
`src/python/requirements.txt`. Record installed C/standard-library tool versions.
`BENCH_BUILD_DIR`/`BENCH_RESULTS` select output, defaulting to `build/`.
`ZIG`, `GO`, `CARGO`, `CC`, `PYTHON` select tools; `BENCH_TRUE`, `BENCH_ECHO`,
`BENCH_CAT`, `BENCH_SH`, `BENCH_SLEEP` select child programs on PATH.
Snapshot scripts take commits and `BENCH_REPO` (this repository by default).
Generated files are ignored.

`lifecycle-claims --quiet-machine` measures the speed claims moved out of the
unit suite: deadline/blocking wait at 3:2, file-actions/fork spawn at 9:10,
stop submission before its 300 ms grace, forced stop before grace plus 2 s,
honoured stop before 5 s, and Reaper/Expect joins before 5 s. It reports each
measurement and original limit; an `over` row is a quiet-machine result,
never a CI assertion. Build with `zig build -Doptimize=ReleaseFast` and run
`zig-out/bin/lifecycle-claims --quiet-machine` only on an exclusively idle
machine. Tiny mode is for harness checks, not evidence for a speed claim.
The spawn comparison requires cgroups unavailable (joining forces fork),
POSIX file-actions enabled and `/usr/bin/true`. Deadline and grace correctness
stay in controlled-clock unit tests; hang watchdogs stay in the unit suite.

Historical measurements moved from the library comments (not current claims):
M3 Max, 1000 null-device `/usr/bin/true` spawns: fork/exec 1336 µs,
file actions 946 µs; orphan scans about 4 µs empty and 30 µs with 100
processes; kevent64 zero timeout 14 µs versus KEVENT_FLAG_IMMEDIATE 0.3 µs.
Reproduce on a quiet machine before using these numbers.
