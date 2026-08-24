#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$PACKAGE_DIR/ThirdParty/lume.lock.json"
REPOSITORY="$(/usr/bin/plutil -extract repository raw -o - "$LOCK_FILE")"
COMMIT="$(/usr/bin/plutil -extract commit raw -o - "$LOCK_FILE")"
SOURCE_PATH="$(/usr/bin/plutil -extract path raw -o - "$LOCK_FILE")"
EXPECTED_VERSION="$(/usr/bin/plutil -extract version raw -o - "$LOCK_FILE")"
PYTHON="$(command -v python3)"
PUBLICATION_HELPER="$SCRIPT_DIR/lume-runtime-publication.py"
RUN_TESTS="${DARKBLOOM_LUME_RUN_TESTS:-0}"
PATCH_RELATIVE_PATHS=()
EXPECTED_PATCH_SHA256S=()
while IFS=$'\t' read -r patch_path patch_sha256; do
    PATCH_RELATIVE_PATHS+=("$patch_path")
    EXPECTED_PATCH_SHA256S+=("$patch_sha256")
done < <("$PYTHON" - "$LOCK_FILE" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    patches = json.load(source).get("patches")
if not isinstance(patches, list) or not patches:
    raise SystemExit("Lume pin must contain at least one patch")

seen = set()
for patch in patches:
    if not isinstance(patch, dict):
        raise SystemExit("invalid Lume patch record")
    path = patch.get("path")
    digest = patch.get("sha256")
    if not isinstance(path, str) or not re.fullmatch(
        r"ThirdParty/lume-patches/[0-9]{4}-[a-z0-9-]+[.]patch",
        path,
    ):
        raise SystemExit("invalid Lume patch path")
    if path in seen:
        raise SystemExit("duplicate Lume patch path")
    if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise SystemExit("invalid Lume patch digest")
    seen.add(path)
    print(f"{path}\t{digest}")
PY
)
CODESIGN_IDENTITY="${DARKBLOOM_LUME_CODESIGN_IDENTITY:--}"
PRODUCTION_CODESIGN_IDENTITY="Developer ID Application: Eigen Labs, Inc. (SLDQ2GJ6TL)"
PRODUCTION_REQUIREMENT='anchor apple generic and identifier "io.darkbloom.sandbox.lume" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
PROVENANCE_SIGNING_IDENTIFIER="io.darkbloom.sandbox.lume.provenance"
PRODUCTION_PROVENANCE_REQUIREMENT='anchor apple generic and identifier "io.darkbloom.sandbox.lume.provenance" and certificate leaf[subject.OU] = "SLDQ2GJ6TL"'
CHECKOUT="${DARKBLOOM_LUME_CHECKOUT:-$PACKAGE_DIR/../.external/cua-lume-${COMMIT:0:12}}"
INSTALL_DIR="${1:-$PACKAGE_DIR/.tools/lume-${COMMIT:0:12}/bin}"
BUILD_ROOT=""
INSTALL_PARENT=""
STAGING_DIR=""
STAGING_ID=""
PUBLICATION_ATTEMPTED=0
PUBLISHED=0

remove_staging_tree() {
    /bin/bash "$SCRIPT_DIR/remove-sealed-lume-staging.sh" \
        "$INSTALL_PARENT" \
        "$1" \
        "$STAGING_ID"
}

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    cleanup_failed=0
    if [[ -n "$BUILD_ROOT" ]]; then
        rm -rf "$BUILD_ROOT" || cleanup_failed=1
    fi
    if [[ -n "$STAGING_DIR" ]]; then
        if [[ -e "$STAGING_DIR" || -L "$STAGING_DIR" ]]; then
            remove_staging_tree "$STAGING_DIR" || cleanup_failed=1
        elif [[ "$PUBLICATION_ATTEMPTED" == "1" ]] \
            && [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
            echo "Lume publication outcome is ambiguous; destination retained: $INSTALL_DIR" >&2
            cleanup_failed=1
        elif [[ "$PUBLICATION_ATTEMPTED" == "1" ]]; then
            echo "Lume publication outcome is ambiguous; neither staging nor destination exists" >&2
            cleanup_failed=1
        fi
    fi
    if [[ "$PUBLISHED" == "1" && "$status" -ne 0 ]]; then
        echo "post-publication validation failed; destination retained: $INSTALL_DIR" >&2
    fi
    if [[ "$status" -eq 0 && "$cleanup_failed" -ne 0 ]]; then
        status=1
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ ! "$COMMIT" =~ ^[0-9a-f]{40}$ ]] \
    || [[ "$SOURCE_PATH" != "libs/lume" ]] \
    || [[ "${#PATCH_RELATIVE_PATHS[@]}" -eq 0 ]] \
    || [[ "${#PATCH_RELATIVE_PATHS[@]}" -ne "${#EXPECTED_PATCH_SHA256S[@]}" ]]; then
    echo "invalid Lume source pin" >&2
    exit 1
fi
if [[ "$CODESIGN_IDENTITY" != "-" ]] \
    && [[ "$CODESIGN_IDENTITY" != "$PRODUCTION_CODESIGN_IDENTITY" ]]; then
    echo "refusing unexpected Lume code-signing identity" >&2
    exit 1
fi
if [[ "$RUN_TESTS" != "0" ]] && [[ "$RUN_TESTS" != "1" ]]; then
    echo "DARKBLOOM_LUME_RUN_TESTS must be 0 or 1" >&2
    exit 1
fi
for index in "${!PATCH_RELATIVE_PATHS[@]}"; do
    patch_file="$PACKAGE_DIR/${PATCH_RELATIVE_PATHS[$index]}"
    if [[ ! -f "$patch_file" ]]; then
        echo "required Lume hardening patch is missing: $patch_file" >&2
        exit 1
    fi
    actual_patch_sha256="$(/usr/bin/shasum -a 256 "$patch_file" | /usr/bin/awk '{print $1}')"
    if [[ "$actual_patch_sha256" != "${EXPECTED_PATCH_SHA256S[$index]}" ]]; then
        echo "Lume hardening patch digest mismatch: ${PATCH_RELATIVE_PATHS[$index]}" >&2
        exit 1
    fi
done

if [[ -e "$CHECKOUT" ]] && [[ ! -d "$CHECKOUT/.git" ]]; then
    echo "refusing non-git Lume checkout path: $CHECKOUT" >&2
    exit 1
fi
if [[ ! -e "$CHECKOUT" ]]; then
    mkdir -p "$(dirname "$CHECKOUT")"
    git clone --filter=blob:none --no-checkout "$REPOSITORY" "$CHECKOUT"
fi

ACTUAL_REMOTE="$(git -C "$CHECKOUT" remote get-url origin)"
if [[ "$ACTUAL_REMOTE" != "$REPOSITORY" ]]; then
    echo "refusing checkout with unexpected origin: $ACTUAL_REMOTE" >&2
    exit 1
fi

git -C "$CHECKOUT" fetch --depth=1 origin "$COMMIT"
ACTUAL_COMMIT="$(git -C "$CHECKOUT" rev-parse "$COMMIT^{commit}")"
if [[ "$ACTUAL_COMMIT" != "$COMMIT" ]]; then
    echo "Lume checkout mismatch: expected $COMMIT, got $ACTUAL_COMMIT" >&2
    exit 1
fi

if [[ "$INSTALL_DIR" != /* ]]; then
    echo "Lume install directory must be absolute: $INSTALL_DIR" >&2
    exit 1
fi
if [[ -e "$INSTALL_DIR" || -L "$INSTALL_DIR" ]]; then
    echo "refusing to overwrite existing Lume install path: $INSTALL_DIR" >&2
    exit 1
fi
INSTALL_PARENT="$(dirname "$INSTALL_DIR")"
mkdir -p "$INSTALL_PARENT"
INSTALL_PARENT="$(cd "$INSTALL_PARENT" && pwd -P)"
INSTALL_DIR="$INSTALL_PARENT/$(basename "$INSTALL_DIR")"
"$PYTHON" "$PUBLICATION_HELPER" require-absent "$INSTALL_PARENT" "$INSTALL_DIR"
STAGING_DIR="$(mktemp -d "$INSTALL_PARENT/.darkbloom-lume-install.XXXXXX")"
STAGING_ID="$(
    "$PYTHON" "$PUBLICATION_HELPER" \
        initialize-staging \
        "$INSTALL_PARENT" \
        "$STAGING_DIR"
)"

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-lume-build.XXXXXX")"
git -C "$CHECKOUT" archive "$COMMIT" "$SOURCE_PATH" \
    | /usr/bin/tar -x -C "$BUILD_ROOT"
for patch_path in "${PATCH_RELATIVE_PATHS[@]}"; do
    /usr/bin/patch \
        --batch \
        --forward \
        -d "$BUILD_ROOT" \
        -p1 \
        < "$PACKAGE_DIR/$patch_path"
done

SOURCE_ROOT="$BUILD_ROOT/$SOURCE_PATH"
if [[ "$RUN_TESTS" == "1" ]]; then
    /bin/bash "$PACKAGE_DIR/Scripts/run-pinned-lume-tests.sh" "$SOURCE_ROOT"
fi
(
    cd "$SOURCE_ROOT"
    LUME_TELEMETRY_ENABLED=false swift build -c release --product lume
)
BUILD_OUTPUT="$SOURCE_ROOT/.build/release"
BUILT_EXECUTABLE="$BUILD_OUTPUT/lume"
RESOURCE_BUNDLE="$BUILD_OUTPUT/lume_lume.bundle"
if [[ ! -x "$BUILT_EXECUTABLE" ]] || [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "Lume build did not produce its executable and resource bundle" >&2
    exit 1
fi

/usr/bin/xattr -c "$BUILT_EXECUTABLE" 2>/dev/null || true
CODESIGN_ARGUMENTS=(
    --force
    --identifier io.darkbloom.sandbox.lume
    --entitlements "$SOURCE_ROOT/resources/lume.local.entitlements"
    --sign "$CODESIGN_IDENTITY"
)
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    CODESIGN_ARGUMENTS+=(--options runtime --timestamp)
fi
/usr/bin/codesign "${CODESIGN_ARGUMENTS[@]}" "$BUILT_EXECUTABLE"
/usr/bin/codesign --verify --strict "$BUILT_EXECUTABLE"
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    /usr/bin/codesign \
        --verify \
        --strict \
        "-R=$PRODUCTION_REQUIREMENT" \
        "$BUILT_EXECUTABLE"
fi

ACTUAL_VERSION="$(
    LUME_TELEMETRY_ENABLED=false \
        LUME_LOG_LEVEL=error \
        "$BUILT_EXECUTABLE" --version
)"
if [[ "$ACTUAL_VERSION" != "$EXPECTED_VERSION" ]]; then
    echo "Lume version mismatch: expected $EXPECTED_VERSION, got $ACTUAL_VERSION" >&2
    exit 1
fi

/usr/bin/install -m 0555 "$BUILT_EXECUTABLE" "$STAGING_DIR/lume"
/bin/cp -R "$RESOURCE_BUNDLE" "$STAGING_DIR/lume_lume.bundle"

BINARY_SHA256="$(/usr/bin/shasum -a 256 "$STAGING_DIR/lume" | /usr/bin/awk '{print $1}')"
PROVENANCE_FILE="$STAGING_DIR/lume.provenance.json"
"$PYTHON" - \
    "$STAGING_DIR" \
    "$PROVENANCE_FILE" \
    "$REPOSITORY" \
    "$COMMIT" \
    "$SOURCE_PATH" \
    "$EXPECTED_VERSION" \
    "$LOCK_FILE" <<'PY'
import hashlib
import json
import os
import stat
import sys

(
    install_dir,
    destination,
    repository,
    commit,
    source_path,
    version,
    lock_file,
) = sys.argv[1:]
with open(lock_file, encoding="utf-8") as source:
    patch_records = json.load(source)["patches"]
patches = {
    record["path"]: record["sha256"]
    for record in patch_records
}
directories = []
files = {}
for root, names, entries in os.walk(install_dir, followlinks=False):
    names.sort()
    entries.sort()
    for name in names:
        path = os.path.join(root, name)
        relative = os.path.relpath(path, install_dir)
        metadata = os.lstat(path)
        if not stat.S_ISDIR(metadata.st_mode):
            raise SystemExit(f"unsupported Lume runtime directory: {relative}")
        directories.append(relative)
    for name in entries:
        path = os.path.join(root, name)
        relative = os.path.relpath(path, install_dir)
        if relative == "lume.provenance.json":
            continue
        metadata = os.lstat(path)
        if not stat.S_ISREG(metadata.st_mode):
            raise SystemExit(f"unsupported Lume runtime entry: {relative}")
        digest = hashlib.sha256()
        with open(path, "rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        files[relative] = digest.hexdigest()

if "lume" not in files or "lume_lume.bundle" not in directories:
    raise SystemExit("Lume runtime tree is incomplete")

with open(destination, "x", encoding="utf-8") as output:
    json.dump(
        {
            "schema_version": 3,
            "repository": repository,
            "commit": commit,
            "source_path": source_path,
            "version": version,
            "patches": patches,
            "directories": sorted(directories),
            "files": files,
        },
        output,
        indent=2,
        sort_keys=True,
    )
    output.write("\n")
PY

PROVENANCE_CODESIGN_ARGUMENTS=(
    --force
    --identifier "$PROVENANCE_SIGNING_IDENTIFIER"
    --sign "$CODESIGN_IDENTITY"
)
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    PROVENANCE_CODESIGN_ARGUMENTS+=(--timestamp)
fi
/usr/bin/codesign "${PROVENANCE_CODESIGN_ARGUMENTS[@]}" "$PROVENANCE_FILE"

"$PYTHON" "$PUBLICATION_HELPER" \
    seal-staging \
    "$INSTALL_PARENT" \
    "$STAGING_DIR" \
    "$STAGING_ID"

# Some Darwin filesystems reject renaming a write-disabled directory. Keep the
# private staging envelope at 0700 until the exclusive namespace operation,
# then the helper seals the published root through its already-open descriptor.
PUBLICATION_ATTEMPTED=1
"$PYTHON" "$PUBLICATION_HELPER" \
    publish \
    "$INSTALL_PARENT" \
    "$STAGING_DIR" \
    "$INSTALL_DIR" \
    "$STAGING_ID"
PUBLISHED=1
STAGING_DIR=""
PROVENANCE_FILE="$INSTALL_DIR/lume.provenance.json"

"$PYTHON" "$PUBLICATION_HELPER" \
    verify \
    "$INSTALL_PARENT" \
    "$INSTALL_DIR" \
    "$STAGING_ID"
/usr/bin/codesign --verify --strict "$INSTALL_DIR/lume"
/usr/bin/codesign --verify --strict "$PROVENANCE_FILE"
if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
    /usr/bin/codesign \
        --verify \
        --strict \
        "-R=$PRODUCTION_REQUIREMENT" \
        "$INSTALL_DIR/lume"
    /usr/bin/codesign \
        --verify \
        --strict \
        "-R=$PRODUCTION_PROVENANCE_REQUIREMENT" \
        "$PROVENANCE_FILE"
fi

if ! LUME_TELEMETRY_ENABLED=false \
    LUME_LOG_LEVEL=error \
    "$INSTALL_DIR/lume" --version >/dev/null; then
    echo "hardened Lume runtime failed its launch check" >&2
    exit 1
fi

"$PYTHON" "$PUBLICATION_HELPER" \
    verify \
    "$INSTALL_PARENT" \
    "$INSTALL_DIR" \
    "$STAGING_ID"

echo "lume_commit=$ACTUAL_COMMIT"
echo "lume_version=$ACTUAL_VERSION"
echo "lume_sha256=$BINARY_SHA256"
echo "lume_provenance=$PROVENANCE_FILE"
