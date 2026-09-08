#!/bin/bash
# Prod coordinator swap. Runs on the VM as root, invoked by Cloud Build over
# IAP SSH. Enforces the deploy gates from docs/operations/coordinator-deploy.md;
# release-specific checks stay in the runbook.
#
# Usage:
#   IMAGE=<image@sha256:...> EXPECTED_COMMIT=<short-sha> deploy-coordinator.sh

set -euo pipefail

IMAGE="${IMAGE:?IMAGE (by digest) is required}"
EXPECTED_COMMIT="${EXPECTED_COMMIT:?EXPECTED_COMMIT is required}"
ENV_DIR="${ENV_DIR:-/usr/local/lib/darkbloom-env}"
ENV_FILE=/etc/d-inference/env
DATA_MOUNT=/mnt/disks/userdata
STOP_TIMEOUT=630

[[ "$IMAGE" == *"@sha256:"* ]] || { echo "FATAL: IMAGE must be pinned by digest, got: $IMAGE"; exit 1; }
[[ "$EXPECTED_COMMIT" =~ ^[0-9a-f]{7}$ ]] || { echo "FATAL: EXPECTED_COMMIT must be a 7-char short SHA"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "FATAL: must run as root"; exit 1; }
[ -f "$ENV_FILE" ] || { echo "FATAL: $ENV_FILE missing"; exit 1; }
findmnt -n -o FSTYPE --target /etc/d-inference | grep -qx tmpfs && {
  echo "FATAL: /etc/d-inference is tmpfs; run the boot-disk migration from the runbook first"; exit 1; }
mountpoint -q "$DATA_MOUNT" || { echo "FATAL: $DATA_MOUNT not mounted; refusing to boot a blank MicroMDM"; exit 1; }
command -v jq >/dev/null || apt-get install -y -qq jq >/dev/null

# Digest of cache-routing controls + master key. Only the hash is ever printed.
cache_env_digest() {
  awk -F= '$1 ~ /^EIGENINFERENCE_CACHE_ROUTING_/ ||
           $1 == "EIGENINFERENCE_CACHE_MASTER_KEY" { print }' "$ENV_FILE" |
    LC_ALL=C sort | sha256sum | awk '{ print $1 }'
}

echo "==> DB lock pre-check"
command -v psql >/dev/null || apt-get install -y -qq postgresql-client >/dev/null
DB_URL=$(awk -F= '$1=="EIGENINFERENCE_DATABASE_URL" { print substr($0, index($0,"=")+1) }' "$ENV_FILE")
[ -n "$DB_URL" ] || { echo "FATAL: EIGENINFERENCE_DATABASE_URL not in env file"; exit 1; }
LONG_RUNNING=$(psql "$DB_URL" -tAc "select count(*) from pg_stat_activity
  where state <> 'idle' and query_start < now() - interval '60 seconds'
    and pid <> pg_backend_pid();")
BLOCKED=$(psql "$DB_URL" -tAc "select count(*) from pg_locks where granted = false;")
if [ "$LONG_RUNNING" != "0" ] || [ "$BLOCKED" != "0" ]; then
  echo "FATAL: DB not quiet (long-running=$LONG_RUNNING blocked=$BLOCKED); startup migrations"
  echo "would queue behind these locks. Clear blocking PIDs per the runbook and re-run."
  exit 1
fi

echo "==> Env refresh (reviewed repo inputs, atomic apply)"
PRE_REFRESH_DIGEST=$(cache_env_digest)
REQUIRED_FILE="$ENV_DIR/required-env-keys.txt" DEFAULTS_FILE="$ENV_DIR/release-env-defaults" \
  /usr/local/sbin/darkbloom-refresh-env --check
REQUIRED_FILE="$ENV_DIR/required-env-keys.txt" DEFAULTS_FILE="$ENV_DIR/release-env-defaults" \
  /usr/local/sbin/darkbloom-refresh-env --apply
POST_REFRESH_DIGEST=$(cache_env_digest)
if [ "$PRE_REFRESH_DIGEST" != "$POST_REFRESH_DIGEST" ]; then
  echo "FATAL: env refresh changed cache-routing controls; operator state is authoritative."
  echo "Aborting before swap ($PRE_REFRESH_DIGEST -> $POST_REFRESH_DIGEST)."
  exit 1
fi
grep -qFx 'EIGENINFERENCE_PREFILL_KEEPALIVE_INTERVAL=5s' "$ENV_FILE" || {
  echo "FATAL: prefill keepalive must be exactly 5s (see runbook)"; exit 1; }

echo "==> Snapshot pre-swap state"
BEFORE_HEALTH=$(curl -s --max-time 10 localhost:8080/health || true)
BEFORE_CACHE=$(curl -s --max-time 10 localhost:8080/v1/cache/status | jq -S \
  '{routing_mode, percent:.activation.percent, max_plan_qps:.activation.max_plan_qps}' || true)
echo "    pre-swap /health: $(echo "$BEFORE_HEALTH" | jq -c 'del(.build_date)' 2>/dev/null || echo '<unavailable>')"

echo "==> Pull image by digest"
docker pull "$IMAGE"

echo "==> Swap (one container at a time, ${STOP_TIMEOUT}s drain)"
# Keep exactly one stopped fallback for forensics; prune older ones.
docker ps -a --filter status=exited --format '{{.Names}}' |
  grep '^coordinator_fallback_' | sort | head -n -1 | xargs -r docker rm >/dev/null || true
FALLBACK="coordinator_fallback_$(date +%Y%m%d-%H%M%S)"
if docker inspect coordinator >/dev/null 2>&1; then
  docker rename coordinator "$FALLBACK"
  docker stop -t "$STOP_TIMEOUT" "$FALLBACK"
fi
docker run -d --name coordinator \
  --network host \
  --restart unless-stopped \
  --stop-timeout "$STOP_TIMEOUT" \
  -v "$DATA_MOUNT":"$DATA_MOUNT" \
  --env-file "$ENV_FILE" \
  "$IMAGE"

echo "==> Verify"
# Startup is ~15-40s. Poll to 90s; on failure do NOT restart (runbook: suspect
# a DB lock; restarting stacks migrations).
HEALTH_OK=""
for i in $(seq 1 18); do
  if curl -sf --max-time 5 localhost:8080/health >/dev/null 2>&1; then HEALTH_OK=1; break; fi
  sleep 5
done
if [ -z "$HEALTH_OK" ]; then
  echo "FATAL: /health not responding after 90s. Not restarting (roll-forward only)."
  echo "Likely a migration behind a DB lock; check pg_stat_activity per the runbook."
  echo "Old container kept stopped as $FALLBACK."
  docker logs --tail 50 coordinator || true
  exit 1
fi

HEALTH=$(curl -s localhost:8080/health)
echo "$HEALTH" | jq -e --arg c "$EXPECTED_COMMIT" \
  '(.build_commit | startswith($c)) and .build_date != "unknown"' >/dev/null || {
  echo "FATAL: deployed build_commit does not match expected $EXPECTED_COMMIT:"
  echo "$HEALTH" | jq '{version, build_commit, build_date}'
  exit 1; }

AFTER_CACHE=$(curl -s localhost:8080/v1/cache/status | jq -S \
  '{routing_mode, percent:.activation.percent, max_plan_qps:.activation.max_plan_qps}')
if [ -n "$BEFORE_CACHE" ] && [ "$BEFORE_CACHE" != "$AFTER_CACHE" ]; then
  echo "FATAL: cache controls changed across the swap:"
  diff <(echo "$BEFORE_CACHE") <(echo "$AFTER_CACHE") || true
  exit 1
fi
POST_SWAP_DIGEST=$(cache_env_digest)
[ "$POST_REFRESH_DIGEST" = "$POST_SWAP_DIGEST" ] || {
  echo "FATAL: cache env digest changed during swap"; exit 1; }

# Warn only; the healthy baseline is fleet-dependent.
NOT_FOUND=$(docker logs coordinator 2>&1 | grep -c "device not found in MDM" || true)
if [ "${NOT_FOUND:-0}" -gt 100 ]; then
  echo "WARNING: $NOT_FOUND 'device not found in MDM' lines. Hundreds usually means the"
  echo "volume mount is missing; consider rollback per the runbook."
fi

echo "OK: deployed $IMAGE"
echo "$HEALTH" | jq '{version, build_commit, build_date}'
