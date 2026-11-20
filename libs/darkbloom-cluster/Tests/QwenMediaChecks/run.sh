#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$task_root/Tests/Support/check-phases.sh"
check_build_directory task_build "${TMPDIR:-/tmp}/cluster-qwen-media.XXXXXX"
compile_checks() {
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0" \
    -emit-library -emit-module -module-name DarkbloomClusterProtocol \
    -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
    "$task_root"/Sources/DarkbloomClusterProtocol/*.swift -o "$task_build/libDarkbloomClusterProtocol.dylib"
  xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library -target "$(uname -m)-apple-macos14.0" \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Tests/QwenMediaChecks/QwenMediaChecks.swift" -o "$task_build/check"
}
check_phases compile_checks
"$task_build/check"
