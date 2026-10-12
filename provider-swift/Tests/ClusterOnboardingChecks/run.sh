#!/bin/bash
# Model-free checks of the leader-first onboarding (`darkbloom cluster`): the
# pairing state machine and both sides' flows on a real pseudo-terminal with
# scripted operations. Plain swiftc, no provider build, no network, no model.
# ONBOARDING_TRANSCRIPTS=/ABS/DIR keeps each flow's exact screen text there.
set -euo pipefail
task_provider="$(cd "$(dirname "$0")/../.." && pwd)"
task_sources="$task_provider/Sources/ProviderCore/Inference/Distributed/Onboarding"
task_build="$(mktemp -d "$task_provider/.cluster-onboarding.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  "$task_sources/ClusterOnboardingFlow.swift" "$task_sources/ClusterOnboardingTerminal.swift" \
  "$task_provider/Tests/ClusterOnboardingChecks/OnboardingChecks.swift" -o "$task_build/onboarding-checks"
"$task_build/onboarding-checks"
