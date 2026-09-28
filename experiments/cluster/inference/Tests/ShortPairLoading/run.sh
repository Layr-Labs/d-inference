#!/bin/bash
set -euo pipefail

if [[ $# -gt 1 ]]; then
  printf '%s\n' 'Usage: run.sh [production ClusterInference source directory]' >&2
  exit 2
fi

test_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source_dir="${1:-$test_dir/../../Sources/ClusterInference}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-short-pair-loading-checks.XXXXXX")"
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
  "$source_dir/QwenDenseProfileTypes.swift" \
  "$source_dir/QwenDenseRegisteredSpecification.swift" \
  "$source_dir/QwenDenseStateBudget.swift" \
  "$source_dir/QwenDenseStorageRequirement.swift" \
  "$source_dir/QwenRegisteredDenseModelProfile.swift" \
  "$source_dir/CanonicalJSON.swift" \
  "$source_dir/QwenDenseLegacySourceBounds.swift" \
  "$source_dir/QwenDenseObservedSource.swift" \
  "$source_dir/QwenDenseObservedStage.swift" \
  "$source_dir/QwenLayerStageInventoryTypes.swift" \
  "$source_dir/QwenCheckpointManifestPin.swift" \
  "$source_dir/VerifiedCheckpoint.swift" \
  "$source_dir/CheckpointAlignedReadAccounting.swift" \
  "$source_dir/CheckpointAlignedReader.swift" \
  "$source_dir/QwenLongPrefillArithmeticEnvironment.swift" \
  "$source_dir/QwenDenseConstructorAdmission.swift" \
  "$test_dir/../LayerStageCandidates/TestSupport.swift" \
  "$test_dir/../ObservedDenseLoader/ObservedCheckSupport.swift" \
  "$source_dir/QwenDenseStageLoadBudget.swift" \
  "$source_dir/QwenDenseStageLoadPolicy.swift" \
  "$source_dir/QwenLayerStageSchedule.swift" \
  "$source_dir/QwenLayerStageRecordedRequest.swift" \
  "$source_dir/QwenDenseShortLedgerTypes.swift" \
  "$source_dir/QwenDenseShortStateLedger.swift" \
  "$source_dir/QwenDenseShortFusionLedger.swift" \
  "$source_dir/QwenDenseShortWorkspaceLedger.swift" \
  "$source_dir/QwenDenseShortRequestLedger.swift" \
  "$source_dir/QwenDenseShortReferenceAdmission.swift" \
  "$test_dir/../ObservedDenseLoader/ObservedStageFixture.swift" \
  "$source_dir/QwenDenseShortPairLoadBudget.swift" \
  "$source_dir/QwenDenseShortPairResourcePolicy.swift" \
  "$test_dir/ShortPairLoadCheck.swift" \
  "$test_dir/ShortPairLoadCheckMain.swift" \
  -o "$check_dir/check"
"$check_dir/check" < "$test_dir/../RegisteredDenseProfiles/retained-inputs.json"
