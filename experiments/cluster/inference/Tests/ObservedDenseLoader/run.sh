#!/bin/bash
set -euo pipefail
if [[ $# -gt 1 ]]; then
  printf '%s\n' 'Usage: run.sh [production ClusterInference source directory]' >&2
  exit 2
fi
test_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source_dir="${1:-$test_dir/../../Sources/ClusterInference}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-observed-loader-checks.XXXXXX")"
trap 'rm -rf -- "$check_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
  "$source_dir/WorkerJSONScanner.swift" \
  "$source_dir/BoundedProbeInput.swift" \
  "$source_dir/QwenLayerStageMetadata.swift" \
  "$source_dir/QwenLayerStagePlan.swift" \
  "$source_dir/QwenLayerStageCandidates.swift" \
  "$source_dir/QwenLongPrefillTensorBudget.swift" \
  "$source_dir/QwenRegistered9BLongPrefillAdmission.swift" \
  "$source_dir/QwenLongPrefillStageCut.swift" \
  "$test_dir/../LayerStageCandidates/TestSupport.swift" \
  "$source_dir/QwenDenseProfileTypes.swift" \
  "$source_dir/QwenDenseRegisteredSpecification.swift" \
  "$source_dir/QwenDenseResourcePlanning.swift" \
  "$source_dir/QwenDenseStateBudget.swift" \
  "$source_dir/QwenDenseStorageRequirement.swift" \
  "$source_dir/QwenRegisteredDenseModelProfile.swift" \
  "$source_dir/CanonicalJSON.swift" \
  "$source_dir/QwenDenseLegacySourceBounds.swift" \
  "$source_dir/QwenDenseObservedSource.swift" \
  "$source_dir/QwenDenseObservedStage.swift" \
  "$source_dir/QwenLayerStageInventoryTypes.swift" \
  "$source_dir/QwenCheckpointManifestPin.swift" \
  "$test_dir/ObservedCheckMain.swift" \
  "$test_dir/ObservedCheckSupport.swift" \
  "$test_dir/ObservedLegacyCheck.swift" \
  "$test_dir/ObservedManifestPinCheck.swift" \
  "$test_dir/ObservedRegisteredSourceCheck.swift" \
  "$test_dir/ObservedStageCheck.swift" \
  "$test_dir/ObservedStageFixture.swift" \
  "$test_dir/ObservedCheckpointConstructorCheck.swift" \
  "$source_dir/VerifiedCheckpoint.swift" \
  -o "$check_dir/check"
"$check_dir/check" < "$test_dir/../RegisteredDenseProfiles/retained-inputs.json"
