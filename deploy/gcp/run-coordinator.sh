#!/bin/bash
set -euo pipefail

readonly METADATA_BASE="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
readonly ENV_FILE="/etc/d-inference/env"
readonly SECRET_DIR="/etc/d-inference/secrets"
readonly CANDIDATE_FILE="/run/d-inference/candidate.env"
readonly DATA_MOUNT="/mnt/disks/userdata"
readonly CONTAINER_NAME="d-inference-coordinator"

install -d -m 0755 /run/d-inference
exec 9>/run/d-inference/owner.lock
flock -n 9 || {
  echo "another coordinator ownership wrapper is active" >&2
  exit 75
}

metadata_value() {
  curl -fsSL -H "Metadata-Flavor: Google" "${METADATA_BASE}/$1"
}

file_value() {
  local file=$1
  local key=$2
  awk -v key="$key" '
    index($0, key "=") == 1 {
      print substr($0, length(key) + 2)
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}

if [[ -f "$CANDIDATE_FILE" ]]; then
  IMAGE=$(file_value "$CANDIDATE_FILE" DINF_IMAGE)
  SELECTOR=$(file_value "$CANDIDATE_FILE" DINF_COORDINATOR_BINARY)
  ENVIRONMENT_ID=$(file_value "$CANDIDATE_FILE" DINF_CUTOVER_ENVIRONMENT_ID ||
    printf '%064d' 0)
else
  IMAGE=$(metadata_value DINF_IMAGE)
  SELECTOR=$(metadata_value DINF_COORDINATOR_BINARY)
  ENVIRONMENT_ID=$(metadata_value DINF_CUTOVER_ENVIRONMENT_ID 2>/dev/null ||
    printf '%064d' 0)
fi

[[ "$IMAGE" =~ ^[a-zA-Z0-9._/:@-]+@sha256:[a-fA-F0-9]{64}$ ]] || {
  echo "DINF_IMAGE must be an immutable sha256 digest reference" >&2
  exit 64
}
[[ "$SELECTOR" == "go" || "$SELECTOR" == "rust" ]] || {
  echo "DINF_COORDINATOR_BINARY must be exactly go or rust" >&2
  exit 64
}
[[ "$ENVIRONMENT_ID" =~ ^[a-f0-9]{64}$ ]] || {
  echo "DINF_CUTOVER_ENVIRONMENT_ID must be a lowercase SHA-256" >&2
  exit 64
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
  /usr/bin/docker ps --filter label=com.darkbloom.role=recovery --format '{{.ID}}'
  /usr/bin/docker ps --filter name='^/d-inference-recovery$' --format '{{.ID}}'
} | awk 'NF && !seen[$0]++ { found=1 } END { exit !found }'; then
  echo "offline recovery owner is running; refusing serving owner" >&2
  exit 75
fi
serving_count=$(
  {
    /usr/bin/docker ps --filter label=com.darkbloom.role=serving --format '{{.ID}}'
    /usr/bin/docker ps --filter name='^/d-inference-coordinator$' --format '{{.ID}}'
    /usr/bin/docker ps --filter name='^/coordinator$' --format '{{.ID}}'
  } | awk 'NF && !seen[$0]++ { count++ } END { print count + 0 }'
)
if [[ "$serving_count" -ne 0 ]]; then
  echo "a serving coordinator container is already running" >&2
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
if ! /usr/bin/docker image inspect \
  --format '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE" |
  awk -v expected="$IMAGE" '
    $0 == expected { found = 1 }
    END { exit !found }
  '; then
  echo "pulled image metadata does not contain the configured immutable digest" >&2
  exit 65
fi

if /usr/bin/docker inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
  /usr/bin/docker rm "$CONTAINER_NAME" >/dev/null
fi

/usr/bin/docker run --rm \
  --network host \
  --env-file "$ENV_FILE" \
  --env "EIGENINFERENCE_COORDINATOR_BINARY=$SELECTOR" \
  --env "EIGENINFERENCE_ENVIRONMENT_ID=$ENVIRONMENT_ID" \
  --env "EIGENINFERENCE_IMAGE_DIGEST=$IMAGE" \
  --mount "type=bind,source=$DATA_MOUNT,target=$DATA_MOUNT" \
  --mount "type=bind,source=$SECRET_DIR,target=/run/d-inference-secrets,readonly" \
  --entrypoint /usr/local/bin/coordinator-image-check \
  "$IMAGE" config

exec /usr/bin/docker run \
  --name "$CONTAINER_NAME" \
  --network host \
  --stop-timeout 45 \
  --label com.darkbloom.role=serving \
  --label "com.darkbloom.binary=$SELECTOR" \
  --label "com.darkbloom.image-digest=$IMAGE" \
  --env-file "$ENV_FILE" \
  --env "EIGENINFERENCE_COORDINATOR_BINARY=$SELECTOR" \
  --env "EIGENINFERENCE_ENVIRONMENT_ID=$ENVIRONMENT_ID" \
  --env "EIGENINFERENCE_IMAGE_DIGEST=$IMAGE" \
  --mount "type=bind,source=$DATA_MOUNT,target=$DATA_MOUNT" \
  --mount "type=bind,source=$SECRET_DIR,target=/run/d-inference-secrets,readonly" \
  "$IMAGE"
