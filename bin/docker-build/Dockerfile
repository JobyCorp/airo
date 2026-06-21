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
# This image is toolchain-only and cache-friendly — source is mounted at run
# time by bin/deploy-docker.sh, not copied in here.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MISE_DATA_DIR=/root/.local/share/mise \
    PATH=/root/.local/bin:/root/.local/share/mise/shims:/root/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Build deps: kerl/OTP-from-source toolchain + ortex/rust + asset fetch.
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential autoconf m4 libncurses-dev libssl-dev \
      ca-certificates curl git unzip xz-utils pkg-config cmake \
    && rm -rf /var/lib/apt/lists/*

# Skip the parts of OTP we never ship in a server release — much faster build.
ENV KERL_CONFIGURE_OPTIONS="--without-wx --without-debugger --without-observer --without-et --without-odbc --without-jinterface"

# mise — same version manager the VM uses.
RUN curl -fsSL https://mise.run | sh

# Compile the pinned toolchain into the image layer (cached across deploys).
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
