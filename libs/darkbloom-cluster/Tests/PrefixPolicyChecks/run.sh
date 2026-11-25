#!/bin/bash
# The prompt-prefix tiers' model-free decisions (QwenStagePrefixDiskPolicy) and
# the SSD tier's configuration, from the runtime's actual sources, compiled
# without MLX: which restore failure deletes a record, whose record a header
# is, and the bounds derived from the Mac's memory and the plan's stop margin.
# No model, no GPU, no disk records. A few seconds.
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
prefix="$task_root/Sources/DarkbloomClusterRuntime/Models/Qwen/Prefix"
source "$task_root/Tests/Support/check-phases.sh"
check_build_directory task_build "${TMPDIR:-/tmp}/cluster-prefix-policy.XXXXXX"
compile_checks() {
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0" -parse-as-library \
    "$task_root/Sources/DarkbloomClusterProtocol/ClusterForcedExitBounds.swift" \
    "$task_root/Sources/DarkbloomClusterRuntime/Support/ClusterRuntimeError.swift" \
    "$prefix/QwenStagePrefixDiskPolicy.swift" "$prefix/QwenStagePrefixDiskConfiguration.swift" \
    "$task_root/Tests/PrefixPolicyChecks/PrefixPolicyCheck.swift" -o "$task_build/prefix-policy-check"
}
check_phases compile_checks
"$task_build/prefix-policy-check"
