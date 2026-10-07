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
ENV_FILE=${ENV_FILE:-/etc/d-inference/env}
STATE=${STATE:-/var/lib/darkbloom-deploy}
ROLLBACK_STATE=$STATE/rollback-state
LAST_GOOD=$STATE/last-good-image
DEPLOY_ROOT=${DEPLOY_ROOT:-/usr/local/lib/darkbloom-deploy}
ENVLIB=${ENVLIB:-/usr/local/lib/darkbloom-env}
REFRESH_BIN=${REFRESH_BIN:-/usr/local/sbin/darkbloom-refresh-env}
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
CLEANUP_PHASE=none
CLEANUP_ACTIVE=0
ROLLBACK_ACTIVE=0
COMMITTED=0
PG_TMP=""
cleanup_pg_files() {
    [ -z "$PG_TMP" ] && return 0
    case "$PG_TMP" in
        "$STATE"/.pg.*) rm -rf "$PG_TMP" || return 1 ;;
        *) return 1 ;;
    esac
    PG_TMP=""
}
automatic_cleanup() {
    local original_rc=$? cleanup_rc=0 pg_cleanup_rc=0 result_line
    trap - EXIT
    set +e
    if [ "$original_rc" -ne 0 ] && [ "$COMMITTED" = 0 ] && [ "$CLEANUP_PHASE" != none ] && [ "$CLEANUP_ACTIVE" = 0 ]; then
        CLEANUP_ACTIVE=1
        if [ "$CLEANUP_PHASE" = swap ]; then
            (rollback)
            cleanup_rc=$?
        else
            (restore_files)
            cleanup_rc=$?
        fi
        if [ "$cleanup_rc" = 0 ]; then
            echo "REPORT automatic cleanup restored the pre-deploy state after an unexpected failure"
        else
            echo "REPORT automatic cleanup failed with status $cleanup_rc; inspect $ROLLBACK_STATE locally on the VM" >&2
        fi
    fi
    cleanup_pg_files
    pg_cleanup_rc=$?
    if [ "$pg_cleanup_rc" -ne 0 ]; then
        echo "REPORT private database credential cleanup failed with status $pg_cleanup_rc" >&2
        if [ -s "$RESULT" ]; then
            result_line=$(cat "$RESULT")
            printf '%s; private database credential cleanup failed (status %s)\n' "$result_line" "$pg_cleanup_rc" > "$RESULT"
        else
            printf 'FAIL unexpected exit (status %s); automatic cleanup status=%s; private database credential cleanup failed (status %s)\n' \
                "$original_rc" "$cleanup_rc" "$pg_cleanup_rc" > "$RESULT"
        fi
    elif [ ! -s "$RESULT" ]; then
        echo "FAIL unexpected exit (status $original_rc); automatic cleanup status=$cleanup_rc" > "$RESULT"
    fi
    exit "$original_rc"
}
trap automatic_cleanup EXIT

[ "$(id -u)" = 0 ] || fail "run as root"
project=$(curl -fsS --max-time 5 -H 'Metadata-Flavor: Google' "$METADATA_URL") || fail "no metadata server"
[ "$project" = "$PROJECT" ] || fail "project is $project, not $PROJECT"
[ -f "$ENV_FILE" ] || fail "$ENV_FILE does not exist; run host-setup.sh --apply and seed-env.sh --seed first"
# shellcheck source=deploy/gcp/dev/refresh-backup.sh
. "$LIB/deploy/gcp/dev/refresh-backup.sh"

refresh() {
    REQUIRED_FILE=$LIB/deploy/gcp/prod/required-env-keys.txt \
        DEFAULTS_FILE=$LIB/deploy/gcp/prod/release-env-defaults \
        ENV_FILE=$ENV_FILE "$LIB/deploy/gcp/prod/refresh-env.sh" "$@"
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
prepare_psql() {
    local tmp
    tmp=$(mktemp -d "$STATE/.pg.XXXXXX") || return 1
    PG_TMP=$tmp
    chmod 0700 "$PG_TMP" || return 1
    if ! python3 - "$ENV_FILE" "$PG_TMP/connection" "$PG_TMP/pgpass" <<'PYDB'
import os
from pathlib import Path
import re
import sys
from urllib.parse import parse_qsl, unquote, urlsplit

env_file, connection_file, passfile = map(Path, sys.argv[1:])
prefix = "EIGENINFERENCE_DATABASE_URL="
url = next((line[len(prefix):] for line in env_file.read_text().splitlines() if line.startswith(prefix)), "")
parsed = urlsplit(url)
if parsed.scheme not in ("postgres", "postgresql") or parsed.fragment:
    raise SystemExit(1)
try:
    user = unquote(parsed.username or "")
    password = unquote(parsed.password or "")
    host = parsed.hostname or ""
    port = str(parsed.port or 5432)
except ValueError:
    raise SystemExit(1)
database = unquote(parsed.path.removeprefix("/"))
fields = (host, port, database, user)
if not password or re.search(r"[\x00\r\n]", password):
    raise SystemExit(1)
if any(not value or re.search(r"[\t\r\n]", value) for value in fields):
    raise SystemExit(1)
if not re.fullmatch(r"[A-Za-z0-9.-]+", host) or not port.isdigit():
    raise SystemExit(1)
if not re.fullmatch(r"[A-Za-z0-9_.-]+", database) or not re.fullmatch(r"[A-Za-z0-9_.-]+", user):
    raise SystemExit(1)
# TLS is required. The URI names the only host, port, database and user;
# query parameters that libpq reads as another target are refused.
try:
    params = parse_qsl(parsed.query, keep_blank_values=True, strict_parsing=True)
except ValueError:
    raise SystemExit(1)
sslmodes = [value for key, value in params if key == "sslmode"]
if len(sslmodes) != 1 or sslmodes[0] not in ("require", "verify-ca", "verify-full"):
    raise SystemExit(1)
if any(key in ("host", "hostaddr", "port", "dbname", "user", "password", "passfile", "service")
       for key, _ in params):
    raise SystemExit(1)
sslrootcerts = [value for key, value in params if key == "sslrootcert"]
if len(sslrootcerts) > 1:
    raise SystemExit(1)
sslrootcert = sslrootcerts[0] if sslrootcerts else ""
if re.search(r"[\x00\t\r\n]", sslrootcert):
    raise SystemExit(1)
def pgpass_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace(":", "\\:")
def write_private(path: Path, value: str) -> None:
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as stream:
        stream.write(value)
write_private(connection_file, "\t".join((*fields, sslmodes[0], sslrootcert)) + "\n")
write_private(passfile, ":".join(pgpass_escape(value) for value in (*fields[:3], user, password)) + "\n")
PYDB
    then
        return 1
    fi
    IFS=$'\t' read -r PG_HOST PG_PORT PG_DATABASE PG_USER PG_SSLMODE PG_SSLROOTCERT < "$PG_TMP/connection"
    [ -n "$PG_HOST" ] && [ -n "$PG_PORT" ] && [ -n "$PG_DATABASE" ] && [ -n "$PG_USER" ] || return 1
    case "$PG_SSLMODE" in require|verify-ca|verify-full) ;; *) return 1 ;; esac
}
psql_private() {
    PGHOST="$PG_HOST" PGPORT="$PG_PORT" PGDATABASE="$PG_DATABASE" PGUSER="$PG_USER" \
        PGSSLMODE="$PG_SSLMODE" PGSSLROOTCERT="$PG_SSLROOTCERT" PGPASSFILE="$PG_TMP/pgpass" psql "$@"
}
db_clear() {    # runbook step 2 and schema-migration.md step 3; counts only
    local long blocked goose
    long=$(psql_private -Atc "select count(*) from pg_stat_activity where state <> 'idle'
        and query_start < now() - interval '60 seconds' and pid <> pg_backend_pid();")
    blocked=$(psql_private -Atc "select count(*) from pg_locks where granted = false;")
    goose=$(psql_private -Atc "select count(*) from pg_locks where locktype = 'advisory'
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

backup_path() { # <source> <name> <attempt-dir>
    local source=$1 name=$2 attempt=$3
    if [ -e "$source" ]; then
        [ -f "$source" ] && [ ! -L "$source" ] || fail "$source is not a regular file; nothing changed"
        cp -p "$source" "$attempt/$name"
    else
        : > "$attempt/$name.absent"
    fi
}
restore_path() { # <destination> <name> <attempt-dir> <mode>
    local destination=$1 name=$2 attempt=$3 mode=$4
    if [ -f "$attempt/$name.absent" ]; then
        rm -f "$destination" || return 1
    else
        install -D -o root -g root -m "$mode" "$attempt/$name" "$destination" || return 1
    fi
}
restore_deploy_files() { # validated values from this attempt or load_rollback_state
    install -o root -g root -m 0600 "$PREVIOUS_ENV_BACKUP" "$ENV_FILE" || return 1
    restore_path "$REFRESH_BIN" refresh-env.sh "$TOOLING_BACKUP" 0755 || return 1
    restore_path "$ENVLIB/required-env-keys.txt" required-env-keys.txt "$TOOLING_BACKUP" 0644 || return 1
    restore_path "$ENVLIB/release-env-defaults" release-env-defaults "$TOOLING_BACKUP" 0644 || return 1
    if [ "$PREVIOUS_CURRENT" = none ]; then
        rm -f "$DEPLOY_ROOT/current" || return 1
    else
        ln -sfnT "$PREVIOUS_CURRENT" "$DEPLOY_ROOT/current" || return 1
    fi
}
restore_prior_rollback_state() {
    local temp
    if [ -f "$TOOLING_BACKUP/rollback-state.absent" ]; then
        rm -f "$ROLLBACK_STATE" || return 1
        sync -f "$STATE" || return 1
        return 0
    fi
    temp=$(mktemp "$STATE/.rollback-state.restore.XXXXXX") || return 1
    if ! install -o root -g root -m 0600 "$TOOLING_BACKUP/rollback-state" "$temp" ||
        ! sync -f "$temp" || ! mv -f "$temp" "$ROLLBACK_STATE" || ! sync -f "$STATE"; then
        rm -f "$temp" || true
        return 1
    fi
}
restore_files() {
    restore_deploy_files || return 1
    restore_prior_rollback_state || return 1
}
publish_rollback_state() {
    local temp
    temp=$(mktemp "$STATE/.rollback-state.publish.XXXXXX") || return 1
    if ! chmod 0600 "$temp" || ! chown root:root "$temp" ||
        ! printf '%s\n%s\n%s\n%s\n%s\n%s\n' "$PREVIOUS_IMAGE" "$PREVIOUS_ENV_BACKUP" \
            "$PREVIOUS_ENV_BACKUP_SHA256" "$FALLBACK" "$TOOLING_BACKUP" "$PREVIOUS_CURRENT" > "$temp" ||
        ! sync -f "$temp" || ! mv -f "$temp" "$ROLLBACK_STATE" || ! sync -f "$STATE"; then
        rm -f "$temp" || true
        return 1
    fi
}
load_rollback_state() {
    [ -f "$ROLLBACK_STATE" ] || fail "no rollback state; nothing to roll back to"
    [ "$(stat -c '%U:%G:%a' "$ROLLBACK_STATE")" = root:root:600 ] || fail "rollback state is not root:root 600"
    PREVIOUS_IMAGE=$(sed -n 1p "$ROLLBACK_STATE")
    PREVIOUS_ENV_BACKUP=$(sed -n 2p "$ROLLBACK_STATE")
    PREVIOUS_ENV_BACKUP_SHA256=$(sed -n 3p "$ROLLBACK_STATE")
    FALLBACK=$(sed -n 4p "$ROLLBACK_STATE")
    TOOLING_BACKUP=$(sed -n 5p "$ROLLBACK_STATE")
    PREVIOUS_CURRENT=$(sed -n 6p "$ROLLBACK_STATE")
    case "$PREVIOUS_ENV_BACKUP" in "$STATE"/attempt-*/env.before) ;; *) fail "invalid env backup path in rollback state" ;; esac
    case "$TOOLING_BACKUP" in "$STATE"/attempt-*) ;; *) fail "invalid tooling backup path in rollback state" ;; esac
    [ -d "$TOOLING_BACKUP" ] && [ "$(stat -c '%U:%G:%a' "$TOOLING_BACKUP")" = root:root:700 ] ||
        fail "tooling backup is not a root:root 0700 directory"
    [ "$(sha256sum "$PREVIOUS_ENV_BACKUP" | cut -d' ' -f1)" = "$PREVIOUS_ENV_BACKUP_SHA256" ] || fail "the env backup changed"
    grep -Fxq "$DRAIN_GRACE_LINE" "$PREVIOUS_ENV_BACKUP" || fail "the env backup has no $DRAIN_GRACE_LINE"
    for item in refresh-env.sh required-env-keys.txt release-env-defaults rollback-state; do
        [ -f "$TOOLING_BACKUP/$item" ] || [ -f "$TOOLING_BACKUP/$item.absent" ] ||
            fail "tooling backup is incomplete ($item)"
    done
    if [ "$PREVIOUS_CURRENT" != none ]; then
        case "$PREVIOUS_CURRENT" in "$DEPLOY_ROOT"/*) ;; *) fail "invalid previous current path" ;; esac
        [ -d "$PREVIOUS_CURRENT" ] || fail "previous current files no longer exist"
    fi
}
rollback() {    # runbook "Rollback"
    [ "$ROLLBACK_ACTIVE" = 0 ] || fail "rollback is already active; recovery context retained"
    ROLLBACK_ACTIVE=1
    CLEANUP_ACTIVE=1
    load_rollback_state
    if [ "$PREVIOUS_IMAGE" != none ]; then
        docker image inspect "$PREVIOUS_IMAGE" --format '{{.Id}}' >/dev/null || fail "previous image $PREVIOUS_IMAGE is not on the host"
    fi
    if docker container inspect coordinator >/dev/null 2>&1; then
        container_has_drain_grace coordinator || fail "the coordinator container has no $DRAIN_GRACE_LINE; nothing stopped"
        docker stop -t "$STOP_TIMEOUT" coordinator >/dev/null || fail "could not stop coordinator during rollback"
        docker rm coordinator >/dev/null || fail "could not remove coordinator during rollback"
    fi
    if docker ps -q --filter "name=^${FALLBACK}\$" | grep -q .; then
        container_has_drain_grace "$FALLBACK" || fail "$FALLBACK has no $DRAIN_GRACE_LINE"
        docker stop -t "$STOP_TIMEOUT" "$FALLBACK" >/dev/null || fail "could not stop $FALLBACK during rollback"
    fi
    restore_deploy_files || fail "could not restore env, tooling or current link; recovery context retained"
    if [ "$PREVIOUS_IMAGE" = none ]; then
        rm -f "$LAST_GOOD" || fail "could not remove $LAST_GOOD; recovery context retained"
        restore_prior_rollback_state || fail "pre-first-deploy state is restored, but prior rollback metadata could not be published"
        echo "REPORT restored the pre-deploy env, tooling and current link; no previous container existed"
        CLEANUP_PHASE=none
        return 0
    fi
    run_coordinator "$PREVIOUS_IMAGE" || fail "could not restart previous image $PREVIOUS_IMAGE; recovery context retained"
    PREVIOUS_COMMIT=$(docker image inspect "$PREVIOUS_IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')
    if ! wait_ready "$PREVIOUS_COMMIT"; then
        save_logs coordinator
        fail "rollback image $PREVIOUS_IMAGE is not ready within 180 s; recovery context retained"
    fi
    [ "$(docker inspect --format '{{.Image}}' coordinator)" = "$PREVIOUS_IMAGE" ] ||
        fail "rollback runs the wrong image; recovery context retained"
    printf '%s\n' "$PREVIOUS_IMAGE" | install -m 0600 /dev/stdin "$LAST_GOOD" ||
        fail "could not restore $LAST_GOOD; recovery context retained"
    restore_prior_rollback_state || fail "previous image recovered, but prior rollback metadata could not be published"
    CLEANUP_PHASE=none
}
if [ "$MODE" = rollback ]; then
    rollback
    if [ -f "$LAST_GOOD" ]; then
        finish "OK rolled back to $(cat "$LAST_GOOD")"
    else
        finish "OK restored the pre-first-deploy state"
    fi
    exit 0
fi
[ "$MODE" = deploy ] || fail "MODE must be deploy or rollback"

: "${CANDIDATE_VERSION:?}" "${CANDIDATE_COMMIT:?}" "${CANDIDATE_DIGEST:?}"
[[ "$CANDIDATE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "CANDIDATE_COMMIT must be 40 lowercase hex"
[[ "$CANDIDATE_DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "CANDIDATE_DIGEST must be sha256:<64 hex>"
MIGRATE_ONLY=${MIGRATE_ONLY:-1}
CANDIDATE_IMAGE="$REPO@$CANDIDATE_DIGEST"

# The candidate's seed contract is a hard pre-mutation gate. It checks the
# live file, its root ownership/modes and the production env contract without
# reading Secret Manager or printing any value.
if ! SEED_CHECK=$(ENV_DIR=$(dirname "$ENV_FILE") "$LIB/deploy/gcp/dev/seed-env.sh" --check 2>&1); then
    printf '%s\n' "$SEED_CHECK" | grep -E '^(PASS|REPORT|FAIL) ' |
        sed -E 's/^(PASS|REPORT|FAIL) /REPORT seed check: /' || true
    fail "seed-env.sh --check failed; nothing changed"
fi
printf '%s\n' "$SEED_CHECK" | grep -E '^(PASS|REPORT) ' |
    sed -E 's/^(PASS|REPORT) /REPORT seed check: /' || true

# Resolve the published deploy files before any local or remote mutation.
# GNU readlink -f can return a canonical path for an absent final component,
# so absence must be established from the directory entry itself.
if [ ! -e "$DEPLOY_ROOT/current" ] && [ ! -L "$DEPLOY_ROOT/current" ]; then
    PREVIOUS_CURRENT=none
else
    [ -L "$DEPLOY_ROOT/current" ] ||
        fail "$DEPLOY_ROOT/current exists but is not a symlink; nothing changed"
    PREVIOUS_CURRENT=$(readlink -f "$DEPLOY_ROOT/current") ||
        fail "$DEPLOY_ROOT/current is a dangling or unreadable symlink; nothing changed"
    case "$PREVIOUS_CURRENT" in
        "$DEPLOY_ROOT"/*) ;;
        *) fail "current deploy files resolve outside $DEPLOY_ROOT; nothing changed" ;;
    esac
    [ -d "$PREVIOUS_CURRENT" ] ||
        fail "current deploy files do not resolve to an existing directory; nothing changed"
fi
install -d -o root -g root -m 0700 "$STATE"
prepare_psql ||
    fail "EIGENINFERENCE_DATABASE_URL is not a single-host URI with sslmode require, verify-ca or verify-full; nothing changed"

# Step 2: pre-swap checks. Nothing changes until they pass.
psql_private -Atc 'select 1' >/dev/null 2>&1 ||
    fail "cannot connect to the database with EIGENINFERENCE_DATABASE_URL; nothing changed"
db_clear || fail "long queries, blocked locks or a goose lock holder; nothing changed"
psql_private -Atc "select id from schema_migrations where id in ('backfill_withdrawable_balance_v1',
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

# Resolve and validate every rollback input before the env or host tooling changes.
FALLBACK=coordinator_fallback_$(date +%Y%m%d-%H%M%S)
if [ "$CURRENT" = true ]; then
    container_has_drain_grace coordinator || fail "the running container has no $DRAIN_GRACE_LINE; nothing changed"
    PREVIOUS_IMAGE=$(docker inspect --format '{{.Image}}' coordinator)
    APPROVED_PREVIOUS_IMAGE=$(cat "$LAST_GOOD" 2>/dev/null || true)
    [ "$PREVIOUS_IMAGE" = "$APPROVED_PREVIOUS_IMAGE" ] ||
        fail "the running image is not the last verified image ($LAST_GOOD); nothing changed"
else
    PREVIOUS_IMAGE=none
fi
ATTEMPT=$STATE/attempt-$(date -u +%Y%m%dT%H%M%SZ)-$$
install -d -o root -g root -m 0700 "$ATTEMPT"
install -o root -g root -m 0600 "$ENV_FILE" "$ATTEMPT/env.before"
backup_path "$REFRESH_BIN" refresh-env.sh "$ATTEMPT"
backup_path "$ENVLIB/required-env-keys.txt" required-env-keys.txt "$ATTEMPT"
backup_path "$ENVLIB/release-env-defaults" release-env-defaults "$ATTEMPT"
backup_path "$ROLLBACK_STATE" rollback-state "$ATTEMPT"
PREVIOUS_ENV_BACKUP=$ATTEMPT/env.before
PREVIOUS_ENV_BACKUP_SHA256=$(sha256sum "$PREVIOUS_ENV_BACKUP" | cut -d' ' -f1)
TOOLING_BACKUP=$ATTEMPT
CLEANUP_PHASE=files
if ! publish_rollback_state; then
    restore_files || fail "rollback-state publication failed and the pre-deploy files could not be restored"
    CLEANUP_PHASE=none
    fail "could not atomically publish rollback state; restored the pre-deploy state"
fi

restore_then_fail() {
    local message=$1
    restore_files || fail "could not restore env, tooling, current link or prior rollback metadata after: $message"
    CLEANUP_PHASE=none
    fail "$message; restored the pre-deploy env, tooling and current link"
}

# Step 3: refresh from the shipped candidate. The rollback state already points
# to an independent pre-refresh env/tooling snapshot, including first deploys.
refresh --check | sed 's/^/REPORT refresh check: /' || restore_then_fail "refresh --check failed"
if ! REFRESH_OUTPUT=$(refresh --apply); then
    restore_then_fail "refresh --apply failed"
fi
printf '%s\n' "$REFRESH_OUTPUT" | sed 's/^/REPORT refresh: /'
refresh_backup=$(reported_refresh_backup "$ENV_FILE" "$REFRESH_OUTPUT") ||
    restore_then_fail "refresh --apply did not report one regular timestamped backup"
# A backup that differs from env.before holds an env change made after that
# snapshot. It is the only copy of that change, so it stays.
[ "$(sha256sum "$refresh_backup" | cut -d' ' -f1)" = "$PREVIOUS_ENV_BACKUP_SHA256" ] ||
    restore_then_fail "the refresh backup $refresh_backup does not match the pre-refresh env and is kept"
rm -f -- "$refresh_backup" || restore_then_fail "could not remove the redundant refresh backup"
if [ "$CURRENT" = true ] && [ "$(cache_env_digest)" != "$BEFORE_DIGEST" ]; then
    restore_then_fail "the refresh changed the cache controls while the current container still serves"
fi
grep -Fxq 'EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS=9000' "$ENV_FILE" ||
    echo "REPORT EIGENINFERENCE_TTFT_LIVE_DEADLINE_BASE_MS is not the prod.env value"
grep -Fxq "$DRAIN_GRACE_LINE" "$ENV_FILE" || restore_then_fail "$ENV_FILE has no $DRAIN_GRACE_LINE"
# Step 4: swap. One host-network container at a time.
CLEANUP_PHASE=swap
T0=$(date +%s)
if [ "$CURRENT" = true ]; then
    if ! docker rename coordinator "$FALLBACK" || ! docker stop -t "$STOP_TIMEOUT" "$FALLBACK" >/dev/null; then
        rollback
        fail "could not drain the current container; restored the pre-deploy state"
    fi
fi
T1=$(date +%s)
if ! run_coordinator "$CANDIDATE_IMAGE"; then
    rollback
    fail "could not start the candidate; restored the pre-deploy state"
fi

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

install_candidate_tooling() {
    install -d -o root -g root -m 0755 "$ENVLIB" || return 1
    install -o root -g root -m 0755 "$LIB/deploy/gcp/prod/refresh-env.sh" "$REFRESH_BIN" || return 1
    install -o root -g root -m 0644 "$LIB/deploy/gcp/prod/required-env-keys.txt" \
        "$ENVLIB/required-env-keys.txt" || return 1
    install -o root -g root -m 0644 "$LIB/deploy/gcp/prod/release-env-defaults" \
        "$ENVLIB/release-env-defaults" || return 1
}
if ! install_candidate_tooling; then
    rollback
    fail "candidate passed health gates but tooling installation failed; restored the pre-deploy state"
fi
if ! docker inspect --format '{{.Image}}' coordinator | install -o root -g root -m 0600 /dev/stdin "$LAST_GOOD"; then
    rollback
    fail "could not record the last-good image; restored the pre-deploy state"
fi
if ! ln -sfnT "$LIB" "$DEPLOY_ROOT/current"; then
    rollback
    fail "could not publish the current deploy files; restored the pre-deploy state"
fi
COMMITTED=1
CLEANUP_PHASE=none
# Past the commit point a failure is reported and never rolls back.
pg_cleanup_report=""
if ! cleanup_pg_files; then
    echo "REPORT private database credential cleanup failed after the commit; remove $PG_TMP on the VM" >&2
    pg_cleanup_report="; private database credential cleanup failed"
    PG_TMP=""   # already reported; the exit trap must not retry and append to the OK line
fi

# prune_superseded_files keeps what one rollback reads: this attempt (the env
# and tooling backup that rollback-state names), and the current and previous
# deploy files. Each older attempt holds a copy of the secret env file.
prune_superseded_files() {
    local dir status=0
    for dir in "$STATE"/attempt-*; do
        [ -d "$dir" ] && [ ! -L "$dir" ] && [ ! "$dir" -ef "$ATTEMPT" ] || continue
        rm -rf "$dir" || status=1
    done
    for dir in "$DEPLOY_ROOT"/*; do
        [[ "${dir##*/}" =~ ^[0-9a-f]{40}$ ]] && [ -d "$dir" ] && [ ! -L "$dir" ] || continue
        [ "$dir" -ef "$LIB" ] || [ "$dir" -ef "$PREVIOUS_CURRENT" ] || rm -rf "$dir" || status=1
    done
    return "$status"
}
# Bound only files generated by this dev deploy machinery. Unknown operator
# files are never matched, and the active result file remains for deploy.sh.
# The second -name of each pair refuses a non-digit in the numeric field.
prune_generated_history() {
    local hex='[0-9a-f]' digit='[0-9]' status=0
    local short_sha=$hex$hex$hex$hex$hex$hex$hex
    local utc=$digit$digit$digit$digit$digit$digit$digit${digit}T$digit$digit$digit$digit$digit${digit}Z
    find "$DEPLOY_ROOT" -maxdepth 1 -type f -mtime +14 ! -path "$RESULT" \( \
        \( -name "darkbloom-dev-swap-$short_sha-$digit*.result" ! -name 'darkbloom-dev-swap-???????-*[!0-9]*.result' \) -o \
        \( -name "darkbloom-dev-rollback-$digit*.result" ! -name 'darkbloom-dev-rollback-*[!0-9]*.result' \) \
        \) -delete || status=1
    find "$STATE" -maxdepth 1 -type f -mtime +14 -name "failed-coordinator-$utc.log" -delete || status=1
    return "$status"
}
prune_generated_history ||
    echo "REPORT could not remove every dev deploy result or failed-container log older than 14 days" >&2

# The boot refresh unit, and a failed removal of a swap refresh backup, leave
# <env file>.bak.<UTC> copies of the secret env file. Remove a copy only when
# its bytes equal the live file or the env.before that rollback-state names.
# Another copy is the only copy of that env state, so it stays.
prune_redundant_env_backups() {
    local file digest live status=0
    live=$(sha256sum "$ENV_FILE" | cut -d' ' -f1) || return 1
    for file in "$ENV_FILE".bak.*; do
        refresh_backup_name_is_valid "$ENV_FILE" "$file" && [ -f "$file" ] && [ ! -L "$file" ] || continue
        digest=$(sha256sum "$file" | cut -d' ' -f1) || { status=1; continue; }
        [ "$digest" = "$live" ] || [ "$digest" = "$PREVIOUS_ENV_BACKUP_SHA256" ] || continue
        rm -f -- "$file" || status=1
    done
    return "$status"
}
prune_redundant_env_backups ||
    echo "REPORT could not remove every redundant $ENV_FILE.bak.* copy" >&2

# Dev housekeeping: keep this run's fallback container, the files of one
# rollback, and images younger than 7 days or in use.
prune_superseded_files ||
    echo "REPORT could not remove every superseded directory in $STATE and $DEPLOY_ROOT" >&2
docker ps -a --format '{{.Names}}' | grep '^coordinator_fallback_' | grep -vx "$FALLBACK" |
    xargs -r docker rm >/dev/null 2>&1 || true
docker image prune -af --filter until=168h >/dev/null 2>&1 || true
finish "OK $CANDIDATE_COMMIT drain_s=$((T1 - T0)) start_to_ready_s=$((T2 - T1))$pg_cleanup_report"
