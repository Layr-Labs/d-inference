#!/bin/bash
set -euo pipefail
base="$(cd -- "$(dirname -- "$0")/.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/dense-resource-check.XXXXXX")"
trap 'rm -rf -- "$build"' EXIT
sources=(WorkerJSONScanner BoundedProbeInput QwenLayerStageMetadata QwenLayerStagePlan
    QwenLayerStageCandidates QwenLongPrefillTensorBudget QwenRegistered9BLongPrefillAdmission
    QwenLongPrefillStageCut QwenDenseProfileTypes
    QwenDenseRegisteredSpecification QwenDenseStorageRequirement QwenDenseStateBudget
    QwenDenseResourcePlanning)
args=()
for source in "${sources[@]}"; do args+=("$base/baseline/$source.swift"); done
xcrun swiftc -warnings-as-errors "${args[@]}" \
    "$base/proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenRegisteredDenseModelProfile.swift" \
    "$base/proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenResidentModelDefinition.swift" \
    "$base/proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/QwenDenseRegisteredResourceProfile.swift" \
    "$base/Tests/TestSupport.swift" "$base/Tests/QwenRegisteredDenseProfileCheck.swift" \
    "$base/Tests/NativeModelProfileCheck.swift" "$base/Tests/ResourceProfileCheck.swift" -o "$build/check"
"$build/check" < "$base/Tests/retained-inputs.json"
