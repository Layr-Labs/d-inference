#!/bin/bash
# The single M3U GPU ticket for the warmup PR: per model, cold pair 1 (A then B), warm pair (C, D)
# on B's bundle, cold pair 2 with fresh ids in reverse order (B then A); then a coherence smoke.
# Run as: ~/ttft-bench/with_gpu.sh warmup ~/ttft-bench/agents/warmup/job.sh
set -u
W=/Users/gaj/ttft-bench/agents/warmup
BIN=$W/bin
S1=$(date +%s); S2=$((S1 + 1))
echo "=== $(date +%T) job start host=$(hostname -s) bin_md5=$(md5 -q $BIN/darkbloom) metallib_md5=$(md5 -q $BIN/mlx.metallib)"
for spec in "gemma-4-26b-qat-4bit 9800" "gpt-oss-20b 9400"; do
  set -- $spec
  $W/run_arms.sh "$1" "$2" "$BIN" p1 ABCD "$S1"
  $W/run_arms.sh "$1" "$2" "$BIN" p2 BA "$S2"
done
export DARKBLOOM_NO_UPDATE_CHECK=1
for m in gemma-4-26b-qat-4bit gpt-oss-20b; do
  echo "=== $(date +%T) runtime-generation $m"
  $BIN/darkbloom benchmark --config /Users/gaj/ttft-bench/provider.toml --runtime-generation --model "$m" \
    --runtime-prompt-file $W/prompt.txt --max-tokens 64 > $W/out/rg-$m.json 2> $W/out/rg-$m.err
  echo "exit $?"
  /usr/bin/python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print({k:str(v)[:300] for k,v in d.items() if k in ('text','output','completion','generatedText')})" $W/out/rg-$m.json 2>/dev/null || head -c 600 $W/out/rg-$m.json
done
echo "=== $(date +%T) job done"
