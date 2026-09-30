#!/usr/bin/env bash
# conduit before/after on Linux, in Docker (ci/linux.sh's glibc image). No
# rivals: the conduit sides only, each a build of conduit-bench for one commit.
#
#   ./linux.sh <commit> [<commit> ...]
#
# Builds build/linux/conduit-bench-<commit> inside the container (from `git
# archive`, the conduit tree untouched), then runs the interleaved protocol of
# alternate.sh -- every trial runs each side once, order rotated per trial,
# each run started at 1-minute load < BENCH_MAX_LOAD (default 4), best of
# BENCH_RUNS (default 7) -- over BENCH_WORKLOADS (default spawn_wait
# spawn_collect pty_spawn tree_kill leaf_kill), twice: in a default container
# (read-only cgroup mount, so no cgroup containment is possible) and in a
# privileged one (writable cgroup: a build that can contain a child in a
# cgroup of its own does). Raw rows go to build/linux.raw.tsv (or BENCH_RAW)
# with the container kind and start load appended. BENCH_SCALE multiplies
# every iteration count (default 1), for longer runs on a noisy VM, and
# BENCH_CPUSET (e.g. 2-3) pins the container to those CPUs.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="${BENCH_BUILD_DIR:-$here/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
repo="${BENCH_REPO:-$(cd "$here/.." && pwd)}"
image="${BENCH_LINUX_IMAGE:-conduit-linux-glibc-0.16.0}"
(( $# > 0 )) || { echo "usage: $0 <commit> ..." >&2; exit 2; }

mkdir -p "$build/linux"
for commit in "$@"; do
    out="$build/linux/conduit-bench-$commit"
    [[ -x "$out" ]] && continue
    bb="$build/conduitbench-linux-$commit"
    rm -rf "$bb"
    mkdir -p "$bb/conduit-src" "$bb/src"
    git -C "$repo" archive "$commit" | tar -x -C "$bb/conduit-src"
    cp "$here/build.zig" "$bb/"
    sed 's|.path = ".."|.path = "conduit-src"|' "$here/build.zig.zon" > "$bb/build.zig.zon"
    cp "$here/src/conduit_bench.zig" "$bb/src/"
    docker run --rm -v "$bb:/b" -w /b "$image" \
        "${ZIG:-zig}" build -j1 --prefix out -Doptimize=ReleaseFast --cache-dir cache --global-cache-dir global-cache
    cp "$bb/out/bin/conduit-bench" "$out"
    rm -rf "$bb"
done

workloads=${BENCH_WORKLOADS:-spawn_wait spawn_collect pty_spawn tree_kill leaf_kill}
raw="${BENCH_RAW:-$build/linux.raw.tsv}"
: > "$raw"
commits="$*"

# The protocol runs inside the container, so the load it reads is the VM's.
inner='
set -eu
max_load=${BENCH_MAX_LOAD:-4}; trials=${BENCH_RUNS:-7}; kind=$1; shift
load1() { cut -d" " -f1 /proc/loadavg; }
wait_quiet() { while awk -v l="$(load1)" -v m="$max_load" "BEGIN{exit !(l>=m)}"; do sleep 20; done; }
count() { case $1 in spawn_wait|spawn_collect) n=2000;; pty_spawn) n=500;; *) n=200;; esac; echo $((n * ${BENCH_SCALE:-1})); }
input() { case $1 in pty_spawn) echo /d/pty-1k.bin;; *) echo /d/arg-1k.txt;; esac; }
set -- $COMMITS
for w in $WORKLOADS; do
  for c in "$@"; do /o/conduit-bench-$c $w $(count $w) $(input $w) >/dev/null; done
  t=0
  while [ $t -lt $trials ]; do
    k=0; n=$#
    while [ $k -lt $n ]; do
      i=$(( (k + t) % n + 1 )); eval c=\${$i}
      wait_quiet; before=$(load1)
      /o/conduit-bench-$c $w $(count $w) $(input $w) | awk -v b="$before" -v s="conduit-$c" -v k="$kind" "BEGIN{FS=OFS=\"\t\"} {\$1=s; print \$0, k, b}"
      k=$((k + 1))
    done
    t=$((t + 1))
    echo "  $kind $w trial $t/$trials, load $(load1)" >&2
  done
done
'
for kind in default privileged; do
    flags=(--rm --init -v "$build/linux:/o:ro" -v "$build/data:/d:ro"
        -e "COMMITS=$commits" -e "WORKLOADS=$workloads"
        -e "BENCH_MAX_LOAD=${BENCH_MAX_LOAD:-4}" -e "BENCH_RUNS=${BENCH_RUNS:-7}"
        -e "BENCH_SCALE=${BENCH_SCALE:-1}")
    [[ $kind == privileged ]] && flags+=(--privileged)
    [[ -n ${BENCH_CPUSET:-} ]] && flags+=(--cpuset-cpus "$BENCH_CPUSET")
    echo "start $kind $(date '+%F %T')" >&2
    docker run "${flags[@]}" "$image" sh -c "$inner" sh "$kind" >> "$raw"
    echo "end $kind $(date '+%F %T')" >&2
done

awk 'BEGIN { FS=OFS="\t" }
    {
        key=$6 FS $2 FS $1 FS $3 FS $5
        higher=($3 == "throughput")
        if (!(key in best) || (higher ? $4 > best[key] : $4 < best[key])) best[key]=$4
        if (!(key in worst) || (higher ? $4 < worst[key] : $4 > worst[key])) worst[key]=$4
        n[key]++
    }
    END {
        for (k in best) {
            split(k, f, FS)
            printf "%s\t%s\t%s\t%s\t%.2f %s\t(worst %.2f)\t%d runs\n", f[1], f[2], f[3], f[4], best[k], f[5], worst[k], n[k]
        }
    }' "$raw" | sort -t $'\t' -k1,1 -k2,2 -k3,3 | column -t -s $'\t'
