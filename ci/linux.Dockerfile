# The glibc Linux image ci/linux.sh runs the suite in.
#
# Debian, because glibc is the libc most Linux users have, and because its
# `ptsname_r` is the one that reports failure by returning the error number
# rather than by returning -1 -- the split this package had to be taught. The
# other half of that split is ci/linux.alpine.Dockerfile.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl xz-utils ca-certificates && rm -rf /var/lib/apt/lists/*
ARG ZIG=0.16.0
RUN set -e; arch=$(uname -m); \
    for name in "zig-${arch}-linux-${ZIG}" "zig-linux-${arch}-${ZIG}"; do \
      if curl -fsSL "https://ziglang.org/download/${ZIG}/${name}.tar.xz" -o /tmp/zig.tar.xz; then break; fi; done; \
    mkdir -p /opt/zig && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 && rm /tmp/zig.tar.xz
ENV PATH=/opt/zig:$PATH
WORKDIR /src
