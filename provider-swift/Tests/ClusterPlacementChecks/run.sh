#!/bin/bash
# The guided flow's choice of rank order and Plan: compiles the placement
# target, the cluster configuration sources and the setup synthesis with Swift
# 6 and warnings as errors, and checks that both members' setups follow a
# placement and are what the strict codec writes. No model, no MLX, no network.
set -euo pipefail
task_provider="$(cd "$(dirname "$0")/../.." && pwd)"
task_repo="$(cd "$task_provider/.." && pwd)"
task_config="$task_provider/Sources/ProviderCore/Config"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-placement-setup.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_flags=(-swift-version 6 -warnings-as-errors)
task_links=(-I "$task_build" -L "$task_build" -Xlinker -rpath -Xlinker "$task_build")
xcrun swiftc -j 4 "${task_flags[@]}" -emit-library -emit-module -module-name DarkbloomClusterProtocol \
  -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
  -Xlinker -install_name -Xlinker @rpath/libDarkbloomClusterProtocol.dylib \
  "$task_repo"/libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol/*.swift -o "$task_build/libDarkbloomClusterProtocol.dylib"
xcrun swiftc -j 4 "${task_flags[@]}" -emit-library -emit-module -module-name DarkbloomClusterPlacement \
  -emit-module-path "$task_build/DarkbloomClusterPlacement.swiftmodule" "${task_links[@]}" -lDarkbloomClusterProtocol \
  -Xlinker -install_name -Xlinker @rpath/libDarkbloomClusterPlacement.dylib \
  "$task_repo"/libs/darkbloom-cluster/Sources/DarkbloomClusterPlacement/*.swift -o "$task_build/libDarkbloomClusterPlacement.dylib"
xcrun swiftc -j 4 "${task_flags[@]}" -parse-as-library "${task_links[@]}" -lDarkbloomClusterProtocol -lDarkbloomClusterPlacement \
  "$task_config/ClusterConfigurationFiles.swift" "$task_config/ClusterConfigurationPaths.swift" \
  "$task_config/ClusterConfiguration.swift" "$task_config/ClusterConfigurationCodec.swift" \
  "$task_config/ClusterGenerationSelection.swift" "$task_config/ClusterCapabilityRecord.swift" \
  "$task_config/ClusterNativeMemberAttachment.swift" "$task_config/ClusterPairApproval.swift" \
  "$task_provider/Sources/ProviderCore/Coordinator/NativePairMemberPolicy.swift" \
  "$task_provider/Sources/ProviderCore/Inference/Distributed/Placement/ClusterPlacementSetup.swift" \
  "$task_provider/Sources/ProviderCore/Inference/Distributed/Placement/ClusterPlacementFlow.swift" \
  "$task_provider/Tests/ClusterPlacementChecks/PlacementSetupCheck.swift" -o "$task_build/setup-check"
# PLACEMENT_CHECK_KEEP=/ABS/DIR keeps the built check and its two libraries
# there, for `setup-check flow ...` (see PlacementSetupCheck.swift); run it
# with DYLD_LIBRARY_PATH set to that directory.
if [[ -n "${PLACEMENT_CHECK_KEEP:-}" ]]; then
  mkdir -p "$PLACEMENT_CHECK_KEEP"
  cp "$task_build/setup-check" "$task_build"/libDarkbloomCluster*.dylib "$PLACEMENT_CHECK_KEEP/"
fi
"$task_build/setup-check"
# PLACEMENT_CHECK_KEEP=/ABS/DIR keeps the built check and its two libraries
# there, for `setup-check flow ...` (see PlacementSetupCheck.swift); run it
# with DYLD_LIBRARY_PATH set to that directory.
if [[ -n "${PLACEMENT_CHECK_KEEP:-}" ]]; then
  mkdir -p "$PLACEMENT_CHECK_KEEP"
  cp "$task_build/setup-check" "$task_build"/libDarkbloomCluster*.dylib "$PLACEMENT_CHECK_KEEP/"
fi
