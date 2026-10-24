#!/usr/bin/env bash
set -euo pipefail

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
out="$(mktemp -d "${TMPDIR:-/tmp}/darkbloom-ssd-budget.XXXXXX")"
trap 'rm -rf "$out"' EXIT
dev="$(xcode-select -p)"
frameworks="$dev/Platforms/MacOSX.platform/Developer/Library/Frameworks"
plugins="$dev/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"

# Compile the production accounting sources unchanged, without the MLX graph.
swiftc -swift-version 6 -warnings-as-errors \
    -emit-library -emit-module -enable-testing -module-name ProviderCore \
    "$root/provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWriteBudget.swift" \
    "$root/provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWriteRateLimiter.swift" \
    -o "$out/libProviderCore.dylib" -emit-module-path "$out/ProviderCore.swiftmodule"
swiftc -swift-version 6 -warnings-as-errors -parse-as-library \
    -DSSD_WRITE_BUDGET_STANDALONE -I "$out" -L "$out" -lProviderCore \
    -Xlinker -rpath -Xlinker "$out" \
    -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" -plugin-path "$plugins" \
    "$root/provider-swift/Tests/ProviderCoreTests/KVCacheSSD/SSDWriteBudgetTests.swift" \
    "$root/provider-swift/Tests/ProviderCoreTests/KVCacheSSD/SSDWriteEnduranceTests.swift" \
    -o "$out/SSDWriteBudgetTests"
"$out/SSDWriteBudgetTests" "$@"
