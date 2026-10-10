#!/bin/bash
# usage: ladder-d.sh KEY CUT
# Step D of the order of proof: the real pair, rank 0 on this Mac and rank 1 on
# the second Mac, joined by the cable (RDMA). Run it inside one hold of
# tools/lane.sh AND tools/lane-b.sh (abcd.sh takes both, in that order), after
# stage-peer.sh has put the same binaries on the second Mac.
#   1 preflight: the link on both Macs, the same binaries, the stage each rank
#     holds loaded and released on the second Mac (step A there), and the
#     pair's own preflight;
#   2 the oracle's requests on the pair in every admitted mode, recorded and
#     compared with the oracle (step B). Gemma 4 admits the pipeline only, with
#     the serial and the one-chunk-lookahead prefill schedules;
#   3 the same requests four times each without recording: first-token time,
#     prefill and decode rates;
#   4 rank 1 ended with SIGTERM while decoding: rank 0 must leave by itself and
#     nothing may stay allocated on either Mac; then one more recorded request.
# A run the host memory gate refuses is waited out and tried again inside the
# hold, three times at most, and every refusal is counted. Nothing is ever done
# to memory. No process is ever sent SIGKILL.
set -uo pipefail
. "$(dirname "$0")/env.sh"
peer_setup || { echo "the second Mac does not answer over the cable"; exit 30; }
key="$1"; cut="$2"; M=$(local_model "$key"); PM=$(peer_model "$key"); O=$E/$key; D=$O/cable; R=$G/run/pair/cable
mkdir -p "$D" "$O/compare" "$O/stage" "$R"
oracle() { echo "$O/reference/ref-a-$1-cut$cut-run1.json"; }
# The request lists can be narrowed (D_RECORDED, D_LOOKAHEAD, D_TIMED; D_SHORT_TIMED=no
# and D_FAULT=no skip those parts), for a later prompt size under the same hold.
RECORDED="${D_RECORDED:-short p4k p8k}"; LOOKAHEAD="${D_LOOKAHEAD:-p4k p8k}"; TIMED="${D_TIMED:-p4k p8k}"
for n in $RECORDED; do [ -s "$(oracle $n)" ] || { echo "no oracle (step B) for $n at cut $cut: D not started"; exit 31; }; done
peer_wired() { "${PEER[@]}" "/usr/bin/vm_stat | /usr/bin/awk -v p=\"\$(/usr/sbin/sysctl -n hw.pagesize)\" '/Pages wired down/ { gsub(\"[.]\", \"\", \$4); printf \"%.0f\", \$4 * p }'"; }
peer_vm_line() { "${PEER[@]}" "/usr/bin/vm_stat | /usr/bin/awk -v p=\"\$(/usr/sbin/sysctl -n hw.pagesize)\" '/Pages free/ {gsub(\"[.]\",\"\",\$3); f=\$3*p} /File-backed pages/ {gsub(\"[.]\",\"\",\$3); c=\$3*p} /Pages wired down/ {gsub(\"[.]\",\"\",\$4); w=\$4*p} /Pages occupied by compressor/ {gsub(\"[.]\",\"\",\$5); z=\$5*p} END {printf \"free %.1f GiB, file-backed %.1f GiB, wired %.1f GiB, compressor %.1f GiB\", f/2^30, c/2^30, w/2^30, z/2^30}'"; }
workers_here() { ps -axo command= | grep "[d]arkbloom-cluster-worker " | grep -c "gemma4"; }
workers_there() { "${PEER[@]}" "ps -axo command= | grep '[d]arkbloom-cluster-worker ' | grep -c gemma4"; }
echo "== D: $key across the cable at cut $cut, rank 0 on Mac A, rank 1 on Mac B, $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "memory before: Mac A $(vm_line); Mac B $(peer_vm_line)" | tee "$D/preflight-cut$cut.txt"

# ---- 1 preflight ------------------------------------------------------------
"$T/bin/darkbloom" cluster link 2>&1 | scrub > "$D/link-a.txt"
grep -q '^Local link: ready' "$D/link-a.txt" || { echo "Mac A: link not ready"; head -5 "$D/link-a.txt"; exit 32; }
"${PEER[@]}" "$PEER_ROOT/bin/darkbloom cluster link 2>&1" | scrub > "$D/link-b.txt"
grep -q '^Local link: ready' "$D/link-b.txt" || { echo "Mac B: link not ready"; head -5 "$D/link-b.txt"; exit 32; }
digest=$(cd "$B" && find . -type f ! -name '.*' -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
[ "$(cat "$E/peer-staging/bin.sha256" 2>/dev/null)" = "$digest" ] || { echo "the binaries on Mac B are not the ones in T/bin/gemma4: run stage-peer.sh"; exit 33; }
echo "link ready on both Macs; binaries on Mac B are the copy of T/bin/gemma4 verified as written ($digest)" | tee -a "$D/preflight-cut$cut.txt"
# Step A on the second Mac: its own verifier reads the artifact; nothing else does.
"${PEER[@]}" "$PEER_ENV $PEER_G/tools/stage-checks.sh $PEER_BIN $PM $PEER_G/evidence/$key/stage b $cut 2>&1" | scrub | tee -a "$D/preflight-cut$cut.txt"
"${PEER[@]}" "cd $PEER_G/evidence/$key/stage && tar cf - stage-b-cut$cut-rank*" | tar xf - -C "$O/stage"
for f in "$O"/stage/stage-b-cut$cut-rank*.stderr; do [ -e "$f" ] && { scrub < "$f" > "$f.s"; mv -f "$f.s" "$f"; }; done
python3 - "$O/stage" "$cut" <<'PY' | tee -a "$D/preflight-cut$cut.txt" || { echo "A did not pass on Mac B: D stopped"; exit 34; }
import json, sys
stage, cut = sys.argv[1], sys.argv[2]
a = json.load(open(f"{stage}/stage-a-cut{cut}-rank0.json"))
ok = True
for rank in (0, 1):
    try: b = json.load(open(f"{stage}/stage-b-cut{cut}-rank{rank}.json"))
    except Exception as e: print(f"Mac B rank {rank}: no receipt ({e})"); ok = False; continue
    same = all(b[k] == a[k] for k in ("storageCommitmentSHA256", "sourceParameterLayoutSHA256", "verifiedAggregateSHA256"))
    print(f"A on Mac B, rank {rank}: {b['loadedTensorBytes']} bytes in {b['loadSeconds']:.1f} s, released {b['modelReleased']}, "
          f"active after {b['activeBytesAfterRelease']}, commitment/layout/aggregate equal to Mac A's: {same}")
    ok = ok and same and b["modelReleased"]
sys.exit(0 if ok else 1)
PY
ssh_options=(); for o in $PEER_CABLE_SSH_OPTS; do case "$o" in -o|BatchMode=*|ConnectTimeout=*) ;; *) ssh_options+=(--ssh-option "$o") ;; esac; done
refusals=0
cable() { # STEM REQUEST SCHEDULE [extra pair-check flags]
  local stem="$1" request="$2" schedule="$3"; shift 3
  [ -s "$D/$stem.json" ] && { echo "$stem exists; kept"; return 0; }
  local attempt=1 rc address port
  while true; do
    address=$(ipconfig getifaddr "$LOCAL_IF") || { echo "no address on the link interface"; return 96; }
    port=$(( 48000 + (RANDOM % 900) ))
    "$B/darkbloom-cluster-pair-check" run --request "$O/requests/$request.json" --stage-cut "$cut" --report "$D/$stem.json" \
      --remote-ssh "$PEER_CABLE_SSH" ${ssh_options[@]+"${ssh_options[@]}"} \
      --local-worker "$B/darkbloom-cluster-worker" --remote-worker "$PEER_BIN/darkbloom-cluster-worker" \
      --local-model-dir "$M" --remote-model-dir "$PM" \
      --local-rdma-device "$LOCAL_RDMA" --remote-rdma-device "$PEER_RDMA" --coordinator "$address:$port" \
      --mode pipeline --prefill-schedule "$schedule" --local-scratch-dir "$R" --remote-scratch-dir "$PEER_ROOT/run/gemma4/pair" \
      --lifetime-seconds "${LIFETIME:-280}" --startup-seconds "${STARTUP:-150}" "$@" > "$D/$stem.stdout.raw" 2> "$D/$stem.stderr.raw"; rc=$?
    for s in stdout stderr; do scrub < "$D/$stem.$s.raw" > "$D/$stem.$s"; rm -f "$D/$stem.$s.raw"; done
    # A report names roles. A path or an address in it is removed the same way.
    if [ -s "$D/$stem.json" ] && grep -q -E "/Users/[^<]|[0-9]{1,3}(\.[0-9]{1,3}){3}" "$D/$stem.json"; then
      scrub < "$D/$stem.json" > "$D/$stem.json.s" && mv -f "$D/$stem.json.s" "$D/$stem.json"; echo "$stem: report scrubbed"
    fi
    if [ $rc != 0 ] && grep -q -s -E "$GATE_REFUSAL" "$D/$stem.json" "$D/$stem.stdout" "$D/$stem.stderr"; then
      refusals=$((refusals + 1))
      echo "$(date -u +%H:%M:%SZ) $stem: memory gate refusal $attempt" | tee -a "$O/gate-refusals.log"
      for f in json stdout stderr; do [ -e "$D/$stem.$f" ] && mv -f "$D/$stem.$f" "$D/$stem.gate-refused-$attempt.$f"; done
      [ $attempt -ge "${GATE_TRIES:-3}" ] && break
      attempt=$((attempt + 1)); sleep 45; continue
    fi
    break
  done
  echo "$stem: status $rc $(date -u +%H:%M:%SZ)"; grep -E "^outcome|^rank [01]|^tokens|^request [0-9]|^repeated" "$D/$stem.stdout" | cut -c1-330
  return $rc
}
cable "preflight-cut$cut" short serial_v1 --evidence none --preflight-only yes || { tail -8 "$D/preflight-cut$cut.stderr"; echo "pair preflight failed: D stopped"; exit 35; }

# ---- 2 recorded, against the oracle ------------------------------------------
fail=0
for n in $RECORDED; do
  cable "pair-$n-cut$cut-serial" $n serial_v1 || { fail=1; tail -6 "$D/pair-$n-cut$cut-serial.stderr"; continue; }
  compare "$O/compare/cable-vs-oracle-$n-cut$cut-serial.txt" "$(oracle $n)" "$D/pair-$n-cut$cut-serial.json" --require exact,tokensEqualLogitsDiffer
  grep -q -E '^verdict: (exact|tokensEqualLogitsDiffer)' "$O/compare/cable-vs-oracle-$n-cut$cut-serial.txt" || fail=1
done
for n in $LOOKAHEAD; do
  cable "pair-$n-cut$cut-lookahead" $n one_chunk_lookahead_v1 || { fail=1; tail -6 "$D/pair-$n-cut$cut-lookahead.stderr"; continue; }
  compare "$O/compare/cable-vs-oracle-$n-cut$cut-lookahead.txt" "$(oracle $n)" "$D/pair-$n-cut$cut-lookahead.json" --allow-schedule-difference yes --require exact,tokensEqualLogitsDiffer
  grep -q -E '^verdict: (exact|tokensEqualLogitsDiffer)' "$O/compare/cable-vs-oracle-$n-cut$cut-lookahead.txt" || fail=1
  [ -s "$D/pair-$n-cut$cut-serial.json" ] && compare "$O/compare/cable-serial-vs-lookahead-$n-cut$cut.txt" "$D/pair-$n-cut$cut-serial.json" "$D/pair-$n-cut$cut-lookahead.json" --allow-schedule-difference yes --require exact
done

# ---- 3 timed: four requests per run, nothing recorded ------------------------
for n in $TIMED; do
  cable "timed-$n-cut$cut-serial" $n serial_v1 --evidence none --repetitions 4 || fail=1
  cable "timed-$n-cut$cut-lookahead" $n one_chunk_lookahead_v1 --evidence none --repetitions 4 || fail=1
done
[ "${D_SHORT_TIMED:-yes}" = yes ] && { cable "timed-short-cut$cut-serial" short serial_v1 --evidence none --repetitions 4 || fail=1; }

# ---- 4 one rank ended mid-decode ---------------------------------------------
stem="fault-rank1-sigterm-mid-decode-cut$cut"
if [ "${D_FAULT:-yes}" != yes ]; then echo "fault and the request after it: not part of this run"; elif [ -s "$D/$stem.observation.json" ]; then echo "$stem exists; kept"; else
  before_a=$(wired_bytes); before_b=$(peer_wired)
  trigger="$R/fault-trigger.$$"; rm -f "$trigger"; mkfifo "$trigger"; exec 9<> "$trigger"
  # The session to the second Mac is open before the request starts, so the
  # signal is not late by a connection. It acts on the one word `go`.
  "${PEER[@]}" "read word; [ \"\$word\" = go ] || exit 0; pid=\$(ps -axo pid=,command= | grep '[d]arkbloom-cluster-worker ' | grep -e '--rank 1 ' | grep gemma4 | awk '{print \$1}' | head -1); if [ -n \"\$pid\" ]; then kill -TERM \"\$pid\" && echo 'rank 1 worker ended with SIGTERM'; else echo 'rank 1 worker not found'; fi" < "$trigger" > "$D/$stem.signal.txt" 2>&1 &
  killer=$!
  ( GATE_TRIES=1 LIFETIME=150 STARTUP=120; cable "$stem" p8k serial_v1 --progress-timeout-ms 10000 --request-seconds 90 ) > "$D/$stem.driver.txt" 2>&1 &
  driver=$!
  seen=no
  for _ in $(seq 1 4400); do
    grep -q "first committed token" "$D/$stem.stderr.raw" 2>/dev/null && { seen=yes; break; }
    kill -0 $driver 2>/dev/null || break; sleep 0.05
  done
  sleep "${END_DELAY:-0.3}"
  if [ $seen = yes ]; then echo go >&9; echo "signal sent at $(date -u +%H:%M:%SZ), ${END_DELAY:-0.3} s after the first committed token was reported" | tee -a "$D/$stem.signal.txt"
  else echo none >&9; echo "the first token was never reported: no rank was ended" | tee -a "$D/$stem.signal.txt"; fi
  wait $killer 2>/dev/null; exec 9>&-; rm -f "$trigger"
  began=$(date +%s); wait $driver; rc=$?
  echo "driver status $rc, $(( $(date +%s) - began )) s after the signal" | tee -a "$D/$stem.signal.txt"
  cat "$D/$stem.driver.txt"; sleep 5
  left_a=$(workers_here); left_b=$(workers_there); after_a=$(wired_bytes); after_b=$(peer_wired)
  printf '{"run":"%s","endedRank":1,"firstTokenSeen":"%s","driverStatus":%d,"workerProcessesLeftMacA":%s,"workerProcessesLeftMacB":%s,"wiredBytesBeforeMacA":%s,"wiredBytesAfterMacA":%s,"wiredBytesBeforeMacB":%s,"wiredBytesAfterMacB":%s}\n' \
    "$stem" "$seen" "$rc" "${left_a:-null}" "${left_b:-null}" "${before_a:-null}" "${after_a:-null}" "${before_b:-null}" "${after_b:-null}" | tee "$D/$stem.observation.json"
  python3 - "$D/$stem.json" <<'PY'
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception as e: print("no report:", e); sys.exit(0)
print("outcome:", d.get("outcome"), "|", (d.get("failure") or "")[:300])
for r in d.get("ranks") or []:
    print("  %s: exit %s signal %s, processes left %s, signals sent by the driver %s" % (r.get("role"), r.get("exitStatus"), r.get("exitSignal"), r.get("workerProcessesLeft"), r.get("signalsSentByDriver")))
    for line in (r.get("runtimeLines") or [])[-3:]: print("     ", line[:260])
PY
fi
if [ "${D_FAULT:-yes}" = yes ]; then
cable "pair-short-cut$cut-after-fault" short serial_v1 || fail=1
[ -s "$D/pair-short-cut$cut-after-fault.json" ] && compare "$O/compare/cable-after-fault-vs-oracle-short-cut$cut.txt" "$(oracle short)" "$D/pair-short-cut$cut-after-fault.json" --require exact,tokensEqualLogitsDiffer
fi
echo "memory after: Mac A $(vm_line); Mac B $(peer_vm_line); worker processes left: Mac A $(workers_here), Mac B $(workers_there)"
echo "gate refusals in this run: $refusals"
echo "== D for $key at cut $cut ended $(date -u +%Y-%m-%dT%H:%M:%SZ); recorded and timed runs $([ $fail = 0 ] && echo 'all passed' || echo 'NOT all passed')"
exit $fail
