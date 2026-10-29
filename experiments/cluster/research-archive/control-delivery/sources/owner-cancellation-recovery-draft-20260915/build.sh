#!/bin/bash
set -euo pipefail
if [[ $# != 1 || -e "$1" ]]; then echo 'usage: build.sh NEW_OUTPUT_DIRECTORY' >&2; exit 64; fi
task_root="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$1"
task_build="$(cd "$1" && pwd)"
task_target="$(uname -m)-apple-macos14.0"
for task_module in DarkbloomClusterProtocol DarkbloomClusterBootstrap DarkbloomClusterProcess DarkbloomClusterRemote; do
  task_links=(-I "$task_build" -L "$task_build")
  case "$task_module" in
    DarkbloomClusterProcess) task_links+=(-lDarkbloomClusterProtocol);;
    DarkbloomClusterRemote) task_links+=(-lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterBootstrap);;
  esac
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
    -module-name "$task_module" -emit-module-path "$task_build/$task_module.swiftmodule" \
    "${task_links[@]}" \
    -Xlinker -install_name -Xlinker "@rpath/lib$task_module.dylib" -Xlinker -rpath -Xlinker @loader_path \
    "$task_root/upstream/$task_module"/*.swift -o "$task_build/lib$task_module.dylib"
done
task_common=("$task_root/Sources/QualificationInput.swift" "$task_root/Sources/CancellationSettings.swift"
  "$task_root/Sources/CancellationObservation.swift" "$task_root/Sources/CancellationOwnedPair.swift" "$task_root/Sources/CancellationCohort.swift")
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterRemote -lDarkbloomClusterBootstrap \
  -Xlinker -rpath -Xlinker @executable_path "${task_common[@]}" "$task_root/Sources/CancellationRemoteFactory.swift" "$task_root/Sources/Controller.swift" -o "$task_build/owner-cancellation-controller"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol \
  -Xlinker -rpath -Xlinker @executable_path "$task_root/Sources/QualificationInput.swift" "$task_root/Tests/FixtureIdentity.swift" "$task_root/Tests/FakeWorker.swift" -o "$task_build/fake-worker"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
  -Xlinker -rpath -Xlinker @executable_path "${task_common[@]}" "$task_root/Tests/FixtureIdentity.swift" "$task_root/Tests/CancellationCheck.swift" -o "$task_build/cancellation-check"
