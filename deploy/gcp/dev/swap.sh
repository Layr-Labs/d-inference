#!/bin/bash
# Dev only. Runs as root on d-inference-dev under systemd-run; deploy.sh starts
# it. It does docs/operations/coordinator-deploy.md steps 2 to 4, Verification
# and Rollback with the same commands, and takes the decisions that production
# leaves to a human. Production stays human-only. It refuses to run outside
# the GCP project darkbloom-dev.
#
# Input (environment):
#   MODE               deploy (default) or rollback
#   LIB                the shipped candidate files: $LIB/deploy/gcp/{prod,dev},
#                      $LIB/deploy/environments/prod.env
#   RESULT             file that gets the last line (OK ... or FAIL ...)
#   CANDIDATE_COMMIT, CANDIDATE_VERSION, CANDIDATE_DIGEST   deploy mode only
#   MIGRATE_ONLY       1 (default): run coordinator --migrate-only before the drain
#
# Output: REPORT lines, then one OK or FAIL line. The container log of a failed
# candidate goes to a root-only file on the VM, not to the output.
set -euo pipefail

MODE=${MODE:-deploy}
LIB=${LIB:?}
RESULT=${RESULT:?}
PROJECT=darkbloom-dev
METADATA_URL=http://metadata.google.internal/computeMetadata/v1/project/project-id
REPO=us-east4-docker.pkg.dev/darkbloom-dev/coordinator/coordinator
ENV_FILE=/etc/d-inference/env
STATE=/var/lib/darkbloom-deploy
ROLLBACK_STATE=$STATE/rollback-state
LAST_GOOD=$STATE/last-good-image
DEPLOY_ROOT=/usr/local/lib/darkbloom-deploy
ENVLIB=/usr/local/lib/darkbloom-env
STOP_TIMEOUT=75
DRAIN_GRACE_LINE=EIGENINFERENCE_DRAIN_GRACE=45s
GOOSE_LOCK_ID=4097083626

finish() {
    echo "$1" > "$RESULT"
    echo "$1"
}
fail() {
    finish "FAIL $*"
    exit 1
}
trap '[ -s "$RESULT" ] || echo "FAIL unexpected exit; read the journal of this unit" > "$RESULT"' EXIT

[ "$(id -u)" = 0 ] || fail "run as root"
project=$(curl -fsS --max-time 5 -H 'Metadata-Flavor: Google' "$METADATA_URL") || fail "no metadata server"
[ "$project" = "$PROJECT" ] || fail "project is $project, not $PROJECT"
[ -f "$ENV_FILE" ] || fail "$ENV_FILE does not exist; run host-setup.sh --apply and seed-env.sh --seed first"
install -d -m 0700 "$STATE"

refresh() {
    REQUIRED_FILE=$ENVLIB/required-env-keys.txt DEFAULTS_FILE=$ENVLIB/release-env-defaults \
        /usr/local/sbin/darkbloom-refresh-env "$@"
}
health_is() {   # <commit> [version]
    curl -fsS --max-time 5 localhost:8080/health | jq -e --arg c "$1" --arg v "${2:-}" \
        '.status == "ok" and .build_commit == $c and .build_date != "unknown" and ($v == "" or .version == $v)' >/dev/null
}
wait_ready() {  # <commit> [version]; up to 180 s
    for _ in $(seq 1 60); do
        if health_is "$@" 2>/dev/null && curl -fsS --max-time 5 localhost:8080/readyz >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
    done
    return 1
}
run_coordinator() {
    docker run -d --name coordinator \
        --network host --restart unless-stopped --stop-timeout "$STOP_TIMEOUT" \
        -v /mnt/disks/userdata:/mnt/disks/userdata \
        --env-file "$ENV_FILE" \
        "$1" >/dev/null
}
container_has_drain_grace() {
    docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -Fxq "$DRAIN_GRACE_LINE"
}
cache_env_digest() {
    awk -F= '$1 ~ /^EIGENINFERENCE_CACHE_ROUTING_/ || $1 == "EIGENINFERENCE_CACHE_MASTER_KEY"' "$ENV_FILE" |
        LC_ALL=C sort | sha256sum | cut -d' ' -f1
}
cache_controls() {
    curl -fsS localhost:8080/v1/cache/status | jq -S \
        '{routing_mode, percent:.activation.percent, max_plan_qps:.activation.max_plan_qps}'
}
db_url() {
    awk -F= '$1 == "EIGENINFERENCE_DATABASE_URL" { print substr($0, index($0, "=") + 1) }' "$ENV_FILE"
}
db_clear() {    # runbook step 2 and schema-migration.md step 3; counts only
    local long blocked goose
    long=$(psql "$(db_url)" -Atc "select count(*) from pg_stat_activity where state <> 'idle'
        and query_start < now() - interval '60 seconds' and pid <> pg_backend_pid();")
    blocked=$(psql "$(db_url)" -Atc "select count(*) from pg_locks where granted = false;")
    goose=$(psql "$(db_url)" -Atc "select count(*) from pg_locks where locktype = 'advisory'
        and classid = 0 and objid = $GOOSE_LOCK_ID and objsubid = 1;")
    echo "REPORT db long_queries=$long blocked_locks=$blocked goose_lock_holders=$goose"
    [ "$long" = 0 ] && [ "$blocked" = 0 ] && [ "$goose" = 0 ]
}
save_logs() {   # <container>; root-only file, never the job output
    local file
    file=$STATE/failed-$1-$(date -u +%Y%m%dT%H%M%SZ).log
    (umask 077; docker logs --tail 500 "$1" > "$file" 2>&1 || true)
    echo "REPORT container log saved on the VM: $file"
}

rollback() {    # runbook "Rollback"
    [ -f "$ROLLBACK_STATE" ] || fail "no rollback state; nothing to roll back to"
    [ "$(stat -c '%U:%G:%a' "$ROLLBACK_STATE")" = root:root:600 ] || fail "rollback state is not root:root 600"
    PREVIOUS_IMAGE=$(sed -n 1p "$ROLLBACK_STATE")
    PREVIOUS_ENV_BACKUP=$(sed -n 2p "$ROLLBACK_STATE")
    PREVIOUS_ENV_BACKUP_SHA256=$(sed -n 3p "$ROLLBACK_STATE")
    FALLBACK=$(sed -n 4p "$ROLLBACK_STATE")
    if [ "$PREVIOUS_IMAGE" = none ]; then
        if docker container inspect coordinator >/dev/null 2>&1; then
            docker stop -t "$STOP_TIMEOUT" coordinator >/dev/null && docker rm coordinator >/dev/null
        fi
        fail "first deploy; no previous image; container coordinator removed"
    fi
    [ "$(sha256sum "$PREVIOUS_ENV_BACKUP" | cut -d' ' -f1)" = "$PREVIOUS_ENV_BACKUP_SHA256" ] || fail "the env backup changed"
    docker image inspect "$PREVIOUS_IMAGE" --format '{{.Id}}' >/dev/null || fail "previous image $PREVIOUS_IMAGE is not on the host"
    grep -Fxq "$DRAIN_GRACE_LINE" "$PREVIOUS_ENV_BACKUP" || fail "the env backup has no $DRAIN_GRACE_LINE"
    if docker container inspect coordinator >/dev/null 2>&1; then
        docker stop -t "$STOP_TIMEOUT" coordinator >/dev/null && docker rm coordinator >/dev/null
    fi
    if docker ps -q --filter "name=^${FALLBACK}\$" | grep -q .; then
        docker stop -t "$STOP_TIMEOUT" "$FALLBACK" >/dev/null
    fi
    cp "$PREVIOUS_ENV_BACKUP" "$ENV_FILE"
    run_coordinator "$PREVIOUS_IMAGE"
    PREVIOUS_COMMIT=$(docker image inspect "$PREVIOUS_IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
    if ! wait_ready "$PREVIOUS_COMMIT"; then
        save_logs coordinator
        fail "rollback image $PREVIOUS_IMAGE is not ready within 180 s"
    fi
    [ "$(docker inspect --format '{{.Image}}' coordinator)" = "$PREVIOUS_IMAGE" ] || fail "rollback runs the wrong image"
    printf '%s\n' "$PREVIOUS_IMAGE" | install -m 0600 /dev/stdin "$LAST_GOOD"
}

if [ "$MODE" = rollback ]; then
    rollback
    finish "OK rolled back to $(cat "$LAST_GOOD")"
    exit 0
fi
[ "$MODE" = deploy ] || fail "MODE must be deploy or rollback"

: "${CANDIDATE_VERSION:?}" "${CANDIDATE_COMMIT:?}" "${CANDIDATE_DIGEST:?}"
[[ "$CANDIDATE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "CANDIDATE_COMMIT must be 40 lowercase hex"
[[ "$CANDIDATE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "CANDIDATE_DIGEST must be sha256:<64 hex>"
MIGRATE_ONLY=${MIGRATE_ONLY:-1}
CANDIDATE_IMAGE="$REPO@$CANDIDATE_DIGEST"

# Step 3, first block: every deploy installs the candidate's refresh script and manifests.
install -d -m 0755 "$ENVLIB"
install -m 0755 "$LIB/deploy/gcp/prod/refresh-env.sh" /usr/local/sbin/darkbloom-refresh-env
install -m 0644 "$LIB/deploy/gcp/prod/required-env-keys.txt" "$ENVLIB/required-env-keys.txt"
install -m 0644 "$LIB/deploy/gcp/prod/release-env-defaults" "$ENVLIB/release-env-defaults"
"$LIB/deploy/gcp/dev/seed-env.sh" --check 2>&1 | grep -E '^(REPORT|FAIL) ' | sed -E 's/^(REPORT )?/REPORT seed check: /' || true

# Step 2: pre-swap checks. Nothing changes until they pass.
psql "$(db_url)" -Atc 'select 1' >/dev/null 2>&1 ||
    fail "cannot connect to the database with EIGENINFERENCE_DATABASE_URL; nothing changed"
db_clear || fail "long queries, blocked locks or a goose lock holder; nothing changed"
psql "$(db_url)" -Atc "select id from schema_migrations where id in ('backfill_withdrawable_balance_v1',
    'backfill_usage_totals_v1', 'backfill_earnings_summary_v1');" 2>/dev/null | sed 's/^/REPORT marker /' || true
docker pull -q "$CANDIDATE_IMAGE" >/dev/null || fail "docker pull $CANDIDATE_IMAGE failed; nothing changed"
[ "$(docker image inspect "$CANDIDATE_IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')" = "$CANDIDATE_COMMIT" ] ||
    fail "image revision label is not $CANDIDATE_COMMIT; nothing changed"
[ "$(docker image inspect "$CANDIDATE_IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')" = "$CANDIDATE_VERSION" ] ||
    fail "image version label is not $CANDIDATE_VERSION; nothing changed"
CURRENT=false
if docker container inspect coordinator >/dev/null 2>&1; then
    CURRENT=true
    curl -fsS --max-time 5 localhost:8080/health >/dev/null || fail "the current coordinator is not healthy; nothing changed"
    cache_controls > "$STATE/cache-controls.before.json"
    BEFORE_DIGEST=$(cache_env_digest)
fi

# Optional step (schema-migration.md step 4): database-only migration while the
# current coordinator serves.
if [ "$MIGRATE_ONLY" = 1 ]; then
    docker run --rm --network host --env-file "$ENV_FILE" \
        --entrypoint /usr/local/bin/coordinator "$CANDIDATE_IMAGE" --migrate-only >/dev/null 2>&1 ||
        fail "--migrate-only failed; the current coordinator still serves"
    echo "REPORT --migrate-only done"
    db_clear || fail "blocked after --migrate-only; the current coordinator still serves"
    [ "$CURRENT" = false ] || curl -fsS --max-time 5 localhost:8080/health >/dev/null ||
        fail "the current coordinator is not healthy after --migrate-only"
fi

# Step 3: refresh the env file and capture the rollback inputs.
refresh --check | sed 's/^/REPORT refresh check: /' || fail "refresh --check failed; nothing changed"
REFRESH_OUTPUT=$(refresh --apply) || fail "refresh --apply failed"
printf '%s\n' "$REFRESH_OUTPUT" | sed 's/^/REPORT refresh: /'
PREVIOUS_ENV_BACKUP=${REFRESH_OUTPUT##*backup=}
PREVIOUS_ENV_BACKUP_SHA256=$(sha256sum "$PREVIOUS_ENV_BACKUP" | cut -d' ' -f1)
if [ "$CURRENT" = true ]; then
    [ "$(cache_env_digest)" = "$BEFORE_DIGEST" ] || fail "the refresh changed the cache controls; the env changed, the container did not"
fi
grep -Fxq 'EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS=9000' "$ENV_FILE" ||
    echo "REPORT EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS is not the prod.env value"
grep -Fxq "$DRAIN_GRACE_LINE" "$ENV_FILE" || fail "$ENV_FILE has no $DRAIN_GRACE_LINE; nothing swapped"
FALLBACK=coordinator_fallback_$(date +%Y%m%d-%H%M%S)
if [ "$CURRENT" = true ]; then
    container_has_drain_grace coordinator || fail "the running container has no $DRAIN_GRACE_LINE; nothing swapped"
    PREVIOUS_IMAGE=$(docker inspect --format '{{.Image}}' coordinator)
    APPROVED_PREVIOUS_IMAGE=$(cat "$LAST_GOOD" 2>/dev/null || true)
    [ "$PREVIOUS_IMAGE" = "$APPROVED_PREVIOUS_IMAGE" ] ||
        fail "the running image is not the last verified image ($LAST_GOOD); nothing swapped"
else
    PREVIOUS_IMAGE=none
fi
printf '%s\n%s\n%s\n%s\n' "$PREVIOUS_IMAGE" "$PREVIOUS_ENV_BACKUP" "$PREVIOUS_ENV_BACKUP_SHA256" "$FALLBACK" |
    install -m 0600 /dev/stdin "$ROLLBACK_STATE"

# Step 4: swap. One host-network container at a time.
T0=$(date +%s)
if [ "$CURRENT" = true ]; then
    docker rename coordinator "$FALLBACK"
    docker stop -t "$STOP_TIMEOUT" "$FALLBACK" >/dev/null
fi
T1=$(date +%s)
run_coordinator "$CANDIDATE_IMAGE"

# Verification. A hard gate rolls back; the rest is reported.
if ! wait_ready "$CANDIDATE_COMMIT" "$CANDIDATE_VERSION"; then
    db_clear || true
    save_logs coordinator
    rollback
    fail "candidate not ready within 180 s; rolled back to $PREVIOUS_IMAGE"
fi
T2=$(date +%s)
if [ "$(docker inspect --format '{{.Config.Image}}' coordinator)" != "$CANDIDATE_IMAGE" ]; then
    rollback
    fail "the container runs the wrong image; rolled back to $PREVIOUS_IMAGE"
fi
if [ "$CURRENT" = true ]; then
    if [ "$(cache_env_digest)" != "$BEFORE_DIGEST" ]; then
        rollback
        fail "the cache controls changed; rolled back to $PREVIOUS_IMAGE"
    fi
    diff -u "$STATE/cache-controls.before.json" <(cache_controls) | sed 's/^/REPORT cache controls: /' || true
fi
curl -fsS --max-time 5 localhost:8080/v1/cache/status |
    jq -c '{sidecar, preload, prompt_artifacts}' | sed 's/^/REPORT cache status: /' || true
echo "REPORT device_not_found=$(docker logs coordinator 2>&1 | grep -c 'device not found in MDM' || true)"
echo "REPORT postgres_migration_lines=$(docker logs coordinator 2>&1 | grep -c '"postgres migration"' || true)"

docker inspect --format '{{.Image}}' coordinator | install -m 0600 /dev/stdin "$LAST_GOOD"
ln -sfn "$LIB" "$DEPLOY_ROOT/current"
# Dev housekeeping: keep this run's fallback container, the current files, and
# images younger than 7 days or in use.
docker ps -a --format '{{.Names}}' | grep '^coordinator_fallback_' | grep -vx "$FALLBACK" |
    xargs -r docker rm >/dev/null 2>&1 || true
find "$DEPLOY_ROOT" -mindepth 1 -maxdepth 1 -type d ! -path "$LIB" -exec rm -rf {} + 2>/dev/null || true
docker image prune -af --filter until=168h >/dev/null 2>&1 || true
finish "OK $CANDIDATE_COMMIT drain_s=$((T1 - T0)) start_to_ready_s=$((T2 - T1))"
