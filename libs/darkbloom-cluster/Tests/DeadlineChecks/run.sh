#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_repo="$(cd "$task_root/../.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/distributed-deadline.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/Requests/DistributedRequestDeadlineContext.swift" \
  "$task_root/Tests/DeadlineChecks/DeadlineContextCheck.swift" -o "$task_build/check"
"$task_build/check"
