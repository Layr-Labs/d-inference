#!/bin/bash
# Apply the schema embedded in an explicitly pinned coordinator image.
# This command never changes VM metadata or restarts the serving owner.
set -euo pipefail

IMAGE="${1:?usage: migrate-coordinator.sh IMAGE_REF [ADOPT_LEGACY]}"
ADOPT_LEGACY="${2:-false}"
if [[ ! "$IMAGE" =~ ^[A-Za-z0-9._/@:-]+$ ]] ||
  [[ "$IMAGE" != *":"* && "$IMAGE" != *"@sha256:"* ]]; then
  echo "invalid coordinator image reference" >&2
  exit 2
fi
if [[ "$ADOPT_LEGACY" != "true" && "$ADOPT_LEGACY" != "false" ]]; then
  echo "ADOPT_LEGACY must be true or false" >&2
  exit 2
fi

META="http://metadata.google.internal/computeMetadata/v1/instance"
REGISTRY="${IMAGE%%/*}"

TOKEN=$(curl -fsSL -H "Metadata-Flavor: Google" \
  "$META/service-accounts/default/token" \
  | jq -er '.access_token')
printf '%s' "$TOKEN" | /usr/bin/docker login \
  -u oauth2accesstoken \
  --password-stdin \
  "$REGISTRY" >/dev/null
unset TOKEN

/usr/bin/docker pull "$IMAGE"
MIGRATION_ARGS=(-lock-timeout=10s -statement-timeout=30m)
if [[ "$ADOPT_LEGACY" == "true" ]]; then
  MIGRATION_ARGS+=(-adopt-legacy)
fi
/usr/bin/docker run --rm \
  --network host \
  --env-file /etc/d-inference/env \
  --entrypoint /usr/local/bin/coordinator-migrate \
  "$IMAGE" \
  "${MIGRATION_ARGS[@]}"
