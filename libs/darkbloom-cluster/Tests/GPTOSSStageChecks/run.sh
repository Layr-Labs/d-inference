#!/bin/bash
set -euo pipefail
task_shared="$(cd "$(dirname "$0")/../.." && pwd)"
task_runtime="$task_shared/Sources/DarkbloomClusterRuntime"
task_fixtures="$(cd "$task_shared/../darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures" && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-gptoss-stage.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0" \
  -emit-library -emit-module -module-name DarkbloomClusterProtocol \
  -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
  "$task_shared"/Sources/DarkbloomClusterProtocol/*.swift -o "$task_build/libDarkbloomClusterProtocol.dylib"
# The adapter's pure source closure; no MLX/Cmlx or model constructor.
task_sources=(
  Support/WorkerJSONScanner
  Support/BoundedProbeInput
  Support/ClusterRuntimeError
  Support/CanonicalJSON
  Support/ClusterMetadataHashing
  Models/Qwen/Metadata/QwenLayerStageMetadata
  Models/Qwen/Metadata/QwenLayerStagePlan
  Models/Qwen/Resources/QwenLongPrefillTensorBudget
  Models/Qwen/Generation/QwenLayerStageGenerationRequest
  Models/Qwen/Generation/QwenLayerStageFrame
  Models/Qwen/Generation/QwenLayerStageWireIdentity
  Models/GPTOSS/Metadata/GPTOSSRegisteredSpecification
  Models/GPTOSS/Metadata/GPTOSSLayerStagePlan
  Models/GPTOSS/Metadata/GPTOSSStageMetadata
  Models/GPTOSS/Metadata/GPTOSSArithmeticEnvironment
  Models/GPTOSS/Metadata/GPTOSSRequestStateBudget
  Models/GPTOSS/Resident/GPTOSSResidentCapabilityMetadata
)
task_paths=()
for task_source in "${task_sources[@]}"; do task_paths+=("$task_runtime/$task_source.swift"); done
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker "$task_build" \
  "${task_paths[@]}" "$task_shared/Tests/GPTOSSStageChecks/GPTOSSStageChecks.swift" -o "$task_build/check"
"$task_build/check" "$task_fixtures"
