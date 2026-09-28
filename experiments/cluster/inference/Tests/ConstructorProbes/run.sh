#!/bin/bash
set -euo pipefail
if [[ $# -gt 1 ]]; then
  printf '%s\n' 'Usage: run.sh [production ClusterInference source directory]' >&2
  exit 2
fi
test_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source_dir="${1:-$test_dir/../../Sources/ClusterInference}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-constructor-checks.XXXXXX")"
trap 'rm -rf -- "$check_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
  "$source_dir/WorkerJSONScanner.swift" \
  "$source_dir/BoundedProbeInput.swift" \
  "$source_dir/QwenLayerStageMetadata.swift" \
  "$source_dir/QwenLayerStagePlan.swift" \
  "$source_dir/QwenLongPrefillTensorBudget.swift" \
  "$source_dir/QwenDenseProfileTypes.swift" \
  "$source_dir/QwenDenseRegisteredSpecification.swift" \
  "$source_dir/QwenLongPrefillArithmeticEnvironment.swift" \
  "$source_dir/QwenCheckpointManifestPin.swift" \
  "$test_dir/../LayerStageCandidates/TestSupport.swift" \
  "$source_dir/VerifiedCheckpoint.swift" \
  "$source_dir/QwenDenseConstructorAdmission.swift" \
  "$source_dir/QwenDenseConstructorCLI.swift" \
  "$test_dir/ConstructorProbeCheck.swift" \
  "$test_dir/ConstructorProbeCheckMain.swift" \
  -o "$check_dir/check"
"$check_dir/check" < "$test_dir/../RegisteredDenseProfiles/retained-inputs.json"
