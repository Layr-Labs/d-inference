#!/bin/bash
set -euo pipefail
task_package="$(cd "$(dirname "$0")/../.." && pwd)"
task_fixtures="$task_package/Tests/CapabilityChecks"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-capability-protocol.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0" \
  -emit-library -emit-module -module-name DarkbloomClusterProtocol \
  -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
  "$task_package"/Sources/DarkbloomClusterProtocol/*.swift -o "$task_build/libDarkbloomClusterProtocol.dylib"
# The existing Protocol checks run in their own runner (Tests/ProtocolChecks/run.sh).
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker "$task_build" \
  "$task_fixtures/CapabilityProtocolCheck.swift" -o "$task_build/capability"
"$task_build/capability" "$task_fixtures/Fixtures/registered-qwen35-9b.capability.json"
