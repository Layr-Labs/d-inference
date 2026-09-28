#!/bin/bash
set -euo pipefail
if [[ $# -gt 1 ]]; then
  printf '%s\n' 'Usage: run.sh [production ClusterInference source directory]' >&2
  exit 2
fi
test_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source_dir="${1:-$test_dir/../../Sources/ClusterInference}"
tool_dir="$test_dir/../../Tools/LayerStageCandidates"
support_dir="$source_dir/../../Tests/LayerStageCandidates"
input_file="$source_dir/../../Tests/RegisteredDenseProfiles/retained-inputs.json"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-candidate-export-check.XXXXXX")"
trap 'rm -rf -- "$check_dir"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors \
  "$source_dir/WorkerJSONScanner.swift" \
  "$source_dir/BoundedProbeInput.swift" \
  "$source_dir/QwenLayerStageMetadata.swift" \
  "$source_dir/QwenLayerStagePlan.swift" \
  "$source_dir/QwenLayerStageCandidates.swift" \
  "$support_dir/TestSupport.swift" \
  "$tool_dir/CandidateExportTypes.swift" \
  "$tool_dir/CandidateExportJSON.swift" \
  "$tool_dir/CandidateExport.swift" \
  "$tool_dir/CandidateExportInput.swift" \
  "$tool_dir/CandidateExportCLI.swift" \
  "$support_dir/CandidateFixture.swift" \
  "$test_dir/CandidateExportCheck.swift" \
  "$test_dir/main.swift" -o "$check_dir/check"
"$check_dir/check" < "$input_file"
