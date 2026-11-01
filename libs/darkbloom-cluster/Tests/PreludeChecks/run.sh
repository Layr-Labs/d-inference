#!/bin/bash
# Key-prelude checks: compiles the actual Bootstrap + Security modules with
# Swift 6 and warnings as errors, then runs the native key prelude over actual
# local owner/native children (two-rank X25519 exchange, HMAC confirmation,
# transcript completion) plus refusal groups. No MLX, no network, no RDMA, no
# model. This does not qualify cross-host execution.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-prelude.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
target="$(uname -m)-apple-macos14.0"

xcrun swiftc -swift-version 6 -warnings-as-errors -target "$target" \
  -enable-testing -emit-library -emit-module -module-name DarkbloomClusterBootstrap \
  -emit-module-path "$task_build/DarkbloomClusterBootstrap.swiftmodule" \
  "$task_root"/Sources/DarkbloomClusterBootstrap/*.swift -o "$task_build/libDarkbloomClusterBootstrap.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$target" \
  -enable-testing -emit-library -emit-module -module-name DarkbloomClusterSecurity \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterBootstrap \
  -Xlinker -rpath -Xlinker "$task_build" \
  -emit-module-path "$task_build/DarkbloomClusterSecurity.swiftmodule" \
  "$task_root"/Sources/DarkbloomClusterSecurity/*.swift -o "$task_build/libDarkbloomClusterSecurity.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library -target "$target" \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterBootstrap -lDarkbloomClusterSecurity \
  -Xlinker -rpath -Xlinker "$task_build" \
  "$task_root/Tests/PreludeChecks/main.swift" -o "$task_build/check"
"$task_build/check"
