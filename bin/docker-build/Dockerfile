# Builder image for airo prod releases.
#
# Why this exists: the local dev host moved to glibc 2.43 (Ubuntu 26.04), but
# the airo VM runs Ubuntu 24.04 (glibc 2.39). A release (bundled ERTS + native
# NIFs like ortex) built on 2.43 will not start on the VM. Building inside
# ubuntu:24.04 makes beam.smp AND every NIF link against glibc 2.39, matching
# the target exactly.
#
# Toolchain mirrors the VM: mise-managed erlang 28.5 + elixir 1.19.5-otp-28,
# plus rustup stable for the ortex (ONNX/Ortex) Rust NIF.
#
# This image is toolchain-only and cache-friendly — source is copied in at run
# time by bin/deploy-docker.sh, not baked in here.
#
# --platform is hard-pinned: the artifact only ever targets the x86_64 VM, so
# building this image for any other arch (e.g. natively on Apple Silicon) is
# always a mistake. On arm64 hosts this runs under Rosetta/QEMU.
FROM --platform=linux/amd64 ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MISE_DATA_DIR=/root/.local/share/mise \
    PATH=/root/.local/bin:/root/.local/share/mise/shims:/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Build deps: NIF/toolchain compilers + asset fetch. (Also covers a kerl
# OTP-from-source fallback, though mise normally pulls a precompiled OTP.)
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential autoconf m4 libncurses-dev libssl-dev \
      ca-certificates curl git unzip xz-utils pkg-config cmake \
    && rm -rf /var/lib/apt/lists/*

# Only relevant if mise falls back to compiling OTP from source: skip the
# parts we never ship in a server release.
ENV KERL_CONFIGURE_OPTIONS="--without-wx --without-debugger --without-observer --without-et --without-odbc --without-jinterface"

# BEAM's x86_64 JIT segfaults under Rosetta (Apple Silicon hosts running this
# amd64 image): Rosetta can't translate the JIT's dual-mapped W^X code pages.
# +JMsingle true (single-mapped RWX, the documented Rosetta workaround) fixes
# every BEAM run inside the container. Build-time only — the env isn't part of
# the release, so the VM runs the JIT with default settings.
ENV ERL_FLAGS="+JMsingle true"

# mise — same version manager the VM uses.
RUN curl -fsSL https://mise.run | sh

# Install the pinned toolchain into the image layer (cached across deploys).
# mise resolves a precompiled amd64 ubuntu-24.04 OTP build — no source compile.
# node is needed to npm-install the assets/ JS deps (vega-embed et al) that
# esbuild bundles for the perf chart.
RUN mise use -g erlang@28.5 elixir@1.19.5-otp-28 node@24 \
    && mise install \
    && mise reshim \
    && mise exec -- mix local.hex --force \
    && mise exec -- mix local.rebar --force

# Rust for the ortex NIF.
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal

WORKDIR /build
