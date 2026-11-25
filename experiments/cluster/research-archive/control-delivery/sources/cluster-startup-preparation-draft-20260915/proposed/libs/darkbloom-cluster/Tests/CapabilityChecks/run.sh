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
for task_case in capability original startup; do
  task_source="$task_fixtures/CapabilityProtocolCheck.swift"
  if [[ "$task_case" == original ]]; then task_source="$task_package/Tests/ProtocolChecks/ClusterWorkerProtocolTests.swift"; fi
  if [[ "$task_case" == startup ]]; then task_source="$task_fixtures/StartupPreparationCheck.swift"; fi
  xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library -target "$(uname -m)-apple-macos14.0" \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker "$task_build" \
    "$task_source" -o "$task_build/$task_case"
done
"$task_build/capability" "$task_fixtures/Fixtures/registered-qwen35-9b.capability.json"
"$task_build/original"
"$task_build/startup" "$task_fixtures/Fixtures/registered-qwen35-9b.capability.json"
