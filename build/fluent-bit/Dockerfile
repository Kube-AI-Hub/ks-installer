# fluent-bit for Kylin v10 ARM64 (PAGESIZE=65536) and 4KiB hosts.
#
# Official fluent/fluent-bit and kubesphere/fluent-bit images compile jemalloc
# for 4KiB pages. On 64KiB kernels jemalloc aborts with:
#   <jemalloc>: Unsupported system page size
# Rebuild with --with-lg-page=16 (2^16=65536). jemalloc 4.2+ allows a compiled
# page size larger than the host, so the same binary also runs on 4KiB amd64.
#
# 5.1.1 matches upstream dockerfiles/Dockerfile: Debian 13 (trixie) +
# distroless/cc-debian13. The 5.1.1 binary cannot run on
# kubesphere/fluent-bit:v3.0.4 (Debian 11 / libssl1.1).
#
# Runtime is the mirrored official fluent/fluent-bit (matching libs).
# fluent-bit-watcher is copied from mirrored kubesphere/fluent-bit:v3.0.4 for
# fluentbit-operator v0.14.0 (config at /fluent-bit/config, entrypoint watcher).

ARG WATCHER_IMAGE=watering-ai-registry.cn-shanghai.cr.aliyuncs.com/kube-ai-hub/fluent-bit:v3.0.4
ARG RUNTIME_IMAGE=watering-ai-registry.cn-shanghai.cr.aliyuncs.com/kube-ai-hub/fluent/fluent-bit:5.1.1

FROM watering-ai-registry.cn-shanghai.cr.aliyuncs.com/kube-ai-hub/debian:trixie-slim AS builder

ARG FLUENT_BIT_VERSION=5.1.1
ARG FLUENT_BIT_TARBALL_URL
ARG DEBIAN_MIRROR=

ENV DEBIAN_FRONTEND=noninteractive

RUN set -eux; \
    if [ -n "${DEBIAN_MIRROR}" ]; then \
      if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
        sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g; s|security.debian.org|${DEBIAN_MIRROR}|g" \
          /etc/apt/sources.list.d/debian.sources; \
      fi; \
      if [ -f /etc/apt/sources.list ]; then \
        sed -i "s|deb.debian.org|${DEBIAN_MIRROR}|g; s|security.debian.org|${DEBIAN_MIRROR}|g" \
          /etc/apt/sources.list; \
      fi; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      curl \
      flex \
      bison \
      autoconf \
      automake \
      libtool \
      pkg-config \
      libssl-dev \
      libcurl4-openssl-dev \
      libsasl2-dev \
      libsystemd-dev \
      zlib1g-dev \
      libpq-dev \
      postgresql-server-dev-all \
      libyaml-dev \
    && apt-get satisfy -y cmake "cmake (<< 4.0)" \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src/fluent-bit

RUN set -eux; \
    url="${FLUENT_BIT_TARBALL_URL:-https://github.com/fluent/fluent-bit/archive/refs/tags/v${FLUENT_BIT_VERSION}.tar.gz}"; \
    curl -fsSL "${url}" | tar xz --strip-components=1

WORKDIR /src/fluent-bit/build

# --with-lg-page=16: 64KiB pages (Kylin v10 ARM64). --with-lg-quantum=3 is the
# jemalloc default and must be restated whenever FLB_JEMALLOC_OPTIONS is set.
RUN cmake -DFLB_RELEASE=On \
      -DFLB_SIMD=On \
      -DFLB_JEMALLOC=On \
      -DFLB_JEMALLOC_OPTIONS="--with-lg-page=16 --with-lg-quantum=3" \
      -DFLB_TLS=On \
      -DFLB_SHARED_LIB=Off \
      -DFLB_EXAMPLES=Off \
      -DFLB_HTTP_SERVER=On \
      -DFLB_IN_EXEC=Off \
      -DFLB_IN_SYSTEMD=On \
      -DFLB_OUT_KAFKA=On \
      -DFLB_OUT_PGSQL=On \
      -DFLB_CHUNK_TRACE=On \
      -DFLB_LOG_NO_CONTROL_CHARS=On \
      .. \
    && make -j"$(getconf _NPROCESSORS_ONLN)" \
    && test -x bin/fluent-bit

FROM ${WATCHER_IMAGE} AS watcher

FROM ${RUNTIME_IMAGE}

COPY --from=builder /src/fluent-bit/build/bin/fluent-bit /fluent-bit/bin/fluent-bit
COPY --from=watcher /fluent-bit/bin/fluent-bit-watcher /fluent-bit/bin/fluent-bit-watcher
# Match kubesphere/fluent-bit: watcher starts /fluent-bit/etc/fluent-bit.conf,
# which must include the operator Secret mounted at /fluent-bit/config.
COPY fluent-bit.conf /fluent-bit/etc/fluent-bit.conf

# Drop official fluent-bit CMD so Kubernetes does not pass it as watcher args.
ENTRYPOINT ["/fluent-bit/bin/fluent-bit-watcher"]
CMD []
