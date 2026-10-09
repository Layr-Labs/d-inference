#!/bin/bash
# Nemotron layer-stage metadata checks: compiles the model-free Runtime closure
# (stage metadata, Plan, registered row, profile, storage requirement, resident
# row, arithmetic policy, capability metadata) with Swift 6 and warnings as
# errors, then runs it on the registered configuration and manifest fixtures.
# No model, no GPU, no MLX, no weights, no network.
set -euo pipefail
task_package="$(cd "$(dirname "$0")/../.." && pwd)"
task_runtime="$task_package/Sources/DarkbloomClusterRuntime"
task_fixtures="$task_package/../darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-nemotron-stage.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_flags=(-swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0")
task_links=(-I "$task_build" -L "$task_build" -Xlinker -rpath -Xlinker "$task_build")
xcrun swiftc "${task_flags[@]}" -emit-library -emit-module -module-name DarkbloomClusterProtocol \
  -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
  "$task_package"/Sources/DarkbloomClusterProtocol/*.swift -o "$task_build/libDarkbloomClusterProtocol.dylib"
task_sources=(
  Support/WorkerJSONScanner
  Support/BoundedProbeInput
  Support/ClusterRuntimeError
  Support/CanonicalJSON
  Support/ClusterMetadataHashing
  Models/Qwen/Metadata/QwenLayerStageMetadata
  Models/Qwen/Metadata/QwenRoutedExpertStageMetadata
  Models/Qwen/Metadata/QwenLayerStagePlan
  Models/Nemotron/NemotronStageMetadata
  Models/Nemotron/NemotronLayerStagePlan
  Models/Nemotron/NemotronRegisteredProfile
  Models/Qwen/Resources/QwenLongPrefillTensorBudget
  Models/Qwen/Resources/QwenDenseStateBudget
  Models/Qwen/Metadata/QwenDenseProfileTypes
  Models/Qwen/Metadata/QwenDenseRegisteredSpecification
  Models/Qwen/Metadata/QwenRegisteredDenseModelProfile
  Models/Qwen/Metadata/QwenDenseStorageRequirement
  Models/Qwen/Generation/QwenLayerStageGenerationRequest
  Models/Qwen/Generation/QwenLayerStageFrame
  Models/Qwen/Generation/QwenLayerStageWireIdentity
  Models/Qwen/Prefill/QwenLongPrefillArithmeticEnvironment
  Models/Qwen/Prefill/QwenResidentArithmeticPolicy
  Models/Qwen/Loading/QwenLayerStageCandidates
  Models/Qwen/Resident/QwenResidentModelDefinition
  Models/Qwen/Resident/QwenResidentAdapterDefinition
  Models/Qwen/Resident/QwenResidentCapabilityMetadata
)
task_paths=()
for task_source in "${task_sources[@]}"; do task_paths+=("$task_runtime/$task_source.swift"); done
xcrun swiftc "${task_flags[@]}" -enable-testing -emit-library -emit-module -module-name DarkbloomClusterRuntimeChecks \
  -emit-module-path "$task_build/DarkbloomClusterRuntimeChecks.swiftmodule" "${task_links[@]}" -lDarkbloomClusterProtocol \
  "${task_paths[@]}" -o "$task_build/libDarkbloomClusterRuntimeChecks.dylib"
xcrun swiftc "${task_flags[@]}" -parse-as-library "${task_links[@]}" -lDarkbloomClusterProtocol -lDarkbloomClusterRuntimeChecks \
  "$task_package/Tests/DarkbloomClusterRuntimeTests/NemotronInventoryFixture.swift" \
  "$task_package/Tests/NemotronStageChecks/NemotronStageCheck.swift" -o "$task_build/check"
"$task_build/check" "$task_fixtures"
