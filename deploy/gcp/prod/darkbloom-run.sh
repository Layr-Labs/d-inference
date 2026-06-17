#!/bin/bash
# darkbloom-run.sh (DAR-327 Phase 2) — blue-green container launcher for the
# GCE coordinator box. Invoked by the systemd units:
#   darkbloom-platform.service       -> darkbloom-run.sh platform
#   darkbloom-coordinator@<color>    -> darkbloom-run.sh coordinator <blue|green>
#
# Mirrors deploy/gcp/vm-startup.sh's d-inference-run.sh: resolves the pinned
# image (explicit DINF_IMAGE, else the DINF_IMAGE_TAG instance-metadata tag,
# else :latest), authenticates to Artifact Registry using the VM service-account
# token from the metadata server, pulls, then launches the requested container.
#
# Secret-safety: nothing secret is baked in here. Registry auth uses the
# metadata server (no stored key); app config + secrets are read by the
# container from --env-file /etc/d-inference/env (written by refresh-env.sh from
# GCP Secret Manager). The per-color EIGENINFERENCE_PORT is passed as an
# explicit `-e` AFTER --env-file so it overrides the file's default.
set -euo pipefail

usage() {
  echo "usage: darkbloom-run.sh platform" >&2
  echo "       darkbloom-run.sh coordinator <blue|green>" >&2
  exit 2
}

ROLE="${1:-}"
[ -n "$ROLE" ] || usage

META="http://metadata.google.internal/computeMetadata/v1/instance"

# ---- Resolve image ref ----
# DINF_IMAGE (full ref) wins; otherwise build from repo + metadata tag.
IMAGE_REPO="${DINF_IMAGE_REPO:-us-central1-docker.pkg.dev/sepolia-ai/coordinator/coordinator}"
if [ -n "${DINF_IMAGE:-}" ]; then
  IMAGE="$DINF_IMAGE"
else
  TAG="$(curl -fsSL -H 'Metadata-Flavor: Google' "$META/attributes/DINF_IMAGE_TAG" 2>/dev/null || echo latest)"
  IMAGE="${IMAGE_REPO}:${TAG}"
fi
REGISTRY_HOST="${IMAGE%%/*}"

DATA_MOUNT="${DINF_DATA_MOUNT:-/mnt/disks/userdata}"
ENV_FILE="${DINF_ENV_FILE:-/etc/d-inference/env}"
DOCKER="${DOCKER:-/usr/bin/docker}"

echo "darkbloom-run: role=$ROLE image=$IMAGE"

# ---- Registry auth via metadata service-account token ----
# Skip when DINF_SKIP_REGISTRY_LOGIN=1 (image already present, or public).
if [ "${DINF_SKIP_REGISTRY_LOGIN:-0}" != "1" ]; then
  TOKEN="$(curl -fsSL -H 'Metadata-Flavor: Google' \
    "$META/service-accounts/default/token" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')"
  printf '%s' "$TOKEN" | "$DOCKER" login -u oauth2accesstoken --password-stdin "$REGISTRY_HOST"
  unset TOKEN
fi

"$DOCKER" pull "$IMAGE"

case "$ROLE" in
  platform)
    NAME="${DINF_PLATFORM_NAME:-darkbloom-platform}"
    # MicroMDM webhook -> stable loopback Caddy listener (active color follows
    # the single upstream swap). Override via EIGENINFERENCE_MDM_WEBHOOK_URL.
    WEBHOOK_URL="${EIGENINFERENCE_MDM_WEBHOOK_URL:-http://127.0.0.1:8090/v1/mdm/webhook}"
    exec "$DOCKER" run --rm --name "$NAME" \
      --network host \
      --env-file "$ENV_FILE" \
      -e "EIGENINFERENCE_MDM_WEBHOOK_URL=${WEBHOOK_URL}" \
      --mount "type=bind,source=${DATA_MOUNT},target=${DATA_MOUNT}" \
      "$IMAGE" start-platform.sh
    ;;
  coordinator)
    COLOR="${2:-}"
    case "$COLOR" in
      blue)  PORT="${BLUE_PORT:-8080}" ;;
      green) PORT="${GREEN_PORT:-8081}" ;;
      *) echo "darkbloom-run: unknown color '${COLOR}' (want blue|green)" >&2; usage ;;
    esac
    exec "$DOCKER" run --rm --name "darkbloom-coordinator-${COLOR}" \
      --network host \
      --env-file "$ENV_FILE" \
      -e "EIGENINFERENCE_PORT=${PORT}" \
      --mount "type=bind,source=${DATA_MOUNT},target=${DATA_MOUNT}" \
      "$IMAGE" start-coordinator.sh
    ;;
  *)
    echo "darkbloom-run: unknown role '${ROLE}'" >&2
    usage
    ;;
esac
