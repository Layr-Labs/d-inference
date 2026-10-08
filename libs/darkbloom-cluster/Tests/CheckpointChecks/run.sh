#!/bin/bash
# Checkpoint verification checks: compiles the model-free Runtime closure
# (stage metadata, manifest schema, verified checkpoint, aligned reader) with
# Swift 6 and warnings as errors, then runs real-file checks: manifest
# agreement/refusal, descriptor pinning, tamper detection, aligned reads,
# EINTR retry, short-read refusal. No model, no GPU, no MLX, no network.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-checkpoint.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
target="$(uname -m)-apple-macos14.0"
R="$task_root/Sources/DarkbloomClusterRuntime"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$target" \
  -enable-testing -emit-library -emit-module -module-name DarkbloomClusterRuntimeChecks \
  -emit-module-path "$task_build/DarkbloomClusterRuntimeChecks.swiftmodule" \
  "$R/Support/WorkerJSONScanner.swift" \
  "$R/Support/BoundedProbeInput.swift" \
  "$R/Models/Qwen/Metadata/QwenLayerStageMetadata.swift" \
  "$R/Models/Qwen/Metadata/QwenLayerStagePlan.swift" \
  "$R/Models/Qwen/Metadata/QwenDenseProfileTypes.swift" \
  "$R/Models/Qwen/Resources/QwenLongPrefillTensorBudget.swift" \
  "$R/Support/CanonicalJSON.swift" \
  "$R/Support/ClusterMetadataHashing.swift" \
  "$R/Support/ClusterRuntimeError.swift" \
  "$R/Models/Metadata/LayerStageTensorMetadata.swift" \
  "$R/Models/Metadata/LayerStageStorageConservation.swift" \
  "$R/Models/Metadata/LayerStageCapturedTensorHeaders.swift" \
  "$R/Models/Gemma/Gemma4TextMetadata.swift" \
  "$R/Models/Gemma/Gemma4TensorInventory.swift" \
  "$R/Models/Gemma/Gemma4ArtifactMetadata.swift" \
  "$R/Models/Gemma/Gemma4StageConstructionDescriptor.swift" \
  "$R/Models/Gemma/Gemma4LayerStagePlan.swift" \
  "$R/Checkpoints/CheckpointManifest.swift" \
  "$R/Checkpoints/VerifiedCheckpoint.swift" \
  "$R/Checkpoints/CheckpointAlignedReader.swift" \
  "$R/Checkpoints/CheckpointAlignedReadAccounting.swift" \
  "$R/Models/Qwen/Loading/QwenCheckpointManifestPin.swift" \
  -o "$task_build/libDarkbloomClusterRuntimeChecks.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library -target "$target" \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterRuntimeChecks \
  -Xlinker -rpath -Xlinker "$task_build" \
  "$task_root/Tests/CheckpointChecks/main.swift" -o "$task_build/check"
"$task_build/check"
