#!/bin/bash
# Model-free checks of the dense Qwen tensor-parallel plan (no MLX, no GPU, no
# SwiftPM): every tensor of a synthetic 27B and 9B checkpoint, and of each
# model directory given as an argument (safetensors headers only), is covered
# exactly once by the two ranks' cuts or replicated, with the shapes the
# divided configuration constructs; and every launch option that changes the
# collectives changes the ranks' first agreement; and the one-token decode loop
# (`TensorParallelOneTokenLoop`) builds greedy steps ahead and ends both ranks together. Swift 6, warnings as errors.
#   bash libs/darkbloom-cluster/Tests/TensorParallelPlanChecks/run.sh [MODEL_DIR...]
set -euo pipefail
package="$(cd "$(dirname "$0")/../.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-tp-plan.XXXXXXXX")"
trap 'rm -rf "$build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0" -parse-as-library \
  "$package/Sources/DarkbloomClusterRuntime/Models/Qwen/TensorParallel/QwenTensorParallelPlan.swift" \
  "$package/Sources/DarkbloomClusterRuntime/Models/Qwen/TensorParallel/QwenTensorParallelLaunch.swift" \
  "$package/Sources/DarkbloomClusterRuntime/Models/Qwen/TensorParallel/QwenTensorParallelSealCodec.swift" \
  "$package/Sources/DarkbloomClusterRuntime/Models/Qwen/TensorParallel/QwenTensorParallelStopRule.swift" \
  "$package/Sources/DarkbloomClusterRuntime/Models/Qwen/TensorParallel/TensorParallelOneTokenLoop.swift" \
  "$package/Sources/DarkbloomClusterRuntime/Support/ClusterRuntimeError.swift" \
  "$package/Tests/TensorParallelPlanChecks/TensorParallelPlanCheck.swift" \
  "$package/Tests/TensorParallelPlanChecks/OneTokenLoopCheck.swift" -o "$build/tp-plan-check"
"$build/tp-plan-check" "$@"
