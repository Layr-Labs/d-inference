#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_repo="${DARKBLOOM_SOURCE_ROOT:-/Users/developer/DarkbloomDev/d-inference}"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/jaccl-bootstrap-abi.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_cmlx="$task_root/proposed/libs/mlx-swift/Source/Cmlx"
task_includes=(-I "$task_root/Tests/stubs" -I "$task_cmlx/mlx-c" -I "$task_repo/libs/mlx-swift/Source/Cmlx/include")
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -c "${task_includes[@]}" \
 "$task_cmlx/mlx-c/mlx/c/distributed_bootstrap.cpp" -o "$task_build/bridge.o"
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -c "${task_includes[@]}" \
 "$task_root/Tests/BootstrapABIStub.cpp" -o "$task_build/stub.o"
cat > "$task_build/module.modulemap" <<EOF
module Cmlx [system] {
  header "$task_cmlx/include/mlx/c/distributed_group.h"
  header "$task_root/Tests/BootstrapTestControl.h"
  export *
}
EOF
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
 -I "$task_build" -Xcc -I -Xcc "$task_repo/libs/mlx-swift/Source/Cmlx/include" \
 "$task_root/proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/JACCLBootstrap.swift" \
 "$task_root/Tests/BootstrapABICheck.swift" "$task_build/bridge.o" "$task_build/stub.o" -lc++ -o "$task_build/check"
"$task_build/check"
