#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/distributed-deadline.XXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
 "$task_root/proposed/provider-swift/Sources/ProviderCore/Inference/Distributed/DistributedRequestDeadlineContext.swift" \
 "$task_root/Tests/DeadlineContextCheck.swift" -o "$task_build/check"
"$task_build/check"
