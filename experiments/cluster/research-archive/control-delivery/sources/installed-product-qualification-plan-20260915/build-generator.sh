#!/bin/sh
set -eu
# Root-owned optional CPU build. No SwiftPM, native worker, MLX or deployment.
test "$#" -eq 1 || { echo 'Usage: build-generator.sh NEW_BUILD_DIRECTORY' >&2; exit 2; }
task_source=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
task_repo=/Users/developer/DarkbloomDev/d-inference
task_build=$1
test ! -e "$task_build"
mkdir -m 700 "$task_build"
python3 - "$task_source/source-pins.json" <<'PY'
import hashlib,json,sys
from pathlib import Path
for member in json.loads(Path(sys.argv[1]).read_text())['inputs']:
    if hashlib.sha256(Path(member['path']).read_bytes()).hexdigest() != member['sha256']:
        raise SystemExit('Source changed: '+member['path'])
PY
swiftc -swift-version 6 -warnings-as-errors -emit-library -emit-module \
  -module-name DarkbloomClusterProtocol \
  "$task_repo"/libs/darkbloom-cluster/Sources/DarkbloomClusterProtocol/*.swift \
  -o "$task_build/libDarkbloomClusterProtocol.dylib" \
  -emit-module-path "$task_build/DarkbloomClusterProtocol.swiftmodule" \
  -Xlinker -install_name -Xlinker '@rpath/libDarkbloomClusterProtocol.dylib'
swiftc -swift-version 6 -warnings-as-errors -I "$task_build" -L "$task_build" \
  -lDarkbloomClusterProtocol -Xlinker -rpath -Xlinker '@executable_path' \
  "$task_repo/provider-swift/Sources/ProviderCore/Config/ClusterConfigurationFiles.swift" \
  "$task_repo/provider-swift/Sources/ProviderCore/Config/ClusterConfigurationPaths.swift" \
  "$task_repo/provider-swift/Sources/ProviderCore/Config/ClusterConfiguration.swift" \
  "$task_repo/provider-swift/Sources/ProviderCore/Config/ClusterConfigurationCodec.swift" \
  "$task_source/Generate.swift" -o "$task_build/generate"
