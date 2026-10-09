#!/bin/bash
# usage: ladder2.sh KEY CUT SECOND_CUT
# Two real worker ranks on ONE Mac over the local test socket (correctness only;
# never RDMA, never a pair timing): the pipeline against this Mac's staged
# reference, one run with lookahead, one at a second cut, then one fault (rank 1
# ended with SIGTERM while decoding) and a run after it.
set -uo pipefail
. "$(dirname "$0")/env.sh"
key="$1"; cut="$2"; second="$3"; M=$(local_model "$key"); O=$E/$key; R=$G/run/pair
mkdir -p $O/pair $O/fault $O/compare $R/r0 $R/r1
LIFETIME=${LIFETIME:-280}; STARTUP=${STARTUP:-200}
pair() { # STEM REQUEST CUT extra flags...
  local stem="$1" request="$2" c="$3"; shift 3
  local port=$(( 47000 + (RANDOM % 900) ))
  [ -s "$O/pair/$stem.json" ] && { echo "$stem exists; kept"; return 0; }
  local attempt=1 rc
  while true; do
  port=$(( 47000 + (RANDOM % 900) ))
  "$B/darkbloom-cluster-pair-check" run --request "$O/requests/$request.json" --stage-cut "$c" --report "$O/pair/$stem.json" \
    --remote-command-prefix /bin/sh --remote-command-prefix -c --transport local-socket-test --coordinator "127.0.0.1:$port" \
    --local-worker "$B/darkbloom-cluster-worker" --remote-worker "$B/darkbloom-cluster-worker" \
    --local-model-dir "$M" --remote-model-dir "$M" --local-rdma-device rdma_en5 --remote-rdma-device rdma_en6 --mode pipeline \
    --local-scratch-dir "$R/r0" --remote-scratch-dir "$R/r1" --lifetime-seconds "$LIFETIME" --startup-seconds "$STARTUP" \
    --request-seconds 200 "$@" > "$O/pair/$stem.stdout.raw" 2> "$O/pair/$stem.stderr.raw"
  rc=$?
  for s in stdout stderr; do scrub < "$O/pair/$stem.$s.raw" > "$O/pair/$stem.$s"; rm -f "$O/pair/$stem.$s.raw"; done
  # A refusal by the host memory gate: wait and retry, twice at most. Nothing is done to memory.
  if [ $rc != 0 ] && grep -q -s -E "$GATE_REFUSAL" "$O/pair/$stem.json" "$O/pair/$stem.stdout" "$O/pair/$stem.stderr"; then
    echo "$(date -u +%H:%M:%SZ) $stem: memory gate refusal $attempt" | tee -a "$O/gate-refusals.log"
    for f in json stdout stderr; do [ -e "$O/pair/$stem.$f" ] && mv -f "$O/pair/$stem.$f" "$O/pair/$stem.gate-refused-$attempt.$f"; done
    [ $attempt -ge 3 ] && break
    attempt=$((attempt + 1)); sleep 45; continue
  fi
  break
  done
  echo "$stem: status $rc $(date -u +%H:%M:%SZ); $(grep -E '^outcome' "$O/pair/$stem.stdout" | head -1 | cut -c1-200)"
  return $rc
}
workers() { pgrep -fl "$B/darkbloom-cluster-worker" | scrub | cut -c1-120; }
echo "== $key pair on Mac $MAC, cut $cut $(date -u +%H:%M:%SZ) host: $(vm_line)"
workers && { echo "a worker is already running; stopping here"; exit 20; }
pair pair-$MAC-short-cut$cut-serial short $cut || { tail -12 $O/pair/pair-$MAC-short-cut$cut-serial.stderr; echo "PAIR SMOKE FAILED"; workers; exit 21; }
compare $O/compare/$MAC-pair-vs-reference-short-cut$cut.txt $O/reference/ref-$MAC-short-cut$cut-run1.json $O/pair/pair-$MAC-short-cut$cut-serial.json --require exact
if [ "${ONLY_SMOKE:-0}" = 1 ]; then
  for n in ${SMOKE_MORE:-}; do
    pair pair-$MAC-$n-cut$cut-serial $n $cut
    compare $O/compare/$MAC-pair-vs-reference-$n-cut$cut.txt $O/reference/ref-$MAC-$n-cut$cut-run1.json $O/pair/pair-$MAC-$n-cut$cut-serial.json --require exact
  done
  workers || echo "no worker process left"; echo "== done $key pair smoke on Mac $MAC $(date -u +%H:%M:%SZ) host: $(vm_line)"; exit 0; fi
for n in p4k p8k; do
  pair pair-$MAC-$n-cut$cut-serial $n $cut
  compare $O/compare/$MAC-pair-vs-reference-$n-cut$cut.txt $O/reference/ref-$MAC-$n-cut$cut-run1.json $O/pair/pair-$MAC-$n-cut$cut-serial.json --require exact
done
pair pair-$MAC-p8k-cut$cut-lookahead p8k $cut --prefill-schedule one_chunk_lookahead_v1
compare $O/compare/$MAC-pair-lookahead-vs-reference-p8k-cut$cut.txt $O/reference/ref-$MAC-p8k-cut$cut-run1.json $O/pair/pair-$MAC-p8k-cut$cut-lookahead.json --allow-schedule-difference yes --require exact
pair pair-$MAC-p4k-cut$second-serial p4k $second
compare $O/compare/$MAC-pair-vs-reference-p4k-cut$second.txt $O/reference/ref-$MAC-p4k-cut$second-run1.json $O/pair/pair-$MAC-p4k-cut$second-serial.json --require exact
echo "-- fault: rank 1 ended with SIGTERM while decoding $(date -u +%H:%M:%SZ) host: $(vm_line)"
F=$O/fault/fault-$MAC-rank1-sigterm-mid-decode
# The fault request is the short prompt with 128 outputs: 127 decode frames
# after the first token. The driver announces the first committed token; the
# signal follows it by `delay` seconds.
delay=1.5
attempt=1
while [ ! -e $F.json ] && [ $attempt -le 3 ]; do
  A=$F.attempt$attempt
  vm_stat > $A.vmstat-before.txt
  port=$(( 47000 + (RANDOM % 900) ))
  "$B/darkbloom-cluster-pair-check" run --request "$O/requests/fault128.json" --stage-cut "$cut" --report "$A.json" \
    --remote-command-prefix /bin/sh --remote-command-prefix -c --transport local-socket-test --coordinator "127.0.0.1:$port" \
    --local-worker "$B/darkbloom-cluster-worker" --remote-worker "$B/darkbloom-cluster-worker" \
    --local-model-dir "$M" --remote-model-dir "$M" --local-rdma-device rdma_en5 --remote-rdma-device rdma_en6 --mode pipeline \
    --local-scratch-dir "$R/r0" --remote-scratch-dir "$R/r1" --lifetime-seconds "$LIFETIME" --startup-seconds "$STARTUP" \
    --request-seconds 120 --evidence none --progress-timeout-ms 10000 > "$A.stdout.raw" 2> "$A.stderr.raw" &
  driver=$!
  until grep -q "first committed token" "$A.stderr.raw" 2>/dev/null || ! kill -0 $driver 2>/dev/null; do sleep 0.05; done
  sleep "$delay"
  rank1=$(pgrep -f "darkbloom-cluster-worker --model-dir .* --rank 1 " | head -1)
  echo "attempt $attempt: SIGTERM to rank 1 (pid ${rank1:-none}) $delay s after the first committed token, $(date -u +%H:%M:%SZ)" | tee $A.action.txt
  [ -n "${rank1:-}" ] && kill -TERM "$rank1"
  began=$(date +%s)
  wait $driver; echo "driver exit $? after $(( $(date +%s) - began )) s" | tee -a $A.action.txt
  for s in stdout stderr; do scrub < "$A.$s.raw" > "$A.$s"; rm -f "$A.$s.raw"; done
  sleep 2; vm_stat > $A.vmstat-after.txt
  { echo "workers after the fault:"; workers || echo "none"; } | tee -a $A.action.txt
  grep -E "^outcome|^rank [01]|pair-check:" $A.stdout $A.stderr | cut -c1-330 | tail -10
  find $R/r0 $R/r1 -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null
  committed=$(grep -oE "after [0-9]+ committed token" $A.stdout $A.stderr | grep -oE "[0-9]+" | head -1)
  if grep -q "^outcome: completed\|^outcome: passed" $A.stdout; then
    echo "the request finished before the signal; next attempt signals sooner"; delay=$(python3 -c "print(round($delay * 0.4, 2))")
  elif [ "${committed:-0}" -ge 1 ] && [ "${committed:-0}" -le 126 ]; then
    for f in json stdout stderr action.txt vmstat-before.txt vmstat-after.txt; do cp $A.$f $F.$f; done
    echo "fault landed mid-decode after $committed committed tokens"
  else
    echo "the signal did not land between the first and the last token (committed: ${committed:-unknown}); trying again"
  fi
  attempt=$((attempt + 1))
done
[ -e $F.json ] || echo "FAULT NOT PLACED MID-DECODE in 3 attempts; see $F.attempt*"
echo "-- after the fault $(date -u +%H:%M:%SZ) host: $(vm_line)"
pair pair-$MAC-short-cut$cut-after-fault short $cut
compare $O/compare/$MAC-pair-after-fault-vs-reference-short-cut$cut.txt $O/reference/ref-$MAC-short-cut$cut-run1.json $O/pair/pair-$MAC-short-cut$cut-after-fault.json --require exact
workers || echo "no worker process left"
echo "== done $key ladder2 on Mac $MAC $(date -u +%H:%M:%SZ) host: $(vm_line)"
