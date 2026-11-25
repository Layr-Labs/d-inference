#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")" && pwd)"
task_side="$1"
task_build="$2"
mkdir "$task_build"
task_target="$(uname -m)-apple-macos14.0"
for task_module in DarkbloomClusterProtocol DarkbloomClusterProcess DarkbloomClusterBootstrap DarkbloomClusterRemote; do
  task_links=(-I "$task_build" -L "$task_build")
  if [[ "$task_module" != DarkbloomClusterProtocol ]]; then task_links+=(-lDarkbloomClusterProtocol); fi
  if [[ "$task_module" == DarkbloomClusterRemote ]]; then task_links+=(-lDarkbloomClusterProcess -lDarkbloomClusterBootstrap); fi
  xcrun swiftc -j 2 -swift-version 6 -warnings-as-errors -enable-testing -target "$task_target" -emit-library -emit-module \
    -module-name "$task_module" -emit-module-path "$task_build/$task_module.swiftmodule" \
    "${task_links[@]}" -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/$task_side/Sources/$task_module"/*.swift -o "$task_build/lib$task_module.dylib"
done
for task_name in FakeClusterWorker FakeOwner RemoteOwnerTests RetirementShutdownTests; do
  task_extra=()
  if [[ "$task_name" == RetirementShutdownTests ]]; then task_extra+=("$task_root/Fixtures/RetirementOwnerConnection.swift"); fi
  xcrun swiftc -j 2 -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterBootstrap -lDarkbloomClusterRemote \
    -Xlinker -rpath -Xlinker "$task_build" "$task_root/Fixtures/FixtureIdentity.swift" \
    "${task_extra[@]}" "$task_root/Fixtures/$task_name.swift" -o "$task_build/$task_name"
done
