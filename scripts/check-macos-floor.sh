#!/bin/bash
# Pin the macOS floor and the two metallib deployment targets across every file
# that hardcodes them.
#
# Each of these files independently believes it knows the floor, and nothing
# else connects them: the installers refuse to install below it, the workflow builds
# the baseline metallib at it and stamps LSMinimumSystemVersion with it, and
# PackagedMetallib.swift quotes it back to the user when MLX cannot start. The
# last time they disagreed — a metallib silently built for macOS 26.2 while the
# installer advertised macOS 14 — every Mac below 26.2 failed to install with a
# message about safe-R1 latching.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SWIFT="$ROOT/provider-swift/Sources/ProviderCore/Inference/PackagedMetallib.swift"
WORKFLOW="$ROOT/.github/workflows/release-swift.yml"
HELPER="$ROOT/scripts/fetch-metallib.sh"
INSTALLERS=(
    "$ROOT/scripts/install.sh"
    "$ROOT/coordinator/api/install.sh"
)
# Surfaces that quote the floor at a prospective provider before they ever run
# the installer. A stale number here is how someone ends up downloading a
# gigabyte and getting refused.
ADVERTISED=(
    "$ROOT/landing/index.html"
    "$ROOT/console-ui/src/app/providers/setup/page.tsx"
    "$ROOT/docs/provider/hardware-requirements.md"
    "$ROOT/docs/architecture/hardware-support.md"
)

fail() {
    echo "macOS floor check: $*" >&2
    exit 1
}

# Exactly-one-match extraction: a second definition anywhere would make the
# winner depend on file order, which is the drift this script exists to catch.
read_pin() {
    local file=$1
    local pattern=$2
    local separator=$3
    local value count
    # Swift wraps `let x =` onto the next line, so fold a trailing `=` into the
    # following line before matching.
    value=$(awk -F"$separator" -v pattern="$pattern" '
        {
            line = $0
            if (pending != "") { line = pending " " line; pending = "" }
            if (line ~ /=[ \t]*$/) { pending = line; next }
            $0 = line
            if ($0 ~ pattern) { print $2 }
        }' "$file")
    count=$(printf '%s\n' "$value" | awk 'NF { n++ } END { print n + 0 }')
    [ "$count" -eq 1 ] || fail "expected exactly one '$pattern' in $file (found $count)"
    printf '%s' "$value"
}

SWIFT_PRIMARY=$(read_pin "$SWIFT" 'let primaryDeploymentTarget =' '"')
SWIFT_BASELINE=$(read_pin "$SWIFT" 'let baselineDeploymentTarget =' '"')
SWIFT_BASELINE_PATH=$(read_pin "$SWIFT" 'let baselineBundleRelativePath =' '"')
SWIFT_MARKER_PATH=$(read_pin "$SWIFT" 'let baselineCapabilityRelativePath =' '"')

WORKFLOW_MIN=$(read_pin "$WORKFLOW" '^  MIN_MACOS:' "'")
WORKFLOW_PRIMARY=$(read_pin "$WORKFLOW" '^  MLX_METALLIB_DEPLOYMENT_TARGET:' "'")
WORKFLOW_BASELINE=$(read_pin "$WORKFLOW" '^  MLX_METALLIB_BASELINE_DEPLOYMENT_TARGET:' "'")
HELPER_NAX=$(read_pin "$HELPER" '^NAX_DEPLOYMENT_TARGET=' '"')

[ "$SWIFT_PRIMARY" = "$WORKFLOW_PRIMARY" ] \
    || fail "primary metallib target: swift=$SWIFT_PRIMARY workflow=$WORKFLOW_PRIMARY"
[ "$SWIFT_PRIMARY" = "$HELPER_NAX" ] \
    || fail "primary metallib target: swift=$SWIFT_PRIMARY fetch-metallib=$HELPER_NAX"
[ "$SWIFT_BASELINE" = "$WORKFLOW_BASELINE" ] \
    || fail "baseline metallib target: swift=$SWIFT_BASELINE workflow=$WORKFLOW_BASELINE"
# The floor IS the baseline target: below it the fallback stops loading too.
[ "$SWIFT_BASELINE" = "$WORKFLOW_MIN" ] \
    || fail "macOS floor: baseline target=$SWIFT_BASELINE workflow MIN_MACOS=$WORKFLOW_MIN"

FLOOR_MAJOR=${WORKFLOW_MIN%%.*}

# The Swift package's deployment target must not claim support the packaged
# kernels cannot deliver.
PACKAGE_SWIFT="$ROOT/provider-swift/Package.swift"
grep -Eq "platforms: \[\.macOS\(\.v${FLOOR_MAJOR}\)\]" "$PACKAGE_SWIFT" \
    || fail "$PACKAGE_SWIFT does not declare .macOS(.v${FLOOR_MAJOR})"

for installer in "${INSTALLERS[@]}"; do
    installer_min=$(read_pin "$installer" '^MIN_MACOS=' '"')
    [ "$installer_min" = "$WORKFLOW_MIN" ] \
        || fail "macOS floor: $installer=$installer_min workflow=$WORKFLOW_MIN"
    grep -Fq "Contents/MacOS/Resources/mlx.metallib" "$installer" \
        || fail "$installer does not reference the baseline metallib path"
    grep -Fq "darkbloom-runtime-capabilities/baseline-metallib-v1" "$installer" \
        || fail "$installer does not reference the baseline capability marker"
done

# "macOS 15" / "macOS 15.0+" both satisfy the pin; any OTHER major is drift.
for surface in "${ADVERTISED[@]}"; do
    grep -Eq "macOS ${FLOOR_MAJOR}(\.[0-9]+)?\+?([^0-9.]|$)" "$surface" \
        || fail "$surface does not advertise the macOS $WORKFLOW_MIN floor"
    stale=$(grep -Eon "macOS (1[0-4]|[0-9])(\.[0-9]+)?\+" "$surface" || true)
    [ -z "$stale" ] || fail "$surface still advertises a floor below $WORKFLOW_MIN: $stale"
done

# The Swift constants name bundle-relative paths; the workflow stages them and
# the installers verify them, all as literals.
grep -Fq "\"\$APP/$SWIFT_BASELINE_PATH\"" "$WORKFLOW" \
    || fail "release workflow does not stage $SWIFT_BASELINE_PATH"
grep -Fq "${SWIFT_MARKER_PATH#Contents/}" "$WORKFLOW" \
    || fail "release workflow does not stage $SWIFT_MARKER_PATH"

echo "macOS floor integrity: min=$WORKFLOW_MIN" \
    "primary metallib=$SWIFT_PRIMARY baseline metallib=$SWIFT_BASELINE"
