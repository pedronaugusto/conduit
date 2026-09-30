#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"
build="${BENCH_BUILD_DIR:-$ROOT/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
results="${BENCH_RESULTS:-$build/results.tsv}"

mkdir -p "$build" "$build/data" "$build/zig-cache" "$build/zig-global" "$build/cargo-home" "$build/cargo" \
    "$build/go-cache" "$build/go-mod" "$build/go-path" "$build/pip-cache"

"${PYTHON:-python3}" src/gen_input.py "$build/data"

ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$build/zig-global}" \
ZIG_LOCAL_CACHE_DIR="$build/zig-cache" \
    "${ZIG:-zig}" build -j1 -Doptimize=ReleaseFast -Dsmoke=$([ "${SMOKE:-0}" = 1 ] && echo true || echo false) --prefix "$build/zig"

CARGO_HOME="${CARGO_HOME:-$build/cargo-home}" \
    "${CARGO:-cargo}" build -j1 --release --locked --manifest-path src/rust/Cargo.toml --target-dir "$build/cargo"

(cd src/go && \
    GOPATH="${GOPATH:-$build/go-path}" GOCACHE="${GOCACHE:-$build/go-cache}" GOMODCACHE="${GOMODCACHE:-$build/go-mod}" \
    "${GO:-go}" build -p=1 -mod=readonly -ldflags='-s -w' -o "$build/go-bench" .)

"${CC:-cc}" -O2 -Wall -Wextra -Werror -pthread src/c/bench.c -o "$build/c-bench"

if [ ! -x "$build/venv/bin/python" ]; then
    "${PYTHON:-python3}" -m venv "$build/venv"
fi
PIP_CACHE_DIR="$build/pip-cache" \
    "$build/venv/bin/python" -m pip install --disable-pip-version-check --quiet \
    -r src/python/requirements.txt

if [ "${BENCH_BUILD_ONLY:-0}" = 1 ]; then
    exit 0
fi

if [ "${SMOKE:-0}" = 1 ]; then
    REPS=1
    SPAWN_N=1
    PTY_N=1
    WAIT_N=1
    TREE_N=1
    THROUGHPUT_INPUT="$build/data/pty-1k.bin"
else
    REPS=5
    SPAWN_N=2000
    PTY_N=500
    WAIT_N=500
    TREE_N=200
    THROUGHPUT_INPUT="$build/data/pty-64m.bin"
fi

RAW="$build/runs.tsv"
: > "$RAW"

point() {
    point_input=$1
    point_iterations=$2
    shift 2
    point_rep=1
    while [ "$point_rep" -le "$REPS" ]; do
        line=$("$@" "$point_iterations" "$point_input")
        fields=$(printf '%s\n' "$line" | awk -F '\t' 'NF == 5 { n++ } END { print n+0 }')
        if [ "$fields" -ne 1 ]; then
            printf 'invalid benchmark output: %s\n' "$line" >&2
            exit 1
        fi
        printf '%s\n' "$line" >> "$RAW"
        point_rep=$((point_rep + 1))
    done
}

# Spawn and wait.
point "$build/data/arg-1k.txt" "$SPAWN_N" "$build/zig/bin/conduit-bench" spawn_wait
point "$build/data/arg-1k.txt" "$SPAWN_N" "$build/cargo/release/conduit-rust-bench" spawn_wait
point "$build/data/arg-1k.txt" "$SPAWN_N" "$build/go-bench" spawn_wait
point "$build/data/arg-1k.txt" "$SPAWN_N" "$build/c-bench" posix_spawn_wait
point "$build/data/arg-1k.txt" "$SPAWN_N" "$build/c-bench" fork_wait
point "$build/data/arg-1k.txt" "$SPAWN_N" "$build/venv/bin/python" src/python/bench.py spawn_wait

# Spawn, capture, and verify 1,025 output bytes.
point "$build/data/arg-1k.txt" "$SPAWN_N" "$build/zig/bin/conduit-bench" spawn_collect
point "$build/data/arg-1k.txt" "$SPAWN_N" "$build/cargo/release/conduit-rust-bench" spawn_collect
point "$build/data/arg-1k.txt" "$SPAWN_N" "$build/go-bench" spawn_collect
point "$build/data/arg-1k.txt" "$SPAWN_N" "$build/c-bench" posix_spawn_collect
point "$build/data/arg-1k.txt" "$SPAWN_N" "$build/c-bench" fork_collect
point "$build/data/arg-1k.txt" "$SPAWN_N" "$build/venv/bin/python" src/python/bench.py spawn_collect

# PTY lifecycle and byte transfer.
point "$build/data/pty-1k.bin" "$PTY_N" "$build/zig/bin/conduit-bench" pty_spawn
point "$build/data/pty-1k.bin" "$PTY_N" "$build/cargo/release/conduit-rust-bench" pty_spawn
point "$build/data/pty-1k.bin" "$PTY_N" "$build/go-bench" pty_spawn
point "$build/data/pty-1k.bin" "$PTY_N" "$build/c-bench" pty_spawn
point "$build/data/pty-1k.bin" "$PTY_N" "$build/venv/bin/python" src/python/bench.py pty_spawn

point "$THROUGHPUT_INPUT" 1 "$build/zig/bin/conduit-bench" pty_throughput
point "$THROUGHPUT_INPUT" 1 "$build/cargo/release/conduit-rust-bench" pty_throughput
point "$THROUGHPUT_INPUT" 1 "$build/go-bench" pty_throughput
point "$THROUGHPUT_INPUT" 1 "$build/c-bench" pty_throughput
point "$THROUGHPUT_INPUT" 1 "$build/venv/bin/python" src/python/bench.py pty_throughput

# Deadline-aware wait. Rust std and portable-pty have no wait-with-timeout API.
point "$build/data/arg-1k.txt" "$WAIT_N" "$build/zig/bin/conduit-bench" wait_timeout
point "$build/data/arg-1k.txt" "$WAIT_N" "$build/go-bench" wait_timeout
point "$build/data/arg-1k.txt" "$WAIT_N" "$build/c-bench" wait_timeout
point "$build/data/arg-1k.txt" "$WAIT_N" "$build/venv/bin/python" src/python/bench.py wait_timeout

# Exact fixed tree: all descendants remain in the new process group.
point "$build/data/arg-1k.txt" "$TREE_N" "$build/zig/bin/conduit-bench" tree_kill
point "$build/data/arg-1k.txt" "$TREE_N" "$build/cargo/release/conduit-rust-bench" tree_kill
point "$build/data/arg-1k.txt" "$TREE_N" "$build/go-bench" tree_kill
point "$build/data/arg-1k.txt" "$TREE_N" "$build/c-bench" tree_kill
point "$build/data/arg-1k.txt" "$TREE_N" "$build/venv/bin/python" src/python/bench.py tree_kill

{
    printf 'side\tworkload\tmetric\tvalue\tunit\n'
    awk -F '\t' 'BEGIN { OFS="\t" }
        {
            key=$1 SUBSEP $2 SUBSEP $3 SUBSEP $5
            if (!(key in seen)) {
                seen[key]=1; order[++count]=key
                side[key]=$1; workload[key]=$2; metric[key]=$3; value[key]=$4; unit[key]=$5
            } else if (($3 == "throughput" && $4+0 > value[key]+0) ||
                       ($3 != "throughput" && $4+0 < value[key]+0)) {
                value[key]=$4
            }
        }
        END {
            for (i=1; i<=count; i++) {
                key=order[i]
                print side[key], workload[key], metric[key], value[key], unit[key]
            }
        }' "$RAW"
    printf 'rust-std\tWAIT-TIMEOUT\tovershoot\tn/a\tus\n'
    if ! command -v node >/dev/null 2>&1; then
        printf 'node-pty (unavailable)\tPTY SPAWN\tlatency\tn/a\tus\n'
        printf 'node-pty (unavailable)\tPTY THROUGHPUT\tthroughput\tn/a\tMB/s\n'
    fi
} > "$results.tmp"
mv "$results.tmp" "$results"

awk -F '\t' '
    NR == 1 { printf "%-27s  %-16s  %-11s  %14s  %s\n", $1, $2, $3, $4, $5; next }
    { printf "%-27s  %-16s  %-11s  %14s  %s\n", $1, $2, $3, $4, $5 }
' "$results"
