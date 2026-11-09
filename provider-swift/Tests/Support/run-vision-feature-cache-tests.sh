#!/usr/bin/env bash
set -euo pipefail
root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
: "${VISION_CACHE_TEST_SCRATCH:?Set an existing task-owned external scratch directory}"
[[ -d "$VISION_CACHE_TEST_SCRATCH" ]] || exit 2
out="$(mktemp -d "$VISION_CACHE_TEST_SCRATCH/vision-cache.XXXXXX")"
dev="$(xcode-select -p)"
frameworks="$dev/Platforms/MacOSX.platform/Developer/Library/Frameworks"
plugins="$dev/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing"
export TMPDIR="$out/"
mkdir -p "$out/modules"
sources=(
  "$root/libs/mlx-swift-lm/Libraries/MLXLMCommon/Utilities/SerialAccessContainer.swift"
  "$root/provider-swift/Sources/ProviderCore/Protocol/ProcessMemoryTelemetry.swift"
  "$root/provider-swift/Sources/ProviderCore/Protocol/InferenceProfile.swift"
  "$root/provider-swift/Sources/ProviderCore/Protocol/DeadlineDecisionProfile.swift"
  "$root/provider-swift/Sources/ProviderCore/Protocol/DeadlineUnboundedReason.swift"
  "$root/provider-swift/Sources/ProviderCore/Telemetry/RequestProfileBuilder.swift"
  "$root/provider-swift/Sources/ProviderCore/Inference/Memory/ProcessMemoryLedger.swift"
  "$root/provider-swift/Sources/ProviderCore/Inference/Vision/VisionFeaturePreparationOwner.swift"
  "$root/provider-swift/Sources/ProviderCore/Inference/Vision/GemmaVisionProcessorIdentity.swift"
  "$root/provider-swift/Sources/ProviderCore/Inference/Vision/VisionFeatureCache.swift"
)
tests=(
  "$root/provider-swift/Tests/ProviderCoreTests/Inference/Vision/VisionFeatureCacheTests.swift"
  "$root/provider-swift/Tests/ProviderCoreTests/Inference/Vision/VisionFeaturePreparationOwnerTests.swift"
  "$root/provider-swift/Tests/ProviderCoreTests/Inference/Vision/GemmaVisionProcessorIdentityTests.swift"
  "$root/provider-swift/Tests/ProviderCoreTests/Inference/Vision/VisionFeatureCacheProfileTests.swift"
  "$root/provider-swift/Tests/ProviderCoreTests/Protocol/ProfileTestFixtures.swift"
)
shasum -a 256 "${sources[@]}" "${tests[@]}" "$0" > "$out/source-sha256.before"
swiftc --version > "$out/compiler-version.txt"
swiftc -swift-version 6 -package-name ImageFeatureCacheTests -warnings-as-errors -module-cache-path "$out/modules" \
  -emit-library -emit-module -enable-testing -module-name ProviderCore \
  "${sources[@]}" \
  -o "$out/libProviderCore.dylib" -emit-module-path "$out/ProviderCore.swiftmodule"
swiftc -swift-version 6 -package-name ImageFeatureCacheTests -warnings-as-errors -parse-as-library -module-cache-path "$out/modules" \
  -DVISION_FEATURE_CACHE_STANDALONE -I "$out" -L "$out" -lProviderCore \
  -Xlinker -rpath -Xlinker "$out" \
  -F "$frameworks" -Xlinker -rpath -Xlinker "$frameworks" -plugin-path "$plugins" \
  "${tests[@]}" \
  -o "$out/VisionFeatureCacheTests"
shasum -a 256 "${sources[@]}" "${tests[@]}" "$0" > "$out/source-sha256.after"
cmp "$out/source-sha256.before" "$out/source-sha256.after"
printf 'CPU source/compiler receipts: %s\n' "$out"
"$out/VisionFeatureCacheTests" "$@"
