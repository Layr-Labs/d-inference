#!/bin/bash
set -euo pipefail
task_package="$(cd "$(dirname "$0")/../.." && pwd)"
task_runtime="$task_package/Sources/DarkbloomClusterRuntime"
task_repo="$(cd "$task_package/../.." && pwd)"
task_fixtures="$task_package/Tests/PrefillScheduleChecks"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-prefill-schedule.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_flags=(-swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0")
task_links=(-I "$task_build" -L "$task_build" -Xlinker -rpath -Xlinker "$task_build")
xcrun swiftc "${task_flags[@]}" -emit-library -emit-module -module-name DarkbloomClusterProtocol \
  -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
  "$task_package"/Sources/DarkbloomClusterProtocol/*.swift -o "$task_build/libDarkbloomClusterProtocol.dylib"
xcrun swiftc "${task_flags[@]}" -parse-as-library "${task_links[@]}" -lDarkbloomClusterProtocol \
  "$task_runtime/Support/ClusterRuntimeError.swift" "$task_runtime/Models/Qwen/Resources/QwenLongPrefillTensorBudget.swift" \
  "$task_runtime/Models/Qwen/Prefill/QwenGenerationPrefillPolicy.swift" "$task_runtime/Models/Qwen/Prefill/QwenGenerationPrefillAllowance.swift" \
  "$task_runtime/Models/Qwen/Prefill/QwenResidentPrefillSelection.swift" \
  "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/DistributedInstalledPrefillSelection.swift" \
  "$task_fixtures/NativePrefillSelectionCheck.swift" \
  -o "$task_build/schedule-check"
"$task_build/schedule-check" "$task_package/Tests/CapabilityChecks/Fixtures/registered-qwen35-9b.capability.json"
# Worker startup checks the whole closed runtime catalog. Its GLM metadata
# now depends on MLXLLM types, so use the actual Runtime instead of an obsolete
# partial source closure. This executes argument admission only, no model/GPU.
bash "$task_package/Tests/Support/native-metadata.sh" bootstrap
