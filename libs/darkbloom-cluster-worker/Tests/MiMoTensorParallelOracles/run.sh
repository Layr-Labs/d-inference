#!/bin/bash
# MiMo V2.6 tensor-parallel oracles on synthetic checkpoints, one Mac, loopback
# only (correctness, never a timing or a pair qualification):
#   bash libs/darkbloom-cluster-worker/Tests/MiMoTensorParallelOracles/run.sh TP_CHECK SCRATCH_DIR [PORT]
# TP_CHECK is a built darkbloom-cluster-tp-check with a source-matched
# mlx.metallib beside it; SCRATCH_DIR a new directory; PORT the first of two
# free 127.0.0.1 ports for the local ring and socket (default 58223).
#
# For each synthetic variant and each request (40 prompt tokens: longer than
# the 8-token window and the 16-token chunk; 6 tokens: shorter than both; 64
# outputs each): `full`, `simulated` (both ranks in one process), then two `tp`
# ranks over the sealed local ring. Required: each tp rank bitwise equal to
# `simulated` (tokens, top-8 logits and log probabilities, every step's whole
# row, the final row, the rank's KV caches), and each tp rank's tokens in
# agreement with `full` under QualificationComparator (exact,
# tokensEqualLogitsDiffer or divergedAtNearTie). Then once on the socket
# backend, and once sampled (temperature 0.8 through the gathered row): tp
# bitwise equal to simulated; the sampled run's verdict against `full` is
# reported only (a sampled token after a near tie is not a greedy divergence).
set -euo pipefail
tp_check="$1"
scratch="$2"
port="${3:-58223}"
if [[ ! -x "$tp_check" || -e "$scratch" ]]; then
  echo 'usage: run.sh TP_CHECK NEW_SCRATCH_DIR [PORT]' >&2
  exit 2
fi
mkdir -p "$scratch"
printf '[["127.0.0.1:%d"],["127.0.0.1:%d"]]' "$port" "$((port + 1))" > "$scratch/hosts.json"
failures=0
tp_pair() {
  local dir="$1" request="$2" tag="$3" backend="$4" environment="$5"; shift 5
  env $environment MLX_RANK=0 MLX_HOSTFILE="$scratch/hosts.json" nice -n 19 "$tp_check" mimo run --mode tp \
    --backend "$backend" --reduction sealed-bench --model-dir "$dir" --request "$dir/$request.json" \
    --report "$dir/$tag-rank0.json" --deadline-seconds 300 "$@" >"$dir/$tag-rank0.log" 2>&1 &
  local rank0=$!
  env $environment MLX_RANK=1 MLX_HOSTFILE="$scratch/hosts.json" nice -n 19 "$tp_check" mimo run --mode tp \
    --backend "$backend" --reduction sealed-bench --model-dir "$dir" --request "$dir/$request.json" \
    --report "$dir/$tag-rank1.json" --deadline-seconds 300 "$@" >"$dir/$tag-rank1.log" 2>&1 || true
  wait "$rank0" || true
}
check_rank() {
  local dir="$1" reference="$2" tag="$3" label="$4" full_required="${5:-yes}"
  for rank in 0 1; do
    if "$tp_check" mimo compare --reference "$dir/$reference-simulated.json" --candidate "$dir/$tag-rank$rank.json" \
         --bitwise yes >"$dir/$tag-rank$rank-vs-simulated.txt" 2>&1; then
      echo "$label: tp rank $rank == simulated, bitwise"
    else
      echo "$label: tp rank $rank DIFFERS from simulated"; failures=$((failures + 1))
    fi
    if "$tp_check" mimo compare --reference "$dir/$reference-full.json" --candidate "$dir/$tag-rank$rank.json" \
         >"$dir/$tag-rank$rank-vs-full.txt" 2>&1 || [[ "$full_required" == no ]]; then
      echo "$label: tp rank $rank against full: $(grep '^verdict ' "$dir/$tag-rank$rank-vs-full.txt")"
    else
      echo "$label: tp rank $rank against full FAILS: $(grep '^verdict ' "$dir/$tag-rank$rank-vs-full.txt" || true)"
      failures=$((failures + 1))
    fi
  done
}
run_variant() {
  local name="$1"; shift
  local environment="$1"; shift
  local dir="$scratch/$name"
  nice -n 19 "$tp_check" mimo synthesize --output "$dir" "$@" >/dev/null 2>&1
  for request in request request-short; do
    for mode in full simulated; do
      env $environment nice -n 19 "$tp_check" mimo run --mode "$mode" --model-dir "$dir" \
        --request "$dir/$request.json" --report "$dir/$request-$mode.json" >"$dir/$request-$mode.log" 2>&1
    done
    tp_pair "$dir" "$request" "$request-tp-ring" ring "$environment"
    check_rank "$dir" "$request" "$request-tp-ring" "$name/$request (ring)"
  done
}
run_variant kernel "" --variant kernel
run_variant tiny "" --variant tiny
# Every token takes all 8 experts: no rounding can flip a route.
run_variant kernel-all-experts "" --variant kernel --experts 8 --top-k 8
run_variant kernel-fp32 "MLX_ENABLE_TF32=0" --variant kernel --dtype float32
# The socket backend once, on the production-kernel shapes.
tp_pair "$scratch/kernel" request request-tp-socket socket ""
check_rank "$scratch/kernel" request request-tp-socket "kernel/request (socket)"
# Sampled through the gathered row, on the production-kernel shapes.
dir="$scratch/kernel"
for mode in full simulated; do
  nice -n 19 "$tp_check" mimo run --mode "$mode" --model-dir "$dir" --request "$dir/request.json" \
    --report "$dir/sampled-$mode.json" --temperature 0.8 --sample-seed 11 >"$dir/sampled-$mode.log" 2>&1
done
tp_pair "$dir" request sampled-tp-ring ring "" --temperature 0.8 --sample-seed 11
check_rank "$dir" sampled sampled-tp-ring "kernel/request sampled (ring)" no
echo "required failures (tp == simulated bitwise, tp against full): $failures"
exit $(( failures == 0 ? 0 : 1 ))
