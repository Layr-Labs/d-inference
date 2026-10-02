#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")" && pwd)"
task_modules="$task_root/../../owner-retirement-controls-build-20260915/build-1/artifacts"
task_output="$task_root/runtime"
mkdir "$task_output"
for task_module in DarkbloomClusterProtocol DarkbloomClusterBootstrap DarkbloomClusterProcess DarkbloomClusterRemote; do
  cp "$task_modules/lib$task_module.dylib" "$task_output/"
done
xcrun swiftc -j 2 -swift-version 6 -warnings-as-errors -target arm64-apple-macos14.0 -parse-as-library \
  -I "$task_modules" -L "$task_modules" -lDarkbloomClusterProtocol -lDarkbloomClusterBootstrap \
  -lDarkbloomClusterProcess -lDarkbloomClusterRemote -Xlinker -rpath -Xlinker @executable_path \
  "$task_root/Sources"/*.swift -o "$task_output/owner-timing-controller"
