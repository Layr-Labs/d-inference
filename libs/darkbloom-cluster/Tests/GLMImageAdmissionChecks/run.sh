#!/bin/bash
# CPU-only protocol/provider admission. No MLX runtime, model, GPU or endpoint.
set -euo pipefail
task_repo="$(cd "$(dirname "$0")/../../../.." && pwd)"
task_out="${GLM_ADMISSION_OUTPUT:-$(mktemp -d)}"
mkdir -p "$task_out"
if [[ -z "${GLM_ADMISSION_OUTPUT:-}" ]]; then trap 'rm -rf "$task_out"' EXIT; fi
task_protocol="$task_repo/libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol"
task_flags=(-j 2 -swift-version 6 -target "$(uname -m)-apple-macos14.0" -module-cache-path "$task_out/cache")
xcrun swiftc "${task_flags[@]}" -emit-library -emit-module -module-name DarkbloomClusterProtocol \
 -emit-module-path "$task_out/DarkbloomClusterProtocol.swiftmodule" "$task_protocol"/*.swift \
 -Xlinker -install_name -Xlinker @rpath/libDarkbloomClusterProtocol.dylib -o "$task_out/libDarkbloomClusterProtocol.dylib"
# Minimal contract values; actual provider refusal source below is compiled unchanged.
python3 - "$task_repo" "$task_out" <<'INNER'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:])
s=(root/'libs/darkbloom-cluster/Tests/ProcessChecks/MLXLMCommonContractValues.swift').read_text()
if 'var clusterStillImages:' not in s:s=s.replace('public var mimoClusterImages:', 'public var clusterStillImages: Data? = nil\n    public var mimoClusterImages:')
(out/'MLXLMCommon.swift').write_text(s)
INNER
xcrun swiftc "${task_flags[@]}" -emit-library -emit-module -module-name MLXLMCommon \
 -emit-module-path "$task_out/MLXLMCommon.swiftmodule" "$task_out/MLXLMCommon.swift" \
 -Xlinker -install_name -Xlinker @rpath/libMLXLMCommon.dylib -o "$task_out/libMLXLMCommon.dylib"
xcrun swiftc "${task_flags[@]}" -parse-as-library -I "$task_out" -L "$task_out" \
 -lDarkbloomClusterProtocol -lMLXLMCommon -Xlinker -rpath -Xlinker "$task_out" \
 "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/DistributedResidentExecution.swift" \
 "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/Installed/ClusterMiMoPrivateImagePolicy.swift" \
 "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/Onboarding/ClusterGLMOnboardingSelection.swift" \
 "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/Onboarding/ClusterOnboardingFlow.swift" \
 "$task_repo/provider-swift/Sources/ProviderCore/Inference/Distributed/Onboarding/ClusterOnboardingTerminal.swift" \
 "$task_repo/libs/darkbloom-cluster/Tests/GLMImageAdmissionChecks/Main.swift" -o "$task_out/check"
"$task_out/check"
