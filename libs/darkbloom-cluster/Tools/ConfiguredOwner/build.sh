#!/bin/bash
set -euo pipefail
if [[ $# != 1 ]]; then echo 'usage: build.sh NEW_OUTPUT_DIRECTORY' >&2; exit 64; fi
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_build="$1"
if [[ -e "$task_build" ]]; then echo 'output must not exist' >&2; exit 64; fi
mkdir -p "$task_build"
task_build="$(cd "$task_build" && pwd)"
task_target="$(uname -m)-apple-macos14.0"
for task_module in DarkbloomClusterProtocol DarkbloomClusterProcess DarkbloomClusterBootstrap DarkbloomClusterRemote; do
  task_links=(-I "$task_build" -L "$task_build")
  if [[ "$task_module" == DarkbloomClusterProcess || "$task_module" == DarkbloomClusterRemote ]]; then task_links+=(-lDarkbloomClusterProtocol); fi
  if [[ "$task_module" == DarkbloomClusterRemote ]]; then task_links+=(-lDarkbloomClusterProcess -lDarkbloomClusterBootstrap); fi
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
    -module-name "$task_module" -emit-module-path "$task_build/$task_module.swiftmodule" \
    "${task_links[@]}" -Xlinker -install_name -Xlinker "@rpath/lib$task_module.dylib" \
    -Xlinker -rpath -Xlinker @loader_path "$task_root/Sources/$task_module"/*.swift \
    -o "$task_build/lib$task_module.dylib"
done
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterBootstrap -lDarkbloomClusterRemote \
  -Xlinker -rpath -Xlinker @executable_path "$task_root/Tools/ConfiguredOwner/main.swift" -o "$task_build/darkbloom-owner-qualification"
