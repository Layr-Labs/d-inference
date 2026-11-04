#!/bin/bash
# Model-free checks of the Gemma 4 tensor-parallel plan (no MLX, no GPU, no
# SwiftPM) against the registered 26B artifact's safetensors headers in
# Tests/StageMetadataChecks/Inputs. Swift 6, warnings as errors.
#   bash libs/darkbloom-cluster/Tests/TensorParallelPlanChecks/gemma-run.sh
set -euo pipefail
package="$(cd "$(dirname "$0")/../.." && pwd)"
build="$(mktemp -d "${TMPDIR:-/tmp}/cluster-gemma-tp-plan.XXXXXXXX")"
trap 'rm -rf "$build"' EXIT
xcrun swiftc -swift-version 6 -warnings-as-errors -target "$(uname -m)-apple-macos14.0" -parse-as-library \
  "$package/Sources/DarkbloomClusterRuntime/Models/Gemma4/TensorParallel/Gemma4TensorParallelPlan.swift" \
  "$package/Sources/DarkbloomClusterRuntime/Support/ClusterRuntimeError.swift" \
  "$package/Tests/TensorParallelPlanChecks/GemmaTensorParallelPlanCheck.swift" -o "$build/gemma-tp-plan-check"
"$build/gemma-tp-plan-check" "$package/Tests/StageMetadataChecks/Inputs"
