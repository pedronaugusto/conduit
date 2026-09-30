#!/usr/bin/env bash
# Interleaved head-to-head: every trial runs each side once, in an order that
# rotates per trial, and waits for the 1-minute load average to fall under
# BENCH_MAX_LOAD (default 4) before each run. Best of BENCH_RUNS (default 7)
# per side and workload: the smallest latency or overshoot, the largest
# throughput. Raw rows, with the load at each run, go to
# build/alternate.raw.tsv (or BENCH_RAW).
#
#   ./alternate.sh [workload ...]
#
# Workloads: spawn_wait spawn_collect pty_spawn pty_throughput wait_timeout
# tree_kill (default: all six), and leaf_kill (conduit sides only: the stop of
# a detached child that never forks, a diagnostic). pty_spawn also runs the diagnostic side
# conduit-childkill (the same lifecycle ended with one kill to the child's pid,
# as the rivals end it).
#
# Iteration counts are run.sh's, except the two PTY SPAWN sides that are two
# orders of magnitude behind (portable-pty, ptyprocess), which run fewer
# iterations of the same mean-per-cycle measure so a trial stays minutes long.
#
# BENCH_NO_BUILD=1 measures the binaries already built. BENCH_VARIANTS=
# "label=binary ..." adds other builds of conduit-bench as sides
# "conduit-<label>" -- per-commit.sh makes them -- so a change is measured
# against the code before it in the same run.
set -euo pipefail
cd "$(dirname "$0")"
build="${BENCH_BUILD_DIR:-$PWD/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"

[[ "${BENCH_NO_BUILD:-0}" == 1 ]] || BENCH_BUILD_ONLY=1 ./run.sh >/dev/null

max_load=${BENCH_MAX_LOAD:-4}
trials=${BENCH_RUNS:-7}
d="$build/data"
zig="$build/zig/bin/conduit-bench"
rust="$build/cargo/release/conduit-rust-bench"
go="$build/go-bench"
cb="$build/c-bench"
py="$build/venv/bin/python $PWD/src/python/bench.py"

workloads=("$@")
if (( ${#workloads[@]} == 0 )); then
    workloads=(spawn_wait spawn_collect pty_spawn pty_throughput wait_timeout tree_kill)
fi

load1() { sysctl -n vm.loadavg | awk '{print $2}'; }
wait_quiet() {
    while awk -v l="$(load1)" -v m="$max_load" 'BEGIN{exit !(l>=m)}'; do sleep 20; done
}

variants=${BENCH_VARIANTS:-}
# "tag<TAB>command" per side; a conduit variant's rows are renamed to its tag.
sides_for() {
    local w=$1 v
    case "$w" in
        spawn_wait|spawn_collect)
            printf 'conduit\t%s %s 2000 %s/arg-1k.txt\n' "$zig" "$w" "$d"
            for v in $variants; do printf 'conduit-%s\t%s %s 2000 %s/arg-1k.txt\n' "${v%%=*}" "${v#*=}" "$w" "$d"; done
            printf 'rust\t%s %s 2000 %s/arg-1k.txt\n' "$rust" "$w" "$d"
            printf 'go\t%s %s 2000 %s/arg-1k.txt\n' "$go" "$w" "$d"
            printf 'c-posix_spawn\t%s posix_%s 2000 %s/arg-1k.txt\n' "$cb" "$w" "$d"
            printf 'c-fork\t%s fork_%s 2000 %s/arg-1k.txt\n' "$cb" "${w#spawn_}" "$d"
            printf 'python\t%s %s 2000 %s/arg-1k.txt\n' "$py" "$w" "$d" ;;
        pty_spawn)
            printf 'conduit\t%s pty_spawn 500 %s/pty-1k.bin\n' "$zig" "$d"
            printf 'conduit-childkill\t%s pty_spawn_child_kill 500 %s/pty-1k.bin\n' "$zig" "$d"
            for v in $variants; do printf 'conduit-%s\t%s pty_spawn 500 %s/pty-1k.bin\n' "${v%%=*}" "${v#*=}" "$d"; done
            printf 'rust\t%s pty_spawn 50 %s/pty-1k.bin\n' "$rust" "$d"
            printf 'go\t%s pty_spawn 500 %s/pty-1k.bin\n' "$go" "$d"
            printf 'c\t%s pty_spawn 500 %s/pty-1k.bin\n' "$cb" "$d"
            printf 'python\t%s pty_spawn 20 %s/pty-1k.bin\n' "$py" "$d" ;;
        pty_throughput)
            printf 'conduit\t%s pty_throughput 1 %s/pty-64m.bin\n' "$zig" "$d"
            for v in $variants; do printf 'conduit-%s\t%s pty_throughput 1 %s/pty-64m.bin\n' "${v%%=*}" "${v#*=}" "$d"; done
            printf 'rust\t%s pty_throughput 1 %s/pty-64m.bin\n' "$rust" "$d"
            printf 'go\t%s pty_throughput 1 %s/pty-64m.bin\n' "$go" "$d"
            printf 'c\t%s pty_throughput 1 %s/pty-64m.bin\n' "$cb" "$d"
            printf 'python\t%s pty_throughput 1 %s/pty-64m.bin\n' "$py" "$d" ;;
        wait_timeout)
            printf 'conduit\t%s wait_timeout 500 %s/arg-1k.txt\n' "$zig" "$d"
            for v in $variants; do printf 'conduit-%s\t%s wait_timeout 500 %s/arg-1k.txt\n' "${v%%=*}" "${v#*=}" "$d"; done
            printf 'go\t%s wait_timeout 500 %s/arg-1k.txt\n' "$go" "$d"
            printf 'c\t%s wait_timeout 500 %s/arg-1k.txt\n' "$cb" "$d"
            printf 'python\t%s wait_timeout 500 %s/arg-1k.txt\n' "$py" "$d" ;;
        tree_kill)
            printf 'conduit\t%s tree_kill 200 %s/arg-1k.txt\n' "$zig" "$d"
            for v in $variants; do printf 'conduit-%s\t%s tree_kill 200 %s/arg-1k.txt\n' "${v%%=*}" "${v#*=}" "$d"; done
            printf 'rust\t%s tree_kill 200 %s/arg-1k.txt\n' "$rust" "$d"
            printf 'go\t%s tree_kill 200 %s/arg-1k.txt\n' "$go" "$d"
            printf 'c\t%s tree_kill 200 %s/arg-1k.txt\n' "$cb" "$d"
            printf 'python\t%s tree_kill 200 %s/arg-1k.txt\n' "$py" "$d" ;;
        leaf_kill)
            printf 'conduit\t%s leaf_kill 200 %s/arg-1k.txt\n' "$zig" "$d"
            for v in $variants; do printf 'conduit-%s\t%s leaf_kill 200 %s/arg-1k.txt\n' "${v%%=*}" "${v#*=}" "$d"; done ;;
        *) echo "unknown workload $w" >&2; exit 2 ;;
    esac
}

raw="${BENCH_RAW:-$build/alternate.raw.tsv}"
: > "$raw"
echo "start $(date '+%F %T') load $(load1)" >&2
for w in "${workloads[@]}"; do
    lines=()
    while IFS= read -r l; do lines+=("$l"); done < <(sides_for "$w")
    n=${#lines[@]}
    # untimed warm-up of each side (run the cheap rows once; skip the slow PTY sides)
    for l in "${lines[@]}"; do
        case "$w:${l%%$'\t'*}" in pty_spawn:rust|pty_spawn:python) continue ;; esac
        ${l#*$'\t'} >/dev/null
    done
    for (( t = 0; t < trials; t++ )); do
        for (( k = 0; k < n; k++ )); do
            l=${lines[$(( (k + t) % n ))]}
            wait_quiet
            before=$(load1)
            tag=${l%%$'\t'*}
            ${l#*$'\t'} | awk -v b="$before" -v t="$tag" 'BEGIN{FS=OFS="\t"}
                { if (t ~ /^conduit-/ && $1 == "conduit") $1 = t; print $0, b }' >> "$raw"
        done
        printf '  %s trial %d/%d done, load %s\n' "$w" $((t + 1)) "$trials" "$(load1)" >&2
    done
done
echo "end $(date '+%F %T') load $(load1)" >&2

awk 'BEGIN { FS=OFS="\t" }
    {
        key=$2 FS $1 FS $3 FS $5
        higher=($3 == "throughput")
        if (!(key in best) || (higher ? $4 > best[key] : $4 < best[key])) best[key]=$4
        if (!(key in worst) || (higher ? $4 < worst[key] : $4 > worst[key])) worst[key]=$4
        n[key]++
    }
    END {
        for (k in best) {
            split(k, f, FS)
            printf "%s\t%s\t%s\t%.2f %s\t(worst %.2f)\t%d runs\n", f[1], f[2], f[3], best[k], f[4], worst[k], n[k]
        }
    }' "$raw" | sort -t $'\t' -k1,1 -k4,4n | column -t -s $'\t'
