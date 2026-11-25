#!/bin/bash
set -euo pipefail
task_draft="$(cd "$(dirname "$0")/.." && pwd)"
task_repo="/Users/developer/DarkbloomDev/d-inference"
task_runtime="$task_draft/proposed/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime"
task_base="$task_repo/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/prefill-window.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  "$task_base/ClusterRuntimeError.swift" "$task_base/QwenLongPrefillTensorBudget.swift" \
  "$task_runtime/QwenGenerationPrefillPolicy.swift" "$task_runtime/QwenGenerationPrefillAllowance.swift" \
  "$task_draft/Tests/PrefillWindowCheck.swift" -o "$task_build/PrefillWindowCheck"
"$task_build/PrefillWindowCheck"
