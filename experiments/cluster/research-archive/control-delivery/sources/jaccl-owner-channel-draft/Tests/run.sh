#!/bin/bash
set -euo pipefail
base="$(cd "$(dirname "$0")/.." && pwd)"
build="${1:-$base/build}"
mkdir -p "$build"
target="$(uname -m)-apple-macosx14.0"
swiftc -target "$target" -swift-version 6 -warnings-as-errors -enable-testing -emit-library -emit-module \
  -module-name DarkbloomClusterBootstrap \
  "$base"/proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterBootstrap/*.swift \
  -emit-module-path "$build/DarkbloomClusterBootstrap.swiftmodule" -o "$build/libDarkbloomClusterBootstrap.dylib"
swiftc -target "$target" -swift-version 6 -warnings-as-errors -parse-as-library \
  -I "$build" -L "$build" -lDarkbloomClusterBootstrap -Xlinker -rpath -Xlinker "$build" \
  "$base/Tests/BootstrapChannelCheck.swift" -o "$build/BootstrapChannelCheck"
"$build/BootstrapChannelCheck"
bash "$base/Tests/run-admission.sh" "$build"
swiftc -target "$target" -swift-version 6 -warnings-as-errors -typecheck -I "$build" \
  "$base/Tests/LoadConfiguration.swift" "$base/Tests/FacadeTypecheckSupport.swift" \
  "$base/proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenResidentBootstrap.swift"
printf '%s\n' 'PASS facade adapter typecheck with explicit native-type stand-ins'
