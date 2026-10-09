#!/bin/bash
# usage: widen.sh KEY CUT        (after D has passed for KEY at CUT)
# Run it under tools/lane.sh (through with-lane.sh). What the order of proof
# puts after D for one cut:
#   this Mac alone: the staged service, four timed requests at 4,096 and 8,192
#     prompt tokens (the single-Mac figure the pair is compared with);
#   then, with tools/lane-b.sh as well: the second Mac's own staged reference
#     at 31, 4,096 and 8,192 prompt tokens compared with this Mac's oracle,
#     and the second Mac alone, timed the same way.
# Gate refusals are waited out and counted; nothing is done to memory.
set -uo pipefail
. "$(dirname "$0")/env.sh"
peer_setup || { echo "the second Mac does not answer over the cable"; exit 30; }
key="$1"; cut="$2"; M=$(local_model "$key"); PM=$(peer_model "$key"); O=$E/$key; A=$O/alone
mkdir -p "$A" "$O/compare" "$O/reference"
ssh_options=(); for o in $PEER_CABLE_SSH_OPTS; do case "$o" in -o|BatchMode=*|ConnectTimeout=*) ;; *) ssh_options+=(--ssh-option "$o") ;; esac; done
alone() { # MAC REQUEST
  local mac="$1" n="$2" stem="alone-$1-$2-cut$cut" attempt=1 rc
  [ -s "$A/$stem.json" ] && { echo "$stem exists; kept"; return 0; }
  while true; do
    if [ "$mac" = a ]; then
      "$B/darkbloom-cluster-pair-check" solo --request "$O/requests/$n.json" --stage-cut "$cut" --report "$A/$stem.json" \
        --service "$B/darkbloom-cluster-reference" --model-dir "$M" --role "Mac A alone" --repetitions 4 \
        --lifetime-seconds 280 > "$A/$stem.stdout.raw" 2> "$A/$stem.stderr.raw"; rc=$?
    else
      "$B/darkbloom-cluster-pair-check" solo --request "$O/requests/$n.json" --stage-cut "$cut" --report "$A/$stem.json" \
        --service "$PEER_BIN/darkbloom-cluster-reference" --model-dir "$PM" --remote-ssh "$PEER_CABLE_SSH" ${ssh_options[@]+"${ssh_options[@]}"} \
        --role "Mac B alone" --repetitions 4 --lifetime-seconds 280 > "$A/$stem.stdout.raw" 2> "$A/$stem.stderr.raw"; rc=$?
    fi
    for s in stdout stderr; do scrub < "$A/$stem.$s.raw" > "$A/$stem.$s"; rm -f "$A/$stem.$s.raw"; done
    if [ -s "$A/$stem.json" ] && grep -q -E "/Users/[^<]|[0-9]{1,3}(\.[0-9]{1,3}){3}" "$A/$stem.json"; then
      scrub < "$A/$stem.json" > "$A/$stem.json.s" && mv -f "$A/$stem.json.s" "$A/$stem.json"; echo "$stem: report scrubbed"
    fi
    if [ $rc != 0 ] && grep -q -s -E "$GATE_REFUSAL" "$A/$stem.json" "$A/$stem.stdout" "$A/$stem.stderr"; then
      echo "$(date -u +%H:%M:%SZ) $stem: memory gate refusal $attempt" | tee -a "$O/gate-refusals.log"
      for f in json stdout stderr; do [ -e "$A/$stem.$f" ] && mv -f "$A/$stem.$f" "$A/$stem.gate-refused-$attempt.$f"; done
      [ $attempt -ge 3 ] && break
      attempt=$((attempt + 1)); sleep 45; continue
    fi
    break
  done
  echo "$stem: status $rc $(date -u +%H:%M:%SZ)"; grep -E "^outcome|^request [0-9]|^repeated|alone:" "$A/$stem.stdout" | cut -c1-300
  return $rc
}
echo "== $key at cut $cut: each Mac alone and the second Mac's reference, $(date -u +%Y-%m-%dT%H:%M:%SZ); Mac A $(vm_line)"
for n in p4k p8k; do alone a $n; done
held_b=no; trap '[ $held_b = yes ] && "$T/tools/lane-b.sh" release >/dev/null 2>&1' EXIT
tries=0
until "$T/tools/lane-b.sh" acquire "gemma4: the second Mac's reference and timed runs alone ($key, cut $cut), about 6 min" >/dev/null 2>&1; do
  tries=$((tries + 1))
  [ $tries -gt "${LANE_B_TRIES:-8}" ] && { echo "lane-b.sh still busy after $tries tries at $(date -u +%H:%M:%SZ): the second Mac's part not started"; exit 20; }
  sleep 40
done
held_b=yes; echo "lane-b.sh held at $(date -u +%H:%M:%SZ)"
"$S/stage-peer.sh" || exit 21
"$T/tools/copy-uncached.sh" "$O/requests" "$PEER_DIR/gemma4/evidence/$key/requests" 2>&1 | scrub | tail -1
"${PEER[@]}" "$PEER_ENV $PEER_G/tools/references.sh $PEER_BIN $PM $PEER_G/evidence/$key/requests $PEER_G/evidence/$key/reference b 'short p4k p8k' '$cut:1' 2>&1" | scrub
"${PEER[@]}" "cd $PEER_G/evidence/$key/reference && tar cf - ref-b-*-cut$cut-run1.json*" | tar xf - -C "$O/reference"
for f in "$O"/reference/ref-b-*-cut$cut-run1.json.std*; do [ -e "$f" ] && { scrub < "$f" > "$f.s"; mv -f "$f.s" "$f"; }; done
for n in short p4k p8k; do
  [ -s "$O/reference/ref-b-$n-cut$cut-run1.json" ] && compare "$O/compare/mac-a-vs-mac-b-$n-cut$cut.txt" "$O/reference/ref-a-$n-cut$cut-run1.json" "$O/reference/ref-b-$n-cut$cut-run1.json" --require exact,tokensEqualLogitsDiffer
done
for n in p4k p8k; do alone b $n; done
echo "Mac B $("${PEER[@]}" "ps -axo command= | grep -c '[d]arkbloom-cluster-reference'") reference processes left; Mac A $(ps -axo command= | grep -c '[d]arkbloom-cluster-reference')"
"$T/tools/lane-b.sh" release >/dev/null 2>&1; held_b=no; echo "lane-b.sh released at $(date -u +%H:%M:%SZ)"
echo "== done $(date -u +%H:%M:%SZ)"
