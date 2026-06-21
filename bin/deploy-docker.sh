#!/usr/bin/env bash
# Build a prod release inside an ubuntu:24.04 container (glibc 2.39 — matches
# the airo VM) and ship it to the airo VM. Use this instead of bin/deploy.sh
# whenever the local build host's glibc is newer than the VM's (2.39): a
# bundled ERTS / native NIF built against a newer glibc will not start there.
#
# The container toolchain (bin/docker-build/Dockerfile) mirrors the VM:
# mise erlang 28.5 + elixir 1.19.5-otp-28, plus rustup stable for the ortex NIF.
#
# Usage:
#   bin/deploy-docker.sh                  # build + ship + migrate + restart
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

cd "$(dirname -- "$0")/.."
if [ ! -f mix.exs ]; then
  echo "error: must run from the project root" >&2
  exit 1
fi

command -v docker >/dev/null || { echo "error: docker not found" >&2; exit 1; }

GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
STAMP="$(date +%Y%m%d-%H%M%S)"
TARBALL="${APP_NAME}-${STAMP}-${GIT_SHA}.tar.gz"

# Builder image — cached unless missing or REBUILD_IMAGE=1. The heavy step
# (compiling OTP from source) lives in the image layer, not per-deploy.
if [ "${REBUILD_IMAGE:-0}" = "1" ] || ! docker image inspect "${IMAGE_TAG}" >/dev/null 2>&1; then
  echo "▸ Building builder image ${IMAGE_TAG} (first run compiles OTP — slow)…"
  docker build -t "${IMAGE_TAG}" -f bin/docker-build/Dockerfile bin/docker-build
fi

# Clean source = exactly HEAD, no host _build/deps (those are glibc-2.43).
SRC_DIR="$(mktemp -d)"
OUT_DIR="$(mktemp -d)"
trap 'rm -rf "${SRC_DIR}" "${OUT_DIR}"' EXIT
echo "▸ Staging clean source from HEAD (${GIT_SHA})…"
git archive HEAD | tar -x -C "${SRC_DIR}"

echo "▸ Building release in container (deps + ortex NIF + assets + release)…"
docker run --rm \
  -v "${SRC_DIR}:/build" \
  -v "${OUT_DIR}:/out" \
  -e MIX_ENV=prod \
  -e HOST_UID="$(id -u)" \
  -e HOST_GID="$(id -g)" \
  "${IMAGE_TAG}" \
  bash -c '
    set -euo pipefail
    cd /build
    mix deps.get --only prod
    mix deps.compile
    npm --prefix assets ci
    mix assets.deploy
    mix release --overwrite
    tar -C _build/prod/rel -czf "/out/'"${TARBALL}"'" airo
    # Hand the build artifacts back to the invoking user so the host trap can
    # clean the temp dirs (the container runs as root otherwise).
    chown -R "${HOST_UID}:${HOST_GID}" /build /out
  '

if [ ! -f "${OUT_DIR}/${TARBALL}" ]; then
  echo "error: container build did not produce ${TARBALL}" >&2
  exit 1
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
