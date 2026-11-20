#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_repo="$(cd "$task_root/../.." && pwd)"
source "$task_root/Tests/Support/check-phases.sh"
check_build_directory task_build "${TMPDIR:-/tmp}/distributed-deadline.XXXXXX"
compile_checks() {
  xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/Requests/DistributedRequestDeadlineContext.swift" \
    "$task_root/Tests/DeadlineChecks/DeadlineContextCheck.swift" -o "$task_build/check"
}
check_phases compile_checks
"$task_build/check"
