# conduit benchmark preparation

Keep the `bench` worktree in the workspace’s `.bench/conduit`, outside `.zig-cache`; `bench/quiet.sh` resolves its files from its own directory.

Pinned before: `8adf8af91329333c2deb7db5e2b14fdbae9520d8`.
Pinned current main: `4a8cb70b061ceedb02ad7ccfb995a85d380bceeb`.
The current pin includes per-child containment on main.

`bench/quiet.sh` is the complete pass. `bench/quiet.sh --smoke` exercises
all available workloads once on tiny fixtures, without warmups or saved timing
values. Smoke is a correctness check, and never evidence for speed. Both
modes write plain Markdown and JSON to `bench/results/<local-date>/`; generated
results and build products are ignored. Smoke writes `smoke.md` / `smoke.json`;
the quiet pass writes `report.md` / `report.json`, so smoke cannot overwrite a
real pass. Use `--output <directory>` for a separate run on the same day.

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

Same-job tools retained: Rust std/portable-pty 0.9.0, Go os/exec/creack/pty
1.1.24, C posix_spawn/fork/openpty, Python subprocess/ptyprocess 0.7.0
(pexpect 4.9.0). Rust has no timeout-wait row. No new tool was added.
The full PTY lifecycle uses 50 Rust and 20 Python iterations versus 500 for
other tools, preserving the existing per-cycle metric and bounded trial size.
Node PTY was never implemented and is not presented as a comparison.

Compatibility adapters replace direct child/output/PTY field access with
borrowing methods, and pass the allocator to PTY open where required. The
before build takes the original API paths at compile time. Process trees,
bytes transferred, grace settings and workload boundaries are unchanged.
Tiny runs have no timing assertions. Failure to build or complete a workload
fails the entry point rather than silently dropping a side.

Planning estimate: **15–30 minutes** for the full pass with dependencies ready;
allow another **5–15 minutes** for a first setup. These are estimates, not
measurements taken during preparation. `run.sh`, `alternate.sh` and
`per-commit.sh` remain low-level helpers; use `quiet.sh` for the complete pass.

Standalone `zig build -Doptimize=Debug` compiles the pinned after harness
without running it. Snapshot builds pass `-Dsnapshot=true` to compile the
archived local revision instead; quiet runs retain ReleaseFast.
