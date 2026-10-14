#!/bin/bash
# Model-free checks of the derived control leader: derivation from synthetic 2-4 member profiles, restarts,
# forwarding to the current leader, failover at lease expiry, degraded serving alone, re-forming on return and
# split-brain refusal. Plain swiftc, no provider build, no network, no model.
set -euo pipefail
task_provider="$(cd "$(dirname "$0")/../.." && pwd)"
task_sources="$task_provider/Sources/ProviderCore/Inference/Distributed/Onboarding"
task_build="$(mktemp -d "$task_provider/.cluster-control.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  "$task_sources/ClusterControlLeadership.swift" "$task_sources/ClusterOnboardingFlow.swift" \
  "$task_provider/Tests/ClusterControlChecks/ControlChecks.swift" -o "$task_build/control-checks"
"$task_build/control-checks"
