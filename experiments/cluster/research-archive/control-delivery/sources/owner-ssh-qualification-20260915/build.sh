#!/bin/bash
set -euo pipefail
if [[ $# != 2 ]]; then echo 'usage: build.sh FROZEN_RELAY_QUALIFICATION_BUILD NEW_OUTPUT_DIRECTORY' >&2; exit 64; fi
task_root="$(cd "$(dirname "$0")" && pwd)"
task_base="$1"
task_build="$2"
if [[ -e "$task_build" ]]; then echo 'output must not exist' >&2; exit 64; fi
mkdir -p "$task_build"
task_build="$(cd "$task_build" && pwd)"
for task_file in "$task_base"/*.dylib "$task_base"/*.swiftmodule "$task_base"/darkbloom-owner-qualification; do cp "$task_file" "$task_build/"; done
task_target="$(uname -m)-apple-macos14.0"
task_remote_sources="$(dirname "$task_base")/workspace/libs/darkbloom-cluster/Sources/DarkbloomClusterRemote"
task_remote=()
for task_file in "$task_remote_sources"/*.swift; do
  if [[ "$(basename "$task_file")" != ClusterRemoteWorkerEndpoint.swift ]]; then task_remote+=("$task_file"); fi
done
# Only the new read-only release-ACK observation differs from the frozen module.
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
  -module-name DarkbloomClusterRemote -emit-module-path "$task_build/DarkbloomClusterRemote.swiftmodule" \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterBootstrap \
  -Xlinker -install_name -Xlinker @rpath/libDarkbloomClusterRemote.dylib -Xlinker -rpath -Xlinker @loader_path \
  "${task_remote[@]}" "$task_root/proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRemote/ClusterRemoteWorkerEndpoint.swift" \
  -o "$task_build/libDarkbloomClusterRemote.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
  -module-name DarkbloomClusterRuntime -emit-module-path "$task_build/DarkbloomClusterRuntime.swiftmodule" \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol \
  -Xlinker -install_name -Xlinker @rpath/libDarkbloomClusterRuntime.dylib -Xlinker -rpath -Xlinker @loader_path \
  "$task_root/upstream/LoadConfiguration.swift" -o "$task_build/libDarkbloomClusterRuntime.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterRuntime -lDarkbloomClusterProtocol -lDarkbloomClusterBootstrap \
  -Xlinker -rpath -Xlinker @executable_path "$task_root/upstream/WorkerConfiguration.swift" \
  "$task_root/upstream/WorkerBootstrapConfiguration.swift" "$task_root/Sources/QualificationInput.swift" \
  "$task_root/Sources/NativeStandIn.swift" -o "$task_build/native-standin"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterRemote -lDarkbloomClusterBootstrap \
  -Xlinker -rpath -Xlinker @executable_path "$task_root/Sources/QualificationInput.swift" \
  "$task_root/Sources/Controller.swift" -o "$task_build/owner-controller"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol \
  -Xlinker -rpath -Xlinker @executable_path "$task_root/Sources/QualificationInput.swift" \
  "$task_root/Sources/PrepareCPU.swift" -o "$task_build/prepare-cpu"
