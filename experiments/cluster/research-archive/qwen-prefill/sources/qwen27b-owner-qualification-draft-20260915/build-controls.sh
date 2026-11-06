#!/bin/bash
set -euo pipefail
if [[ $# != 1 || -e "$1" ]]; then echo 'usage: build-controls.sh NEW_OUTPUT_DIRECTORY' >&2; exit 64; fi
task_root="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$1"
task_build="$(cd "$1" && pwd)"
task_target="arm64-apple-macos14.0"
for task_module in DarkbloomClusterProtocol DarkbloomClusterBootstrap DarkbloomClusterProcess DarkbloomClusterRemote; do
  task_links=(-I "$task_build" -L "$task_build")
  case "$task_module" in
    DarkbloomClusterProcess) task_links+=(-lDarkbloomClusterProtocol);;
    DarkbloomClusterRemote) task_links+=(-lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterBootstrap);;
  esac
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
    -module-name "$task_module" -emit-module-path "$task_build/$task_module.swiftmodule" \
    "${task_links[@]}" -Xlinker -install_name -Xlinker "@rpath/lib$task_module.dylib" \
    -Xlinker -rpath -Xlinker @loader_path \
    "$task_root/upstream/$task_module"/*.swift -o "$task_build/lib$task_module.dylib"
done
task_links=(-I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
  -lDarkbloomClusterRemote -lDarkbloomClusterBootstrap -Xlinker -rpath -Xlinker @executable_path)
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  "${task_links[@]}" "$task_root/Sources/QualificationInput.swift" "$task_root/Sources/Controller.swift" \
  -o "$task_build/owner-controller"
# The old entry is deliberately retained as top-level code. Swift's multi-file
# form requires that exact entry text to have the filename main.swift.
mkdir "$task_build/ConfiguredOwner"
cp "$task_root/Sources/ConfiguredOwner.swift" "$task_build/ConfiguredOwner/main.swift"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" "${task_links[@]}" \
  "$task_root/Sources/Qwen27BQualificationScope.swift" "$task_build/ConfiguredOwner/main.swift" \
  -o "$task_build/darkbloom-owner-qualification"
# Match the existing Foundation metadata fixture's language mode; these exact
# internal runtime sources do not import MLX or construct a model.
xcrun swiftc -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker @executable_path \
  "$task_root/metadata"/*.swift "$task_root/Sources/QualificationInput.swift" \
  "$task_root/Sources/Qwen27BQualificationScope.swift" "$task_root/Sources/PrepareMetadata.swift" \
  -o "$task_build/prepare-metadata"
