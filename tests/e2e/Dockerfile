FROM debian:trixie-slim AS apt-base

ARG DEBIAN_MIRROR=http://mirrors.aliyun.com
RUN sed -i \
        -e "s|http://deb.debian.org/debian-security|${DEBIAN_MIRROR}/debian-security|g" \
        -e "s|http://deb.debian.org/debian|${DEBIAN_MIRROR}/debian|g" \
        /etc/apt/sources.list.d/debian.sources

FROM apt-base AS builder

ARG ZIG_VERSION=0.16.0
ARG ZIG_SHA256=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential ca-certificates cmake curl libfuse3-dev ninja-build \
        pkg-config python3 xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && curl -fsSLo /tmp/zig.tar.xz \
        "https://ziglang.org/download/${ZIG_VERSION}/zig-x86_64-linux-${ZIG_VERSION}.tar.xz" \
    && echo "${ZIG_SHA256}  /tmp/zig.tar.xz" | sha256sum --check - \
    && mkdir /opt/zig \
    && tar -xJf /tmp/zig.tar.xz --strip-components=1 -C /opt/zig \
    && ln -s /opt/zig/zig /usr/local/bin/zig \
    && rm /tmp/zig.tar.xz

WORKDIR /src
COPY . .
RUN mkdir -p /root/.cache/zig/p \
    && cp -a /src/zig-pkg/. /root/.cache/zig/p/ \
    && zig build -Doptimize=ReleaseSafe

FROM apt-base AS controller
RUN apt-get update && apt-get install -y --no-install-recommends netcat-openbsd \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /src/zig-out/bin/zettide-controller /usr/local/bin/zettide-controller
ENTRYPOINT ["/usr/local/bin/zettide-controller"]

FROM apt-base AS data-node
RUN apt-get update && apt-get install -y --no-install-recommends bash netcat-openbsd tgt \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /src/zig-out/bin/zettide-data-node /usr/local/bin/zettide-data-node
COPY tests/e2e/data-node-entrypoint.sh /usr/local/bin/data-node-entrypoint
ENTRYPOINT ["/usr/local/bin/data-node-entrypoint"]

FROM apt-base AS smoke
ARG GRPCURL_VERSION=1.9.3
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash ca-certificates curl jq libiscsi-bin \
    && rm -rf /var/lib/apt/lists/* \
    && curl --retry 5 --retry-all-errors --retry-delay 2 -fsSLo /tmp/grpcurl.tar.gz \
        "https://github.com/fullstorydev/grpcurl/releases/download/v${GRPCURL_VERSION}/grpcurl_${GRPCURL_VERSION}_linux_x86_64.tar.gz" \
    && tar -xzf /tmp/grpcurl.tar.gz -C /usr/local/bin grpcurl \
    && rm /tmp/grpcurl.tar.gz
COPY services/controller/proto /proto
COPY tests/e2e/smoke.sh /usr/local/bin/zettide-e2e-smoke
ENTRYPOINT ["/usr/local/bin/zettide-e2e-smoke"]
