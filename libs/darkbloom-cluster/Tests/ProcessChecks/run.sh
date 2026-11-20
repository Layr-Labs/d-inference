#!/bin/bash
# Process ownership checks, including the provider pipe-contract suites
# against the ACTUAL staged ProviderCore Distributed sources with explicit
# MLXLMCommon contract value stand-ins (no MLX runtime).
set -euo pipefail
task_root="$(cd "$(dirname "$0")/../.." && pwd)"
task_protocol="$task_root/Sources/DarkbloomClusterProtocol"
task_repo="$(cd "$task_root/../.." && pwd)"
source "$task_root/Tests/Support/check-phases.sh"
check_build_directory task_build "${TMPDIR:-/tmp}/cluster-worker-owner.XXXXXX"
task_target="$(uname -m)-apple-macos14.0"
# Every binary first; the checks then run in their order below.
compile_checks() {
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
    -module-name DarkbloomClusterBootstrap -emit-module-path "$task_build/DarkbloomClusterBootstrap.swiftmodule" \
    "$task_root"/Sources/DarkbloomClusterBootstrap/*.swift -o "$task_build/libDarkbloomClusterBootstrap.dylib"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
    -module-name DarkbloomClusterProtocol -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
    "$task_protocol"/*.swift -o "$task_build/libDarkbloomClusterProtocol.dylib"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker "$task_build" \
    -module-name DarkbloomClusterProcess -emit-module-path "$task_build/DarkbloomClusterProcess.swiftmodule" \
    "$task_root"/Sources/DarkbloomClusterProcess/*.swift -o "$task_build/libDarkbloomClusterProcess.dylib"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker "$task_build" \
    -lDarkbloomClusterBootstrap \
    "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/FakeClusterWorker.swift" -o "$task_build/fake-worker"
  if [[ "${1:-}" == "--compile-only" ]]; then exit 0; fi
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/WorkerOwnerTests.swift" -o "$task_build/check"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Tests/ProcessChecks/TensorAssistantReadinessCheck.swift" -o "$task_build/assistant-readiness-check"
  # Focused actual child/owner checks without the provider contract stand-ins.
  if [[ "${1:-}" == "--owner-only" ]]; then return; fi
  if [[ -n "${PROCESS_CHECKS_LONG_SECONDS:-}" ]]; then
    xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
      -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
      -Xlinker -rpath -Xlinker "$task_build" \
      "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/LongSessionCheck.swift" -o "$task_build/long-session"
  fi
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/RetirementPolicyTests.swift" -o "$task_build/retirement-check"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/EndpointOwnershipTests.swift" -o "$task_build/endpoint-check"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/PartialAdmissionTests.swift" -o "$task_build/partial-check"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/CleanStopTests.swift" -o "$task_build/clean-stop-check"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/OrphanWiredCheck.swift" -o "$task_build/orphan-wired-check"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/Support/LaunchStates.swift" "$task_root/Tests/ProcessChecks/LaunchVerificationCheck.swift" -o "$task_build/launch-verification-check"

  # The pipe owner asks the request router (DarkbloomClusterPlacement) for each request's route.
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker "$task_build" \
    -module-name DarkbloomClusterPlacement -emit-module-path "$task_build/DarkbloomClusterPlacement.swiftmodule" \
    "$task_root"/Sources/DarkbloomClusterPlacement/*.swift -o "$task_build/libDarkbloomClusterPlacement.dylib"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
    -module-name MLXLMCommon -emit-module-path "$task_build/MLXLMCommon.swiftmodule" \
    "$task_root/Tests/ProcessChecks/MLXLMCommonContractValues.swift" -o "$task_build/libMLXLMCommon.dylib"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -emit-library -emit-module \
    -I "$task_build" -L "$task_build" -lMLXLMCommon -lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterPlacement \
    -Xlinker -rpath -Xlinker "$task_build" \
    -module-name ProviderPipeContract -emit-module-path "$task_build/ProviderPipeContract.swiftmodule" \
    "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/Requests/DistributedRequestDeadlineContext.swift" \
    "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/DistributedResidentExecution.swift" \
    "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/Placement/ClusterModelFeaturePolicy.swift" \
    "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/DistributedPipeExecutionOwner.swift" \
    "$task_root/Tests/ProcessChecks/ClusterConfigurationErrorStandIn.swift" \
    -o "$task_build/libProviderPipeContract.dylib"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lMLXLMCommon -lProviderPipeContract -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/ProviderPipeContractTests.swift" -o "$task_build/provider-check"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lMLXLMCommon -lProviderPipeContract -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/ProviderDeadlinePipeCheck.swift" -o "$task_build/deadline-check"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lMLXLMCommon -lProviderPipeContract -lDarkbloomClusterProtocol -lDarkbloomClusterProcess \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Tests/ProcessChecks/FixtureIdentity.swift" "$task_root/Tests/ProcessChecks/ProviderCleanStopPipeCheck.swift" -o "$task_build/clean-stop-pipe-check"

  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterBootstrap \
    -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root/Tests/ProcessChecks/PumpFixtureIdentity.swift" "$task_root/Tests/ProcessChecks/FakeClusterWorker.swift" -o "$task_build/wakeup-fake-worker"
  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker "$task_build" \
    "$task_root"/Sources/DarkbloomClusterProcess/*.swift \
    "$task_root/Tests/ProcessChecks/PumpFixtureIdentity.swift" "$task_root/Tests/ProcessChecks/PumpWakeupCheck.swift" -o "$task_build/wakeup-check"

  xcrun swiftc -swift-version 6 -warnings-as-errors -target "$task_target" -parse-as-library \
    "$task_root/Sources/DarkbloomClusterProcess/ClusterDeviceExclusion.swift" \
    "$task_root/Tests/ProcessChecks/DeviceExclusionCheck.swift" -o "$task_build/device-exclusion-check"
}
check_phases compile_checks "$@"
"$task_build/check" "$task_build/fake-worker"
"$task_build/assistant-readiness-check"
# Focused actual child/owner checks without the provider contract stand-ins.
if [[ "${1:-}" == "--owner-only" ]]; then exit 0; fi
if [[ -n "${PROCESS_CHECKS_LONG_SECONDS:-}" ]]; then
  "$task_build/long-session" "$task_build/fake-worker" "$PROCESS_CHECKS_LONG_SECONDS"
fi
"$task_build/retirement-check" "$task_build/fake-worker"
"$task_build/endpoint-check" "$task_build/fake-worker"
"$task_build/partial-check" "$task_build/fake-worker"
"$task_build/clean-stop-check" "$task_build/fake-worker"
"$task_build/orphan-wired-check"
"$task_build/launch-verification-check"
"$task_build/provider-check" "$task_build/fake-worker"
"$task_build/deadline-check" "$task_build/fake-worker"
"$task_build/clean-stop-pipe-check" "$task_build/fake-worker"
"$task_build/wakeup-check" "$task_build/wakeup-fake-worker"
"$task_build/device-exclusion-check"
# Swift Testing calibration ownership checks are not a canonical Package.swift
# test target. Run the complete CPU closure and retain its failure receipts.
python3 -B "$task_root/Tests/ProcessChecks/run-calibration-tests.py"
printf '%s\n' '{"passed":true,"providerPipeContract":"actual-provider-sources","calibrationSwiftTesting":true,"networkUsed":false}'
