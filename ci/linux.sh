#!/usr/bin/env bash
#
# zpty — the suite on Linux, in Docker, from a machine that is not Linux.
#
# A pseudo-terminal is a kernel object and a process group is a kernel concept,
# so "it compiles for Linux" is not the same claim as "it works on Linux". This
# runs the whole suite there, on a real kernel, in Debug and in ReleaseSafe:
# Debug because its safety checks are the ones that catch a bad enum or a bad
# index, and ReleaseSafe because the code between `fork` and `execve` is the
# kind an inlining decision can change.
#
# Usage: ci/linux.sh           # glibc (Debian)
#        ci/linux.sh --musl    # musl (Alpine), where ptsname_r differs
#        ci/linux.sh --both    # one after the other
#
# The caches live under /tmp inside the container, not in the checkout: the
# host's .zig-cache holds objects built for the host, and letting a Linux
# container write into it would leave the next native build to sort out the
# mixture.

set -euo pipefail
cd "$(dirname "$0")/.."

readonly zig_version=0.16.0
readonly modes=(Debug ReleaseSafe)

usage() {
    sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'
}

# Builds the image if it is not already there, then runs the suite in it.
run_in() {
    local libc=$1 dockerfile=$2 image=$3

    echo "==> $libc: image $image"
    docker build \
        --quiet \
        --file "$dockerfile" \
        --build-arg "ZIG=$zig_version" \
        --tag "$image" \
        ci >/dev/null

    for mode in "${modes[@]}"; do
        echo "==> $libc: zig build test -Doptimize=$mode"
        # --init so PID 1 reaps anything the suite's children leave behind, and
        # a read-only mount of nothing: the checkout is mounted read-write
        # because `zig build` writes nowhere else, and both caches are
        # redirected out of it.
        docker run --rm --init \
            --volume "$PWD:/src" \
            --workdir /src \
            "$image" \
            zig build test \
            -Doptimize="$mode" \
            --cache-dir /tmp/zc \
            --global-cache-dir /tmp/zg \
            --summary all
    done

    echo "==> $libc: zig fmt --check"
    docker run --rm --init \
        --volume "$PWD:/src" \
        --workdir /src \
        "$image" \
        zig fmt --check src examples build.zig
}

glibc=1
musl=0
case "${1-}" in
"") ;;
--musl)
    glibc=0
    musl=1
    ;;
--both) musl=1 ;;
-h | --help)
    usage
    exit 0
    ;;
*)
    echo "ci/linux.sh: unknown argument: $1" >&2
    usage >&2
    exit 2
    ;;
esac

if ! docker info >/dev/null 2>&1; then
    echo "ci/linux.sh: Docker is not running." >&2
    exit 1
fi

if [ "$glibc" = 1 ]; then
    run_in glibc ci/linux.Dockerfile "zpty-linux-glibc-$zig_version"
fi
if [ "$musl" = 1 ]; then
    run_in musl ci/linux.alpine.Dockerfile "zpty-linux-musl-$zig_version"
fi

echo "==> all green"
