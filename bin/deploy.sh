#!/usr/bin/env bash
# Build a prod release locally (Linux x86_64) and ship it to the airo VM.
# Idempotent — safe to re-run. Halts on any error.
#
# Prerequisites on the VM (see DEPLOY.md):
#   - SSH alias `airo` resolves and you can `sudo -n` as root
#   - /opt/airo exists and is owned by the `airo` user
#   - /etc/airo.env (0640 root:airo) holds PHX_SERVER, PHX_HOST, PORT,
#     DATABASE_URL, SECRET_KEY_BASE, CLOAK_KEY
#   - A systemd unit `airo.service` runs /opt/airo/bin/server
#
# Usage:
#   bin/deploy.sh                  # build + ship + migrate + restart
#   SKIP_MIGRATE=1 bin/deploy.sh   # skip the migration step
#   SSH_HOST=other bin/deploy.sh   # override the SSH alias

set -euo pipefail

SSH_HOST="${SSH_HOST:-airo}"
REMOTE_DIR="${REMOTE_DIR:-/opt/airo}"
REMOTE_TMP="${REMOTE_TMP:-/tmp}"
SERVICE_NAME="${SERVICE_NAME:-airo.service}"
APP_NAME="airo"

# Bail out if we're being run from anywhere other than the project root.
cd "$(dirname -- "$0")/.."
if [ ! -f mix.exs ]; then
  echo "error: bin/deploy.sh must run from the project root" >&2
  exit 1
fi

if [ "$(uname -s)" != "Linux" ]; then
  echo "error: build host must be Linux (matches the VM target). Got: $(uname -s)" >&2
  exit 1
fi

GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo nogit)"
STAMP="$(date +%Y%m%d-%H%M%S)"
TARBALL="${APP_NAME}-${STAMP}-${GIT_SHA}.tar.gz"

echo "▸ Fetching deps and building…"
mix deps.get --only prod
MIX_ENV=prod mix deps.compile

echo "▸ Compiling assets (esbuild + tailwind, minified, digested)…"
MIX_ENV=prod mix assets.deploy

echo "▸ Building release…"
MIX_ENV=prod mix release --overwrite

REL_DIR="_build/prod/rel/${APP_NAME}"
if [ ! -d "${REL_DIR}" ]; then
  echo "error: release dir not found at ${REL_DIR}" >&2
  exit 1
fi

echo "▸ Packing tarball ${TARBALL}…"
tar -C "_build/prod/rel" -czf "${TARBALL}" "${APP_NAME}"

echo "▸ Shipping to ${SSH_HOST}:${REMOTE_TMP}/…"
scp "${TARBALL}" "${SSH_HOST}:${REMOTE_TMP}/${TARBALL}"

echo "▸ Installing on remote…"
# One ssh session: stop, swap, migrate (optional), start.
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

echo "▸ Cleaning up local tarball…"
rm -f "${TARBALL}"

echo "✓ Deploy complete (${GIT_SHA})"
