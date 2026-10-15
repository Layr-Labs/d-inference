#!/bin/bash
set -euo pipefail
base="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$base/build}"
mkdir -p "$build"
target="$(uname -m)-apple-macosx14.0"
swiftc -target "$target" -swift-version 6 -warnings-as-errors -emit-library -emit-module -module-name DarkbloomClusterProtocol \
  "$base"/Tests/protocol/*.swift -emit-module-path "$build/DarkbloomClusterProtocol.swiftmodule" \
  -o "$build/libDarkbloomClusterProtocol.dylib"
swiftc -target "$target" -swift-version 6 -warnings-as-errors -emit-library -emit-module -module-name DarkbloomClusterRuntime \
  -I "$build" -L "$build" -lDarkbloomClusterProtocol \
  "$base/Tests/LoadConfiguration.swift" -emit-module-path "$build/DarkbloomClusterRuntime.swiftmodule" \
  -o "$build/libDarkbloomClusterRuntime.dylib"
swiftc -target "$target" -swift-version 6 -warnings-as-errors -parse-as-library \
  -I "$build" -L "$build" -lDarkbloomClusterRuntime -lDarkbloomClusterProtocol -lDarkbloomClusterBootstrap \
  -Xlinker -rpath -Xlinker "$build" \
  "$base/proposed/libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/WorkerConfiguration.swift" \
  "$base/proposed/libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/WorkerBootstrapConfiguration.swift" \
  "$base/Tests/WorkerBootstrapAdmissionCheck.swift" -o "$build/WorkerBootstrapAdmissionCheck"
"$build/WorkerBootstrapAdmissionCheck"
