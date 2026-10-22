#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_repo="$(cd "$task_root/../.." && pwd)"
task_protocol="$task_root/Sources/DarkbloomClusterProtocol"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-worker-owner.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_target="$(uname -m)-apple-macos14.0"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
  -module-name DarkbloomClusterProtocol -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
  "$task_protocol"/*.swift -o "$task_build/libDarkbloomClusterProtocol.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker "$task_build" \
  -module-name DarkbloomClusterProcess -emit-module-path "$task_build/DarkbloomClusterProcess.swiftmodule" \
  "$task_root"/Sources/DarkbloomClusterProcess/*.swift -o "$task_build/libDarkbloomClusterProcess.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker "$task_build" \
  "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/FakeClusterWorker.swift" -o "$task_build/fake-worker"
if [[ "${1:-}" == "--compile-only" ]]; then exit 0; fi
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
  -Xlinker -rpath -Xlinker "$task_build" \
  "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/WorkerOwnerTests.swift" -o "$task_build/check"
"$task_build/check" "$task_build/fake-worker"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
  -module-name MLXLMCommon -emit-module-path "$task_build/MLXLMCommon.swiftmodule" \
  "$task_root/Tests/ProcessChecks/MLXLMCommonContractValues.swift" -o "$task_build/libMLXLMCommon.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
  -I "$task_build" -L "$task_build" -lMLXLMCommon -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
  -Xlinker -rpath -Xlinker "$task_build" \
  -module-name ProviderPipeContract -emit-module-path "$task_build/ProviderPipeContract.swiftmodule" \
  "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/DistributedRequestDeadlineContext.swift" \
  "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/DistributedResidentExecution.swift" \
  "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/DistributedPipeExecutionOwner.swift" \
  -o "$task_build/libProviderPipeContract.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lMLXLMCommon -lProviderPipeContract -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
  -Xlinker -rpath -Xlinker "$task_build" \
  "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/ProviderPipeContractTests.swift" -o "$task_build/provider-check"
"$task_build/provider-check" "$task_build/fake-worker"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
  -I "$task_build" -L "$task_build" -lMLXLMCommon -lProviderPipeContract -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
  -Xlinker -rpath -Xlinker "$task_build" \
  "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/ProviderDeadlinePipeCheck.swift" -o "$task_build/deadline-check"
"$task_build/deadline-check" "$task_build/fake-worker"
