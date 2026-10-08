#!/bin/bash
# Dev only. Builds /etc/d-inference/env on the dev coordinator VM from two
# sources, in this order; the first value for a key wins:
#   1. deploy/gcp/dev/env-overrides: literals, and "secret-manager:<name>" values
#      that are read from Secret Manager in darkbloom-dev with the VM account.
#      A literal can use ${KEY} for an earlier literal key of the same file.
#   2. the EIGENINFERENCE_* lines of deploy/environments/prod.env.
# The production refresh (deploy/gcp/prod/refresh-env.sh) then checks the file
# and adds the release defaults. After the seed, the production refresh owns
# the file, as in production. A deploy never reads Secret Manager.
#
#   seed-env.sh [--check]  read only: report the state of the live file (default)
#   seed-env.sh --seed     write the file only when it does not exist
#   seed-env.sh --reseed   replace the live file; the old file stays as env.pre-reseed.<UTC>
#
# The script prints key names and secret names only, never a value. It refuses
# to run outside the GCP project darkbloom-dev.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT=darkbloom-dev
METADATA_URL=http://metadata.google.internal/computeMetadata/v1/project/project-id
MODE=${1:---check}
ENV_DIR=${ENV_DIR:-/etc/d-inference}
ENV_FILE=$ENV_DIR/env
OVERRIDES=$SCRIPT_DIR/env-overrides
PROD_REFERENCE=$SCRIPT_DIR/../../environments/prod.env
REFRESH=$SCRIPT_DIR/../prod/refresh-env.sh
REQUIRED_FILE=$SCRIPT_DIR/../prod/required-env-keys.txt
DEFAULTS_FILE=$SCRIPT_DIR/../prod/release-env-defaults
export ENV_DIR REQUIRED_FILE DEFAULTS_FILE

fail() {
    echo "FAIL dev env seed: $*" >&2
    exit 1
}
# shellcheck source=deploy/gcp/dev/refresh-backup.sh
# Check first: bash 3.2 exits at once when "." names a missing file.
[ -r "$SCRIPT_DIR/refresh-backup.sh" ] || fail "cannot read $SCRIPT_DIR/refresh-backup.sh"
. "$SCRIPT_DIR/refresh-backup.sh" || fail "cannot read $SCRIPT_DIR/refresh-backup.sh"

case "$MODE" in
    --check|--seed|--reseed) ;;
    *) fail "usage: $0 [--check|--seed|--reseed]" ;;
esac

[ "$(id -u)" = 0 ] || fail "run as root"
project=$(curl -fsS --max-time 5 -H 'Metadata-Flavor: Google' "$METADATA_URL") ||
    fail "cannot read the project from the metadata server"
[ "$project" = "$PROJECT" ] || fail "project is $project, not $PROJECT"
for f in "$OVERRIDES" "$PROD_REFERENCE" "$REFRESH" "$REQUIRED_FILE" "$DEFAULTS_FILE"; do
    [ -r "$f" ] || fail "missing input $f"
done

# Prints one line per overlay key: "L<TAB>key<TAB>expanded literal" or
# "S<TAB>key<TAB>secret name". The output stays inside this script.
overlay_lines() {
    awk '
        function expand(v,   out, i, j, name) {
            out = ""
            while ((i = index(v, "${")) > 0) {
                j = index(substr(v, i + 2), "}")
                if (j == 0) break
                name = substr(v, i + 2, j - 1)
                if (!(name in lit)) { unknown = unknown " " name }
                out = out substr(v, 1, i - 1) lit[name]
                v = substr(v, i + 2 + j)
            }
            return out v
        }
        /^[[:space:]]*($|#)/ { next }
        !/^[A-Za-z_][A-Za-z0-9_]*=/ { printf "invalid overlay line %d\n", NR > "/dev/stderr"; bad = 1; next }
        {
            key = $0; sub(/=.*/, "", key)
            value = substr($0, index($0, "=") + 1)
            if (seen[key]++) { printf "duplicate overlay key %s\n", key > "/dev/stderr"; bad = 1; next }
            if (value ~ /^secret-manager:/) { print "S\t" key "\t" substr(value, 16); next }
            value = expand(value)
            lit[key] = value
            print "L\t" key "\t" value
        }
        END {
            if (unknown != "") { printf "overlay references unknown keys:%s\n", unknown > "/dev/stderr"; bad = 1 }
            exit bad
        }
    ' "$OVERRIDES"
}

env_value() {
    awk -F= -v key="$2" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$1"
}

has_key() {
    awk -F= -v key="$2" '$1 == key { found = 1 } END { exit !found }' "$1"
}

overlay=$(overlay_lines) || fail "invalid overlay $OVERRIDES"

if [ "$MODE" = --check ]; then
    status=0
    if [ ! -f "$ENV_FILE" ]; then
        echo "FAIL $ENV_FILE does not exist. Fix: run seed-env.sh --seed"
        exit 1
    fi
    echo "PASS $ENV_FILE exists"
    file_security=$(stat -c '%U:%G:%a' "$ENV_FILE" 2>/dev/null || true)
    dir_security=$(stat -c '%U:%G:%a' "$ENV_DIR" 2>/dev/null || true)
    if [ "$file_security" = root:root:600 ] && [ "$dir_security" = root:root:700 ]; then
        echo "PASS $ENV_FILE is root:root 0600 in a root:root 0700 directory"
    else
        echo "FAIL $ENV_FILE must be root:root 0600 and $ENV_DIR root:root 0700. Fix: chown root:root $ENV_DIR $ENV_FILE; chmod 0700 $ENV_DIR; chmod 0600 $ENV_FILE"
        status=1
    fi
    while IFS=$'\t' read -r kind key value; do
        if ! has_key "$ENV_FILE" "$key"; then
            echo "REPORT overlay key $key is not in the live file"
        elif [ "$kind" = L ] && [ "$(env_value "$ENV_FILE" "$key")" != "$value" ]; then
            echo "REPORT DRIFT $key: the live value is not the overlay value"
        fi
    done <<< "$overlay"
    if out=$(ENV_FILE="$ENV_FILE" "$REFRESH" --check 2>&1); then
        echo "PASS production check of the live file"
    else
        echo "FAIL production check of the live file. Fix: add the missing values, then run seed-env.sh --reseed"
        status=1
    fi
    printf '%s\n' "$out" | sed 's/^/REPORT /'
    exit "$status"
fi

if [ "$MODE" = --seed ] && [ -e "$ENV_FILE" ]; then
    echo "PASS $ENV_FILE exists; nothing to do (use --reseed to replace it)"
    exit 0
fi

install -d -m 0700 "$ENV_DIR"
tmp=$(mktemp "$ENV_DIR/.env.seed.XXXXXX")
trap 'rm -f "$tmp"' EXIT
chmod 0600 "$tmp"

add() {
    has_key "$tmp" "$1" || printf '%s=%s\n' "$1" "$2" >> "$tmp"
}

unread=""
multiline=""
while IFS=$'\t' read -r kind key value; do
    if [ "$kind" = S ]; then
        secret=$value
        if ! value=$(gcloud --quiet secrets versions access latest \
            --project="$PROJECT" --secret="$secret" 2>/dev/null) || [ -z "$value" ]; then
            unread="$unread $key($secret)"
            value=""
        fi
    fi
    case "$value" in
        *$'\n'*) multiline="$multiline $key"; continue ;;
    esac
    [ -z "$value" ] || add "$key" "$value"
done <<< "$overlay"
[ -z "$multiline" ] ||
    fail "values must be one line (store a PEM with \\n escapes):$multiline; nothing written"

while IFS= read -r line; do
    add "${line%%=*}" "${line#*=}"
done < <(grep -E '^EIGENINFERENCE_[A-Z0-9_]*=' "$PROD_REFERENCE")

if [ "$(env_value "$tmp" MICROMDM_API_KEY)" != "$(env_value "$tmp" EIGENINFERENCE_MDM_API_KEY)" ]; then
    fail "MICROMDM_API_KEY and EIGENINFERENCE_MDM_API_KEY differ; nothing written"
fi
[ -z "$unread" ] || echo "REPORT empty or unreadable secrets, left out (key and secret name):$unread"

if ! out=$(ENV_FILE="$tmp" "$REFRESH" --check 2>&1); then
    fail "the new file fails the production check; nothing written: $out"
fi
echo "PASS production check of the new file"
printf '%s\n' "$out" | sed 's/^/REPORT /'

if [ -e "$ENV_FILE" ]; then
    backup="$ENV_FILE.pre-reseed.$(date -u +%Y%m%dT%H%M%SZ)"
    cp -p "$ENV_FILE" "$backup"
    dropped=$(comm -23 \
        <(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ { print $1 }' "$ENV_FILE" | LC_ALL=C sort -u) \
        <(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ { print $1 }' "$tmp" | LC_ALL=C sort -u) | tr '\n' ' ')
    echo "REPORT the old file is kept as $backup"
    [ -z "$dropped" ] || echo "REPORT keys of the old file that the new file does not have: $dropped"
fi
written_sha256=$(sha256sum "$tmp" | cut -d' ' -f1)
mv -f "$tmp" "$ENV_FILE"
trap - EXIT
sync "$ENV_FILE" "$ENV_DIR" 2>/dev/null || sync
if ! refresh_out=$(ENV_FILE="$ENV_FILE" "$REFRESH" --apply); then
    fail "the written file could not be refreshed: $refresh_out"
fi
printf '%s\n' "$refresh_out" | sed 's/^/REPORT /'
# The env file is in place and refreshed. A backup that stays is reported, not
# a failure: a second --seed finds the file and does nothing. A backup that is
# not the file the seed wrote holds a change made since then, so it stays.
if ! refresh_backup=$(reported_refresh_backup "$ENV_FILE" "$refresh_out"); then
    echo "REPORT the refresh did not report one regular timestamped backup; nothing removed"
elif ! refresh_backup_is_copy_of "$refresh_backup" "$written_sha256"; then
    echo "REPORT the refresh backup $refresh_backup is not the file the seed wrote; it is kept"
elif ! rm -f -- "$refresh_backup"; then
    echo "REPORT could not remove the redundant post-seed refresh backup $refresh_backup"
fi
echo "OK wrote $ENV_FILE"
