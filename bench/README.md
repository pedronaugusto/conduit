# conduit's benchmarks

conduit's own measurements of its own calls. They run on POSIX, on a quiet
machine, and are never timed in CI: `zig build bench-build` compiles them, and
`zig build test` runs each once with `--smoke`, every row once and no clock
read, so they keep working with the API.

```sh
zig build bench                                  # all of them
zig-out/bench/conduit-bench --row spawn_wait     # the rows whose name starts so
zig-out/bench/conduit-bench --samples 100        # a hundred samples a row
```

builds three programs in ReleaseFast into `zig-out/bench` and runs them, one
after another. Each prints one JSON line a row on standard output, which
shakedown's `bench` writes: every sample in nanoseconds per unit, in the order
taken, with the best, median and p99, the units a sample times, the commit and
the machine. `zig build bench-ab` runs two commits against each other.

- `lifecycle-claims --quiet-machine` measures the ratios and bounds the
  package promises, and says on standard error whether each holds.
- `orphans-cost` measures `Orphans` on Linux.
- `conduit-bench [--row <prefix>] [--samples <n>] [--input <file>]` measures
  one row per operation of the API. `--input` is a file the size rows read; with
  none it makes a 1 KiB line (1023 bytes and a newline), which is what the
  spawn, terminal and operation rows want. The size rows (`exchange`, `collect`,
  `input_writer`, `proxy`, `pty_throughput`) take any file of whole lines.

## Rows

A row is either **batched** or **sampled**. A batched row's sample is a run of
as many operations as it takes to be long enough to read, and the row is the
mean time of one. A sampled row's sample is one operation, set up before the
clock and torn down after it: the child it kills or waits on is started first,
so the sample is the call and nothing else. A sampled row's unit is the
operation, and a call too short to read is an error, not a longer batch.

`conduit-bench` batched: `spawn_wait`, `spawn_collect`, `pty_spawn`,
`pty_spawn_child_kill`, `exchange`, `collect`, `input_writer`, `try_wait`,
`reaper_wait`, `expect/until`, `expect/until_any`, `expect/bytes`,
`shell_spawn`, `pty_open`, `tty_ops/raw_restore`, `tty_ops/win_size`,
`tty_ops/set_win_size`, `tty_ops/pty_size`, `tty_ops/pty_resize`,
`tty_ops/is_tty`, `tty_ops/tty_name`, `tty_ops/foreground_group`,
`find_program/hit`, `find_program/miss`, `environ/inherit`, `environ/only`,
`process_identity/exists`, `process_identity/start_time`,
`process_identity/capture`, `signal` and `extra_fds`.

`conduit-bench` sampled: `pty_throughput`, `wait_timeout`, `tree_kill`,
`end_recorded`, `leaf_kill/kill` (the call) and `leaf_kill/latency` (the call and
the reap), `read_available`, `proxy`, and on Linux `wait_tree`.

- The size rows' throughput is the input's size over the sample:
  `ops_per_second` times the bytes of the file. `pty_throughput` is a sample of
  its own with a fresh `cat`, so its first bytes wait for the child to start.
- `wait_timeout` times `waitTimeout` on a child that ends in ten milliseconds,
  started before the clock; its overshoot is a sample less those ten.
- `tree_kill` and `end_recorded` end a shell with two children of its own; every
  descendant is confirmed gone after the sample.
- `wait_tree` asks for a Linux child's cgroup once the child has ended. It is
  a row only where this process may make a cgroup.
- A conversation row's `cat` has made one round trip before the clock.

`lifecycle-claims` measures `wait/blocking` and `wait/deadlined`,
`spawn/file_actions` and `spawn/fork` in turn, a round of one then a round of
the other, and the ratios are of their best samples; and `stop/honoured`,
`stop/call`, `stop/forced`, `reaper/join` and `expect/join`, whose bounds are on
the slowest of their samples.

`orphans-cost` measures `spawn_wait/off` and `spawn_wait/on` (spawn and wait of
`true` with `Orphans` tracking off and on) and `look/0`, `look/10` and
`look/100` (one `Orphans.count` with that many live children of conduit's own).

`BENCH_TRUE`, `BENCH_ECHO`, `BENCH_CAT`, `BENCH_SLEEP` and `BENCH_SH` name
the programs the children run, if the ones on `PATH` will not do.
