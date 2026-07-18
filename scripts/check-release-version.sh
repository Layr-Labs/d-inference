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

PROVIDER_VERSION=$(read_version \
    "$ROOT/provider-swift/Sources/ProviderCore/ProviderCore.swift" \
    'public static let version =')
COORDINATOR_VERSION=$(read_version \
    "$ROOT/coordinator/api/server.go" \
    'var LatestProviderVersion =')

SEMVER='^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$'
if [[ ! "$PROVIDER_VERSION" =~ $SEMVER ]]; then
    echo "release version check: invalid ProviderCore.version: $PROVIDER_VERSION" >&2
    exit 1
fi
if [ "$PROVIDER_VERSION" != "$COORDINATOR_VERSION" ]; then
    echo "release version check: provider=$PROVIDER_VERSION coordinator=$COORDINATOR_VERSION" >&2
    exit 1
fi
if [ -n "$EXPECTED" ]; then
    EXPECTED=${EXPECTED#v}
    if [ "$PROVIDER_VERSION" != "$EXPECTED" ]; then
        echo "release version check: source=$PROVIDER_VERSION requested=$EXPECTED" >&2
        exit 1
    fi
fi
if [ -n "$REPORTED" ]; then
    case "$REPORTED" in
        "$PROVIDER_VERSION"|"darkbloom $PROVIDER_VERSION") ;;
        *)
            echo "release version check: binary reported '$REPORTED', expected '$PROVIDER_VERSION'" >&2
            exit 1
            ;;
    esac
fi

echo "release version integrity: $PROVIDER_VERSION"
