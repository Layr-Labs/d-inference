#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REFRESH="$ROOT/deploy/gcp/prod/refresh-env.sh"
REQUIRED="$ROOT/deploy/gcp/prod/required-env-keys.txt"
DEFAULTS="$ROOT/deploy/gcp/prod/release-env-defaults"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-prod-env.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

ENV_DIR="$TEST_ROOT/etc"
ENV_FILE="$ENV_DIR/env"
mkdir -p "$ENV_DIR"
while IFS= read -r key; do
    case "$key" in ""|\#*) continue ;; esac
    printf '%s=%s\n' "$key" "existing-$key" >> "$ENV_FILE"
done < "$REQUIRED"
printf 'UNLISTED_SECRET=do-not-print-or-drop\n' >> "$ENV_FILE"
printf 'EIGENINFERENCE_PROMPT_SIDECAR_ENABLED=true\n' >> "$ENV_FILE"
chmod 0600 "$ENV_FILE"

before_secret=$(awk -F= '$1=="UNLISTED_SECRET" { print substr($0, index($0, "=") + 1) }' "$ENV_FILE")
check_output=$(SKIP_PERSISTENCE_CHECK=1 ENV_DIR="$ENV_DIR" ENV_FILE="$ENV_FILE" \
    REQUIRED_FILE="$REQUIRED" DEFAULTS_FILE="$DEFAULTS" "$REFRESH" --check)
if printf '%s' "$check_output" | grep -Fq "$before_secret"; then
    echo "refresh check leaked an existing secret value" >&2
    exit 1
fi

SKIP_PERSISTENCE_CHECK=1 ENV_DIR="$ENV_DIR" ENV_FILE="$ENV_FILE" \
    REQUIRED_FILE="$REQUIRED" DEFAULTS_FILE="$DEFAULTS" "$REFRESH" --apply >/dev/null

[ "$(awk -F= '$1=="UNLISTED_SECRET" { print substr($0, index($0, "=") + 1) }' "$ENV_FILE")" = "$before_secret" ]
[ "$(awk -F= '$1=="EIGENINFERENCE_PROMPT_SIDECAR_ENABLED" { print $2 }' "$ENV_FILE")" = "true" ]
grep -Fxq 'EIGENINFERENCE_CACHE_ROUTING_MODE=off' "$ENV_FILE"
[ "$(ls "$ENV_DIR"/env.bak.* | wc -l | tr -d ' ')" -eq 1 ]

missing="$TEST_ROOT/missing.env"
cp "$ENV_FILE" "$missing"
awk '$0 !~ /^EIGENINFERENCE_HEALTH_EJECTION=/' "$missing" > "$missing.tmp"
mv "$missing.tmp" "$missing"
if SKIP_PERSISTENCE_CHECK=1 ENV_DIR="$ENV_DIR" ENV_FILE="$missing" \
    REQUIRED_FILE="$REQUIRED" DEFAULTS_FILE="$DEFAULTS" "$REFRESH" --check >/dev/null 2>&1
then
    echo "refresh accepted a dropped live tuning key" >&2
    exit 1
fi

duplicate="$TEST_ROOT/duplicate.env"
cp "$ENV_FILE" "$duplicate"
printf 'DOMAIN=duplicate\n' >> "$duplicate"
if SKIP_PERSISTENCE_CHECK=1 ENV_DIR="$ENV_DIR" ENV_FILE="$duplicate" \
    REQUIRED_FILE="$REQUIRED" DEFAULTS_FILE="$DEFAULTS" "$REFRESH" --check >/dev/null 2>&1
then
    echo "refresh accepted a duplicate key" >&2
    exit 1
fi

echo "production env refresh tests passed"
