#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
EXPECTED=${1:-}
REPORTED=${2:-}

read_version() {
    local file=$1
    local pattern=$2
    local value
    value=$(awk -F'"' -v pattern="$pattern" '$0 ~ pattern { print $2 }' "$file")
    [ "$(printf '%s\n' "$value" | awk 'NF { count++ } END { print count + 0 }')" -eq 1 ] || {
        echo "release version check: expected exactly one version in $file" >&2
        exit 1
    }
    printf '%s' "$value"
}

# The provider owns this release; the coordinator belongs to the separate
# platform repository and does not define provider identity.
PROVIDER_VERSION=$(read_version \
    "$ROOT/provider-swift/Sources/ProviderCore/ProviderCore.swift" \
    'public static let version =')

SEMVER='^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'
if [[ ! "$PROVIDER_VERSION" =~ $SEMVER ]]; then
    echo "release version check: invalid ProviderCore.version: $PROVIDER_VERSION" >&2
    exit 1
fi
# A dev release is the source version plus -dev.<run number>; a staging release
# is the source version plus -staging.<run number>. The master dev lane uses
# -dev.N; the experimental dev-branch lane
# (.github/workflows/release-dev-branch.yml) uses -dev.branch.N so a branch
# build never collides with a master dev build. The release build stamps the
# full value into ProviderCore.version before compiling.
RELEASE_VERSION=$PROVIDER_VERSION
if [ -n "$EXPECTED" ]; then
    EXPECTED=${EXPECTED#v}
    if [ "$PROVIDER_VERSION" != "$EXPECTED" ] &&
        [[ ! "$EXPECTED" =~ ^"$PROVIDER_VERSION"-dev\.(branch\.)?[1-9][0-9]*$ ]] &&
        [[ ! "$EXPECTED" =~ ^"$PROVIDER_VERSION"-staging\.[1-9][0-9]*$ ]]; then
        echo "release version check: source=$PROVIDER_VERSION requested=$EXPECTED" >&2
        exit 1
    fi
    RELEASE_VERSION=$EXPECTED
fi
if [ -n "$REPORTED" ]; then
    case "$REPORTED" in
        "$RELEASE_VERSION"|"darkbloom $RELEASE_VERSION") ;;
        *)
            echo "release version check: binary reported '$REPORTED', expected '$RELEASE_VERSION'" >&2
            exit 1
            ;;
    esac
fi

echo "release version integrity: $RELEASE_VERSION"
