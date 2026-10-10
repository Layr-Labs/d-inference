#!/bin/bash
# Link control channel: compiles the actual control modules (Swift 6, warnings
# as errors, optimized) and runs the two-process loopback check: a listener and
# a client in separate processes, the edge secret handed over standard input,
# measurements, kill-and-restart of each end, wrong secret and wrong epoch.
# Loopback only: no Thunderbolt interface, no peer Mac, no model.
#   --build-only DIR   compile into DIR and stop (hardware runs reuse the binary)
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
if [[ "${1:-}" == "--build-only" ]]; then task_build="$2"; mkdir -p "$task_build"; else
  task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-link-control.XXXXXX")"
  trap 'rm -rf "$task_build"' EXIT
fi
task_target="$(uname -m)-apple-macos14.0"
flags=(-swift-version 6 -warnings-as-errors -target "$task_target" -O -j 4)
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
  -Xlinker -rpath -Xlinker @executable_path \
  "$task_root/Tests/LinkControlChecks/main.swift" -o "$task_build/link-check"
if [[ "${1:-}" == "--build-only" ]]; then echo "built $task_build/link-check"; exit 0; fi
"$task_build/link-check" two-process
