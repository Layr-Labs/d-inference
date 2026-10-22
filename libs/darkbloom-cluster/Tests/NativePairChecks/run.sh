#!/bin/bash
# Focused CPU check: compiles the actual DarkbloomClusterProtocol module plus
# the provider-swift native-pair public control mirror (NativePairMessages,
# ProviderExecutionRole) with Swift 6 and warnings as errors, then runs the
# mirrored contract vectors. No MLX, no network, no coordinator, no model.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
repo_root="$(cd "$task_root/../.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/native-pair-mirror.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0" \
  -emit-library -emit-module -module-name DarkbloomClusterProtocol \
  -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
  "$task_root"/Sources/DarkbloomClusterProtocol/*.swift -o "$task_build/libDarkbloomClusterProtocol.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0" \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol \
  -Xlinker -rpath -Xlinker "$task_build" \
  -module-name NativePairMirror \
  "$repo_root/provider-swift/Sources/ProviderCore/Protocol/NativePairMessages.swift" \
  "$repo_root/provider-swift/Sources/ProviderCore/Protocol/ProviderExecutionRole.swift" \
  "$task_root/Tests/NativePairChecks/main.swift" \
  -o "$task_build/check"
"$task_build/check"
