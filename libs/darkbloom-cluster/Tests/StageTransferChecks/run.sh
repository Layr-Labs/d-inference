#!/bin/bash
# Stage transfer checks: compiles the model-free Runtime closure of the content
# inventory and the stage transfer plan, control values and state machines with
# Swift 6 and warnings as errors. Checks the inventory's canonical encoding,
# refusals and projections; the plan's arithmetic against retained registered
# metadata; and a sender and a receiver over an in-process link on two tiny
# safetensors files, with wrong bytes, wrong framing, wrong and replayed
# control values, aborts and deadlines. Then checks the registered 9B document
# compiled into the runtime: its pin, the pinned layout inventory, and the
# storage commitments recorded by verified local loads. Last, the independent
# Python script recomputes the tiny artifact's inventory, which must equal the
# Swift document byte for byte. No model, no GPU, no MLX, no network, no
# registered artifact and no real transport.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_repo="$(cd "$task_root/../.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-stage-transfer.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
R="$task_root/Sources/DarkbloomClusterRuntime"
target="$(uname -m)-apple-macos14.0"
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$target" \
  -emit-library -emit-module -module-name DarkbloomClusterProtocol \
  -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
  "$task_root"/Sources/DarkbloomClusterProtocol/*.swift -o "$task_build/libDarkbloomClusterProtocol.dylib"
xcrun swiftc -j 2 -swift-version 6 -warnings-as-errors -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker "$task_build" \
  "$R/Support/ClusterRuntimeError.swift" \
  "$R/Support/ClusterMetadataHashing.swift" \
  "$R/Support/CanonicalJSON.swift" \
  "$R/Support/WorkerJSONScanner.swift" \
  "$R/Support/BoundedProbeInput.swift" \
  "$R/Models/Qwen/Resources/QwenLongPrefillTensorBudget.swift" \
  "$R/Models/Qwen/Metadata/QwenDenseProfileTypes.swift" \
  "$R/Models/Qwen/Metadata/QwenDenseRegisteredSpecification.swift" \
  "$R/Models/Qwen/Metadata/QwenRegistered9BContentInventory.swift" \
  "$R/Models/Qwen/Metadata/QwenRegisteredContentInventory.swift" \
  "$R/Models/Qwen/Metadata/QwenLayerStageMetadata.swift" \
  "$R/Models/Qwen/Metadata/QwenRoutedExpertStageMetadata.swift" \
  "$R/Models/Qwen/Metadata/QwenLayerStagePlan.swift" \
  "$R/Models/Qwen/Prism/QwenPrismStageConfiguration.swift" \
  "$R/Models/Qwen/Prism/QwenRegisteredPack.swift" \
  "$R/Models/Nemotron/NemotronStageMetadata.swift" \
  "$R/Models/Nemotron/NemotronLayerStagePlan.swift" \
  "$R/Models/Metadata/LayerStageTensorMetadata.swift" \
  "$R/Models/Metadata/LayerStageTensorContentInventory.swift" \
  "$R/Checkpoints/CheckpointAlignedReadAccounting.swift" \
  "$R/Models/Qwen/Loading/QwenLayerStageInventoryTypes.swift" \
  "$R/Models/Qwen/Metadata/QwenStageSourceTensorManifest.swift" \
  "$R/Models/Qwen/Transfer/QwenStageTransferPlan.swift" \
  "$R/Models/Qwen/Transfer/QwenStageTransferControl.swift" \
  "$R/Models/Qwen/Transfer/QwenStageTransferSender.swift" \
  "$R/Models/Qwen/Transfer/QwenStageTransferReceiver.swift" \
  "$R/Models/Qwen/Transfer/QwenStageTransferTransport.swift" \
  "$task_root"/Tests/StageTransferChecks/*.swift -o "$task_build/check"
"$task_build/check" "$task_root/Tests/StageMetadataChecks/Inputs/qwen-retained-inputs.json" \
  "$task_repo/libs/darkbloom-cluster-worker/Tests/CapabilityChecks/Fixtures/registered-qwen35-9b.configuration.json" \
  "$task_build"
/usr/bin/python3 "$task_repo/scripts/cluster-stage-content-inventory.py" --model-dir "$task_build/tiny-artifact" \
  --compare "$task_build/tiny-content-inventory.txt"
