#!/bin/bash
# usage: same-hold.sh KEY CUT NAME PROMPT_TOKENS OUTPUTS
# One prompt size, everything the comparison table needs, in one hold of
# tools/lane.sh (through with-lane.sh): the request, the oracle on this Mac
# twice (exact), this Mac alone timed, then (taking tools/lane-b.sh) the second
# Mac's reference and the second Mac alone timed, then the pair recorded against
# the oracle and timed in both prefill schedules. PROMPT_TOKENS must be within
# the adapter profile's cap (8,192 today); no limit is changed here.
set -uo pipefail
. "$(dirname "$0")/env.sh"
key="$1"; cut="$2"; name="$3"; tokens="$4"; outputs="$5"; O=$E/$key
mkdir -p "$O/requests" "$O/reference" "$O/compare"
[ -e "$O/requests/$name.json" ] || "$B/darkbloom-cluster-pair-check" request --output "$O/requests/$name.json" --chunk-size 512 \
  --output-count "$outputs" --model-dir "$(local_model "$key")" --user-text-file "$S/prompts/long-passage.txt" --prompt-tokens "$tokens" 2>&1 | scrub
echo "== $key $name ($tokens prompt tokens) at cut $cut, one hold, $(date -u +%H:%M:%SZ)"
"$S/references.sh" "$B" "$(local_model "$key")" "$O/requests" "$O/reference" a "$name" "$cut:2" 2>&1 | scrub
compare "$O/compare/a-$name-cut$cut-run1-vs-run2.txt" "$O/reference/ref-a-$name-cut$cut-run1.json" "$O/reference/ref-a-$name-cut$cut-run2.json" --require exact
grep -q '^verdict: exact' "$O/compare/a-$name-cut$cut-run1-vs-run2.txt" || { echo "the oracle is not the same twice: stopped"; exit 2; }
W_ALONE="$name" W_BREF="$name" "$S/widen.sh" "$key" "$cut" || echo "widen status $?"
SKIP_ABC=yes D_RECORDED="$name" D_LOOKAHEAD="$name" D_TIMED="$name" D_SHORT_TIMED=no D_FAULT=no "$S/abcd.sh" "$key" "$cut"
