#!/bin/bash
# Apply the schema embedded in a pinned dev coordinator image.
# Cloud Build pipes this script to the VM before restarting systemd.
set -euo pipefail

TAG="${1:?usage: migrate-coordinator.sh IMAGE_TAG [ADOPT_LEGACY]}"
ADOPT_LEGACY="${2:-false}"
if [[ ! "$TAG" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "invalid coordinator image tag: $TAG" >&2
  exit 2
fi
if [[ "$ADOPT_LEGACY" != "true" && "$ADOPT_LEGACY" != "false" ]]; then
  echo "ADOPT_LEGACY must be true or false" >&2
  exit 2
fi

META="http://metadata.google.internal/computeMetadata/v1/instance"
REGISTRY="us-central1-docker.pkg.dev"
IMAGE="${REGISTRY}/sepolia-ai/coordinator/coordinator:${TAG}"

TOKEN=$(curl -fsSL -H "Metadata-Flavor: Google" \
  "$META/service-accounts/default/token" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
printf '%s' "$TOKEN" | /usr/bin/docker login \
  -u oauth2accesstoken \
  --password-stdin \
  "$REGISTRY"
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
