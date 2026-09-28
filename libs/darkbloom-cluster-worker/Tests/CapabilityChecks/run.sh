#!/bin/bash
set -euo pipefail
task_package="$(cd "$(dirname "$0")/../.." && pwd)"
task_shared="$(cd "$task_package/../darkbloom-cluster" && pwd)"
task_runtime="$task_shared/Sources/DarkbloomClusterRuntime"
task_fixtures="$task_package/Tests/CapabilityChecks"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-capability-metadata.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0" \
  -emit-library -emit-module -module-name DarkbloomClusterProtocol \
  -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
  "$task_shared"/Sources/DarkbloomClusterProtocol/*.swift -o "$task_build/libDarkbloomClusterProtocol.dylib"
# The producer's actual pure source closure; no MLX/Cmlx or model constructor.
task_sources=(
  Support/WorkerJSONScanner
  Support/BoundedProbeInput
  Models/Qwen/Metadata/QwenLayerStageMetadata
  Models/Qwen/Metadata/QwenLayerStagePlan
  Models/Qwen/Resources/QwenLongPrefillTensorBudget
  Models/Qwen/Metadata/QwenDenseProfileTypes
  Models/Qwen/Metadata/QwenDenseRegisteredSpecification
  Models/Qwen/Generation/QwenLayerStageGenerationRequest
  Models/Qwen/Generation/QwenLayerStageFrame
  Models/Qwen/Generation/QwenLayerStageWireIdentity
  Support/ClusterRuntimeError
  Support/CanonicalJSON
  Support/ClusterMetadataHashing
  Models/Qwen/Prefill/QwenLongPrefillArithmeticEnvironment
  Models/Qwen/Resident/QwenResidentAdapterDefinition
  Models/Qwen/Resident/QwenResidentCapabilityMetadata
)
task_paths=()
for task_source in "${task_sources[@]}"; do task_paths+=("$task_runtime/$task_source.swift"); done
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0" \
  -emit-library -emit-module -module-name DarkbloomClusterRuntime \
  -emit-module-path "$task_build/DarkbloomClusterRuntime.swiftmodule" \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol \
  "${task_paths[@]}" -o "$task_build/libDarkbloomClusterRuntime.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterRuntime \
  -Xlinker -rpath -Xlinker "$task_build" \
  "$task_package/Sources/DarkbloomClusterWorker/Capabilities/WorkerCapabilityInput.swift" \
  "$task_package/Sources/DarkbloomClusterWorker/Capabilities/WorkerCapabilityCommand.swift" \
  "$task_fixtures/CapabilityCheckSupport.swift" "$task_fixtures/CapabilityInputCheck.swift" \
  "$task_fixtures/CapabilityCommandCheck.swift" -o "$task_build/check"
"$task_build/check" "$task_fixtures/Fixtures" "$task_shared/Tests/CapabilityChecks/Fixtures/registered-qwen35-9b.capability.json"
/usr/bin/python3 "$task_fixtures/check_command.py" "$task_build/check" "$task_fixtures/Fixtures"
