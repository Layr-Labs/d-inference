#!/bin/bash
# usage: ladder1.sh KEY SMOKE_CUT "OTHER CUTS" SECOND_CUT
# One Mac, one process at a time: artifact against its catalog manifest, stage
# loads, staged references, and the comparison with the product. Fails fast:
# the first cut's load and a short reference must work before anything longer.
set -uo pipefail
. "$(dirname "$0")/env.sh"
key="$1"; smoke="$2"; others="$3"; second="$4"; M=$(local_model "$key"); O=$E/$key
mkdir -p $O/{artifact,stage,requests,reference,product,compare}
echo "== $key on Mac $MAC $(date -u +%H:%M:%SZ) host: $(vm_line)"
shasum -a 256 $B/darkbloom-cluster-* $B/mlx.metallib | sed -e "s#$B/##" > $O/binaries.sha256
# The catalog manifest is checked file by file on the first Mac only. On the
# peer nothing reads an artifact through the file cache: the stage check's own
# verifier (the registered aggregate, in every receipt) is the check there.
VERIFY=$T/wt-bench/scripts/benchmarks/cluster/verify_artifact.py
if [ "$MAC" = a ] && [ -e "$VERIFY" ]; then
  python3 "$VERIFY" --manifest "$M/manifest.json" --dir "$M" --receipt "$O/artifact/verify-mac-$MAC.json" 2>&1 | scrub | tail -3
  python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print('artifact identical:', r['identical'], r['matched_files'], 'of', r['manifest_file_count'], 'files', r['hashed_bytes'], 'bytes in', r['seconds'], 's')" "$O/artifact/verify-mac-$MAC.json" || exit 10
fi
echo "-- smoke: stage loads at cut $smoke"
$S/stage-checks.sh $B "$M" $O/stage $MAC $smoke 2>&1 | scrub
for r in 0 1; do python3 -c "import json,sys; json.load(open(sys.argv[1]))['storageCommitmentSHA256']" $O/stage/stage-$MAC-cut$smoke-rank$r.json 2>/dev/null || { echo "SMOKE FAILED: stage load cut $smoke rank $r"; tail -5 $O/stage/stage-$MAC-cut$smoke-rank$r.stderr | scrub; exit 11; }; done
echo "-- requests"
$S/make-requests.sh $B "$M" $O/requests $S/prompts 2>&1 | scrub | tail -8 || exit 12
echo "-- smoke: short reference at cut $smoke"
$S/references.sh $B "$M" $O/requests $O/reference $MAC "short" "$smoke:1" 2>&1 | scrub
[ -s $O/reference/ref-$MAC-short-cut$smoke-run1.json ] || { echo "SMOKE FAILED: short reference"; tail -5 $O/reference/ref-$MAC-short-cut$smoke-run1.json.stderr | scrub; exit 13; }
python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print('short reference:', r['evidence']['finishReason'], len(r['evidence']['selectedTokenIDs']), 'tokens;', repr(r.get('decodedOutput','')[:160]))" $O/reference/ref-$MAC-short-cut$smoke-run1.json
if [ "${SMOKE_ONLY:-0}" = 1 ]; then
  $S/references.sh $B "$M" $O/requests $O/reference $MAC "short" "$smoke:2" 2>&1 | scrub
  compare $O/compare/$MAC-short-cut$smoke-run1-vs-run2.txt $O/reference/ref-$MAC-short-cut$smoke-run1.json $O/reference/ref-$MAC-short-cut$smoke-run2.json --require exact
  echo "== done $key smoke (stage loads, oracle twice) on Mac $MAC $(date -u +%H:%M:%SZ) host: $(vm_line)"; exit 0
fi
echo "-- remaining stage loads: $others $(date -u +%H:%M:%SZ)"
$S/stage-checks.sh $B "$M" $O/stage $MAC $others 2>&1 | scrub
echo "-- references $(date -u +%H:%M:%SZ) host: $(vm_line)"
$S/references.sh $B "$M" $O/requests $O/reference $MAC "short p4k p8k" "$smoke:2 $second:1" 2>&1 | scrub
$S/references.sh $B "$M" $O/requests $O/reference $MAC "prod-short prod-4k prod-8k" "$smoke:1" 2>&1 | scrub
for n in short p4k p8k; do
  compare $O/compare/$MAC-$n-cut$smoke-run1-vs-run2.txt $O/reference/ref-$MAC-$n-cut$smoke-run1.json $O/reference/ref-$MAC-$n-cut$smoke-run2.json --require exact
  compare $O/compare/$MAC-$n-cut$smoke-vs-cut$second.txt $O/reference/ref-$MAC-$n-cut$smoke-run1.json $O/reference/ref-$MAC-$n-cut$second-run1.json --allow-cut-difference yes --require exact
done
if [ ! -x "$APP" ]; then echo "-- product: no app layout on this Mac ($APP); skipped"; echo "== done $key ladder1 on Mac $MAC $(date -u +%H:%M:%SZ)"; exit 0; fi
echo "-- product, MTP off, app layout $(date -u +%H:%M:%SZ) host: $(vm_line)"
# The configuration names its model cache relative to itself, so it runs from the work directory.
mkdir -p $G/product && cp -f "$S/provider-mtp-off.toml" $G/product/provider-mtp-off.toml
shasum -a 256 $APP $(dirname $APP)/mlx.metallib | sed -e "s#$(dirname $APP)/##" > $O/product/product-binaries.sha256
python3 $S/product_tokens.py --binary $APP --work $G/product --config $G/product/provider-mtp-off.toml --model "$(catalog_id "$key")" \
  --port 18311 --out $O/product/product-$MAC.json --max-tokens 128 $S/prompts/prod-short.txt $S/prompts/prod-4k.txt $S/prompts/prod-8k.txt 2>&1 | scrub | tail -6
pgrep -fl "Darkbloom.app/Contents/MacOS/darkbloom start --local.*18311" | scrub || echo "no product server left"
python3 -c "import tokenizers" 2>/dev/null || { echo "no Python tokenizers here; the product's text is compared on the other Mac"; echo "== done $key ladder1 on Mac $MAC $(date -u +%H:%M:%SZ) host: $(vm_line)"; exit 0; }
for n in prod-short prod-4k prod-8k; do
  python3 $S/product_compare.py "$M/tokenizer.json" $O/product/product-$MAC.json $n.txt $O/reference/ref-$MAC-$n-cut$smoke-run1.json > $O/compare/$MAC-product-vs-reference-$n.json 2>&1
  python3 -c "import json,sys; r=json.load(open(sys.argv[1])); print(sys.argv[2], 'tokens_equal', r['tokens_equal'], 'compared', r['compared_tokens'], 'first_difference', r['first_difference'], 'prompt tokens', r['product_prompt_tokens'], r['reference_prompt_tokens'], r.get('at_difference',{}).get('margin_top1_top2'))" $O/compare/$MAC-product-vs-reference-$n.json $n 2>&1 | tail -1
done
echo "== done $key ladder1 on Mac $MAC $(date -u +%H:%M:%SZ) host: $(vm_line)"
