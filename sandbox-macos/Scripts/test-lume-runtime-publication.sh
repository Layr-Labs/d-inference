#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${DARKBLOOM_LUME_PYTHON:-$(command -v python3)}"
PUBLICATION_HELPER="$SCRIPT_DIR/lume-runtime-publication.py"
CLEANUP_HELPER="$SCRIPT_DIR/remove-sealed-lume-staging.sh"
TEST_ROOT=""
TEST_COUNT=0
STAGING_DIR=""

fail() {
    echo "Lume publication contract failure: $*" >&2
    exit 1
}

pass() {
    TEST_COUNT=$((TEST_COUNT + 1))
    echo "lume_publication_contract_pass=$1"
}

mode_of() {
    "$PYTHON" - "$1" <<'PY'
import os
import stat
import sys

print(f"{stat.S_IMODE(os.lstat(sys.argv[1]).st_mode):04o}")
PY
}

acl_snapshot() {
    /bin/ls -lde "$1" | /usr/bin/sed -n '2,$p'
}

has_acl() {
    mode_field="$(/bin/ls -lde "$1" | /usr/bin/awk 'NR == 1 { print $1 }')"
    [[ "$mode_field" == *+ ]]
}

create_staging() {
    parent="$1"
    version="$2"
    STAGING_DIR="$(mktemp -d "$parent/.darkbloom-lume-install.XXXXXX")"
    /bin/mkdir -p "$STAGING_DIR/lume_lume.bundle/nested"
    printf '%s\n' \
        '#!/bin/bash' \
        "printf '%s\\n' '$version'" \
        > "$STAGING_DIR/lume"
    printf '%s\n' '{"schema_version":3}' > "$STAGING_DIR/lume.provenance.json"
    printf '%s\n' "$version" > "$STAGING_DIR/lume_lume.bundle/nested/resource.txt"
    /bin/chmod 0700 "$STAGING_DIR"
    /bin/chmod 0700 "$STAGING_DIR/lume"
}

staging_identity() {
    "$PYTHON" "$PUBLICATION_HELPER" identity "$1" "$2"
}

seal_staging() {
    "$PYTHON" "$PUBLICATION_HELPER" seal-staging "$1" "$2" "$3"
}

cleanup_test_root() {
    status=$?
    trap - EXIT HUP INT TERM
    if [[ -n "$TEST_ROOT" && ( -e "$TEST_ROOT" || -L "$TEST_ROOT" ) ]]; then
        if [[ "$(uname -s)" == "Darwin" ]]; then
            /bin/chmod -RN "$TEST_ROOT" 2>/dev/null || true
        fi
        /bin/chmod -R u+rwX "$TEST_ROOT" 2>/dev/null || true
        /bin/rm -rf -- "$TEST_ROOT"
    fi
    exit "$status"
}
trap cleanup_test_root EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

TEMPORARY_ROOT="${TMPDIR:-/tmp}"
TEMPORARY_ROOT="${TEMPORARY_ROOT%/}"
TEST_ROOT="$(mktemp -d "$TEMPORARY_ROOT/darkbloom-lume-publication-test.XXXXXX")"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
/bin/chmod 0700 "$TEST_ROOT"

# The staging envelope stays private and writable while every descendant is
# sealed. Publication atomically renames it and only then seals the final root.
create_staging "$TEST_ROOT" "dummy-lume 1.0"
first_staging="$STAGING_DIR"
first_identity="$(staging_identity "$TEST_ROOT" "$first_staging")"
seal_staging "$TEST_ROOT" "$first_staging" "$first_identity"
[[ "$(mode_of "$first_staging")" == "0700" ]] \
    || fail "staging envelope was sealed before publication"
[[ "$(mode_of "$first_staging/lume")" == "0555" ]] \
    || fail "staged executable was not sealed"
[[ "$(mode_of "$first_staging/lume_lume.bundle")" == "0555" ]] \
    || fail "staged resource directory was not sealed"
[[ "$(mode_of "$first_staging/lume.provenance.json")" == "0444" ]] \
    || fail "staged provenance was not sealed"

destination="$TEST_ROOT/darkbloom-pinned-lume"
"$PYTHON" "$PUBLICATION_HELPER" require-absent "$TEST_ROOT" "$destination"
"$PYTHON" "$PUBLICATION_HELPER" \
    publish \
    "$TEST_ROOT" \
    "$first_staging" \
    "$destination" \
    "$first_identity"
[[ ! -e "$first_staging" && ! -L "$first_staging" ]] \
    || fail "published staging name still exists"
[[ "$(mode_of "$destination")" == "0555" ]] \
    || fail "published root was not sealed"
"$PYTHON" "$PUBLICATION_HELPER" verify "$TEST_ROOT" "$destination" "$first_identity"
[[ "$("$destination/lume" --version)" == "dummy-lume 1.0" ]] \
    || fail "published executable did not launch from its final path"
pass "sealed-tree"

# RENAME_EXCL/RENAME_NOREPLACE must win the destination race without replacing
# or nesting under the already-published tree.
create_staging "$TEST_ROOT" "replacement"
replacement_staging="$STAGING_DIR"
replacement_identity="$(staging_identity "$TEST_ROOT" "$replacement_staging")"
seal_staging "$TEST_ROOT" "$replacement_staging" "$replacement_identity"
if "$PYTHON" "$PUBLICATION_HELPER" \
    publish \
    "$TEST_ROOT" \
    "$replacement_staging" \
    "$destination" \
    "$replacement_identity" >/dev/null 2>&1; then
    fail "publication overwrote an existing destination"
fi
"$PYTHON" "$PUBLICATION_HELPER" verify "$TEST_ROOT" "$destination" "$first_identity"
[[ "$("$destination/lume" --version)" == "dummy-lume 1.0" ]] \
    || fail "failed publication changed the destination"
DARKBLOOM_LUME_PYTHON="$PYTHON" \
    /bin/bash "$CLEANUP_HELPER" \
    "$TEST_ROOT" \
    "$replacement_staging" \
    "$replacement_identity"
pass "no-overwrite"

# An error after the atomic rename leaves a private, writable, therefore
# unusable destination for inspection. Cleanup of the vanished staging name
# must not infer authority to remove that destination.
create_staging "$TEST_ROOT" "ambiguous"
ambiguous_staging="$STAGING_DIR"
ambiguous_identity="$(staging_identity "$TEST_ROOT" "$ambiguous_staging")"
seal_staging "$TEST_ROOT" "$ambiguous_staging" "$ambiguous_identity"
ambiguous_destination="$TEST_ROOT/ambiguous-lume"
ambiguous_log="$TEST_ROOT/ambiguous.log"
if "$PYTHON" "$PUBLICATION_HELPER" \
    publish \
    "$TEST_ROOT" \
    "$ambiguous_staging" \
    "$ambiguous_destination" \
    "$ambiguous_identity" \
    --test-fail-after-rename >"$ambiguous_log" 2>&1; then
    fail "injected post-publication failure unexpectedly succeeded"
fi
/usr/bin/grep -q 'destination retained for inspection' "$ambiguous_log" \
    || fail "post-publication failure was not reported as retained"
[[ ! -e "$ambiguous_staging" && -d "$ambiguous_destination" ]] \
    || fail "post-publication failure did not retain only the destination"
[[ "$(mode_of "$ambiguous_destination")" == "0700" ]] \
    || fail "ambiguous destination did not remain private and unusable"
if "$PYTHON" "$PUBLICATION_HELPER" \
    verify \
    "$TEST_ROOT" \
    "$ambiguous_destination" \
    "$ambiguous_identity" >/dev/null 2>&1; then
    fail "ambiguous writable destination passed final verification"
fi
DARKBLOOM_LUME_PYTHON="$PYTHON" \
    /bin/bash "$CLEANUP_HELPER" \
    "$TEST_ROOT" \
    "$ambiguous_staging" \
    "$ambiguous_identity"
[[ -d "$ambiguous_destination" ]] \
    || fail "staging cleanup deleted an ambiguous destination"
pass "post-publication-retention"

# Cleanup is identity-bound and never follows a source symlink or edits the
# caller-owned parent.
parent_mode_before="$(mode_of "$TEST_ROOT")"
create_staging "$TEST_ROOT" "cleanup"
cleanup_staging="$STAGING_DIR"
cleanup_identity="$(staging_identity "$TEST_ROOT" "$cleanup_staging")"
seal_staging "$TEST_ROOT" "$cleanup_staging" "$cleanup_identity"
DARKBLOOM_LUME_PYTHON="$PYTHON" \
    /bin/bash "$CLEANUP_HELPER" \
    "$TEST_ROOT" \
    "$cleanup_staging" \
    "$cleanup_identity"
[[ ! -e "$cleanup_staging" && ! -L "$cleanup_staging" ]] \
    || fail "sealed staging cleanup left the tree behind"
[[ "$(mode_of "$TEST_ROOT")" == "$parent_mode_before" ]] \
    || fail "staging cleanup changed the parent mode"

symlink_target="$TEST_ROOT/symlink-target"
/bin/mkdir "$symlink_target"
printf '%s\n' "keep" > "$symlink_target/marker"
symlink_staging="$TEST_ROOT/.darkbloom-lume-install.symlink"
/bin/ln -s "$symlink_target" "$symlink_staging"
if "$PYTHON" "$PUBLICATION_HELPER" \
    identity "$TEST_ROOT" "$symlink_staging" >/dev/null 2>&1; then
    fail "identity accepted a staging symlink"
fi
if DARKBLOOM_LUME_PYTHON="$PYTHON" \
    /bin/bash "$CLEANUP_HELPER" \
    "$TEST_ROOT" \
    "$symlink_staging" \
    "$cleanup_identity" >/dev/null 2>&1; then
    fail "cleanup accepted a staging symlink"
fi
[[ "$(<"$symlink_target/marker")" == "keep" ]] \
    || fail "unsafe cleanup traversed a staging symlink"
pass "identity-bound-cleanup"

# Destination symlinks and lexical traversal are rejected before publication.
unsafe_destination="$TEST_ROOT/unsafe-destination"
/bin/ln -s "$TEST_ROOT/missing-target" "$unsafe_destination"
if "$PYTHON" "$PUBLICATION_HELPER" \
    require-absent "$TEST_ROOT" "$unsafe_destination" >/dev/null 2>&1; then
    fail "dangling destination symlink was treated as absent"
fi
if "$PYTHON" "$PUBLICATION_HELPER" \
    require-absent "$TEST_ROOT" "$TEST_ROOT/../escaped" >/dev/null 2>&1; then
    fail "destination traversal was accepted"
fi
[[ -L "$unsafe_destination" && ! -e "$TEST_ROOT/missing-target" ]] \
    || fail "destination validation changed a symlink or its target"
pass "unsafe-path-rejection"

if [[ "$(uname -s)" == "Darwin" ]]; then
    acl_parent="$(mktemp -d "$TEMPORARY_ROOT/darkbloom-lume-publication-acl-test.XXXXXX")"
    acl_parent="$(cd "$acl_parent" && pwd -P)"
    /bin/chmod 0700 "$acl_parent"
    acl_entry="user:$(/usr/bin/id -un) allow list,search,readattr,readextattr,readsecurity,file_inherit,directory_inherit"
    /bin/chmod +a "$acl_entry" "$acl_parent"
    acl_parent_mode="$(mode_of "$acl_parent")"
    acl_parent_before="$(acl_snapshot "$acl_parent")"

    create_staging "$acl_parent" "acl"
    acl_staging="$STAGING_DIR"
    has_acl "$acl_staging" || fail "ACL fixture did not inherit an ACL"
    acl_identity="$(staging_identity "$acl_parent" "$acl_staging")"
    seal_staging "$acl_parent" "$acl_staging" "$acl_identity"
    acl_destination="$acl_parent/darkbloom-pinned-lume"
    "$PYTHON" "$PUBLICATION_HELPER" \
        publish \
        "$acl_parent" \
        "$acl_staging" \
        "$acl_destination" \
        "$acl_identity"
    "$PYTHON" "$PUBLICATION_HELPER" \
        verify \
        "$acl_parent" \
        "$acl_destination" \
        "$acl_identity"
    [[ "$(mode_of "$acl_parent")" == "$acl_parent_mode" ]] \
        || fail "ACL-bearing parent mode changed during publication"
    [[ "$(acl_snapshot "$acl_parent")" == "$acl_parent_before" ]] \
        || fail "caller-owned parent ACL changed during publication"

    create_staging "$acl_parent" "acl-cleanup"
    acl_cleanup_staging="$STAGING_DIR"
    acl_cleanup_identity="$(staging_identity "$acl_parent" "$acl_cleanup_staging")"
    seal_staging "$acl_parent" "$acl_cleanup_staging" "$acl_cleanup_identity"
    /bin/chmod +a "user:$(/usr/bin/id -un) allow readattr,readextattr,readsecurity" \
        "$acl_cleanup_staging"
    has_acl "$acl_cleanup_staging" || fail "cleanup ACL fixture has no ACL"
    DARKBLOOM_LUME_PYTHON="$PYTHON" \
        /bin/bash "$CLEANUP_HELPER" \
        "$acl_parent" \
        "$acl_cleanup_staging" \
        "$acl_cleanup_identity"
    [[ "$(mode_of "$acl_parent")" == "$acl_parent_mode" ]] \
        || fail "ACL-bearing parent mode changed during cleanup"
    [[ "$(acl_snapshot "$acl_parent")" == "$acl_parent_before" ]] \
        || fail "caller-owned parent ACL changed during cleanup"

    /bin/chmod -RN "$acl_parent"
    /bin/chmod -R u+rwX "$acl_parent"
    /bin/rm -rf -- "$acl_parent"
    pass "acl-isolation"
else
    echo "lume_publication_contract_skip=acl-isolation:requires-macos"
fi

if [[ "$TEST_COUNT" -lt 6 ]]; then
    fail "publication contract executed only $TEST_COUNT tests"
fi
echo "lume_publication_contract_tests=$TEST_COUNT"
