#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_tests="$task_root/Tests/BootstrapChecks"
task_cmlx="$task_root/../mlx-swift/Source/Cmlx"
task_worker="$task_root/../darkbloom-cluster-worker/Sources/DarkbloomClusterWorker"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-bootstrap.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_target="$(uname -m)-apple-macosx14.0"

# Actual callback state implementation; no native device or network calls.
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -pthread \
  -iquote "$task_cmlx/mlx-c/mlx/c/private" \
  "$task_tests/NativeABI/BootstrapStateCheck.cpp" -o "$task_build/state-check"
"$task_build/state-check"

# Actual C and Swift bridge, with explicit native factory/cache stand-ins.
mkdir -p "$task_build/abi"
task_includes=(-I "$task_tests/NativeABI/stubs" -I "$task_cmlx/mlx-c")
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -c "${task_includes[@]}" \
  "$task_cmlx/mlx-c/mlx/c/distributed_bootstrap.cpp" -o "$task_build/abi/bridge.o"
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -c "${task_includes[@]}" \
  "$task_tests/NativeABI/BootstrapABIStub.cpp" -o "$task_build/abi/stub.o"
cat > "$task_build/abi/module.modulemap" <<EOF
module Cmlx [system] {
  header "$task_cmlx/include/mlx/c/distributed_group.h"
  header "$task_tests/NativeABI/BootstrapTestControl.h"
  export *
}
EOF
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -I "$task_build/abi" -Xcc -I -Xcc "$task_cmlx/mlx-c" \
  "$task_root/Sources/DarkbloomClusterRuntime/Transport/JACCLBootstrap.swift" \
  "$task_tests/NativeABI/BootstrapABICheck.swift" \
  "$task_build/abi/bridge.o" "$task_build/abi/stub.o" -lc++ -o "$task_build/abi/check"
"$task_build/abi/check"

# Actual local channel and protocol modules, including actual direct children.
mkdir -p "$task_build/channel"
task_channel="$task_build/channel"
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
xcrun swiftc -target "$task_target" -swift-version 6 -warnings-as-errors \
  -emit-library -emit-module -module-name DarkbloomClusterProtocol \
  "$task_root"/Sources/DarkbloomClusterProtocol/*.swift \
  -emit-module-path "$task_channel/DarkbloomClusterProtocol.swiftmodule" \
  -o "$task_channel/libDarkbloomClusterProtocol.dylib"

# Admission and facade checks use explicit runtime value stand-ins, not MLX.
xcrun swiftc -target "$task_target" -swift-version 6 -warnings-as-errors \
  -emit-library -emit-module -module-name DarkbloomClusterRuntime \
  -I "$task_channel" -L "$task_channel" -lDarkbloomClusterProtocol \
  "$task_tests/Channel/LoadConfiguration.swift" \
  -emit-module-path "$task_channel/DarkbloomClusterRuntime.swiftmodule" \
  -o "$task_channel/libDarkbloomClusterRuntime.dylib"
xcrun swiftc -target "$task_target" -swift-version 6 -warnings-as-errors -parse-as-library \
  -I "$task_channel" -L "$task_channel" -lDarkbloomClusterRuntime \
  -lDarkbloomClusterProtocol -lDarkbloomClusterBootstrap \
  -Xlinker -rpath -Xlinker "$task_channel" \
  "$task_worker/Startup/WorkerConfiguration.swift" "$task_worker/Startup/WorkerBootstrapConfiguration.swift" \
  "$task_tests/Channel/WorkerBootstrapAdmissionCheck.swift" -o "$task_channel/admission-check"
"$task_channel/admission-check"
xcrun swiftc -target "$task_target" -swift-version 6 -warnings-as-errors -typecheck \
  -I "$task_channel" "$task_tests/Channel/LoadConfiguration.swift" \
  "$task_tests/Channel/FacadeTypecheckSupport.swift" \
  "$task_root/Sources/DarkbloomClusterRuntime/Models/Qwen/Resident/QwenResidentBootstrap.swift"
printf '%s\n' 'PASS facade adapter typecheck with explicit native-type stand-ins'
