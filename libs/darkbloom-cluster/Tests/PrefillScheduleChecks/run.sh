#!/bin/bash
set -euo pipefail
task_package="$(cd "$(dirname "$0")/../.." && pwd)"
task_runtime="$task_package/Sources/DarkbloomClusterRuntime"
task_repo="$(cd "$task_package/../.." && pwd)"
task_worker="$task_package/../darkbloom-cluster-worker/Sources/DarkbloomClusterWorker"
task_fixtures="$task_package/Tests/PrefillScheduleChecks"
task_bootstrap_tests="$task_package/Tests/BootstrapChecks/Channel"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-prefill-schedule.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_flags=(-swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0")
task_links=(-I "$task_build" -L "$task_build" -Xlinker -rpath -Xlinker "$task_build")
xcrun swiftc "${task_flags[@]}" -emit-library -emit-module -module-name DarkbloomClusterProtocol \
  -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
  "$task_package"/Sources/DarkbloomClusterProtocol/*.swift -o "$task_build/libDarkbloomClusterProtocol.dylib"
xcrun swiftc "${task_flags[@]}" -parse-as-library "${task_links[@]}" -lDarkbloomClusterProtocol \
  "$task_runtime/ClusterRuntimeError.swift" "$task_runtime/QwenLongPrefillTensorBudget.swift" \
  "$task_runtime/QwenGenerationPrefillPolicy.swift" "$task_runtime/QwenGenerationPrefillAllowance.swift" \
  "$task_runtime/QwenResidentPrefillSelection.swift" \
  "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/DistributedInstalledPrefillSelection.swift" \
  "$task_fixtures/NativePrefillSelectionCheck.swift" \
  -o "$task_build/schedule-check"
"$task_build/schedule-check" "$task_package/Tests/CapabilityChecks/Fixtures/registered-qwen35-9b.capability.json"
xcrun swiftc "${task_flags[@]}" -emit-library -emit-module -module-name DarkbloomClusterBootstrap \
  -emit-module-path "$task_build/DarkbloomClusterBootstrap.swiftmodule" \
  "$task_package"/Sources/DarkbloomClusterBootstrap/*.swift -o "$task_build/libDarkbloomClusterBootstrap.dylib"
xcrun swiftc "${task_flags[@]}" -emit-library -emit-module -module-name DarkbloomClusterRuntime \
  -emit-module-path "$task_build/DarkbloomClusterRuntime.swiftmodule" "${task_links[@]}" -lDarkbloomClusterProtocol \
  "$task_bootstrap_tests/LoadConfiguration.swift" -o "$task_build/libDarkbloomClusterRuntime.dylib"
xcrun swiftc "${task_flags[@]}" -parse-as-library "${task_links[@]}" \
  -lDarkbloomClusterProtocol -lDarkbloomClusterRuntime -lDarkbloomClusterBootstrap \
  "$task_worker/WorkerConfiguration.swift" "$task_worker/WorkerBootstrapConfiguration.swift" \
  "$task_bootstrap_tests/WorkerBootstrapAdmissionCheck.swift" -o "$task_build/worker-check"
"$task_build/worker-check"
