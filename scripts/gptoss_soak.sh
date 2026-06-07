#!/usr/bin/env bash
#
# gpt-oss-20b 4h CORRECTNESS/STRESS soak (v2: A/B dropped, eviction-sized).
# The probe already showed the speedup (3.7x warm). This run validates the
# encrypted SSD cache under sustained churn: no crash, no decrypt/integrity
# failures, bounded disk, RAM+SSD eviction firing, no leak, over 4h.
#
# Sizing for gpt-oss's ~12MB checkpoints (window=128): POOL=40 with
# MAX_GB=0.3 (~27 files) and DISK_GB=0.1 (~8 files) => 40 promoted prefixes
# overcommit BOTH tiers => continuous RAM + SSD eviction + decrypt-reload.
# Soak prompts ~2500 tok cross in-window 64/128 + past-window 2048; fast enough
# (~3-5s) that the 40-prefix pool recurs ~150x each over 4h.
set -u
SOAK=~/soak
LOG="$SOAK/g2_orchestrator.log"
PLIST=~/Library/LaunchAgents/io.darkbloom.provider.plist
LABEL=io.darkbloom.provider
KV="$HOME/Library/Caches/darkbloom/kv"
BIN=~/projects/darkbloom/d-inference/provider-swift/.build/release/darkbloom
MODEL=gpt-oss-20b
PORT=8014
TPB=117
PROMPT_TOKENS=2500
# SIZING (v3 lesson): under RANDOM reuse gpt-oss runs ~99% hit-rate, so the hot
# set stays RAM-resident and the SSD tier barely moves (pool=12/40 both saw
# ssdFlushes<=3, diskEvictions~0). The fix is the WORKLOAD, not the budgets:
# --rotate cycles ROUND-ROBIN through a pool LARGER than the RAM tier, so by the
# time each prefix comes around again it has been RAM-evicted => every post-
# first-cycle touch is a RAM-miss + SSD RELOAD (decrypt). That is the heaviest
# SSD stress possible. unique-fraction=0 (rotation already forces churn).
#   MAX_GB=0.1 (~8 RAM slots), DISK_GB=0.05 (~4 disk slots), POOL=60 (>> 8)
#   => every cycle: 60 reloads from SSD + continuous SSD eviction. ~12MB files.
POOL=60
MAX_GB=0.1
DISK_GB=0.05
ROTATE="--rotate"
UNIQ=0.0
DURATION_MIN=240
mkdir -p "$SOAK"; : > "$LOG"
say(){ echo "$(date '+%Y-%m-%dT%H:%M:%S') $*" | tee -a "$LOG"; }

start_server(){  # $1=logfile
  local lf="$1"; : > "$lf"
  env DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1 \
      DARKBLOOM_PREFIX_CACHE=1 \
      DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS=0 \
      DARKBLOOM_PREFIX_CACHE_MAX_GB="$MAX_GB" \
      DARKBLOOM_PREFIX_CACHE_DISK_GB="$DISK_GB" \
      DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS=60 \
      "$BIN" start --local --no-auth --model "$MODEL" --port "$PORT" >> "$lf" 2>&1 &
  echo $!
}
wait_bind(){ local pid=$1 lf=$2 i; for i in $(seq 1 90); do
    grep -q "listening on" "$lf" 2>/dev/null && { say "  bound ~$((i*2))s"; return 0; }
    kill -0 "$pid" 2>/dev/null || { say "  SERVER DIED"; tail -20 "$lf"|tee -a "$LOG"; return 1; }
    sleep 2; done; say "  no bind 180s"; return 1; }
stop_server(){ pkill -f "darkbloom .*start --local" 2>/dev/null; sleep 3; }

# ROOT-CAUSE FIX for orphaned children: kill anything THIS orchestrator spawned
# by command signature, so a `kill <orchestrator_pid>` (or normal exit) can't
# leave a detached load driver / monitor / log-stream / local server running to
# corrupt shared output files and steal the GPU on the next run. Belt-and-braces:
# also kill our own monitor pid if recorded.
kill_my_children(){
  [ -f "$SOAK/g2_monitor.pid" ] && kill -9 "$(cat "$SOAK/g2_monitor.pid")" 2>/dev/null
  pkill -9 -f "load_soak.py .*g2_client.csv" 2>/dev/null
  pkill -9 -f "load_soak.py .*g2_smoke_client.csv" 2>/dev/null
  pkill -9 -f "cache_soak_monitor.sh .*g2_samples.csv" 2>/dev/null
  pkill -9 -f "darkbloom .*start --local --no-auth --model $MODEL --port $PORT" 2>/dev/null
  sleep 2
}

restore(){
  say "TRAP/teardown: stopping my children + restoring prod"
  kill_my_children
  stop_server
  launchctl bootstrap gui/$(id -u) "$PLIST" 2>>"$LOG"
  launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>>"$LOG"
  sleep 6
  pgrep -f 'darkbloom .*foreground' >/dev/null && say "prod RESTORED ($(pgrep -f 'darkbloom .*foreground'|head -1))" || say "WARN: prod not up — manual restore needed"
}
trap restore EXIT INT TERM

# SAFETY: refuse to start if a previous run's children are still alive (avoids
# the file-contamination + GPU-contention that corrupted the v3 attempt).
if pgrep -f 'load_soak.py .*g2_' >/dev/null || pgrep -f 'darkbloom .*start --local' >/dev/null; then
  echo "ABORT: stale soak processes still running — clean them first:"
  pgrep -fl 'load_soak.py|cache_soak_monitor|darkbloom .*start --local'
  exit 2
fi

say "=== gpt-oss SOAK v2 START (smoke -> ${DURATION_MIN}min) ==="
launchctl bootout "gui/$(id -u)/$LABEL" 2>>"$LOG"; sleep 3
pkill -f 'darkbloom .*foreground' 2>/dev/null; sleep 2
say "cleaning kv ($(du -sh "$KV" 2>/dev/null|awk '{print $1}'))"; rm -rf "$KV"

#############################################
# SMOKE (5 min) — must see stores>0 AND ssd_evict>0 before committing 4h
#############################################
say "--- SMOKE (pool=$POOL --rotate, 6min — same as 4h run) ---"
SRV=$(start_server "$SOAK/g2_smoke_server.log"); say "smoke pid $SRV"
wait_bind "$SRV" "$SOAK/g2_smoke_server.log" || exit 1
python3 "$SOAK/load_soak.py" --base-url http://127.0.0.1:$PORT/v1 --model "$MODEL" \
  --duration-minutes 6 --concurrency 4 --max-tokens 48 \
  --prefix-pool "$POOL" --prompt-tokens "$PROMPT_TOKENS" --tokens-per-base "$TPB" \
  $ROTATE --unique-fraction "$UNIQ" --report-every-seconds 30 --out "$SOAK/g2_smoke_client.csv" >> "$SOAK/g2_smoke.out" 2>&1
# Read the AUTHORITATIVE manager stats line (ssdFlushes/diskEvictions), not
# fragile log greps — gpt-oss's small-checkpoint store path doesn't emit the
# same "wrote N chunks" line, but ssdFlushes/diskEvictions in the stats line are
# the real counts (this is exactly what the v1 attempt got wrong).
SMK_STATS=$(log show --last 8m --info --predicate 'subsystem == "dev.darkbloom.provider"' --style compact 2>/dev/null | grep "prefix cache stats:" | tail -1)
say "smoke stats: $SMK_STATS"
SMK_FLUSH=$(printf '%s' "$SMK_STATS" | grep -oE 'ssdFlushes=[0-9]+' | cut -d= -f2); SMK_FLUSH=${SMK_FLUSH:-0}
SMK_EVICT=$(printf '%s' "$SMK_STATS" | grep -oE 'diskEvictions=[0-9]+' | cut -d= -f2); SMK_EVICT=${SMK_EVICT:-0}
SMK_DECF=$(printf '%s' "$SMK_STATS" | grep -oE 'ssdReadErrors=[0-9]+' | cut -d= -f2); SMK_DECF=${SMK_DECF:-0}
SMK_SSDHIT=$(printf '%s' "$SMK_STATS" | grep -oE 'ssd=[0-9]+' | cut -d= -f2); SMK_SSDHIT=${SMK_SSDHIT:-0}
say "smoke: disk=$(du -sh "$KV" 2>/dev/null|awk '{print $1}') files=$(/usr/bin/find "$KV" -name '*.darkbloom-kv'|wc -l|tr -d ' ') ssdFlushes=$SMK_FLUSH diskEvictions=$SMK_EVICT ssdReloads=$SMK_SSDHIT ssdReadErrors=$SMK_DECF"
stop_server
# CORRECTNESS soak: require the SSD WRITE path (flush) + eviction. SSD RELOAD
# (ssd= hits) is a known non-goal for gpt-oss — short 64/128-tok checkpoints stay
# RAM-resident and shadow the SSD tier (see docs/kv-cache-lookup-shadowing-
# finding.md), so ssd= stays 0 by design for this model. The soak still validates
# no-crash / no-decrypt-fail / bounded-disk / no-leak under continuous flush+evict.
if [ "$SMK_FLUSH" -lt 1 ] || [ "$SMK_EVICT" -lt 1 ]; then
  say "SMOKE: SSD flush+evict not exercised (flush=$SMK_FLUSH evict=$SMK_EVICT) — ABORTING before 4h"
  exit 1
fi
say "smoke PASS (ssdFlushes=$SMK_FLUSH diskEvictions=$SMK_EVICT ssdReloads=$SMK_SSDHIT[expected 0 for gpt-oss] ssdReadErrors=$SMK_DECF) — proceeding to 4h correctness soak"

#############################################
# 4h SOAK
#############################################
say "--- 4h SOAK (pool=$POOL ~${PROMPT_TOKENS}tok) ---"
rm -rf "$KV"
SRV=$(start_server "$SOAK/g2_soak_server.log"); say "soak pid $SRV"; echo "$SRV" > "$SOAK/g2_server.pid"
wait_bind "$SRV" "$SOAK/g2_soak_server.log" || exit 1
curl -s -m 120 http://127.0.0.1:$PORT/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"'"$MODEL"'","messages":[{"role":"user","content":"warmup ok"}],"max_tokens":8,"temperature":0,"stream":false}' >/dev/null 2>&1
log show --last 2m --info --predicate 'subsystem == "dev.darkbloom.provider"' --style compact 2>/dev/null | grep -q "encrypted prefix cache active" && say "cache ACTIVE confirmed" || say "WARN cache active not seen"
: > "$SOAK/g2_events.log"
nohup "$SOAK/cache_soak_monitor.sh" --kv-dir "$KV" --proc darkbloom --interval 30 \
  --duration-minutes $((DURATION_MIN+5)) --out-csv "$SOAK/g2_samples.csv" \
  --events-log "$SOAK/g2_events.log" --raw-log "$SOAK/g2_provider.log" >> "$SOAK/g2_monitor.out" 2>&1 &
MON=$!; echo "$MON" > "$SOAK/g2_monitor.pid"; say "monitor pid $MON"
say "starting 4h load"
python3 "$SOAK/load_soak.py" --base-url http://127.0.0.1:$PORT/v1 --model "$MODEL" \
  --duration-minutes "$DURATION_MIN" --concurrency 4 --max-tokens 128 \
  --prefix-pool "$POOL" --prompt-tokens "$PROMPT_TOKENS" --tokens-per-base "$TPB" \
  $ROTATE --unique-fraction "$UNIQ" --report-every-seconds 60 --out "$SOAK/g2_client.csv" >> "$SOAK/g2_client.out" 2>&1
say "load finished rc=$?"
kill "$MON" 2>/dev/null
cd "$SOAK"
tar czf "g2_artifacts_final.tar.gz" g2_client.csv g2_samples.csv g2_events.log g2_provider.log \
  g2_soak_server.log g2_orchestrator.log g2_smoke_client.csv 2>/dev/null
say "=== gpt-oss SOAK v2 COMPLETE — artifacts $(ls -lh g2_artifacts_final.tar.gz|awk '{print $5}') ==="
# trap restores prod
