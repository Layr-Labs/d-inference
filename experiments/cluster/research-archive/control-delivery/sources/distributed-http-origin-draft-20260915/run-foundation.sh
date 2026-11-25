#!/bin/bash
set -euo pipefail
if [[ $# != 1 || -e "$1" ]]; then echo 'usage: run-foundation.sh NEW_OUTPUT_DIRECTORY' >&2; exit 64; fi
task_root="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$1"
task_build="$(cd "$1" && pwd)"
task_distributed="$task_root/proposed/provider-swift/Sources/ProviderCore/Inference/Distributed"
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  "$task_root/upstream/DistributedRequestDeadlineContext.swift" \
  "$task_distributed/DistributedRequestOrigin.swift" \
  "$task_distributed/DistributedFirstTokenBudgetPolicy.swift" \
  "$task_root/Tests/FoundationCheck.swift" -o "$task_build/foundation-check"
"$task_build/foundation-check"
