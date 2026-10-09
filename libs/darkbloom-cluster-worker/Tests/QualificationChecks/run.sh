#!/bin/bash
# The qualification tests without SwiftPM and without MLX: the comparator, the
# request and evidence readers, and the pair driver against two copies of the
# fake worker. Compiles the actual sources with Swift 6 and warnings as errors
# in a temporary directory. No model, no GPU, no second Mac.
set -euo pipefail
task_package="$(cd "$(dirname "$0")/../.." && pwd)"
task_shared="$(cd "$task_package/../darkbloom-cluster" && pwd)"
task_build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-qualification.XXXXXXXX")"
trap 'rm -rf "$task_build"' EXIT
task_flags=(-swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0")
task_platform="$(xcrun --show-sdk-platform-path)/Developer"
task_module() { # name, extra flags..., then sources after --
  local name="$1"; shift
  local flags=()
  while [[ "$1" != -- ]]; do flags+=("$1"); shift; done
  shift
  xcrun swiftc "${task_flags[@]}" -emit-library -emit-module -module-name "$name" \
    -emit-module-path "$task_build/$name.swiftmodule" -I "$task_build" -L "$task_build" \
    ${flags[@]+"${flags[@]}"} "$@" -o "$task_build/lib$name.dylib"
}
task_module DarkbloomClusterProtocol -- "$task_shared"/Sources/DarkbloomClusterProtocol/*.swift
task_module DarkbloomClusterProcess -lDarkbloomClusterProtocol -- "$task_shared"/Sources/DarkbloomClusterProcess/*.swift
task_module DarkbloomClusterQualification -enable-testing -lDarkbloomClusterProtocol -lDarkbloomClusterProcess -- \
  "$task_package"/Sources/DarkbloomClusterQualification/*.swift
xcrun swiftc "${task_flags[@]}" -parse-as-library -I "$task_build" -L "$task_build" -lDarkbloomClusterProtocol \
  -Xlinker -rpath -Xlinker "$task_build" \
  "$task_package"/Sources/PairCheckFakeWorker/*.swift -o "$task_build/PairCheckFakeWorker"
mkdir -p "$task_build/Qualification.xctest/Contents/MacOS"
xcrun swiftc "${task_flags[@]}" -emit-library -module-name QualificationChecks -I "$task_build" -L "$task_build" \
  -lDarkbloomClusterProtocol -lDarkbloomClusterProcess -lDarkbloomClusterQualification \
  -F "$task_platform/Library/Frameworks" -I "$task_platform/usr/lib" -L "$task_platform/usr/lib" -framework XCTest \
  -Xlinker -rpath -Xlinker "$task_build" -Xlinker -rpath -Xlinker "$task_platform/Library/Frameworks" \
  -Xlinker -rpath -Xlinker "$task_platform/usr/lib" -Xlinker -bundle \
  "$task_package"/Tests/DarkbloomClusterQualificationTests/*.swift \
  -o "$task_build/Qualification.xctest/Contents/MacOS/Qualification"
PAIR_CHECK_FAKE_WORKER="$task_build/PairCheckFakeWorker" xcrun xctest "$task_build/Qualification.xctest"
