# conduit's benchmarks

conduit's own measurements of its own calls. They run on POSIX, on a quiet
machine, and are never timed in CI: `zig build bench-build` compiles them, and
`zig build test` runs each once with `--smoke`, every point once and no clock
read, so they keep working with the API.

```sh
zig build bench                        # all of them
zig-out/bench/conduit-bench input.txt spawn_wait 1000 # one workload, a thousand times
```

The migration is unfinished on `measuring`: `spawn_wait`, `spawn_collect`,
`pty_spawn` and `pty_spawn_child_kill` use shared shakedown JSONL output, with
samples in ns/spawn or ns/round-trip. The remaining rows retain their older
formats and timing loops until shared per-sample setup/teardown hooks exist.
`conduit-bench --row <prefix>` selects existing workload names.

`zig build bench` builds three programs in ReleaseFast into `zig-out/bench` and runs them, one
after another:

- `lifecycle-claims --quiet-machine` measures the ratios and bounds the
  package promises and says whether each holds.
- `orphans-cost` measures `Orphans` on Linux.
- `conduit-bench <input> [workload] [count]` runs a workload `count` times
  (100 unless given), or every workload in turn, and prints a row per
  measurement: the program, the workload, the metric, the value and its unit.
  `input` is a file the workload reads; with no arguments it creates a 1 KiB line
  (1023 bytes and a newline), which is what the spawn, PTY and operation
  workloads want. The size workloads (`exchange`, `collect`, `input_writer`,
  `proxy`, `pty_throughput`) take any file of whole lines: run
  `zig-out/bench/conduit-bench` with one.

The workloads: `spawn_wait`, `spawn_collect`, `pty_spawn`,
`pty_spawn_child_kill`, `pty_throughput`, `wait_timeout`, `tree_kill`,
`leaf_kill`, `end_recorded`, and one per operation of the rest of the API
(`bench/coverage.zig`): `exchange`, `collect`, `input_writer`,
`read_available`, `try_wait`, `reaper_wait`, `expect`, `proxy`,
`shell_spawn`, `pty_open`, `tty_ops`, `find_program`, `environ`,
`process_identity`, `signal`, `extra_fds` and `wait_tree`.

`BENCH_TRUE`, `BENCH_ECHO`, `BENCH_CAT`, `BENCH_SLEEP` and `BENCH_SH` name
the programs the children run, if the ones on `PATH` will not do.
