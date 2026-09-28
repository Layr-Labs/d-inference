#!/bin/bash
set -euo pipefail
task_provider="$(cd "$(dirname "$0")/../.." && pwd)"
task_repo="$(cd "$task_provider/.." && pwd)"
task_cluster="$task_repo/libs/darkbloom-cluster"
task_sources="$task_provider/Sources/ProviderCore"
task_fixtures="$task_provider/Tests/ClusterInstalledSessionChecks"
task_diagnostics="$task_provider/Tests/ClusterDiagnosticsChecks"
# The real installed-file policy rejects symlinked path components, including
# /var aliases. Keep the test-owned binaries and files in the checkout tree.
task_build="$(mktemp -d "$task_provider/.cluster-installed-session.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_target="$(uname -m)-apple-macos14.0"
task_flags=(-swift-version 6 -warnings-as-errors -target "$task_target")
task_links=(-I "$task_build" -L "$task_build" -Xlinker -rpath -Xlinker "$task_build")

build_module() {
  local task_name="$1"
  shift
  local task_dependencies=("${task_links[@]}")
  case "$task_name" in
    DarkbloomClusterProcess) task_dependencies+=(-lDarkbloomClusterProtocol) ;;
    DarkbloomClusterRemote) task_dependencies+=(-lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterBootstrap) ;;
    InstalledContract) task_dependencies+=(-lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterBootstrap -lDarkbloomClusterRemote -lMLXLMCommon -lProviderCoreFoundation) ;;
  esac
  xcrun swiftc "${task_flags[@]}" -emit-library -emit-module -enable-testing \
    -module-name "$task_name" -emit-module-path "$task_build/$task_name.swiftmodule" \
    "${task_dependencies[@]}" "$@" \
    -o "$task_build/lib$task_name.dylib" \
    -Xlinker -install_name -Xlinker "@rpath/lib$task_name.dylib"
}

build_module DarkbloomClusterProtocol "$task_cluster"/Sources/DarkbloomClusterProtocol/*.swift
build_module DarkbloomClusterBootstrap "$task_cluster"/Sources/DarkbloomClusterBootstrap/*.swift
build_module DarkbloomClusterProcess "$task_cluster"/Sources/DarkbloomClusterProcess/*.swift
build_module DarkbloomClusterRemote "$task_cluster"/Sources/DarkbloomClusterRemote/*.swift
build_module MLXLMCommon "$task_cluster/Tests/ProcessChecks/MLXLMCommonContractValues.swift"
build_module ProviderCoreFoundation "$task_provider/Sources/ProviderCoreFoundation/Manifest.swift"
build_module InstalledContract \
  "$task_sources/Config/ClusterConfiguration.swift" \
  "$task_sources/Config/ClusterConfigurationCodec.swift" \
  "$task_sources/Config/ClusterConfigurationFiles.swift" \
  "$task_sources/Config/ClusterConfigurationPaths.swift" \
  "$task_sources/Config/ClusterConfigurationStore.swift" \
  "$task_sources/Inference/Distributed/DistributedRequestDeadlineContext.swift" \
  "$task_sources/Inference/Distributed/DistributedResidentExecution.swift" \
  "$task_sources/Inference/Distributed/DistributedPipeExecutionOwner.swift" \
  "$task_sources"/Inference/Distributed/Installed/*.swift \
  "$task_sources"/Inference/Distributed/Diagnostics/ClusterStatusValues.swift \
  "$task_sources"/Inference/Distributed/Diagnostics/ClusterStatusCodec.swift \
  "$task_sources"/Inference/Distributed/Diagnostics/ClusterStatusDiscovery.swift \
  "$task_sources"/Inference/Distributed/Diagnostics/ClusterStatusClient.swift \
  "$task_sources"/Inference/Distributed/Diagnostics/ClusterDeviceJournalObservation.swift

task_fixture_links=("${task_links[@]}" -lDarkbloomClusterProtocol -lDarkbloomClusterBootstrap \
  -lDarkbloomClusterProcess -lDarkbloomClusterRemote -lMLXLMCommon -lProviderCoreFoundation -lInstalledContract)
for task_name in InstalledProbeFixture InstalledFakeOwner InstalledFakeWorker ClusterDiagnosticsCheck; do
  case "$task_name" in
    InstalledProbeFixture) task_inputs=("$task_fixtures/InstalledProbeFixture.swift") ;;
    InstalledFakeOwner) task_inputs=("$task_fixtures/InstalledFixtureIdentity.swift" "$task_fixtures/InstalledFakeOwner.swift") ;;
    InstalledFakeWorker) task_inputs=("$task_fixtures/InstalledFixtureIdentity.swift" "$task_cluster/Tests/ProcessChecks/FakeClusterWorker.swift") ;;
    ClusterDiagnosticsCheck) task_inputs=("$task_fixtures/InstalledFixture.swift" "$task_diagnostics/ClusterDiagnosticsCheck.swift") ;;
  esac
  xcrun swiftc "${task_flags[@]}" -parse-as-library "${task_fixture_links[@]}" \
    "${task_inputs[@]}" -o "$task_build/$task_name"
done

cd "$task_build"
"$task_build/ClusterDiagnosticsCheck" "$task_build/InstalledProbeFixture" \
  "$task_build/InstalledFakeOwner" "$task_build/InstalledFakeWorker"
