#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
source "$task_root/Tests/Support/check-phases.sh"
check_build_directory task_build "${TMPDIR:-/tmp}/cluster-remote-owner.XXXXXX"
compile_checks() {
  mkdir -p "$task_build/Sources" "$task_build/Tests"
  # Compile exact current control sources independently of the native MLX graph.
  local task_module
  for task_module in DarkbloomClusterProtocol DarkbloomClusterProcess DarkbloomClusterBootstrap DarkbloomClusterSecurity DarkbloomClusterRemote; do
    cp -R "$task_root/Sources/$task_module" "$task_build/Sources/$task_module"
  done
  cp -R "$task_root/Tests/DarkbloomClusterRemoteTests" "$task_build/Tests/DarkbloomClusterRemoteTests"
  cat > "$task_build/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "ClusterRemoteChecks", platforms: [.macOS(.v14)], targets: [
    .target(name: "DarkbloomClusterProtocol"),
    .target(name: "DarkbloomClusterBootstrap"),
    .target(name: "DarkbloomClusterProcess", dependencies: ["DarkbloomClusterProtocol"]),
    .target(name: "DarkbloomClusterSecurity", dependencies: ["DarkbloomClusterBootstrap"]),
    .target(name: "DarkbloomClusterRemote", dependencies: ["DarkbloomClusterProtocol", "DarkbloomClusterProcess", "DarkbloomClusterBootstrap", "DarkbloomClusterSecurity"]),
    .testTarget(name: "DarkbloomClusterRemoteTests", dependencies: ["DarkbloomClusterRemote", "DarkbloomClusterProtocol"]),
])
SWIFT
  swift build --package-path "$task_build" --build-tests --jobs 1 -Xswiftc -warnings-as-errors
}
check_phases compile_checks
swift test --package-path "$task_build" --skip-build --jobs 1 -Xswiftc -warnings-as-errors
