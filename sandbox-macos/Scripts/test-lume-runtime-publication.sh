#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${DARKBLOOM_LUME_PYTHON:-$(command -v python3)}"
PUBLICATION_HELPER="$SCRIPT_DIR/lume-runtime-publication.py"
CLEANUP_HELPER="$SCRIPT_DIR/remove-sealed-lume-staging.sh"
TEST_ROOT=""
TEST_COUNT=0
STAGING_DIR=""
STAGING_ID=""

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
    if [[ "${EXPECT_STAGING_ACL:-0}" == "1" ]]; then
        has_acl "$STAGING_DIR" || fail "staging root did not inherit the fixture ACL"
    fi
    STAGING_ID="$(
        "$PYTHON" "$PUBLICATION_HELPER" \
            initialize-staging \
            "$parent" \
            "$STAGING_DIR"
    )"
    if [[ "$(uname -s)" == "Darwin" ]] && has_acl "$STAGING_DIR"; then
        fail "initialized staging root retained an inherited ACL"
    fi
    /bin/mkdir -p "$STAGING_DIR/lume_lume.bundle/nested"
    printf '%s\n' \
        '#!/bin/bash' \
        "printf '%s\\n' '$version'" \
        > "$STAGING_DIR/lume"
    printf '%s\n' '{"schema_version":3}' > "$STAGING_DIR/lume.provenance.json"
    printf '%s\n' "$version" > "$STAGING_DIR/lume_lume.bundle/nested/resource.txt"
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
first_identity="$STAGING_ID"
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
replacement_identity="$STAGING_ID"
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

# Seal must reject a hardlinked file before changing that external inode.
create_staging "$TEST_ROOT" "hardlink"
hardlink_staging="$STAGING_DIR"
hardlink_identity="$STAGING_ID"
hardlink_external="$TEST_ROOT/hardlink-external"
printf '%s\n' "external-content" > "$hardlink_external"
/bin/chmod 0640 "$hardlink_external"
hardlink_acl_before=""
if [[ "$(uname -s)" == "Darwin" ]]; then
    /bin/chmod +a "user:$(/usr/bin/id -un) allow readattr,readextattr,readsecurity" \
        "$hardlink_external"
    hardlink_acl_before="$(acl_snapshot "$hardlink_external")"
fi
/bin/ln "$hardlink_external" "$hardlink_staging/0-hardlink"
if seal_staging "$TEST_ROOT" "$hardlink_staging" "$hardlink_identity" \
    >/dev/null 2>&1; then
    fail "seal accepted a hardlinked runtime file"
fi
[[ "$(mode_of "$hardlink_external")" == "0640" ]] \
    || fail "hardlink rejection changed the external inode mode"
[[ "$(<"$hardlink_external")" == "external-content" ]] \
    || fail "hardlink rejection changed the external inode content"
if [[ "$(uname -s)" == "Darwin" ]]; then
    [[ "$(acl_snapshot "$hardlink_external")" == "$hardlink_acl_before" ]] \
        || fail "hardlink rejection changed the external inode ACL"
fi
DARKBLOOM_LUME_PYTHON="$PYTHON" \
    /bin/bash "$CLEANUP_HELPER" \
    "$TEST_ROOT" \
    "$hardlink_staging" \
    "$hardlink_identity"
/bin/rm -f -- "$hardlink_external"
pass "hardlink-rejection"

# An error after the atomic rename leaves a private, writable, therefore
# unusable destination for inspection. Cleanup of the vanished staging name
# must not infer authority to remove that destination.
create_staging "$TEST_ROOT" "ambiguous"
ambiguous_staging="$STAGING_DIR"
ambiguous_identity="$STAGING_ID"
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
cleanup_identity="$STAGING_ID"
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

# Swap the emptied expected root out of the namespace immediately before the
# final binding check. Cleanup must report ambiguity and retain both inodes.
create_staging "$TEST_ROOT" "cleanup-race"
cleanup_race_staging="$STAGING_DIR"
cleanup_race_identity="$STAGING_ID"
seal_staging "$TEST_ROOT" "$cleanup_race_staging" "$cleanup_race_identity"
cleanup_race_moved="$TEST_ROOT/.darkbloom-lume-install.moved"
cleanup_race_report="$(
    "$PYTHON" - \
        "$PUBLICATION_HELPER" \
        "$TEST_ROOT" \
        "$cleanup_race_staging" \
        "$cleanup_race_identity" \
        "$cleanup_race_moved" <<'PY'
import argparse
import importlib.util
import os
import sys

helper, parent, staging, identity, moved = sys.argv[1:]
spec = importlib.util.spec_from_file_location("lume_runtime_publication", helper)
publication = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = publication
spec.loader.exec_module(publication)
remove_contents = publication.remove_tree_contents
replacement_identity = None

def swap_after_empty(descriptor):
    global replacement_identity
    publication.remove_tree_contents = remove_contents
    remove_contents(descriptor)
    os.rename(staging, moved)
    os.mkdir(staging, 0o700)
    replacement_identity = publication.FileIdentity.from_stat(os.lstat(staging))

publication.remove_tree_contents = swap_after_empty
arguments = argparse.Namespace(parent=parent, tree=staging, identity=identity)
try:
    publication.command_cleanup(arguments)
except publication.PublicationError as error:
    report = str(error)
    if "namespace became ambiguous" not in report:
        raise
else:
    raise SystemExit("cleanup accepted a replaced staging namespace")

if publication.FileIdentity.from_stat(os.lstat(staging)) != replacement_identity:
    raise SystemExit("cleanup deleted or replaced the empty replacement")
if str(publication.FileIdentity.from_stat(os.lstat(moved))) != identity:
    raise SystemExit("cleanup lost the expected staging inode")
if os.listdir(staging) or os.listdir(moved):
    raise SystemExit("cleanup race fixture roots are not empty")
print(report)
PY
)"
[[ "$cleanup_race_report" == *"namespace became ambiguous"* ]] \
    || fail "cleanup replacement ambiguity was not reported"
/bin/rmdir "$cleanup_race_staging" "$cleanup_race_moved"
pass "cleanup-replacement"

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

    EXPECT_STAGING_ACL=1 create_staging "$acl_parent" "acl"
    acl_staging="$STAGING_DIR"
    if has_acl "$acl_staging"; then
        fail "staging initialization did not clear the inherited root ACL"
    fi
    acl_identity="$STAGING_ID"
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

    EXPECT_STAGING_ACL=1 create_staging "$acl_parent" "acl-cleanup"
    acl_cleanup_staging="$STAGING_DIR"
    acl_cleanup_identity="$STAGING_ID"
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

    # ACL-bearing descendants are rejected in place, not recursively repaired.
    EXPECT_STAGING_ACL=1 create_staging "$acl_parent" "descendant-acl"
    descendant_acl_staging="$STAGING_DIR"
    descendant_acl_identity="$STAGING_ID"
    descendant_acl_file="$descendant_acl_staging/lume_lume.bundle/nested/resource.txt"
    descendant_content_before="$(<"$descendant_acl_file")"
    /bin/chmod +a "user:$(/usr/bin/id -un) allow readattr,readextattr,readsecurity" \
        "$descendant_acl_file"
    descendant_mode_before="$(mode_of "$descendant_acl_file")"
    descendant_acl_before="$(acl_snapshot "$descendant_acl_file")"
    if seal_staging \
        "$acl_parent" \
        "$descendant_acl_staging" \
        "$descendant_acl_identity" >/dev/null 2>&1; then
        fail "seal accepted an ACL-bearing descendant"
    fi
    [[ "$(mode_of "$descendant_acl_file")" == "$descendant_mode_before" ]] \
        || fail "ACL rejection changed the descendant mode"
    [[ "$(<"$descendant_acl_file")" == "$descendant_content_before" ]] \
        || fail "ACL rejection changed the descendant content"
    [[ "$(acl_snapshot "$descendant_acl_file")" == "$descendant_acl_before" ]] \
        || fail "ACL rejection changed the descendant ACL"
    [[ "$(mode_of "$acl_parent")" == "$acl_parent_mode" ]] \
        || fail "descendant ACL rejection changed the parent mode"
    [[ "$(acl_snapshot "$acl_parent")" == "$acl_parent_before" ]] \
        || fail "descendant ACL rejection changed the parent ACL"
    DARKBLOOM_LUME_PYTHON="$PYTHON" \
        /bin/bash "$CLEANUP_HELPER" \
        "$acl_parent" \
        "$descendant_acl_staging" \
        "$descendant_acl_identity"
    pass "descendant-acl-rejection"

    /bin/chmod -RN "$acl_parent"
    /bin/chmod -R u+rwX "$acl_parent"
    /bin/rm -rf -- "$acl_parent"
    pass "acl-isolation"
else
    echo "lume_publication_contract_skip=descendant-acl-rejection:requires-macos"
    echo "lume_publication_contract_skip=acl-isolation:requires-macos"
fi

if [[ "$(uname -s)" == "Darwin" ]]; then
    EXPECTED_TEST_COUNT=9
else
    EXPECTED_TEST_COUNT=7
fi
if [[ "$TEST_COUNT" -ne "$EXPECTED_TEST_COUNT" ]]; then
    fail "publication contract executed $TEST_COUNT tests; expected $EXPECTED_TEST_COUNT"
fi
echo "lume_publication_contract_tests=$TEST_COUNT"
