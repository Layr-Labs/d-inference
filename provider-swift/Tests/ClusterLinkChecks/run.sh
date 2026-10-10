#!/bin/bash
set -euo pipefail
task_provider="$(cd "$(dirname "$0")/../.." && pwd)"
task_link="$task_provider/Sources/ProviderCore/Inference/Distributed/Diagnostics/Link"
task_config="$task_provider/Sources/ProviderCore/Config"
task_checks="$task_provider/Tests/ClusterLinkChecks"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-link.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
# ClusterLinkDiagnosticChecks.swift maps a report onto the doctor's check type,
# which needs the installed-session closure; ClusterDiagnosticsChecks covers it.
task_sources=()
for task_source in "$task_link"/*.swift; do
  [[ "$(basename "$task_source")" == "ClusterLinkDiagnosticChecks.swift" ]] || task_sources+=("$task_source")
done
# The alias record is kept with the cluster file policy and user paths.
task_sources+=("$task_config/ClusterConfigurationFiles.swift" "$task_config/ClusterConfigurationPaths.swift")
xcrun swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
  -target "$(uname -m)-apple-macos14.0" \
  "${task_sources[@]}" "$task_checks"/*.swift -o "$task_build/link-check"
# That file policy refuses symlinked path components such as /var, so the
# record fixture lives under the checkout.
(cd "$task_provider" && "$task_build/link-check")
