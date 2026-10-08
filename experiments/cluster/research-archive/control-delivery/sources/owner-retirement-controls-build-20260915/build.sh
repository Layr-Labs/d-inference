#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")" && pwd)"
task_build="$1"
mkdir "$task_build"
task_target="arm64-apple-macos14.0"
for task_module in DarkbloomClusterProtocol DarkbloomClusterBootstrap DarkbloomClusterProcess DarkbloomClusterRemote; do
  task_links=(-I "$task_build" -L "$task_build")
  case "$task_module" in
    DarkbloomClusterProcess) task_links+=(-lDarkbloomClusterProtocol);;
    DarkbloomClusterRemote) task_links+=(-lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterBootstrap);;
  esac
  xcrun swiftc -j 2 -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
    -module-name "$task_module" -emit-module-path "$task_build/$task_module.swiftmodule" \
    "${task_links[@]}" -Xlinker -install_name -Xlinker "@rpath/lib$task_module.dylib" \
    -Xlinker -rpath -Xlinker @loader_path \
    "$task_root/Sources/$task_module"/*.swift -o "$task_build/lib$task_module.dylib"
done
task_links=(-I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
  -lDarkbloomClusterRemote -lDarkbloomClusterBootstrap -Xlinker -rpath -Xlinker @executable_path)
xcrun swiftc -j 2 -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  "${task_links[@]}" "$task_root/Entries/controller/QualificationInput.swift" "$task_root/Entries/controller/Controller.swift" \
  -o "$task_build/owner-controller"
for task_scope in mtp qwen27b; do
  mkdir "$task_build/$task_scope"
  xcrun swiftc -j 2 -swift-version 6 -warnings-as-errors -target "$task_target" "${task_links[@]}" \
    "$task_root/Entries/$task_scope"/*.swift -o "$task_build/$task_scope/darkbloom-owner-qualification"
done
