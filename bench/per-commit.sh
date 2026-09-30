#!/usr/bin/env bash
# Builds conduit-bench against each named conduit commit, into
# build/conduit-bench-<commit>, for alternate.sh's BENCH_VARIANTS. The commit
# is exported with `git archive`, so the conduit repository's working tree and
# worktree list are never touched. Scratch directories live under build/.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
build="${BENCH_BUILD_DIR:-$here/build}"
mkdir -p "$build"
build="$(cd "$build" && pwd)"
repo="${BENCH_REPO:-$(cd "$here/.." && pwd)}"
for c in "$@"; do
    out="$build/conduit-bench-$c"
    [[ -x "$out" ]] && continue
    bb="$build/conduitbench-bb-$c"
    rm -rf "$bb"
    mkdir -p "$bb/conduit-src" "$bb/src"
    git -C "$repo" archive "$c" | tar -x -C "$bb/conduit-src"
    cp "$here/build.zig" "$bb/"
    sed 's|.path = ".."|.path = "conduit-src"|' "$here/build.zig.zon" > "$bb/build.zig.zon"
    cp "$here/src/conduit_bench.zig" "$bb/src/"
    (cd "$bb" && "${ZIG:-zig}" build -j1 --prefix "$bb/out" -Doptimize=ReleaseFast)
    cp "$bb/out/bin/conduit-bench" "$out"
    rm -rf "$bb"
done
