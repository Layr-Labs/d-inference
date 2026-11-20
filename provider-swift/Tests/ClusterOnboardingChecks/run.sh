#!/bin/bash
# Model-free checks of the leader-first onboarding (`darkbloom cluster`): the
# pairing state machine and both sides' flows on a real pseudo-terminal with
# scripted operations. Plain swiftc, no provider build, no network, no model.
# Each group of checks runs in its own process, one per core at a time (ONBOARDING_JOBS=N sets N), and its seconds are
# printed as it ends. `run.sh --list` names the groups; `run.sh --group NAME` runs one alone.
# ONBOARDING_TRANSCRIPTS=/ABS/DIR keeps each flow's exact screen text there.
set -euo pipefail
task_provider="$(cd "$(dirname "$0")/../.." && pwd)"
task_sources="$task_provider/Sources/ProviderCore/Inference/Distributed/Onboarding"
task_build="$(mktemp -d "$task_provider/.cluster-onboarding.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  "$task_sources/ClusterOnboardingFlow.swift" "$task_sources/ClusterOnboardingTerminal.swift" \
  "$task_sources/ClusterOnboardingBrand.swift" "$task_sources/ClusterOnboardingPairServing.swift" \
  "$task_sources/ClusterOnboardingFollow.swift" "$task_sources/ClusterOnboardingLeaderStep.swift" \
  "$task_sources/ClusterOnboardingSoloServing.swift" \
  "$task_provider/Tests/ClusterOnboardingChecks/VersionSplitChecks.swift" \
  "$task_provider/Tests/ClusterOnboardingChecks/WaitHonestChecks.swift" \
  "$task_sources/ClusterOnboardingStartProgress.swift" \
  "$task_provider/Tests/ClusterOnboardingChecks/OnboardingChecks.swift" "$task_provider/Tests/ClusterOnboardingChecks/FollowWaitChecks.swift" \
  "$task_provider/Tests/ClusterOnboardingChecks/StartProgressChecks.swift" \
  "$task_provider/Tests/ClusterOnboardingChecks/FollowFinalChecks.swift" "$task_provider/Tests/ClusterOnboardingChecks/NoFalseCrossChecks.swift" \
  "$task_provider/Tests/ClusterOnboardingChecks/RoleHeaderChecks.swift" \
  "$task_provider/Tests/ClusterOnboardingChecks/StepFoldChecks.swift" \
  "$task_provider/Tests/ClusterOnboardingChecks/SimplerOnboardingChecks.swift" \
  "$task_provider/Tests/ClusterOnboardingChecks/GroupRunner.swift" -o "$task_build/onboarding-checks"
echo "onboarding checks: compiled in ${SECONDS} s"
"$task_build/onboarding-checks" "$@"
