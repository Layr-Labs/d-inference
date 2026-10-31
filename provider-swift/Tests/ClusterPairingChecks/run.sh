#!/bin/bash
# Pairing ceremony checks (PROD-PLAN S17): plain swiftc, Swift 6, warnings as
# errors, no SwiftPM, no MLX, no Metal, no Secure Enclave (software keys stand
# in). About a minute; the link checks use loopback ports 40000-46000.
set -euo pipefail
task_provider="$(cd "$(dirname "$0")/../.." && pwd)"
task_repo="$(cd "$task_provider/.." && pwd)"
task_cluster="$task_repo/libs/darkbloom-cluster/Sources"
task_checks="$task_provider/Tests/ClusterPairingChecks"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-pairing.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_flags=(-swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0" -I "$task_build" -L "$task_build"
  -Xlinker -rpath -Xlinker "$task_build")

build_module() {
  local task_name="$1" task_dependencies="$2"
  shift 2
  # shellcheck disable=SC2086
  xcrun swiftc "${task_flags[@]}" -emit-library -emit-module -enable-testing -module-name "$task_name" \
    -emit-module-path "$task_build/$task_name.swiftmodule" $task_dependencies "$@" \
    -o "$task_build/lib$task_name.dylib" -Xlinker -install_name -Xlinker "@rpath/lib$task_name.dylib"
}

build_module DarkbloomClusterProtocol "" "$task_cluster"/DarkbloomClusterProtocol/*.swift
build_module DarkbloomClusterBootstrap "" "$task_cluster"/DarkbloomClusterBootstrap/*.swift
build_module DarkbloomClusterSecurity "-lDarkbloomClusterBootstrap" "$task_cluster"/DarkbloomClusterSecurity/*.swift
build_module DarkbloomClusterProcess "-lDarkbloomClusterProtocol" "$task_cluster"/DarkbloomClusterProcess/*.swift
build_module DarkbloomClusterRemote "-lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterBootstrap -lDarkbloomClusterSecurity" \
  "$task_cluster"/DarkbloomClusterRemote/*.swift

task_links=(-lDarkbloomClusterProtocol -lDarkbloomClusterBootstrap -lDarkbloomClusterSecurity -lDarkbloomClusterProcess -lDarkbloomClusterRemote)
xcrun swiftc "${task_flags[@]}" -parse-as-library "${task_links[@]}" \
  "$task_checks/Child/PairingTerminalChild.swift" "$task_checks/PairingShared.swift" \
  "$task_provider/Sources/ProviderCore/Inference/Distributed/Pairing/ClusterPairingTerminal.swift" \
  -o "$task_build/PairingTerminalChild"
xcrun swiftc "${task_flags[@]}" -parse-as-library "${task_links[@]}" "$task_checks"/*.swift -o "$task_build/PairingCheck"

mkdir -p "$task_build/scratch"
"$task_build/PairingCheck" "$task_build/PairingTerminalChild" \
  "$task_provider/Tests/ProviderCoreTests/Fixtures/coordinator-wire/cluster_registration_vector.json" "$task_build/scratch"
