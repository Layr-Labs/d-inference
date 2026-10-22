#!/bin/bash
# usage: abc.sh KEY CUT
# Steps A, B and C of the order of proof on the Mac that owns the lanes, in one
# hold of tools/lane.sh:
#   A  each rank's stage at CUT, loaded and released;
#   B  the staged reference (the oracle) at 31, 4,096 and 8,192 prompt tokens,
#      each twice, the two runs required to be exact;
#   C  two real workers over the local test socket, 31 and 4,096 prompt
#      tokens, required to be exact against B.
# Stops at the first step that does not pass.
set -uo pipefail
. "$(dirname "$0")/env.sh"
key="$1"; cut="$2"; O=$E/$key
SMOKE_ONLY=1 "$S/ladder1.sh" "$key" "$cut" "" "$cut" || { echo "A or the first reference did not pass (status $?)"; exit 1; }
"$S/references.sh" "$B" "$(local_model "$key")" "$O/requests" "$O/reference" "$MAC" "p4k p8k" "$cut:2" 2>&1 | scrub
fail=0
for n in short p4k p8k; do
  compare "$O/compare/$MAC-$n-cut$cut-run1-vs-run2.txt" "$O/reference/ref-$MAC-$n-cut$cut-run1.json" "$O/reference/ref-$MAC-$n-cut$cut-run2.json" --require exact
  grep -q '^verdict: exact' "$O/compare/$MAC-$n-cut$cut-run1-vs-run2.txt" || fail=1
done
[ $fail = 0 ] || { echo "B did not pass: the oracle is not the same twice"; exit 2; }
echo "B passed: the oracle is exact twice at 31, 4,096 and 8,192 prompt tokens"
ONLY_SMOKE=1 SMOKE_MORE="p4k" "$S/ladder2.sh" "$key" "$cut" "$cut" || { echo "C did not pass (status $?)"; exit 3; }
for n in short p4k; do grep -q '^verdict: exact' "$O/compare/$MAC-pair-vs-reference-$n-cut$cut.txt" || fail=1; done
[ $fail = 0 ] || { echo "C did not pass: the local pair differs from the oracle"; exit 3; }
echo "C passed: two workers over the local socket are exact against the oracle at 31 and 4,096 prompt tokens"
