#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ENV_DIR=${ENV_DIR:-/etc/d-inference}
ENV_FILE=${ENV_FILE:-$ENV_DIR/env}
REQUIRED_FILE=${REQUIRED_FILE:-$SCRIPT_DIR/required-env-keys.txt}
DEFAULTS_FILE=${DEFAULTS_FILE:-$SCRIPT_DIR/release-env-defaults}
MODE=${1:---check}

fail() {
    echo "prod env refresh: $*" >&2
    exit 1
}

case "$MODE" in
    --check|--apply) ;;
    *) fail "usage: $0 [--check|--apply]" ;;
esac

[[ "$ENV_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    fail "ENV_DIR must be an absolute path containing only safe path characters"
[[ "$ENV_FILE" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    fail "ENV_FILE must be an absolute path containing only safe path characters"
case "$ENV_FILE" in
    "$ENV_DIR"/*) ;;
    *) fail "ENV_FILE must be inside ENV_DIR" ;;
esac

[ -f "$ENV_FILE" ] && [ ! -L "$ENV_FILE" ] || fail "$ENV_FILE must be an existing regular file"
[ -r "$REQUIRED_FILE" ] || fail "missing required-key manifest: $REQUIRED_FILE"
[ -r "$DEFAULTS_FILE" ] || fail "missing release defaults: $DEFAULTS_FILE"

if [ "${SKIP_PERSISTENCE_CHECK:-0}" != 1 ]; then
    command -v findmnt >/dev/null 2>&1 || fail "findmnt is required to verify persistent storage"
    fs_type=$(findmnt -n -o FSTYPE --target "$ENV_DIR" 2>/dev/null) ||
        fail "cannot resolve filesystem for $ENV_DIR"
    [ -n "$fs_type" ] || fail "filesystem type for $ENV_DIR is empty"
    [ "$fs_type" != "tmpfs" ] || fail "$ENV_DIR is tmpfs; migrate it to the boot disk before refresh"
fi

validate_env_file() {
    local file=$1
    awk '
        /^[[:space:]]*($|#)/ { next }
        !/^[A-Za-z_][A-Za-z0-9_]*=/ {
            printf "invalid env line %d\n", NR > "/dev/stderr"
            failed = 1
            next
        }
        {
            key = $0
            sub(/=.*/, "", key)
            if (seen[key]++) {
                printf "duplicate env key %s\n", key > "/dev/stderr"
                failed = 1
            }
        }
        END { exit failed }
    ' "$file" || fail "invalid environment file: $file"
}

require_existing_values() {
    local file=$1
    local missing=""
    while IFS= read -r key; do
        case "$key" in ""|\#*) continue ;; esac
        if ! awk -F= -v key="$key" '$1 == key && length(substr($0, index($0, "=") + 1)) > 0 { found=1 } END { exit !found }' "$file"; then
            missing="$missing $key"
        fi
    done < "$REQUIRED_FILE"
    [ -z "$missing" ] || fail "required existing variables are missing or empty:$missing"
}

validate_env_file "$ENV_FILE"
require_existing_values "$ENV_FILE"
validate_env_file "$DEFAULTS_FILE"

mkdir -p "$ENV_DIR"
tmp=$(mktemp "$ENV_DIR/.env.release.XXXXXX")
trap 'rm -f "$tmp"' EXIT
cp "$ENV_FILE" "$tmp"

migrated=0
migrate_exact_value() {
    local key=$1
    local old_value=$2
    local new_value=$3
    local current
    current=$(awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1) }' "$tmp")
    [ "$current" = "$old_value" ] || return 0

    awk -F= -v key="$key" -v value="$new_value" \
        '$1 == key { print key "=" value; next } { print }' "$tmp" > "$tmp.migrated"
    mv "$tmp.migrated" "$tmp"
    printf 'MIGRATE %s\n' "$key"
    migrated=$((migrated + 1))
}

# /data is a runtime symlink. The prompt artifact cache rejects every symlinked
# path component, so the v0.7.11 default could never provision a contract.
migrate_exact_value \
    EIGENINFERENCE_PROMPT_SIDECAR_ARTIFACT_ROOT \
    /data/prompt-contracts \
    /mnt/disks/userdata/prompt-contracts

# v0.7.12 shipped one-strike-era probe timings. Migrate only those exact
# historical defaults so explicit operator tuning remains untouched.
migrate_exact_value \
    EIGENINFERENCE_PROMPT_SIDECAR_STARTUP_TIMEOUT_MS \
    5000 \
    120000
migrate_exact_value \
    EIGENINFERENCE_PROMPT_SIDECAR_HEALTH_INTERVAL_MS \
    100 \
    1000

added=0
while IFS= read -r line; do
    case "$line" in ""|\#*) continue ;; esac
    key=${line%%=*}
    if ! awk -F= -v key="$key" '$1 == key { found=1 } END { exit !found }' "$tmp"; then
        printf '%s\n' "$line" >> "$tmp"
        printf 'ADD %s\n' "$line"
        added=$((added + 1))
    fi
done < "$DEFAULTS_FILE"

validate_env_file "$tmp"
require_existing_values "$tmp"

old_keys=$(mktemp "${TMPDIR:-/tmp}/darkbloom-env-old.XXXXXX")
new_keys=$(mktemp "${TMPDIR:-/tmp}/darkbloom-env-new.XXXXXX")
trap 'rm -f "$tmp" "$old_keys" "$new_keys"' EXIT
awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ { print $1 }' "$ENV_FILE" | LC_ALL=C sort -u > "$old_keys"
awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ { print $1 }' "$tmp" | LC_ALL=C sort -u > "$new_keys"
dropped=$(comm -23 "$old_keys" "$new_keys")
[ -z "$dropped" ] || fail "generation would drop existing keys: $(printf '%s' "$dropped" | tr '\n' ' ')"

if [ "$MODE" = "--check" ]; then
    if [ "$added" -eq 0 ] && [ "$migrated" -eq 0 ]; then
        echo "prod env refresh: no changes"
    else
        echo "prod env refresh: $added safe defaults and $migrated migrations would be applied"
    fi
    exit 0
fi

backup="$ENV_FILE.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "$ENV_FILE" "$backup"
chmod 0600 "$tmp"
if command -v chown >/dev/null 2>&1; then
    chown --reference="$ENV_FILE" "$tmp" 2>/dev/null || true
fi
mv -f "$tmp" "$ENV_FILE"
trap 'rm -f "$old_keys" "$new_keys"' EXIT
sync "$ENV_FILE" "$ENV_DIR" 2>/dev/null || sync
echo "prod env refresh: applied $added additions and $migrated migrations; backup=$backup"
