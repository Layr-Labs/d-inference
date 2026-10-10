#!/bin/bash
# The registered Qwen3.5 9B through this branch's binaries: its stage receipts
# against the ones recorded before the change, and its staged reference on the
# earlier 8,192-token request against the report an earlier build wrote.
set -uo pipefail
. "$(dirname "$0")/env.sh"
O=$E/qwen-regression; mkdir -p $O
Q=$T/scratch/night-bench/cache/models--Qwen3.5-9B/snapshots/2026-09-03-r1
P=$T/evidence/phase-split-20261009T055312Z
export DARKBLOOM_CBV2_ATTN_QUERY_BLOCK=128 DARKBLOOM_BF16_WEIGHTS=1 MLX_ENABLE_TF32=1
echo "== Qwen 9B regression on Mac A $(date -u +%H:%M:%SZ) host: $(vm_line)"
for rank in 0 1; do
  [ -e $O/stage-9b-cut8-rank$rank.json ] || "$B/darkbloom-cluster-stage-check" --model-dir "$Q" --rank $rank --stage-cut 8 --deadline-seconds 200 > $O/stage-9b-cut8-rank$rank.json 2> $O/stage-9b-cut8-rank$rank.stderr
  echo "9B cut 8 rank $rank exit $?"
done
python3 - "$O" "$T/evidence/stage-check/rank0-cut8.json" <<'PY'
import json,sys
old=json.load(open(sys.argv[2]))
for rank in (0,1):
    new=json.load(open(f"{sys.argv[1]}/stage-9b-cut8-rank{rank}.json"))
    same=all(new[k]==old[k] for k in ("storageCommitmentSHA256","sourceParameterLayoutSHA256","verifiedAggregateSHA256"))
    print(f"rank {rank}: commitment {new['storageCommitmentSHA256'][:16]} layout {new['sourceParameterLayoutSHA256'][:16]} equal to the recorded receipt: {same}; loaded {new['loadedTensorBytes']} bytes" + (f" (recorded {old['loadedTensorBytes']})" if rank==0 else ""), "released", new["modelReleased"], "active after", new["activeBytesAfterRelease"])
PY
[ -e $O/ref-9b-g2max-cut4.json ] || "$B/darkbloom-cluster-reference" --model-dir "$Q" --request "$P/request-g2max.json" --stage-cut 4 --report $O/ref-9b-g2max-cut4.json --deadline-seconds 280 > $O/ref-9b-g2max-cut4.stdout 2> $O/ref-9b-g2max-cut4.stderr
echo "9B reference exit $?"
compare $O/compare-9b-earlier-build-vs-this-build-g2max-cut4.txt $P/earlier-reference-g2max-cut4.json $O/ref-9b-g2max-cut4.json --require exact
pgrep -fl "darkbloom-cluster-(reference|stage-check)" || echo "no process left"
echo "== done $(date -u +%H:%M:%SZ)"
