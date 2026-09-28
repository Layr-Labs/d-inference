#!/bin/bash
set -euo pipefail
if [[ $# -gt 1 ]]; then
  printf '%s\n' 'Usage: run.sh [production ClusterInference source directory]' >&2
  exit 2
fi
test_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source_dir="${1:-$test_dir/../../Sources/ClusterInference}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-candidate-checks.XXXXXX")"
trap 'rm -rf -- "$check_dir"' EXIT
xcrun swiftc \
  "$source_dir/WorkerJSONScanner.swift" \
  "$source_dir/BoundedProbeInput.swift" \
  "$source_dir/QwenLayerStageMetadata.swift" \
  "$source_dir/QwenLayerStagePlan.swift" \
  "$source_dir/QwenLayerStageCandidates.swift" \
  "$test_dir/TestSupport.swift" "$test_dir/CandidateFixture.swift" \
  "$test_dir/CandidateOwnershipCheck.swift" "$test_dir/CandidateRejectionCheck.swift" \
  "$test_dir/QwenStageOutputGateMetadataCheck.swift" \
  "$test_dir/main.swift" -o "$check_dir/check"
"$check_dir/check"
