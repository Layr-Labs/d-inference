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
printf 'EIGENINFERENCE_PROMPT_SIDECAR_ARTIFACT_ROOT=/data/prompt-contracts\n' >> "$ENV_FILE"
printf 'EIGENINFERENCE_PROMPT_SIDECAR_STARTUP_TIMEOUT_MS=5000\n' >> "$ENV_FILE"
printf 'EIGENINFERENCE_PROMPT_SIDECAR_HEALTH_INTERVAL_MS=100\n' >> "$ENV_FILE"
awk -F= '$1=="EIGENINFERENCE_PREFILL_KEEPALIVE_INTERVAL" {
    print $1 "=10s"
    next
} { print }' "$ENV_FILE" > "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"
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
grep -Fxq 'EIGENINFERENCE_CACHE_ROUTING_PERCENT=1' "$ENV_FILE"
grep -Fxq 'EIGENINFERENCE_CACHE_ROUTING_MAX_PLAN_QPS=1' "$ENV_FILE"
grep -Fxq 'EIGENINFERENCE_PROMPT_SIDECAR_ARTIFACT_ROOT=/mnt/disks/userdata/prompt-contracts' "$ENV_FILE"
grep -Fxq 'EIGENINFERENCE_PROMPT_SIDECAR_HEALTH_TIMEOUT_MS=250' "$ENV_FILE"
grep -Fxq 'EIGENINFERENCE_PROMPT_SIDECAR_PRELOAD_TIMEOUT_MS=120000' "$ENV_FILE"
grep -Fxq 'EIGENINFERENCE_PROMPT_SIDECAR_STARTUP_TIMEOUT_MS=120000' "$ENV_FILE"
grep -Fxq 'EIGENINFERENCE_PROMPT_SIDECAR_HEALTH_INTERVAL_MS=1000' "$ENV_FILE"
grep -Fxq 'EIGENINFERENCE_PREFILL_KEEPALIVE_INTERVAL=5s' "$ENV_FILE"
grep -Fxq 'EIGENINFERENCE_PROMPT_SIDECAR_HEALTH_FAILURE_THRESHOLD=5' "$ENV_FILE"
grep -Fxq 'EIGENINFERENCE_PROMPT_SIDECAR_RESTART_MAX_IN_WINDOW=3' "$ENV_FILE"
grep -Fxq 'EIGENINFERENCE_PROMPT_SIDECAR_RESTART_COOLDOWN_MS=30000' "$ENV_FILE"
[ "$(ls "$ENV_DIR"/env.bak.* | wc -l | tr -d ' ')" -eq 1 ]

# Negative cases MUST live inside $ENV_DIR: an env file outside it trips the
# path guard before any manifest check runs, so a case placed outside would
# pass whatever the manifest logic did. Assert the reason, not just the exit.
expect_refresh_failure() {
    local label=$1 file=$2 want=$3 out
    if out=$(SKIP_PERSISTENCE_CHECK=1 ENV_DIR="$ENV_DIR" ENV_FILE="$file" \
        REQUIRED_FILE="$REQUIRED" DEFAULTS_FILE="$DEFAULTS" "$REFRESH" --check 2>&1)
    then
        echo "refresh accepted $label" >&2
        exit 1
    fi
    if ! printf '%s' "$out" | grep -Fq "$want"; then
        echo "refresh rejected $label for the wrong reason: $out" >&2
        exit 1
    fi
}

missing="$ENV_DIR/missing.env"
awk '$0 !~ /^EIGENINFERENCE_HEALTH_EJECTION=/' "$ENV_FILE" > "$missing"
chmod 0600 "$missing"
expect_refresh_failure "a dropped live tuning key" "$missing" \
    "required existing variables are missing or empty: EIGENINFERENCE_HEALTH_EJECTION"

duplicate="$ENV_DIR/duplicate.env"
cp "$ENV_FILE" "$duplicate"
printf 'DOMAIN=duplicate\n' >> "$duplicate"
expect_refresh_failure "a duplicate key" "$duplicate" "duplicate env key DOMAIN"

custom="$ENV_DIR/custom.env"
cp "$ENV_FILE" "$custom"
awk -F= '$1=="EIGENINFERENCE_PROMPT_SIDECAR_ARTIFACT_ROOT" {
    print $1 "=/mnt/disks/userdata/custom-prompt-contracts"
    next
} $1=="EIGENINFERENCE_PROMPT_SIDECAR_STARTUP_TIMEOUT_MS" {
    print $1 "=9000"
    next
} $1=="EIGENINFERENCE_PROMPT_SIDECAR_HEALTH_INTERVAL_MS" {
    print $1 "=750"
    next
} $1=="EIGENINFERENCE_PREFILL_KEEPALIVE_INTERVAL" {
    print $1 "=7s"
    next
} { print }' "$custom" > "$custom.tmp"
mv "$custom.tmp" "$custom"
SKIP_PERSISTENCE_CHECK=1 ENV_DIR="$ENV_DIR" ENV_FILE="$custom" \
    REQUIRED_FILE="$REQUIRED" DEFAULTS_FILE="$DEFAULTS" "$REFRESH" --apply >/dev/null
grep -Fxq \
    'EIGENINFERENCE_PROMPT_SIDECAR_ARTIFACT_ROOT=/mnt/disks/userdata/custom-prompt-contracts' \
    "$custom"
grep -Fxq 'EIGENINFERENCE_PROMPT_SIDECAR_STARTUP_TIMEOUT_MS=9000' "$custom"
grep -Fxq 'EIGENINFERENCE_PROMPT_SIDECAR_HEALTH_INTERVAL_MS=750' "$custom"
grep -Fxq 'EIGENINFERENCE_PREFILL_KEEPALIVE_INTERVAL=7s' "$custom"

# A required key that release-env-defaults SUPPLIES must bootstrap. The box not
# having it yet is the entire reason the release ships a default, so demanding
# it pre-merge would make such a key impossible to introduce — the deploy would
# hard-fail on every box instead of installing it. EIGENINFERENCE_MODEL_SOLO_TPS_SEED
# is the first key in both manifests and shipped absent from prod for a release.
seed_key=EIGENINFERENCE_MODEL_SOLO_TPS_SEED
grep -q "^$seed_key=" "$DEFAULTS"
grep -Fxq "$seed_key" "$REQUIRED"

bootstrap="$ENV_DIR/bootstrap.env"
awk -v k="^$seed_key=" '$0 !~ k' "$ENV_FILE" > "$bootstrap"
chmod 0600 "$bootstrap"
SKIP_PERSISTENCE_CHECK=1 ENV_DIR="$ENV_DIR" ENV_FILE="$bootstrap" \
    REQUIRED_FILE="$REQUIRED" DEFAULTS_FILE="$DEFAULTS" "$REFRESH" --apply >/dev/null
grep -Fxq "$(grep "^$seed_key=" "$DEFAULTS")" "$bootstrap"

# ...but a BLANKED value is a misconfiguration, not a bootstrap: the merge only
# adds absent keys, so the post-merge check must still reject it.
blanked="$ENV_DIR/blanked.env"
sed "s/^$seed_key=.*/$seed_key=/" "$ENV_FILE" > "$blanked"
chmod 0600 "$blanked"
expect_refresh_failure "a blanked release-default key" "$blanked" \
    "required existing variables are missing or empty: $seed_key"

marker="$TEST_ROOT/path-injection-ran"
if SKIP_PERSISTENCE_CHECK=1 \
    ENV_DIR="$ENV_DIR;touch$marker" ENV_FILE="$ENV_FILE" \
    REQUIRED_FILE="$REQUIRED" DEFAULTS_FILE="$DEFAULTS" \
    "$REFRESH" --check >/dev/null 2>&1
then
    echo "refresh accepted an unsafe environment directory" >&2
    exit 1
fi
[ ! -e "$marker" ]

echo "production env refresh tests passed"
