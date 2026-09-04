#!/usr/bin/env bash
# Build a prod release inside an ubuntu:24.04 container (glibc 2.39 — matches
# the airo VM) and ship it to the airo VM. Use this instead of bin/deploy.sh
# whenever the local build host's glibc is newer than the VM's (2.39), and
# always from macOS — it is the only deploy path that works there: a bundled
# ERTS / native NIF built against a newer glibc (or the wrong OS/arch) will
# not start on the VM.
#
# The build is pinned to linux/amd64 (the VM's arch). On Apple Silicon that
# means emulation — enable Rosetta in your runtime (colima: --vz-rosetta;
# Docker Desktop: "Use Rosetta for x86_64/amd64 emulation") or builds crawl
# under QEMU.
#
# The container toolchain (bin/docker-build/Dockerfile) mirrors the VM:
# mise erlang 28.5 + elixir 1.19.5-otp-28 + node 24, plus rustup stable for
# the ortex NIF.
#
# Usage:
#   bin/deploy-docker.sh                  # build + verify + ship + migrate + restart
#   BUILD_ONLY=1 bin/deploy-docker.sh     # build + verify the artifact, don't ship
#   SKIP_MIGRATE=1 bin/deploy-docker.sh   # skip the migration step
#   SSH_HOST=other bin/deploy-docker.sh   # override the SSH alias
#   REBUILD_IMAGE=1 bin/deploy-docker.sh  # force-rebuild the builder image

set -euo pipefail

SSH_HOST="${SSH_HOST:-airo}"
REMOTE_DIR="${REMOTE_DIR:-/opt/airo}"
REMOTE_TMP="${REMOTE_TMP:-/tmp}"
SERVICE_NAME="${SERVICE_NAME:-airo.service}"
APP_NAME="airo"
IMAGE_TAG="${IMAGE_TAG:-airo-builder:ubuntu2404}"
# The VM (phx2) is x86_64 — pin every docker step to it so a build from an
# arm64 host (Apple Silicon) can't silently produce an aarch64 release.
PLATFORM="${PLATFORM:-linux/amd64}"

cd "$(dirname -- "$0")/.."
if [ ! -f mix.exs ]; then
  echo "error: must run from the project root" >&2
  exit 1
fi

command -v docker >/dev/null || { echo "error: docker not found" >&2; exit 1; }

GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
STAMP="$(date +%Y%m%d-%H%M%S)"
TARBALL="${APP_NAME}-${STAMP}-${GIT_SHA}.tar.gz"

# Builder image — cached unless missing, wrong-arch, or REBUILD_IMAGE=1. The
# toolchain (precompiled OTP via mise + node + rustup) lives in the image
# layer, not per-deploy.
IMAGE_ARCH="$(docker image inspect "${IMAGE_TAG}" --format '{{.Os}}/{{.Architecture}}' 2>/dev/null || true)"
if [ "${REBUILD_IMAGE:-0}" = "1" ] || [ "${IMAGE_ARCH}" != "${PLATFORM}" ]; then
  [ -n "${IMAGE_ARCH}" ] && [ "${IMAGE_ARCH}" != "${PLATFORM}" ] && \
    echo "▸ Cached image is ${IMAGE_ARCH}, need ${PLATFORM} — rebuilding…"
  echo "▸ Building builder image ${IMAGE_TAG} for ${PLATFORM}…"
  docker build --platform "${PLATFORM}" -t "${IMAGE_TAG}" -f bin/docker-build/Dockerfile bin/docker-build
fi

# Stage source = exactly HEAD (git archive), then bring the host's already-fetched
# deps/ in: joby_kit is a private GitHub dep and the container has no GitHub
# credentials, so the host checkout (at the locked ref) is reused instead of
# fetched. Host-compiled native artifacts are scrubbed so the container rebuilds
# them against glibc 2.39 (esp. the ortex/onnxruntime and tokenizers NIFs).
STAGE="$(mktemp -d)"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "${STAGE}" "${OUT_DIR}"' EXIT
echo "▸ Staging source from HEAD (${GIT_SHA}) + host deps…"
git archive HEAD | tar -x -C "${STAGE}"
if [ -d deps ]; then
  cp -a deps "${STAGE}/deps"
  find "${STAGE}/deps" -type d -name target -prune -exec rm -rf {} + 2>/dev/null || true
  find "${STAGE}/deps" -type f \( -name '*.so' -o -name '*.dylib' \) -delete 2>/dev/null || true
fi

# The local ONNX routing classifier models (S15) live under priv/models/, which
# is gitignored — so `git archive` omits them and `mix release` would ship a
# release whose classifier boots :unavailable. There is no HTTPS source in the
# manifest (url: nil), so copy the fetched, checksum-verified artifacts from the
# working tree into the staged source. Fetch them first if missing.
if [ -d priv/models ] && [ -n "$(ls -A priv/models 2>/dev/null)" ]; then
  echo "▸ Including priv/models (local ONNX classifier artifacts)…"
  mkdir -p "${STAGE}/priv/models"
  cp -a priv/models/. "${STAGE}/priv/models/"
else
  echo "error: priv/models is empty — the local classifier won't ship." >&2
  echo "       run 'mix airo.fetch_model <name> --from DIR' before deploying." >&2
  exit 1
fi

echo "▸ Building release in container (deps + ortex NIF + assets + release)…"
# Build on the container's own filesystem (no bind mount — host mktemp dirs
# aren't shared into the colima VM), copy artifacts in/out.
CID="$(docker create --platform "${PLATFORM}" -w /build -e MIX_ENV=prod "${IMAGE_TAG}" bash -c '
    set -euo pipefail
    # Belt and braces: refuse to build a release the VM cannot run.
    [ "$(uname -m)" = "x86_64" ] || { echo "error: container is $(uname -m), need x86_64" >&2; exit 1; }
    cd /build
    mix deps.get --only prod
    mix deps.compile
    npm --prefix assets ci
    mix assets.deploy
    mix release --overwrite
    tar -C _build/prod/rel -czf "/tmp/'"${TARBALL}"'" airo
  ')"
trap 'docker rm -f "${CID}" >/dev/null 2>&1 || true; rm -rf "${STAGE}" "${OUT_DIR}"' EXIT
docker cp "${STAGE}/." "${CID}:/build"
docker start -a "${CID}"
docker cp "${CID}:/tmp/${TARBALL}" "${OUT_DIR}/${TARBALL}"

if [ ! -f "${OUT_DIR}/${TARBALL}" ]; then
  echo "error: container build did not produce ${TARBALL}" >&2
  exit 1
fi

if [ "${BUILD_ONLY:-0}" = "1" ]; then
  # Save the artifact before verification so a verification-tooling failure
  # can never throw away a finished build (OUT_DIR is trap-cleaned on exit).
  cp "${OUT_DIR}/${TARBALL}" "/tmp/${TARBALL}"
fi

# Verify the artifact matches the VM: beam.smp and every native NIF must be
# x86-64 ELF with no glibc symbol newer than the VM's 2.39. Verified inside the
# builder image (readelf/strings live there; the tarball is docker-cp'd in).
echo "▸ Verifying artifact (x86-64 ELF, glibc ≤ 2.39)…"
VCID="$(docker create --platform "${PLATFORM}" "${IMAGE_TAG}" bash -c '
    set -euo pipefail
    cd "$(mktemp -d)"
    tar -xzf /art.tar.gz
    BEAM="$(find . -name beam.smp | head -1)"
    [ -n "${BEAM}" ] || { echo "error: beam.smp missing from release" >&2; exit 1; }
    NIFS="$(find . -path "*/priv/native/*.so")"
    [ -n "${NIFS}" ] || { echo "error: no native NIFs found (ortex/tokenizers expected)" >&2; exit 1; }
    for f in "${BEAM}" ${NIFS}; do
      readelf -h "${f}" | grep -q "X86-64" || { echo "error: ${f} is not x86-64" >&2; exit 1; }
      BAD="$(strings -a "${f}" | grep -oE "GLIBC_2\.[0-9]+" | sort -uV | awk -F. "\$2 > 39" || true)"
      [ -z "${BAD}" ] || { echo "error: ${f} needs ${BAD} (VM has 2.39)" >&2; exit 1; }
      echo "  ✓ ${f}: x86-64, glibc ≤ 2.39"
    done
  ')"
trap 'docker rm -f "${CID}" "${VCID}" >/dev/null 2>&1 || true; rm -rf "${STAGE}" "${OUT_DIR}"' EXIT
docker cp "${OUT_DIR}/${TARBALL}" "${VCID}:/art.tar.gz"
docker start -a "${VCID}"

if [ "${BUILD_ONLY:-0}" = "1" ]; then
  echo "✓ Build verified (${GIT_SHA}) — BUILD_ONLY=1, not shipping."
  echo "  tarball kept at /tmp/${TARBALL}"
  exit 0
fi

echo "▸ Shipping to ${SSH_HOST}:${REMOTE_TMP}/…"
scp "${OUT_DIR}/${TARBALL}" "${SSH_HOST}:${REMOTE_TMP}/${TARBALL}"

echo "▸ Installing on remote…"
ssh "${SSH_HOST}" bash -s -- \
  "${REMOTE_TMP}/${TARBALL}" \
  "${REMOTE_DIR}" \
  "${SERVICE_NAME}" \
  "${SKIP_MIGRATE:-0}" <<'REMOTE'
set -euo pipefail
TARBALL="$1"
REMOTE_DIR="$2"
SERVICE_NAME="$3"
SKIP_MIGRATE="$4"

echo "  • stopping ${SERVICE_NAME}"
sudo systemctl stop "${SERVICE_NAME}" || true

echo "  • extracting into ${REMOTE_DIR}"
sudo install -d -o airo -g airo -m 0755 "${REMOTE_DIR}"
sudo tar -xzf "${TARBALL}" -C "${REMOTE_DIR}" --strip-components=1
sudo chown -R airo:airo "${REMOTE_DIR}"

if [ "${SKIP_MIGRATE}" != "1" ]; then
  echo "  • running migrations"
  sudo -u airo env $(sudo grep -v '^#' /etc/airo.env | xargs -d '\n') \
    "${REMOTE_DIR}/bin/migrate"
fi

echo "  • starting ${SERVICE_NAME}"
sudo systemctl start "${SERVICE_NAME}"
sudo systemctl --no-pager --lines=10 status "${SERVICE_NAME}" || true

echo "  • cleanup"
rm -f "${TARBALL}"
REMOTE

echo "✓ Deploy complete (${GIT_SHA})"
