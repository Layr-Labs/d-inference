#!/bin/bash
# Foundation/CryptoKit only: no MLX, model, GPU, network, or live provider state.
set -euo pipefail
task_package="$(cd "$(dirname "$0")/../.." && pwd)"
source "$task_package/Tests/Support/check-phases.sh"
check_build_directory task_build "${TMPDIR:-/tmp}/cluster-still-images.XXXXXX"
compile_checks() {
  task_flags=(-swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0" -module-cache-path "$task_build/cache")
  xcrun swiftc -j 2 "${task_flags[@]}" -emit-library -emit-module -module-name DarkbloomClusterProtocol \
    -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
    -Xlinker -install_name -Xlinker @rpath/libDarkbloomClusterProtocol.dylib \
    "$task_package"/Sources/DarkbloomClusterProtocol/*.swift -o "$task_build/libDarkbloomClusterProtocol.dylib"
  xcrun swiftc -j 2 "${task_flags[@]}" -parse-as-library -I "$task_build" -L "$task_build" \
    -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker "$task_build" \
    "$task_package/Tests/StillImageChecks/Main.swift" -o "$task_build/check"
}
check_phases compile_checks
"$task_build/check"
