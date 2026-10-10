#!/bin/bash
# Placement checks: compiles the placement target, the host memory gate's own
# policy file and the dense Qwen family's pure metadata closure with Swift 6
# and warnings as errors, then checks that the device profile's reduction of
# the gate is exact, that layouts conserve an artifact's bytes and reproduce
# figures real loads recorded, that the planner places every constructed
# device mix it can and refuses exactly when nothing fits, and that speed
# estimates are ranked and labelled. Constructed Macs and retained header
# metadata only: no model, no GPU, no MLX, no network. A pass here is not a
# hardware pass.
set -euo pipefail
task_package="$(cd "$(dirname "$0")/../.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-placement.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
R="$task_package/Sources/DarkbloomClusterRuntime"
task_flags=(-swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0")
task_links=(-I "$task_build" -L "$task_build" -Xlinker -rpath -Xlinker "$task_build")
xcrun swiftc -j 4 "${task_flags[@]}" -emit-library -emit-module -module-name DarkbloomClusterProtocol \
  -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
  -Xlinker -install_name -Xlinker @rpath/libDarkbloomClusterProtocol.dylib \
  "$task_package"/Sources/DarkbloomClusterProtocol/*.swift -o "$task_build/libDarkbloomClusterProtocol.dylib"
xcrun swiftc -j 4 "${task_flags[@]}" -emit-library -emit-module -module-name DarkbloomClusterPlacement \
  -emit-module-path "$task_build/DarkbloomClusterPlacement.swiftmodule" "${task_links[@]}" -lDarkbloomClusterProtocol \
  -Xlinker -install_name -Xlinker @rpath/libDarkbloomClusterPlacement.dylib \
  "$task_package"/Sources/DarkbloomClusterPlacement/*.swift -o "$task_build/libDarkbloomClusterPlacement.dylib"
xcrun swiftc -j 4 "${task_flags[@]}" -parse-as-library "${task_links[@]}" -lDarkbloomClusterProtocol -lDarkbloomClusterPlacement \
  "$R/Support/ClusterRuntimeError.swift" \
  "$R/Support/ClusterMetadataHashing.swift" \
  "$R/Support/CanonicalJSON.swift" \
  "$R/Support/WorkerJSONScanner.swift" \
  "$R/Support/BoundedProbeInput.swift" \
  "$R/Checkpoints/CheckpointAlignedReadAccounting.swift" \
  "$R/Models/Qwen/Resources/QwenLongPrefillTensorBudget.swift" \
  "$R/Models/Qwen/Resources/QwenDenseStageLoadPolicy.swift" \
  "$R/Models/Qwen/Metadata/QwenDenseProfileTypes.swift" \
  "$R/Models/Qwen/Metadata/QwenDenseRegisteredSpecification.swift" \
  "$R/Models/Qwen/Metadata/QwenLayerStageMetadata.swift" \
  "$R/Models/Qwen/Metadata/QwenRoutedExpertStageMetadata.swift" \
  "$R/Models/Qwen/Prism/QwenPrismStageConfiguration.swift" \
  "$R/Models/Qwen/Prism/QwenRegisteredPack.swift" \
  "$R/Models/Nemotron/NemotronStageMetadata.swift" \
  "$R/Models/Nemotron/NemotronLayerStagePlan.swift" \
  "$R/Models/Nemotron/NemotronRegisteredProfile.swift" \
  "$R/Models/Qwen/Resources/QwenDenseStateBudget.swift" \
  "$R/Models/Qwen/Metadata/QwenRegisteredDenseModelProfile.swift" \
  "$R/Models/Qwen/Metadata/QwenDenseStorageRequirement.swift" \
  "$R/Models/Qwen/Metadata/QwenLayerStagePlan.swift" \
  "$R/Models/Qwen/Prefill/QwenLongPrefillArithmeticEnvironment.swift" \
  "$R/Models/Qwen/Prefill/QwenResidentArithmeticPolicy.swift" \
  "$R/Models/Qwen/Generation/QwenLayerStageGenerationRequest.swift" \
  "$R/Models/Qwen/Generation/QwenLayerStageFrame.swift" \
  "$R/Models/Qwen/Generation/QwenLayerStageWireIdentity.swift" \
  "$R/Models/Qwen/Loading/QwenLayerStageCandidates.swift" \
  "$R/Models/Qwen/Resident/QwenResidentModelDefinition.swift" \
  "$R/Models/Qwen/Resident/QwenResidentAdapterDefinition.swift" \
  "$R/Models/Placement/ClusterDeviceMemoryGate.swift" \
  "$R/Models/Placement/QwenDensePlacementFamily.swift" \
  "$R/Models/Placement/ClusterPlacementArtifact.swift" \
  "$R/Models/Placement/ClusterPlacementTool.swift" \
  "$task_package"/Tests/PlacementChecks/*.swift -o "$task_build/check"
"$task_build/check" "$task_package/Tests/StageMetadataChecks/Inputs/qwen-retained-inputs.json"
# PLACEMENT_CHECK_KEEP=/ABS/DIR keeps the built check and its two libraries
# there, for `check tool ...` (see Main.swift).
if [[ -n "${PLACEMENT_CHECK_KEEP:-}" ]]; then
  mkdir -p "$PLACEMENT_CHECK_KEEP"
  cp "$task_build/check" "$task_build"/libDarkbloomCluster*.dylib "$PLACEMENT_CHECK_KEEP/"
  install_name_tool -add_rpath "$PLACEMENT_CHECK_KEEP" "$PLACEMENT_CHECK_KEEP/check" 2>/dev/null || true
fi
