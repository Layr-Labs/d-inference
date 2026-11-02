#!/bin/bash
# MiMo V2.6 tensor-parallel oracles on synthetic checkpoints, one Mac, loopback
# only (correctness, never a timing or a pair qualification):
#   bash libs/darkbloom-cluster-worker/Tests/MiMoTensorParallelOracles/run.sh TP_CHECK SCRATCH_DIR [PORT]
# TP_CHECK is a built darkbloom-cluster-tp-check with a source-matched
# mlx.metallib beside it; SCRATCH_DIR a new directory; PORT the first of two
# free 127.0.0.1 ports for the local ring and socket (default 58223).
# MIMO_ORACLE_PATHS (default "contiguous paged") picks the matrices to run.
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
#
# `contiguous` is the foundation's path (the checkpoint read whole and cut,
# ordinary caches). `paged` is the resident runtime's (`--path paged`): the
# verified load (manifest first, then only this rank's byte runs), paged KV,
# the per-step agreement sum, 100-op decode buffers, greedy logprobs through
# the split top-k gather, sampling with the product's sampler over the
# gathered row. The paged matrix also requires paged `full` and `simulated`
# bitwise equal to contiguous ones, each tp rank to have read exactly its
# shard's bytes, and two refusals: ranks told different agreements, and a
# checkpoint byte changed after its manifest. A 192-token prompt (three
# 64-token pages before decode) runs on both paths and over the ring. Route
# sets are recorded to report where `simulated` first routes a token to other
# experts than `full` (informational; recording must change nothing).
set -euo pipefail
tp_check="$1"
scratch="$2"
port="${3:-58223}"
paths="${MIMO_ORACLE_PATHS:-contiguous paged}"
if [[ ! -x "$tp_check" || -e "$scratch" ]]; then
  echo 'usage: run.sh TP_CHECK NEW_SCRATCH_DIR [PORT]' >&2
  exit 2
fi
mkdir -p "$scratch"
printf '[["127.0.0.1:%d"],["127.0.0.1:%d"]]' "$port" "$((port + 1))" > "$scratch/hosts.json"
failures=0
# Each tp rank's exit status, for the refusal checks.
rank0_status=0
rank1_status=0
tp_pair() {
  local dir="$1" request="$2" tag="$3" backend="$4" environment="$5"; shift 5
  local rank0_extra=()
  if [[ "${RANK0_EXTRA:-}" != "" ]]; then read -r -a rank0_extra <<<"$RANK0_EXTRA"; fi
  env $environment MLX_RANK=0 MLX_HOSTFILE="$scratch/hosts.json" nice -n 19 "$tp_check" mimo run --mode tp \
    --backend "$backend" --reduction sealed-bench --model-dir "$dir" --request "$dir/$request.json" \
    --report "$dir/$tag-rank0.json" --deadline-seconds 300 "$@" ${rank0_extra[@]+"${rank0_extra[@]}"} \
    >"$dir/$tag-rank0.log" 2>&1 &
  local rank0=$!
  rank1_status=0
  env $environment MLX_RANK=1 MLX_HOSTFILE="$scratch/hosts.json" nice -n 19 "$tp_check" mimo run --mode tp \
    --backend "$backend" --reduction sealed-bench --model-dir "$dir" --request "$dir/$request.json" \
    --report "$dir/$tag-rank1.json" --deadline-seconds 300 "$@" >"$dir/$tag-rank1.log" 2>&1 || rank1_status=$?
  rank0_status=0
  wait "$rank0" || rank0_status=$?
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
# A paged tp rank read exactly the bytes its shard holds, and fewer than the whole text.
check_read_bytes() {
  local report="$1" label="$2"
  if python3 - "$report" <<'EOF'
import json, sys
r = json.load(open(sys.argv[1]))
ok = r.get("path") == "paged" and r["readBytes"] == r["loadedParameterBytes"] and r["readBytes"] < r["textBytes"]
print(f"read {r['readBytes']} of {r['textBytes']} text bytes, holds {r['loadedParameterBytes']}")
sys.exit(0 if ok else 1)
EOF
  then echo "$label: read only its byte runs"; else echo "$label: READ MORE THAN ITS SHARD"; failures=$((failures + 1)); fi
}
synthesize() {
  local dir="$1"; shift
  [[ -d "$dir" ]] || nice -n 19 "$tp_check" mimo synthesize --output "$dir" "$@" >/dev/null 2>&1
}
run_variant() {
  local path="$1" name="$2" environment="$3"; shift 3
  local dir="$scratch/$name" prefix="" options=()
  if [[ "$path" == paged ]]; then prefix="paged-"; options=(--path paged); fi
  synthesize "$dir" "$@"
  for request in request request-short; do
    for mode in full simulated; do
      env $environment nice -n 19 "$tp_check" mimo run --mode "$mode" --model-dir "$dir" \
        --request "$dir/$request.json" --report "$dir/$prefix$request-$mode.json" ${options[@]+"${options[@]}"} \
        >"$dir/$prefix$request-$mode.log" 2>&1
    done
    tp_pair "$dir" "$request" "$prefix$request-tp-ring" ring "$environment" ${options[@]+"${options[@]}"}
    check_rank "$dir" "$prefix$request" "$prefix$request-tp-ring" "$path $name/$request (ring)"
    if [[ "$path" == paged ]]; then
      for rank in 0 1; do check_read_bytes "$dir/$prefix$request-tp-ring-rank$rank.json" "paged $name/$request tp rank $rank"; done
    fi
  done
}
run_matrix() {
  local path="$1" prefix="" options=()
  if [[ "$path" == paged ]]; then prefix="paged-"; options=(--path paged); fi
  run_variant "$path" kernel "" --variant kernel
  run_variant "$path" tiny "" --variant tiny
  # Every token takes all 8 experts: no rounding can flip a route.
  run_variant "$path" kernel-all-experts "" --variant kernel --experts 8 --top-k 8
  # Paged histories hold BF16 only, as the product's do: FP32 runs the contiguous path alone.
  if [[ "$path" == contiguous ]]; then
    run_variant "$path" kernel-fp32 "MLX_ENABLE_TF32=0" --variant kernel --dtype float32
  fi
  # The socket backend once, on the production-kernel shapes.
  tp_pair "$scratch/kernel" request "${prefix}request-tp-socket" socket "" ${options[@]+"${options[@]}"}
  check_rank "$scratch/kernel" "${prefix}request" "${prefix}request-tp-socket" "$path kernel/request (socket)"
  # Sampled through the gathered row, on the production-kernel shapes.
  local dir="$scratch/kernel"
  for mode in full simulated; do
    nice -n 19 "$tp_check" mimo run --mode "$mode" --model-dir "$dir" --request "$dir/request.json" \
      --report "$dir/${prefix}sampled-$mode.json" --temperature 0.8 --sample-seed 11 ${options[@]+"${options[@]}"} \
      >"$dir/${prefix}sampled-$mode.log" 2>&1
  done
  tp_pair "$dir" request "${prefix}sampled-tp-ring" ring "" --temperature 0.8 --sample-seed 11 ${options[@]+"${options[@]}"}
  check_rank "$dir" "${prefix}sampled" "${prefix}sampled-tp-ring" "$path kernel/request sampled (ring)" no
}
paged_extras() {
  local dir="$scratch/kernel"
  # The paged path is the contiguous path's arithmetic: same tokens, rows and cache digests.
  if [[ "$paths" == *contiguous* ]]; then
    for mode in full simulated; do
      if "$tp_check" mimo compare --reference "$dir/request-$mode.json" --candidate "$dir/paged-request-$mode.json" \
           --bitwise yes >"$dir/paged-vs-contiguous-$mode.txt" 2>&1; then
        echo "paged kernel/request $mode == contiguous $mode, bitwise"
      else
        echo "paged kernel/request $mode DIFFERS from contiguous"; failures=$((failures + 1))
      fi
    done
  fi
  # Ranks told different agreements refuse before loading.
  RANK0_EXTRA="--agreement-tamper yes" tp_pair "$dir" request paged-tamper-agreement ring "" --path paged
  if [[ $rank0_status -ne 0 && $rank1_status -ne 0 ]] \
       && grep -q "disagree" "$dir/paged-tamper-agreement-rank0.log" "$dir/paged-tamper-agreement-rank1.log"; then
    echo "paged: ranks with different agreements refused (exit $rank0_status / $rank1_status)"
  else
    echo "paged: MISMATCHED AGREEMENT WAS NOT REFUSED"; failures=$((failures + 1))
  fi
  # A checkpoint byte changed after its manifest: the verified load refuses before any tensor is read.
  local tampered="$scratch/kernel-tampered"
  mkdir -p "$tampered"
  for file in config.json manifest.json model.safetensors model.safetensors.index.json request.json; do
    cp -c "$dir/$file" "$tampered/$file"
  done
  python3 - "$tampered/model.safetensors" <<'EOF'
import os, sys
path = sys.argv[1]
with open(path, "r+b") as f:
    f.seek(os.path.getsize(path) // 2)
    byte = f.read(1)
    f.seek(-1, 1)
    f.write(bytes([byte[0] ^ 0x01]))
EOF
  if nice -n 19 "$tp_check" mimo run --mode full --path paged --model-dir "$tampered" --request "$tampered/request.json" \
       --report "$tampered/full.json" >"$tampered/full.log" 2>&1; then
    echo "paged: A TAMPERED CHECKPOINT WAS LOADED"; failures=$((failures + 1))
  elif grep -q "SHA256 mismatch" "$tampered/full.log"; then
    echo "paged: a tampered checkpoint was refused ($(grep -o 'Checkpoint SHA256 mismatch[^"]*' "$tampered/full.log" | head -1))"
  else
    echo "paged: tampered checkpoint failed for another reason"; failures=$((failures + 1))
  fi
}
# A 192-token prompt (three 64-token pages before decode) on the paged path: tp bitwise equal to
# simulated, each rank reading only its runs, and paged full and simulated bitwise equal to contiguous ones.
paged_long() {
  local dir="$scratch/kernel" request=request-long
  for mode in full simulated; do
    nice -n 19 "$tp_check" mimo run --mode "$mode" --path paged --model-dir "$dir" --request "$dir/$request.json" \
      --report "$dir/paged-$request-$mode.json" >"$dir/paged-$request-$mode.log" 2>&1
    nice -n 19 "$tp_check" mimo run --mode "$mode" --model-dir "$dir" --request "$dir/$request.json" \
      --report "$dir/$request-$mode.json" >"$dir/$request-$mode.log" 2>&1
    if "$tp_check" mimo compare --reference "$dir/$request-$mode.json" --candidate "$dir/paged-$request-$mode.json" \
         --bitwise yes >"$dir/paged-vs-contiguous-$request-$mode.txt" 2>&1; then
      echo "paged kernel/$request $mode == contiguous $mode, bitwise"
    else
      echo "paged kernel/$request $mode DIFFERS from contiguous"; failures=$((failures + 1))
    fi
  done
  tp_pair "$dir" "$request" "paged-$request-tp-ring" ring "" --path paged
  check_rank "$dir" "paged-$request" "paged-$request-tp-ring" "paged kernel/$request (ring)"
  for rank in 0 1; do check_read_bytes "$dir/paged-$request-tp-ring-rank$rank.json" "paged kernel/$request tp rank $rank"; done
}
# Route sets (informational): where `simulated` (bitwise `tp`) first routes a token to other experts
# than `full`. Required only that recording the routes changes nothing.
paged_routes() {
  local name request dir
  for name_request in kernel/request kernel/request-short tiny/request kernel-all-experts/request; do
    name="${name_request%/*}" request="${name_request#*/}" dir="$scratch/$name"
    for mode in full simulated; do
      nice -n 19 "$tp_check" mimo run --mode "$mode" --path paged --record-routes yes --model-dir "$dir" \
        --request "$dir/$request.json" --report "$dir/routes-$request-$mode.json" >"$dir/routes-$request-$mode.log" 2>&1
    done
    if "$tp_check" mimo compare --reference "$dir/paged-$request-simulated.json" \
         --candidate "$dir/routes-$request-simulated.json" --bitwise yes >/dev/null 2>&1; then
      echo "paged $name/$request: recording routes changes nothing (bitwise)"
    else
      echo "paged $name/$request: RECORDING ROUTES CHANGED THE RUN"; failures=$((failures + 1))
    fi
    "$tp_check" mimo compare --reference "$dir/routes-$request-full.json" \
      --candidate "$dir/routes-$request-simulated.json" >"$dir/routes-$request.txt" 2>&1 || true
    echo "paged $name/$request: $(grep '^route sets:' "$dir/routes-$request.txt")"
  done
}
for path in $paths; do
  run_matrix "$path"
  if [[ "$path" == paged ]]; then paged_extras; paged_long; paged_routes; fi
done
echo "required failures (tp == simulated bitwise, tp against full, paged extras): $failures"
exit $(( failures == 0 ? 0 : 1 ))
