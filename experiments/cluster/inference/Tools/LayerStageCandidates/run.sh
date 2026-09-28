#!/bin/bash
set -euo pipefail
if [[ $# -ne 8 ]]; then
  printf '%s\n' 'Usage: run.sh --config FILE --config-sha256 SHA256 --canonical-names FILE --canonical-names-sha256 SHA256' >&2
  exit 2
fi
tool_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source_dir="${CLUSTER_INFERENCE_SOURCE_DIR:-$tool_dir/../../Sources/ClusterInference}"
support_dir="$source_dir/../../Tests/LayerStageCandidates"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-candidate-export.XXXXXX")"
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
  "$tool_dir/main.swift" -o "$check_dir/export"
"$check_dir/export" "$@"
