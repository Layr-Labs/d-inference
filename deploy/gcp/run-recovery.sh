#!/bin/bash
set -euo pipefail

readonly METADATA_BASE="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
readonly ENV_FILE="/etc/d-inference/env"
readonly SECRET_DIR="/etc/d-inference/secrets"
readonly ENABLE_FILE="/etc/d-inference/enable-offline-recovery"
readonly DATA_MOUNT="/mnt/disks/userdata"
readonly CONTAINER_NAME="d-inference-recovery"

install -d -m 0755 /run/d-inference
exec 9>/run/d-inference/owner.lock
flock -n 9 || {
  echo "another coordinator ownership wrapper is active" >&2
  exit 75
}

[[ -f "$ENABLE_FILE" ]] || {
  echo "offline recovery is disabled; create $ENABLE_FILE during a maintenance window" >&2
  exit 1
}
[[ -r "$ENV_FILE" ]] || {
  echo "coordinator env file is unavailable" >&2
  exit 1
}
[[ -d "$SECRET_DIR" ]] || {
  echo "coordinator secret directory is unavailable" >&2
  exit 1
}
mountpoint -q "$DATA_MOUNT" || {
  echo "persistent state disk is not mounted" >&2
  exit 1
}
if {
  /usr/bin/docker ps --filter label=com.darkbloom.role=serving --format '{{.ID}}'
  /usr/bin/docker ps --filter name='^/d-inference-coordinator$' --format '{{.ID}}'
  /usr/bin/docker ps --filter name='^/coordinator$' --format '{{.ID}}'
} | awk 'NF && !seen[$0]++ { found=1 } END { exit !found }'; then
  echo "serving owner is running; offline recovery cannot contend for ownership" >&2
  exit 75
fi

IMAGE=$(curl -fsSL -H "Metadata-Flavor: Google" \
  "${METADATA_BASE}/DINF_IMAGE")
[[ "$IMAGE" =~ ^[a-zA-Z0-9._/:@-]+@sha256:[a-fA-F0-9]{64}$ ]] || {
  echo "DINF_IMAGE must be an immutable sha256 digest reference" >&2
  exit 64
}
if {
  /usr/bin/docker ps --filter label=com.darkbloom.role=recovery --format '{{.ID}}'
  /usr/bin/docker ps --filter name='^/d-inference-recovery$' --format '{{.ID}}'
} | awk 'NF && !seen[$0]++ { found=1 } END { exit !found }'; then
  echo "an offline recovery owner is already running" >&2
  exit 75
fi
registry=${IMAGE%%/*}
token=$(curl -fsSL -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" |
  jq -er '.access_token')
printf '%s' "$token" | /usr/bin/docker login \
  -u oauth2accesstoken --password-stdin "$registry" >/dev/null
unset token
/usr/bin/docker pull "$IMAGE" >/dev/null

if /usr/bin/docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  /usr/bin/docker rm "$CONTAINER_NAME" >/dev/null
fi

exec /usr/bin/docker run \
  --name "$CONTAINER_NAME" \
  --network host \
  --stop-timeout 45 \
  --label com.darkbloom.role=recovery \
  --label com.darkbloom.binary=rust \
  --env-file "$ENV_FILE" \
  --mount "type=bind,source=$DATA_MOUNT,target=$DATA_MOUNT" \
  --mount "type=bind,source=$SECRET_DIR,target=/run/d-inference-secrets,readonly" \
  --entrypoint /usr/local/bin/coordinator-rs \
  "$IMAGE" recovery
