#!/bin/bash
# Scoped slice-4 runner: bootstrap channel only.
# Deferred: NativeABI bridge checks (blocked: master's pinned mlx-swift/mlx-c
# 6923a80f/02cf6f4 lacks the distributed_bootstrap C bridge that research pin
# 2180e51c carries; changing the submodule pin would alter provider bytes) and
# worker admission/facade checks (need the darkbloom-cluster-worker package).
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_tests="$task_root/Tests/BootstrapChecks"
task_cmlx="$task_root/../mlx-swift/Source/Cmlx"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-bootstrap.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_target="$(uname -m)-apple-macosx14.0"

# Actual local channel and protocol modules, including actual direct children.
task_channel="$task_build/channel"
mkdir -p "$task_channel"
xcrun swiftc -target "$task_target" -swift-version 6 -warnings-as-errors \
  -enable-testing -emit-library -emit-module -module-name DarkbloomClusterBootstrap \
  "$task_root"/Sources/DarkbloomClusterBootstrap/*.swift \
  -emit-module-path "$task_channel/DarkbloomClusterBootstrap.swiftmodule" \
  -o "$task_channel/libDarkbloomClusterBootstrap.dylib"
xcrun swiftc -target "$task_target" -swift-version 6 -warnings-as-errors -parse-as-library \
  -I "$task_channel" -L "$task_channel" -lDarkbloomClusterBootstrap \
  -Xlinker -rpath -Xlinker "$task_channel" \
  "$task_tests/Channel/BootstrapChannelCheck.swift" -o "$task_channel/channel-check"
"$task_channel/channel-check"
printf '%s\n' 'PASS scoped bootstrap checks (local channel)'; printf '%s\n' '{"passed":true,"nativeABI":"blocked-submodule-pin","networkUsed":false}'
