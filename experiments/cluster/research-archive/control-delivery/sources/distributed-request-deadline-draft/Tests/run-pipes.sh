#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/distributed-deadline-pipes.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_support="$task_root/Tests/support"
task_process="$task_root/proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterProcess"
task_provider="$task_root/proposed/provider-swift/Sources/ProviderCore/Inference/Distributed"
task_link=(-I "$task_build" -L "$task_build" -Xlinker -rpath -Xlinker "$task_build")
xcrun swiftc -swift-version 6 -warnings-as-errors -emit-library -emit-module -module-name DarkbloomClusterProtocol \
 -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" "$task_support"/DarkbloomClusterProtocol/*.swift \
 -o "$task_build/libDarkbloomClusterProtocol.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -emit-library -emit-module -module-name DarkbloomClusterProcess \
 -emit-module-path "$task_build/DarkbloomClusterProcess.swiftmodule" "${task_link[@]}" -lDarkbloomClusterProtocol \
 "$task_support/DarkbloomClusterProcess/ClusterWorkerProcess.swift" "$task_process"/*.swift \
 -o "$task_build/libDarkbloomClusterProcess.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library "${task_link[@]}" -lDarkbloomClusterProtocol \
 "$task_support/FixtureIdentity.swift" "$task_support/FakeClusterWorker.swift" -o "$task_build/fake-worker"
xcrun swiftc -swift-version 6 -warnings-as-errors -emit-library -emit-module -module-name MLXLMCommon \
 -emit-module-path "$task_build/MLXLMCommon.swiftmodule" "$task_support/MLXLMCommonContractValues.swift" \
 -o "$task_build/libMLXLMCommon.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -emit-library -emit-module -module-name ProviderDeadlineContract \
 -emit-module-path "$task_build/ProviderDeadlineContract.swiftmodule" "${task_link[@]}" \
 -lMLXLMCommon -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
 "$task_provider/DistributedResidentExecution.swift" "$task_provider/DistributedRequestDeadlineContext.swift" \
 "$task_provider/DistributedPipeExecutionOwner.swift" -o "$task_build/libProviderDeadlineContract.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library "${task_link[@]}" \
 -lMLXLMCommon -lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lProviderDeadlineContract \
 "$task_support/FixtureIdentity.swift" "$task_root/Tests/ProviderDeadlinePipeCheck.swift" -o "$task_build/check"
"$task_build/check" "$task_build/fake-worker"
