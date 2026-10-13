#!/bin/bash
# Model-free checks of cluster model provisioning: manifest verification, the copy-or-download decision, the
# receiver (uncached staged writes, resume, digest refusal, single-link refusal, free-disk refusal, atomic rename)
# and the copy frames. Plain swiftc, temporary folders, no provider build, no network, no model.
set -euo pipefail
task_provider="$(cd "$(dirname "$0")/../.." && pwd)"
task_sources="$task_provider/Sources/ProviderCore/Inference/Distributed/Onboarding"
task_build="$(mktemp -d "$task_provider/.cluster-provisioning.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  "$task_sources/ClusterModelProvisioning.swift" \
  "$task_provider/Tests/ClusterModelProvisioningChecks/ProvisioningChecks.swift" -o "$task_build/provisioning-checks"
TMPDIR="$task_build" "$task_build/provisioning-checks"
