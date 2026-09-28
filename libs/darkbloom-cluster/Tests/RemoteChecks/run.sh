#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-remote-owner.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
mkdir -p "$task_build/Sources" "$task_build/Tests"
# Compile exact current control sources independently of the native MLX graph.
for task_module in DarkbloomClusterProtocol DarkbloomClusterProcess DarkbloomClusterBootstrap DarkbloomClusterRemote; do
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
    .target(name: "DarkbloomClusterRemote", dependencies: ["DarkbloomClusterProtocol", "DarkbloomClusterProcess", "DarkbloomClusterBootstrap"]),
    .testTarget(name: "DarkbloomClusterRemoteTests", dependencies: ["DarkbloomClusterRemote", "DarkbloomClusterProtocol"]),
])
SWIFT
swift test --package-path "$task_build" --jobs 1 -Xswiftc -warnings-as-errors
