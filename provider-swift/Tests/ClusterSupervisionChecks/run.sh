#!/bin/bash
# Model-free checks of the cluster-member supervision policies (S18).
# Plain swiftc, no MLX/Metal/network/launchd; suitable for lane-light.sh.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
provider="$(cd "$here/../.." && pwd)"
sources="$provider/Sources/ProviderCore"
build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-supervision-checks.XXXXXXXX")"
trap 'rm -rf "$build"' EXIT
expected_offset=$(python3 -I -c '
h = 0xcbf29ce484222325
for b in b"cluster-1":
    h ^= b
    h = (h * 0x100000001b3) % (1 << 64)
print(h % 1800)')
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0" \
  -module-name ClusterSupervisionChecks \
  "$sources"/Service/ClusterSupervision/*.swift \
  "$sources/Inference/Distributed/Diagnostics/Link/ClusterLinkReadinessState.swift" \
  "$here/main.swift" -o "$build/checks"
EXPECTED_FNV_OFFSET="$expected_offset" "$build/checks"
