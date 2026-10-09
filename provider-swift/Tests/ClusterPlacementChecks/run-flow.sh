#!/bin/bash
# The guided step end to end on one Mac, with a stand-in for the installed plan
# tool: compiles the installed path's own sources (as the installed-session
# checks do) with the placement step, runs the two child commands for real,
# and checks the decision and the files written. No model, no MLX, no network.
set -euo pipefail
task_provider="$(cd "$(dirname "$0")/../.." && pwd)"
task_repo="$(cd "$task_provider/.." && pwd)"
task_cluster="$task_repo/libs/darkbloom-cluster"
task_sources="$task_provider/Sources/ProviderCore"
# The strict file readers reject symlinked path components, including /var
# aliases, so the build and the fixture stay in the checkout tree.
task_build="$(mktemp -d "$task_provider/.cluster-placement-flow.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_flags=(-j 4 -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0")
task_links=(-I "$task_build" -L "$task_build" -Xlinker -rpath -Xlinker "$task_build")
build_module() {
  local task_name="$1" task_needs="$2"; shift 2
  local task_dependencies=("${task_links[@]}")
  for task_need in $task_needs; do task_dependencies+=("-l$task_need"); done
  xcrun swiftc "${task_flags[@]}" -emit-library -emit-module -enable-testing \
    -module-name "$task_name" -emit-module-path "$task_build/$task_name.swiftmodule" \
    "${task_dependencies[@]}" "$@" -o "$task_build/lib$task_name.dylib" \
    -Xlinker -install_name -Xlinker "@rpath/lib$task_name.dylib"
}
build_module DarkbloomClusterProtocol "" "$task_cluster"/Sources/DarkbloomClusterProtocol/*.swift
build_module DarkbloomClusterPlacement "DarkbloomClusterProtocol" "$task_cluster"/Sources/DarkbloomClusterPlacement/*.swift
build_module DarkbloomClusterBootstrap "" "$task_cluster"/Sources/DarkbloomClusterBootstrap/*.swift
build_module DarkbloomClusterSecurity "DarkbloomClusterBootstrap" "$task_cluster"/Sources/DarkbloomClusterSecurity/*.swift
build_module DarkbloomClusterProcess "DarkbloomClusterProtocol" "$task_cluster"/Sources/DarkbloomClusterProcess/*.swift
build_module DarkbloomClusterRemote "DarkbloomClusterProtocol DarkbloomClusterProcess DarkbloomClusterBootstrap DarkbloomClusterSecurity" \
  "$task_cluster"/Sources/DarkbloomClusterRemote/*.swift
build_module MLXLMCommon "" "$task_cluster/Tests/ProcessChecks/MLXLMCommonContractValues.swift"
build_module ProviderCoreFoundation "" "$task_provider/Sources/ProviderCoreFoundation/Manifest.swift"
task_all="DarkbloomClusterProtocol DarkbloomClusterPlacement DarkbloomClusterProcess DarkbloomClusterBootstrap DarkbloomClusterRemote MLXLMCommon ProviderCoreFoundation"
build_module InstalledContract "$task_all" \
  "$task_sources/Config/ClusterConfiguration.swift" \
  "$task_sources/Config/ClusterConfigurationCodec.swift" \
  "$task_sources/Config/ClusterGenerationSelection.swift" \
  "$task_sources/Config/ClusterCapabilityRecord.swift" \
  "$task_sources/Config/ClusterConfigurationFiles.swift" \
  "$task_sources/Config/ClusterConfigurationPaths.swift" \
  "$task_sources/Config/ClusterConfigurationStore.swift" \
  "$task_sources/Config/ClusterNativeMemberAttachment.swift" \
  "$task_sources/Config/ClusterPairApproval.swift" \
  "$task_sources/Coordinator/NativePairMemberPolicy.swift" \
  "$task_sources/Inference/Distributed/Requests/DistributedRequestDeadlineContext.swift" \
  "$task_sources/Inference/Distributed/Requests/DistributedFirstTokenBudgetPolicy.swift" \
  "$task_sources/Inference/Distributed/DistributedResidentExecution.swift" \
  "$task_sources/Inference/Distributed/DistributedPipeExecutionOwner.swift" \
  "$task_sources"/Inference/Distributed/Installed/*.swift \
  "$task_sources"/Inference/Distributed/Placement/*.swift \
  "$task_sources"/Inference/Distributed/Diagnostics/ClusterStatusValues.swift \
  "$task_sources"/Inference/Distributed/Diagnostics/ClusterStatusCodec.swift
xcrun swiftc "${task_flags[@]}" -parse-as-library "${task_links[@]}" -lDarkbloomClusterProtocol -lDarkbloomClusterPlacement -lDarkbloomClusterProcess -lInstalledContract \
  "$task_provider/Tests/ClusterPlacementChecks/FlowRunCheck.swift" -o "$task_build/flow-run-check"
(cd "$task_build" && ./flow-run-check)
