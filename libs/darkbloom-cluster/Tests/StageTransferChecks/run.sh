#!/bin/bash
# Stage transfer checks: compiles the model-free Runtime closure of the content
# inventory with Swift 6 and warnings as errors, then checks its canonical
# encoding, its refusals and its two projections against retained registered
# metadata. No model, no GPU, no MLX, no network, no artifact.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-stage-transfer.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
R="$task_root/Sources/DarkbloomClusterRuntime"
xcrun swiftc -j 2 -swift-version 6 -warnings-as-errors -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  "$R/Support/ClusterRuntimeError.swift" \
  "$R/Support/ClusterMetadataHashing.swift" \
  "$R/Support/CanonicalJSON.swift" \
  "$R/Models/Qwen/Resources/QwenLongPrefillTensorBudget.swift" \
  "$R/Models/Qwen/Metadata/QwenDenseProfileTypes.swift" \
  "$R/Models/Metadata/LayerStageTensorMetadata.swift" \
  "$R/Models/Metadata/LayerStageTensorContentInventory.swift" \
  "$R/Checkpoints/CheckpointAlignedReadAccounting.swift" \
  "$R/Models/Qwen/Loading/QwenLayerStageInventoryTypes.swift" \
  "$R/Models/Qwen/Metadata/QwenStageSourceTensorManifest.swift" \
  "$task_root"/Tests/StageTransferChecks/*.swift -o "$task_build/check"
"$task_build/check" "$task_root/Tests/StageMetadataChecks/Inputs/qwen-retained-inputs.json"
