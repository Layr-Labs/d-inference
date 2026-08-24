#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${DARKBLOOM_LUME_PYTHON:-$(command -v python3)}"
PUBLICATION_HELPER="$SCRIPT_DIR/lume-runtime-publication.py"
QUARANTINE_HELPER="$SCRIPT_DIR/quarantine-sealed-lume-staging.sh"
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

path_identity() {
    "$PYTHON" - "$1" <<'PY'
import os
import sys

metadata = os.lstat(sys.argv[1])
print(f"{metadata.st_dev}:{metadata.st_ino}")
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

quarantine_staging() {
    DARKBLOOM_LUME_PYTHON="$PYTHON" \
        /bin/bash "$QUARANTINE_HELPER" "$1" "$2" "$3"
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
replacement_quarantine="$(
    quarantine_staging \
        "$TEST_ROOT" \
        "$replacement_staging" \
        "$replacement_identity"
)"
[[ "$replacement_quarantine" == "$TEST_ROOT"/.darkbloom-lume-quarantine.* ]] \
    || fail "failed publication did not report its quarantine path"
[[ ! -e "$replacement_staging" && ! -L "$replacement_staging" ]] \
    || fail "failed publication left the expected staging name bound"
[[ "$(path_identity "$replacement_quarantine")" == "$replacement_identity" ]] \
    || fail "failed publication quarantined the wrong staging inode"
[[ "$(<"$replacement_quarantine/lume_lume.bundle/nested/resource.txt")" == "replacement" ]] \
    || fail "failed publication did not retain nested staging content"
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
hardlink_quarantine="$(
    quarantine_staging \
        "$TEST_ROOT" \
        "$hardlink_staging" \
        "$hardlink_identity"
)"
[[ "$(path_identity "$hardlink_quarantine")" == "$hardlink_identity" ]] \
    || fail "hardlink rejection quarantined the wrong staging inode"
[[ "$(<"$hardlink_quarantine/0-hardlink")" == "external-content" ]] \
    || fail "quarantine changed the rejected hardlink content"
[[ "$(<"$hardlink_quarantine/lume_lume.bundle/nested/resource.txt")" == "hardlink" ]] \
    || fail "quarantine discarded nested hardlink-rejection content"
/bin/rm -f -- "$hardlink_external"
[[ "$(<"$hardlink_quarantine/0-hardlink")" == "external-content" ]] \
    || fail "offline external-link removal changed quarantined content"
pass "hardlink-rejection"

# An error after the atomic rename leaves a private, writable, therefore
# unusable destination for inspection. Quarantine of the vanished staging name
# is a no-op and must not infer authority to rename or remove that destination.
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
missing_quarantine_output="$(
    quarantine_staging \
        "$TEST_ROOT" \
        "$ambiguous_staging" \
        "$ambiguous_identity"
)"
[[ -z "$missing_quarantine_output" ]] \
    || fail "missing committed staging unexpectedly reported a quarantine"
[[ -d "$ambiguous_destination" ]] \
    || fail "staging quarantine changed an ambiguous destination"
[[ "$(path_identity "$ambiguous_destination")" == "$ambiguous_identity" ]] \
    || fail "missing staging quarantine targeted the committed destination"
pass "post-publication-retention"

# Quarantine atomically moves the exact staging inode, preserves every
# descendant, reports the reserved path, and never edits the caller-owned parent.
parent_mode_before="$(mode_of "$TEST_ROOT")"
create_staging "$TEST_ROOT" "quarantine"
quarantine_staging_path="$STAGING_DIR"
quarantine_identity="$STAGING_ID"
seal_staging "$TEST_ROOT" "$quarantine_staging_path" "$quarantine_identity"
quarantine_path="$(
    quarantine_staging \
        "$TEST_ROOT" \
        "$quarantine_staging_path" \
        "$quarantine_identity"
)"
[[ "$quarantine_path" == "$TEST_ROOT"/.darkbloom-lume-quarantine.* ]] \
    || fail "ordinary failure did not report a reserved quarantine path"
[[ ! -e "$quarantine_staging_path" && ! -L "$quarantine_staging_path" ]] \
    || fail "quarantine left the exact staging inode at its original name"
[[ "$(path_identity "$quarantine_path")" == "$quarantine_identity" ]] \
    || fail "quarantine moved an inode other than the open expected staging inode"
[[ "$(<"$quarantine_path/lume_lume.bundle/nested/resource.txt")" == "quarantine" ]] \
    || fail "quarantine did not preserve nested staging content"
[[ "$(mode_of "$TEST_ROOT")" == "$parent_mode_before" ]] \
    || fail "staging quarantine changed the parent mode"

# Swap the expected root after it is open but immediately before the atomic
# no-replace rename. The replacement is moved to quarantine, verification must
# report ambiguity, and both complete trees must remain retained.
create_staging "$TEST_ROOT" "quarantine-race"
quarantine_race_staging="$STAGING_DIR"
quarantine_race_identity="$STAGING_ID"
seal_staging "$TEST_ROOT" "$quarantine_race_staging" "$quarantine_race_identity"
quarantine_race_moved="$TEST_ROOT/.darkbloom-lume-install.moved"
quarantine_race_report="$(
    "$PYTHON" - \
        "$PUBLICATION_HELPER" \
        "$TEST_ROOT" \
        "$quarantine_race_staging" \
        "$quarantine_race_identity" \
        "$quarantine_race_moved" <<'PY'
import argparse
import importlib.util
import os
import sys

helper, parent, staging, identity, moved = sys.argv[1:]
spec = importlib.util.spec_from_file_location("lume_runtime_publication", helper)
publication = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = publication
spec.loader.exec_module(publication)
atomic_rename = publication.exclusive_rename
replacement_identity = None
quarantine_path = None

def swap_before_atomic_rename(parent_fd, source_name, destination_name):
    global quarantine_path, replacement_identity
    if source_name != os.path.basename(staging):
        raise SystemExit("quarantine race hook received the wrong source")
    if not destination_name.startswith(publication.QUARANTINE_PREFIX):
        raise SystemExit("quarantine race hook received a non-reserved destination")
    os.rename(staging, moved)
    os.mkdir(staging, 0o700)
    os.makedirs(os.path.join(staging, "replacement", "nested"))
    with open(
        os.path.join(staging, "replacement", "nested", "marker.txt"),
        "x",
        encoding="utf-8",
    ) as marker:
        marker.write("replacement-retained\n")
    replacement_identity = publication.FileIdentity.from_stat(os.lstat(staging))
    quarantine_path = os.path.join(parent, destination_name)
    atomic_rename(parent_fd, source_name, destination_name)

publication.exclusive_rename = swap_before_atomic_rename
arguments = argparse.Namespace(parent=parent, tree=staging, identity=identity)
try:
    publication.command_quarantine(arguments)
except publication.PublicationError as error:
    report = str(error)
    if "namespace became ambiguous" not in report or "no entry was deleted" not in report:
        raise
else:
    raise SystemExit("quarantine accepted a replaced staging namespace")

if str(publication.FileIdentity.from_stat(os.lstat(moved))) != identity:
    raise SystemExit("quarantine lost the expected staging inode")
if quarantine_path is None or replacement_identity is None:
    raise SystemExit("quarantine race hook did not run")
if publication.FileIdentity.from_stat(os.lstat(quarantine_path)) != replacement_identity:
    raise SystemExit("quarantine lost the replacement staging inode")
with open(
    os.path.join(moved, "lume_lume.bundle", "nested", "resource.txt"),
    encoding="utf-8",
) as expected_marker:
    if expected_marker.read().strip() != "quarantine-race":
        raise SystemExit("quarantine changed expected nested content")
with open(
    os.path.join(quarantine_path, "replacement", "nested", "marker.txt"),
    encoding="utf-8",
) as replacement_marker:
    if replacement_marker.read().strip() != "replacement-retained":
        raise SystemExit("quarantine changed replacement nested content")
if os.path.lexists(staging):
    raise SystemExit("atomic rename did not consume the replacement source name")
print(report)
PY
)"
[[ "$quarantine_race_report" == *"namespace became ambiguous"* ]] \
    || fail "quarantine replacement ambiguity was not reported"
pass "quarantine-replacement"

symlink_target="$TEST_ROOT/symlink-target"
/bin/mkdir "$symlink_target"
printf '%s\n' "keep" > "$symlink_target/marker"
symlink_staging="$TEST_ROOT/.darkbloom-lume-install.symlink"
/bin/ln -s "$symlink_target" "$symlink_staging"
if "$PYTHON" "$PUBLICATION_HELPER" \
    identity "$TEST_ROOT" "$symlink_staging" >/dev/null 2>&1; then
    fail "identity accepted a staging symlink"
fi
if quarantine_staging \
    "$TEST_ROOT" \
    "$symlink_staging" \
    "$quarantine_identity" >/dev/null 2>&1; then
    fail "quarantine accepted a staging symlink"
fi
[[ "$(<"$symlink_target/marker")" == "keep" ]] \
    || fail "unsafe quarantine traversed a staging symlink"
pass "identity-bound-quarantine"

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

    EXPECT_STAGING_ACL=1 create_staging "$acl_parent" "acl-quarantine"
    acl_quarantine_staging="$STAGING_DIR"
    acl_quarantine_identity="$STAGING_ID"
    seal_staging "$acl_parent" "$acl_quarantine_staging" "$acl_quarantine_identity"
    /bin/chmod +a "user:$(/usr/bin/id -un) allow readattr,readextattr,readsecurity" \
        "$acl_quarantine_staging"
    has_acl "$acl_quarantine_staging" || fail "quarantine ACL fixture has no ACL"
    acl_quarantine_path="$(
        quarantine_staging \
            "$acl_parent" \
            "$acl_quarantine_staging" \
            "$acl_quarantine_identity"
    )"
    [[ "$(path_identity "$acl_quarantine_path")" == "$acl_quarantine_identity" ]] \
        || fail "ACL-bearing staging quarantine moved the wrong inode"
    has_acl "$acl_quarantine_path" \
        || fail "staging quarantine did not retain the root ACL"
    [[ "$(mode_of "$acl_parent")" == "$acl_parent_mode" ]] \
        || fail "ACL-bearing parent mode changed during quarantine"
    [[ "$(acl_snapshot "$acl_parent")" == "$acl_parent_before" ]] \
        || fail "caller-owned parent ACL changed during quarantine"

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
    descendant_acl_quarantine="$(
        quarantine_staging \
            "$acl_parent" \
            "$descendant_acl_staging" \
            "$descendant_acl_identity"
    )"
    quarantined_descendant_acl_file="$descendant_acl_quarantine/lume_lume.bundle/nested/resource.txt"
    [[ "$(mode_of "$quarantined_descendant_acl_file")" == "$descendant_mode_before" ]] \
        || fail "quarantine changed the rejected descendant mode"
    [[ "$(<"$quarantined_descendant_acl_file")" == "$descendant_content_before" ]] \
        || fail "quarantine changed the rejected descendant content"
    [[ "$(acl_snapshot "$quarantined_descendant_acl_file")" == "$descendant_acl_before" ]] \
        || fail "quarantine changed the rejected descendant ACL"
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
