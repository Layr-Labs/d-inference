#!/bin/bash
set -euo pipefail
task_root="$(cd "$(dirname "$0")/.." && pwd)"
check_directory="$(mktemp -d "${TMPDIR:-/tmp}/benchmark-prefill-policy.XXXXXX")"
trap 'rm -rf "$check_directory"' EXIT
swiftc -swift-version 6 -warnings-as-errors \
  "$task_root/proposed/libs/darkbloom-cluster-worker/Sources/DarkbloomClusterWorker/BenchmarkPrefillPolicy.swift" \
  "$task_root/Tests/BenchmarkPrefillPolicyCheck.swift" \
  -o "$check_directory/check"
"$check_directory/check"
