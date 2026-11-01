#!/bin/bash
# S24 observability: compiles the actual control modules (Swift 6, warnings as
# errors) and runs the model-free checks of the incident log, the failure
# classifier and guidance, the pair telemetry log, the request telemetry event
# of the worker protocol, and the follower status mirror over a real link
# control edge on loopback. No Thunderbolt interface, no peer Mac, no model:
# a pass here is not a hardware pass.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-observability.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_target="$(uname -m)-apple-macos14.0"
flags=(-swift-version 6 -warnings-as-errors -target "$task_target" -j 4)
build() {
  local module=$1; shift; local links=()
  for dependency in "$@"; do links+=(-l"$dependency"); done
  xcrun swiftc "${flags[@]}" -emit-library -emit-module -module-name "$module" \
    -emit-module-path "$task_build/$module.swiftmodule" -I "$task_build" -L "$task_build" ${links[@]+"${links[@]}"} \
    -Xlinker -rpath -Xlinker @executable_path -Xlinker -install_name -Xlinker "@rpath/lib$module.dylib" \
    "$task_root/Sources/$module"/*.swift -o "$task_build/lib$module.dylib"
}
build DarkbloomClusterBootstrap
build DarkbloomClusterProtocol
build DarkbloomClusterProcess DarkbloomClusterProtocol
build DarkbloomClusterSecurity DarkbloomClusterBootstrap
build DarkbloomClusterRemote DarkbloomClusterProtocol DarkbloomClusterProcess DarkbloomClusterBootstrap DarkbloomClusterSecurity
xcrun swiftc "${flags[@]}" -I "$task_build" -L "$task_build" -lDarkbloomClusterRemote -lDarkbloomClusterSecurity \
  -lDarkbloomClusterProtocol -lDarkbloomClusterProcess -Xlinker -rpath -Xlinker @executable_path \
  "$task_root/Tests/ObservabilityChecks/main.swift" -o "$task_build/observability-check"
"$task_build/observability-check" "$task_build/scratch"
