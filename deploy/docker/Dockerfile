# syntax=docker/dockerfile:1
#
# moonflux, in a container: the platform plus the SDF example catalog.
#
# WHY THE IMAGE PRESERVES THE REPO LAYOUT
#
# The catalog's specs reference operator wasm modules by REPO-RELATIVE path
# (_build/wasm/debug/build/apps/operator-*/…​.wasm, 77 references across
# examples/sdf). Rewriting those paths to suit an image would put the image in
# charge of the catalog, so the image keeps the layout instead: /opt/moonflux is
# the repository root, and a case runs from there with the same spec files a
# gate would use. That is also why the runtime stage copies the DEBUG wasm
# modules: they are the paths the catalog names.
#
# Two facts this Dockerfile inherits rather than re-decides:
#   * the MoonBit toolchain is installed as `latest`, because the CDN refuses
#     versioned binaries (README decision 80) — CI and this image agree on it;
#   * the operator host dlopens libwasmtime (no link-time dependency), so the
#     runtime image carries the shared library and names it in
#     MOONFLUX_WASMTIME_LIB, the same variable CI sets.

# ---- builder -------------------------------------------------------------
FROM debian:bookworm-slim AS builder
ARG WASMTIME_VERSION=48.0.2
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl xz-utils python3 git \
 && rm -rf /var/lib/apt/lists/*

# The wasmtime C API, at the version and prefix CI uses (/usr/local/include is
# what adapters/wasmtime-native/moon.pkg names in its stub-cc-flags).
RUN set -eux; \
    W="wasmtime-v${WASMTIME_VERSION}-x86_64-linux-c-api"; \
    curl -sSfL -o /tmp/wasmtime.tar.xz \
      "https://github.com/bytecodealliance/wasmtime/releases/download/v${WASMTIME_VERSION}/${W}.tar.xz"; \
    tar -xJf /tmp/wasmtime.tar.xz -C /tmp; \
    mkdir -p /usr/local/include /usr/local/lib; \
    cp -R "/tmp/${W}/include/." /usr/local/include/; \
    cp -R "/tmp/${W}/lib/." /usr/local/lib/; \
    rm -rf /tmp/wasmtime.tar.xz "/tmp/${W}"; \
    test -f /usr/local/include/wasmtime.h; \
    test -f /usr/local/lib/libwasmtime.so

RUN curl -fsSL https://cli.moonbitlang.com/install/unix.sh | bash
ENV PATH="/root/.moon/bin:${PATH}"

WORKDIR /src
# the registry index first, so a source change does not re-fetch the world
COPY moon.mod ./
COPY .mooncakes ./.mooncakes
RUN moon update
COPY . .

# the operator modules (wasm), the CLI (release), and the page's kernel (js)
RUN scripts/build-operators.sh \
 && moon build --target native --release \
 && moon build --target js --release apps/editor-kernel

# ---- runtime -------------------------------------------------------------
FROM debian:bookworm-slim AS runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl python3 \
 && rm -rf /var/lib/apt/lists/*
# the shared library the operator host dlopens at runtime
COPY --from=builder /usr/local/lib/libwasmtime.so* /usr/local/lib/
RUN ldconfig

WORKDIR /opt/moonflux
COPY --from=builder /src/_build/native/release/build/apps/cli/cli.exe /usr/local/bin/moonflux
COPY --from=builder /src/_build/wasm/debug/build/apps/ /opt/moonflux/_build/wasm/debug/build/apps/
COPY --from=builder /src/examples/ /opt/moonflux/examples/
COPY --from=builder /src/web/editor/index.html /opt/moonflux/web/editor/index.html
COPY --from=builder /src/_build/js/release/build/apps/editor-kernel/editor-kernel.js /opt/moonflux/web/editor/editor-kernel.js

ENV MOONFLUX_WASMTIME_LIB=/usr/local/lib/libwasmtime.so
ENV MOONFLUX_EXE=/usr/local/bin/moonflux

# a non-root user, and one volume for every data dir the platform keeps
RUN useradd --create-home --uid 10001 moonflux \
 && mkdir -p /data \
 && chown -R moonflux:moonflux /opt/moonflux /data
USER moonflux
VOLUME ["/data"]
EXPOSE 19801 19802 8080

# /healthz is the readiness answer (P35): it reads real state (metadata, the
# applied task set) and a standby control plane answers 503, which is exactly
# what an orchestrator needs to see.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=5 \
  CMD curl -fsS http://127.0.0.1:19802/healthz || exit 1

ENTRYPOINT ["/usr/local/bin/moonflux"]
CMD ["serve", "--data-dir", "/data", "--listen", "0.0.0.0:19801", \
     "--metrics-listen", "0.0.0.0:19802"]
