#!/bin/bash
set -euo pipefail
task_provider="$(cd "$(dirname "$0")/../.." && pwd)"
task_repo="$(cd "$task_provider/.." && pwd)"
task_config="$task_provider/Sources/ProviderCore/Config"
task_fixtures="$task_provider/Tests/ClusterConfigurationChecks"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-configuration.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors \
  -emit-library -emit-module -module-name DarkbloomClusterProtocol \
  -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
  "$task_repo"/libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol/*.swift \
  -o "$task_build/libDarkbloomClusterProtocol.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors \
  "$task_config/ClusterConfigurationFiles.swift" "$task_config/ClusterConfigurationPaths.swift" \
  "$task_provider"/Sources/ProviderBuildEnvironment/*.swift \
  "$task_fixtures/ConfigurationFilesCheck.swift" -o "$task_build/files-check"
"$task_build/files-check"
xcrun swiftc -swift-version 6 -warnings-as-errors \
  "$task_config/ClusterConfigurationFiles.swift" "$task_config/ProviderConfigFile.swift" \
  "$task_fixtures/ProviderConfigFileCheck.swift" -o "$task_build/provider-config-file-check"
# The strict reader refuses symlinked path components such as /var, so the
# fixture directory lives under the checkout.
(cd "$task_provider" && "$task_build/provider-config-file-check")
# The setup's grant and public-model rules (`ClusterPublicModels`, `ClusterPairServingGrants`) read the placement types.
xcrun swiftc -swift-version 6 -warnings-as-errors \
  -emit-library -emit-module -module-name DarkbloomClusterPlacement \
  -emit-module-path "$task_build/DarkbloomClusterPlacement.swiftmodule" \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker "$task_build" \
  "$task_repo"/libs/darkbloom-cluster/Sources/DarkbloomClusterPlacement/*.swift \
  -o "$task_build/libDarkbloomClusterPlacement.dylib"
xcrun swiftc -swift-version 6 -warnings-as-errors \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol -lDarkbloomClusterPlacement \
  -Xlinker -rpath -Xlinker "$task_build" \
  "$task_config/ClusterConfigurationFiles.swift" "$task_config/ClusterConfigurationPaths.swift" \
  "$task_provider"/Sources/ProviderBuildEnvironment/*.swift \
  "$task_config/ClusterConfiguration.swift" "$task_config/ClusterConfigurationCodec.swift" \
  "$task_config/ClusterGenerationSelection.swift" "$task_config/ClusterCapabilityRecord.swift" \
  "$task_config/ClusterNativeMemberAttachment.swift" "$task_config/ClusterLinkControlAttachment.swift" "$task_config/ClusterPairApproval.swift" \
  "$task_provider/Sources/ProviderCore/Coordinator/NativePairMemberPolicy.swift" \
  "$task_provider/Sources/ProviderCore/Config/ClusterRuntimeApproval.swift" "$task_provider/Sources/ProviderCore/Protocol/ClusterRosterRegistration.swift" \
  "$task_provider/Tests/ClusterInstalledSessionChecks/AttestationSignerStandIn.swift" \
  "$task_provider/Tests/ClusterPlacementChecks/OnboardingCommandStandIn.swift" \
  "$task_provider/Sources/ProviderCore/Inference/Distributed/Placement/ClusterModelFeaturePolicy.swift" \
  "$task_provider/Sources/ProviderCore/Inference/Distributed/Installed/DistributedInstalledPairServingGrant.swift" \
  "$task_provider/Sources/ProviderCore/Inference/Distributed/Installed/ClusterPublicModels.swift" \
  "$task_provider/Sources/ProviderCore/Inference/Distributed/Installed/DistributedInstalledPairQualificationRecords.swift" \
  "$task_provider/Sources/ProviderCore/Inference/Distributed/Installed/ClusterBenchChip.swift" \
  "$task_config/ClusterConfigurationStore.swift" "$task_fixtures/ConfigurationCheck.swift" \
  -o "$task_build/configuration-check"
"$task_build/configuration-check"
