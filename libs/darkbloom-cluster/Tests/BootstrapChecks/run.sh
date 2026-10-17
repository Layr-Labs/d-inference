#!/bin/bash
# Bootstrap checks: the pinned mlx-c owner-bootstrap bridge (its callback state
# and its C entry point, with the Swift adapter `JACCLOwnerBootstrap` and a
# stand-in for MLX's native factory and cache), then the local owner-child
# channel with actual direct children. No JACCL, RDMA, network or model.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_tests="$task_root/Tests/BootstrapChecks"
task_cmlx="$task_root/../mlx-swift/Source/Cmlx"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-bootstrap.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_target="$(uname -m)-apple-macosx14.0"

# Actual callback state implementation (pinned mlx-c private header).
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -pthread \
  -iquote "$task_cmlx/mlx-c/mlx/c/private" \
  "$task_tests/NativeABI/BootstrapStateCheck.cpp" -o "$task_build/state-check"
"$task_build/state-check"

# Actual C bridge and Swift adapter, with explicit native factory/cache stand-ins.
mkdir -p "$task_build/abi"
task_includes=(-I "$task_tests/NativeABI/stubs" -I "$task_cmlx/mlx-c")
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -c "${task_includes[@]}" \
  "$task_cmlx/mlx-c/mlx/c/distributed_bootstrap.cpp" -o "$task_build/abi/bridge.o"
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -c "${task_includes[@]}" \
  "$task_tests/NativeABI/BootstrapABIStub.cpp" -o "$task_build/abi/stub.o"
cat > "$task_build/abi/module.modulemap" <<MAP
module Cmlx [system] {
  header "$task_cmlx/include/mlx/c/distributed_group.h"
  header "$task_tests/NativeABI/BootstrapTestControl.h"
  export *
}
MAP
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -I "$task_build/abi" -Xcc -I -Xcc "$task_cmlx/mlx-c" \
  "$task_root/Sources/DarkbloomClusterRuntime/Transport/JACCLOwnerBootstrap.swift" \
  "$task_tests/NativeABI/BootstrapABICheck.swift" \
  "$task_build/abi/bridge.o" "$task_build/abi/stub.o" -lc++ -o "$task_build/abi/check"
"$task_build/abi/check"

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
printf '%s\n' 'PASS bootstrap checks (bridge state, C bridge + Swift adapter, local channel)'; printf '%s\n' '{"passed":true,"nativeABI":"pinned-mlx-c-bridge","networkUsed":false}'
