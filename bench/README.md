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
