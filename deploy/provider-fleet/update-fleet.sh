#!/bin/bash
# Reinstall / refresh the provider on every machine in a fleet inventory.
#
# Usage:
#   deploy/provider-fleet/update-fleet.sh dev
#   deploy/provider-fleet/update-fleet.sh prod    # requires explicit --force-prod
#
# Each machine runs the coordinator-served install.sh, which fetches the
# latest release registered against that coordinator. Dev machines can only
# ever talk to dev coordinator because the install.sh is served from there.

set -euo pipefail

ENV_NAME="${1:-}"
if [ -z "$ENV_NAME" ]; then
  echo "usage: $0 <dev|prod> [--force-prod]" >&2
  exit 1
fi

case "$ENV_NAME" in
  dev)
    COORD_URL="https://api.dev.darkbloom.dev"
    INVENTORY="$(dirname "$0")/dev-inventory.txt"
    ;;
  prod)
    if [ "${2:-}" != "--force-prod" ]; then
      echo "refusing to touch prod fleet without --force-prod" >&2
      exit 2
    fi
    COORD_URL="https://api.darkbloom.dev"
    INVENTORY="$(dirname "$0")/prod-inventory.txt"
    ;;
  *)
    echo "unknown env: $ENV_NAME (expected dev or prod)" >&2
    exit 1
    ;;
esac

if [ ! -f "$INVENTORY" ]; then
  echo "inventory file not found: $INVENTORY" >&2
  exit 1
fi

HOSTS=$(grep -v '^[[:space:]]*#' "$INVENTORY" | awk 'NF {print $1}')

if [ -z "$HOSTS" ]; then
  echo "no hosts in $INVENTORY" >&2
  exit 1
fi

echo "==> Updating $ENV_NAME fleet against $COORD_URL"
for HOST in $HOSTS; do
  echo "---- $HOST ----"
  ssh "$HOST" "curl -fsSL $COORD_URL/install.sh | bash" || {
    echo "!!! $HOST failed — continuing" >&2
  }
done

echo "==> Fleet update complete"
