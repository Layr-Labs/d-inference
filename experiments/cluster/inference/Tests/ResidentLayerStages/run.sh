#!/bin/bash
set -euo pipefail
if [[ $# -gt 1 ]]; then
  printf '%s\n' 'Usage: run.sh [production ClusterInference source directory]' >&2
  exit 2
fi
test_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
source_dir="${1:-$test_dir/../../Sources/ClusterInference}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-resident-stage-checks.XXXXXX")"
trap 'rm -rf -- "$check_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 6 -warnings-as-errors \
  "$source_dir/QwenLayerStageResidentLifecycle.swift" \
  "$test_dir/QwenLayerStageResidentFakeOwner.swift" \
  "$test_dir/QwenLayerStageResidentLifecycleCheck.swift" \
  "$test_dir/QwenLayerStageResidentOverlapCheck.swift" -o "$check_dir/check"
"$check_dir/check"
