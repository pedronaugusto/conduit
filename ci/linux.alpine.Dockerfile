# The musl Linux image ci/linux.sh --musl runs the suite in.
#
# Alpine is here for one reason: `ptsname_r` disagrees with itself across
# libcs. glibc returns the error number, musl and Darwin return -1 and set
# `errno`. This package reads `errno` on all three and only tests the return
# value against zero, and that claim is worth a second Linux image to hold it
# honest -- the image is small and the Zig release tarball is static, so it
# costs a package and a download.
FROM alpine:3.21
# musl-dev is the libc this package links against here; the others are for
# fetching and unpacking the Zig release.
RUN apk add --no-cache curl xz ca-certificates musl-dev
ARG ZIG=0.16.0
RUN set -e; arch=$(uname -m); \
    for name in "zig-${arch}-linux-${ZIG}" "zig-linux-${arch}-${ZIG}"; do \
      if curl -fsSL "https://ziglang.org/download/${ZIG}/${name}.tar.xz" -o /tmp/zig.tar.xz; then break; fi; done; \
    mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH
WORKDIR /src
