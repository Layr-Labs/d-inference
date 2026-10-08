#!/bin/bash
# Scoped slice-7 runner: process ownership checks without the provider
# pipe-contract suites (those need the research branch's ProviderCore
# Distributed/* sources and land with the member-invocation slice).
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_protocol="$task_root/Sources/DarkbloomClusterProtocol"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-worker-owner.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_target="$(uname -m)-apple-macos14.0"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
  -module-name DarkbloomClusterBootstrap -emit-module-path "$task_build/DarkbloomClusterBootstrap.swiftmodule" \
  "$task_root"/Sources/DarkbloomClusterBootstrap/*.swift -o "$task_build/libDarkbloomClusterBootstrap.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
  -module-name DarkbloomClusterProtocol -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
  "$task_protocol"/*.swift -o "$task_build/libDarkbloomClusterProtocol.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker "$task_build" \
  -module-name DarkbloomClusterProcess -emit-module-path "$task_build/DarkbloomClusterProcess.swiftmodule" \
  "$task_root"/Sources/DarkbloomClusterProcess/*.swift -o "$task_build/libDarkbloomClusterProcess.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker "$task_build" \
  -lDarkbloomClusterBootstrap \
  "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/FakeClusterWorker.swift" -o "$task_build/fake-worker"
if [[ "${1:-}" == "--compile-only" ]]; then exit 0; fi
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
  -Xlinker -rpath -Xlinker "$task_build" \
  "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/WorkerOwnerTests.swift" -o "$task_build/check"
"$task_build/check" "$task_build/fake-worker"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
  -Xlinker -rpath -Xlinker "$task_build" \
  "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/EndpointOwnershipTests.swift" -o "$task_build/endpoint-check"
"$task_build/endpoint-check" "$task_build/fake-worker"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
  -Xlinker -rpath -Xlinker "$task_build" \
  "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/PartialAdmissionTests.swift" -o "$task_build/partial-check"
"$task_build/partial-check" "$task_build/fake-worker"

xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterBootstrap \
  -Xlinker -rpath -Xlinker "$task_build" \
  "$task_root/Tests/ProcessChecks/PumpFixtureIdentity.swift" "$task_root/Tests/ProcessChecks/FakeClusterWorker.swift" -o "$task_build/wakeup-fake-worker"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker "$task_build" \
  "$task_root"/Sources/DarkbloomClusterProcess/*.swift \
  "$task_root/Tests/ProcessChecks/PumpFixtureIdentity.swift" "$task_root/Tests/ProcessChecks/PumpWakeupCheck.swift" -o "$task_build/wakeup-check"
"$task_build/wakeup-check" "$task_build/wakeup-fake-worker"

xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  "$task_root/Sources/DarkbloomClusterProcess/ClusterDeviceExclusion.swift" \
  "$task_root/Tests/ProcessChecks/DeviceExclusionCheck.swift" -o "$task_build/device-exclusion-check"
"$task_build/device-exclusion-check"
printf '%s\n' '{"passed":true,"providerPipeContract":"deferred-member-slice","networkUsed":false}'
