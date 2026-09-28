#!/bin/bash
set -euo pipefail
if [[ $# -gt 1 ]]; then
  printf '%s\n' 'Usage: run.sh [production ClusterInference source directory]' >&2
  exit 2
fi
test_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source_dir="${1:-$test_dir/../../Sources/ClusterInference}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-dense-profile-checks.XXXXXX")"
trap 'rm -rf -- "$check_dir"' EXIT
xcrun swiftc -warnings-as-errors \
  "$source_dir/WorkerJSONScanner.swift" \
  "$source_dir/BoundedProbeInput.swift" \
  "$source_dir/QwenLayerStageMetadata.swift" \
  "$source_dir/QwenLayerStagePlan.swift" \
  "$source_dir/QwenLayerStageCandidates.swift" \
  "$source_dir/QwenLongPrefillTensorBudget.swift" \
  "$source_dir/QwenRegistered9BLongPrefillAdmission.swift" \
  "$source_dir/QwenLongPrefillStageCut.swift" \
  "$source_dir/QwenDenseProfileTypes.swift" \
  "$source_dir/QwenRegisteredDenseModelProfile.swift" \
  "$source_dir/QwenDenseRegisteredSpecification.swift" \
  "$source_dir/QwenDenseStorageRequirement.swift" \
  "$source_dir/QwenDenseStateBudget.swift" \
  "$source_dir/QwenDenseResourcePlanning.swift" \
  "$test_dir/../LayerStageCandidates/TestSupport.swift" \
  "$test_dir/QwenRegisteredDenseProfileCheck.swift" \
  "$test_dir/ProfileCheckMain.swift" -o "$check_dir/check"
"$check_dir/check" < "$test_dir/retained-inputs.json"
