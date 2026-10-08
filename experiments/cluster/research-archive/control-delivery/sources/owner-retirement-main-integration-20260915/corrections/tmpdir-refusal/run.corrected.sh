#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_build="$(mktemp -d "/private/tmp/cluster-remote-owner.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_target="$(uname -m)-apple-macos14.0"
for task_module in DarkbloomClusterProtocol DarkbloomClusterProcess DarkbloomClusterBootstrap DarkbloomClusterRemote; do
  task_links=(-I "$task_build" -L "$task_build")
  if [[ "$task_module" != DarkbloomClusterProtocol ]]; then task_links+=(-lDarkbloomClusterProtocol); fi
  if [[ "$task_module" == DarkbloomClusterRemote ]]; then task_links+=(-lDarkbloomClusterProcess -lDarkbloomClusterBootstrap); fi
  xcrun swiftc -j 2 -swift-version 6 -warnings-as-errors -enable-testing -target "$task_target" -emit-library -emit-module \
    -module-name "$task_module" -emit-module-path "$task_build/$task_module.swiftmodule" \
    -I "$task_build" -L "$task_build" "${task_links[@]}" -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Sources/$task_module"/*.swift -o "$task_build/lib$task_module.dylib"
done
for task_name in FakeClusterWorker FakeOwner RemoteOwnerTests RetirementShutdownTests; do
  task_source="$task_root/Tests/SSHChecks/$task_name.swift"
  if [[ "$task_name" == FakeClusterWorker ]]; then task_source="$task_root/Tests/ProcessChecks/$task_name.swift"; fi
  task_sources=("$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_source")
  if [[ "$task_name" == RetirementShutdownTests ]]; then task_sources+=("$task_root/Tests/SSHChecks/RetirementOwnerConnection.swift"); fi
  xcrun swiftc -j 2 -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterBootstrap -lDarkbloomClusterRemote \
    -Xlinker -rpath -Xlinker "$task_build" "${task_sources[@]}" -o "$task_build/$task_name"
done
"$task_build/RemoteOwnerTests" "$task_build/FakeOwner" "$task_build/FakeClusterWorker"
mkdir "$task_build/retirement-checks"
"$task_build/RetirementShutdownTests" "$task_build/FakeOwner" "$task_build/FakeClusterWorker" "$task_build/retirement-checks" corrected

xcrun swiftc -j 2 -swift-version 6 -warnings-as-errors -target "$task_target" \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterBootstrap -lDarkbloomClusterRemote \
  -Xlinker -rpath -Xlinker "$task_build" "$task_root/Tools/ConfiguredOwner/main.swift" -o "$task_build/configured-owner"
