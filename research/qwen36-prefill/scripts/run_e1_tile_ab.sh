#!/bin/bash
# E1: expert-tile vs legacy gather-QMM at M=16384/32768/65536.
# Run on the M3 Max only. Does not raise CBv2 scheduler budgets.
set -euo pipefail

ROOT="${1:-/Users/gaj/work/d-inference}"
SWIFT="$ROOT/libs/mlx-swift"
OUT="${2:-/Users/gaj/work/qwen36-prefill/results}"
mkdir -p "$OUT"

if [[ ! -d "$SWIFT/Source/Cmlx/mlx/mlx" ]]; then
  echo "populating Source/Cmlx/mlx from libs/mlx" >&2
  rsync -a --delete --exclude .git "$ROOT/libs/mlx/" "$SWIFT/Source/Cmlx/mlx/"
fi

pmset -g batt | tee "$OUT/e1-power.txt"
sysctl -n machdep.cpu.brand_string | tee -a "$OUT/e1-power.txt"
echo "powermode=$(pmset -g | awk '/powermode/{print $2}')" | tee -a "$OUT/e1-power.txt"

cd "$SWIFT"
export MLX_EXPERT_TILES_PERF=1

echo "=== TILE route ===" | tee "$OUT/e1-tile.log"
MLX_GATHER_QMM_EXPERT_SLICES=1 swift test --filter QwenExpertTilePerfTests \
  2>&1 | tee -a "$OUT/e1-tile.log"

echo "=== LEGACY route ===" | tee "$OUT/e1-legacy.log"
MLX_GATHER_QMM_EXPERT_SLICES=0 swift test --filter QwenExpertTilePerfTests \
  2>&1 | tee -a "$OUT/e1-legacy.log"

echo "done. logs in $OUT"
