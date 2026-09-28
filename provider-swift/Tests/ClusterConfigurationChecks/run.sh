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
  "$task_fixtures/ConfigurationFilesCheck.swift" -o "$task_build/files-check"
"$task_build/files-check"
xcrun swiftc -swift-version 6 -warnings-as-errors \
  -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol \
  -Xlinker -rpath -Xlinker "$task_build" \
  "$task_config/ClusterConfigurationFiles.swift" "$task_config/ClusterConfigurationPaths.swift" \
  "$task_config/ClusterConfiguration.swift" "$task_config/ClusterConfigurationCodec.swift" \
  "$task_config/ClusterConfigurationStore.swift" "$task_fixtures/ConfigurationCheck.swift" \
  -o "$task_build/configuration-check"
"$task_build/configuration-check"
