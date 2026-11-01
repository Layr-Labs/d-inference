#!/bin/bash
# Gemma 4 tensor-parallel oracles on synthetic checkpoints, one Mac, loopback
# only (correctness, never a timing or a pair qualification):
#   bash libs/darkbloom-cluster-worker/Tests/GemmaTensorParallelOracles/run.sh TP_CHECK SCRATCH_DIR [PORT] [PATH]
# TP_CHECK is a built darkbloom-cluster-tp-check with a source-matched
# mlx.metallib beside it; SCRATCH_DIR a new directory; PORT the first of two
# free 127.0.0.1 ports for the local ring (default 58123); PATH `legacy` (the
# SDK's legacy caches, the default) or `paged` (the resident runtime's own
# request path: paged KV with each rank's own heads, the product's CBv2
# prompt entry, each step's token and stop flags agreed in its evaluation).
#
# For each synthetic variant: `full`, `split-sum` (legacy only), `simulated`
# (both ranks in one process), then two `tp` ranks over the sealed local ring.
# Required: each tp rank bitwise equal to `simulated`. Reported: the
# comparator's verdict of each rank against `full`, and `split-sum` against tp.
set -euo pipefail
tp_check="$1"
scratch="$2"
port="${3:-58123}"
path="${4:-legacy}"
if [[ ! -x "$tp_check" || -e "$scratch" || ( "$path" != legacy && "$path" != paged ) ]]; then
  echo 'usage: run.sh TP_CHECK NEW_SCRATCH_DIR [PORT] [legacy|paged]' >&2
  exit 2
fi
mkdir -p "$scratch"
printf '[["127.0.0.1:%d"],["127.0.0.1:%d"]]' "$port" "$((port + 1))" > "$scratch/hosts.json"
failures=0
run_variant() {
  local name="$1"; shift
  local environment="$1"; shift
  local dir="$scratch/$name"
  local modes=(full split-sum simulated)
  [[ "$path" == paged ]] && modes=(full simulated)
  nice -n 19 "$tp_check" gemma synthesize --output "$dir" "$@" >/dev/null 2>&1
  for mode in "${modes[@]}"; do
    env $environment nice -n 19 "$tp_check" gemma run --mode "$mode" --path "$path" --model-dir "$dir" \
      --request "$dir/request.json" --report "$dir/$mode.json" >"$dir/$mode.log" 2>&1
  done
  env $environment MLX_RANK=0 MLX_HOSTFILE="$scratch/hosts.json" nice -n 19 "$tp_check" gemma run --mode tp \
    --path "$path" --backend ring --reduction sealed-bench --model-dir "$dir" --request "$dir/request.json" \
    --report "$dir/tp-rank0.json" --deadline-seconds 300 >"$dir/tp-rank0.log" 2>&1 &
  local rank0=$!
  env $environment MLX_RANK=1 MLX_HOSTFILE="$scratch/hosts.json" nice -n 19 "$tp_check" gemma run --mode tp \
    --path "$path" --backend ring --reduction sealed-bench --model-dir "$dir" --request "$dir/request.json" \
    --report "$dir/tp-rank1.json" --deadline-seconds 300 >"$dir/tp-rank1.log" 2>&1
  wait "$rank0"
  for rank in 0 1; do
    if "$tp_check" gemma compare --reference "$dir/simulated.json" --candidate "$dir/tp-rank$rank.json" \
         --bitwise yes >"$dir/tp-rank$rank-vs-simulated.txt" 2>&1; then
      echo "$name ($path): tp rank $rank == simulated, bitwise"
    else
      echo "$name ($path): tp rank $rank DIFFERS from simulated"; failures=$((failures + 1))
    fi
    "$tp_check" gemma compare --reference "$dir/full.json" --candidate "$dir/tp-rank$rank.json" \
      >"$dir/tp-rank$rank-vs-full.txt" 2>&1 || true
    echo "$name ($path): tp rank $rank against full: $(grep '^verdict ' "$dir/tp-rank$rank-vs-full.txt")"
  done
  if [[ "$path" == legacy ]]; then
    "$tp_check" gemma compare --reference "$dir/split-sum.json" --candidate "$dir/tp-rank0.json" --bitwise yes \
      >"$dir/split-sum-vs-tp.txt" 2>&1 || true
    echo "$name ($path): split-sum against tp: $(grep -E '^bitwise' "$dir/split-sum-vs-tp.txt")"
  fi
}
run_variant w4-routed "" --bits 4
run_variant w8-routed "" --bits 8
run_variant w4-all-experts "" --bits 4 --experts 4 --top-k 4
run_variant w8-all-experts "" --bits 8 --experts 4 --top-k 4
run_variant w4-routed-fp32 "MLX_ENABLE_TF32=0" --bits 4 --dtype float32
echo "required tp == simulated failures ($path): $failures"
exit $(( failures == 0 ? 0 : 1 ))
