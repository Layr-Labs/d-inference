#!/bin/bash
# Stage transfer checks: compiles the model-free Runtime closure of the content
# inventory and the stage transfer plan, control values and state machines with
# Swift 6 and warnings as errors. Checks the inventory's canonical encoding,
# refusals and projections; the plan's arithmetic against retained registered
# metadata; and a sender and a receiver over an in-process link on two tiny
# safetensors files, with wrong bytes, wrong framing, wrong and replayed
# control values, aborts and deadlines. No model, no GPU, no MLX, no network,
# no artifact and no real transport.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-stage-transfer.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
R="$task_root/Sources/DarkbloomClusterRuntime"
xcrun swiftc -j 2 -swift-version 6 -warnings-as-errors -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  "$R/Support/ClusterRuntimeError.swift" \
  "$R/Support/ClusterMetadataHashing.swift" \
  "$R/Support/CanonicalJSON.swift" \
  "$R/Support/WorkerJSONScanner.swift" \
  "$R/Support/BoundedProbeInput.swift" \
  "$R/Models/Qwen/Resources/QwenLongPrefillTensorBudget.swift" \
  "$R/Models/Qwen/Metadata/QwenDenseProfileTypes.swift" \
  "$R/Models/Qwen/Metadata/QwenLayerStageMetadata.swift" \
  "$R/Models/Qwen/Metadata/QwenLayerStagePlan.swift" \
  "$R/Models/Metadata/LayerStageTensorMetadata.swift" \
  "$R/Models/Metadata/LayerStageTensorContentInventory.swift" \
  "$R/Checkpoints/CheckpointAlignedReadAccounting.swift" \
  "$R/Models/Qwen/Loading/QwenLayerStageInventoryTypes.swift" \
  "$R/Models/Qwen/Metadata/QwenStageSourceTensorManifest.swift" \
  "$R"/Models/Qwen/Transfer/*.swift \
  "$task_root"/Tests/StageTransferChecks/*.swift -o "$task_build/check"
"$task_build/check" "$task_root/Tests/StageMetadataChecks/Inputs/qwen-retained-inputs.json"
