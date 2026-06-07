#!/usr/bin/env bash
#
# cache_soak_monitor.sh — provider-side observer for the SSD KV-cache soak.
#
# The Swift provider logs cache behavior through Apple's unified logging
# (os.Logger, subsystem "dev.darkbloom.provider"), NOT stdout. So this script
# owns a background `log stream` into a raw file and, each sample tick, reads
# only the bytes appended since the last tick and tallies the cache markers.
# It also samples on-disk state, the darkbloom process RSS, and CPU thermal
# throttling directly (all without sudo).
#
# Outputs:
#   --out-csv     : one row per interval (disk, files, rss, thermal, marker deltas)
#   --events-log  : append-only log of notable events (evictions, decrypt fails,
#                   MB-1 drops, hash mismatches) with timestamps
#   --raw-log     : the full `log stream` capture (subsystem-filtered, debug level)
#
# macOS only; bash 3.2 compatible (the system bash on the M5). No deps beyond
# coreutils + log + pmset + ps, all stock.
#
# Usage:
#   ./cache_soak_monitor.sh \
#       --kv-dir "$HOME/Library/Caches/darkbloom/kv" \
#       --proc darkbloom \
#       --interval 30 \
#       --out-csv soak_samples.csv \
#       --events-log soak_events.log \
#       --raw-log soak_provider.log \
#       [--duration-minutes 240]   # optional auto-stop; omit to run until Ctrl-C
set -uo pipefail

KV_DIR="$HOME/Library/Caches/darkbloom/kv"
PROC="darkbloom"
INTERVAL=30
OUT_CSV="soak_samples.csv"
EVENTS_LOG="soak_events.log"
RAW_LOG="soak_provider.log"
DURATION_MIN=""
SUBSYSTEM="dev.darkbloom.provider"

while [ $# -gt 0 ]; do
  case "$1" in
    --kv-dir)            KV_DIR="$2"; shift 2 ;;
    --proc)              PROC="$2"; shift 2 ;;
    --interval)          INTERVAL="$2"; shift 2 ;;
    --out-csv)           OUT_CSV="$2"; shift 2 ;;
    --events-log)        EVENTS_LOG="$2"; shift 2 ;;
    --raw-log)           RAW_LOG="$2"; shift 2 ;;
    --duration-minutes)  DURATION_MIN="$2"; shift 2 ;;
    --subsystem)         SUBSYSTEM="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

ts() { date '+%Y-%m-%dT%H:%M:%S'; }

# ---- start the unified-log capture in the background --------------------------
# Debug level is needed for the per-file store/write markers; the failure and
# eviction markers are info/warning. --style compact keeps lines greppable.
echo "$(ts) monitor: starting log stream (subsystem=$SUBSYSTEM) -> $RAW_LOG" | tee -a "$EVENTS_LOG"
: > "$RAW_LOG"
log stream \
  --predicate "subsystem == \"$SUBSYSTEM\"" \
  --level debug \
  --style compact >> "$RAW_LOG" 2>&1 &
LOG_PID=$!

cleanup() {
  echo "$(ts) monitor: stopping (log stream pid=$LOG_PID)" | tee -a "$EVENTS_LOG"
  kill "$LOG_PID" 2>/dev/null
  wait "$LOG_PID" 2>/dev/null
}
trap cleanup EXIT INT TERM

# ---- marker patterns (extended regex) -----------------------------------------
# Each maps to a CSV column counting NEW occurrences in the window. Keep these
# in sync with the os.Logger call sites in Sources/ProviderCore/KVCache/ and
# Inference/BatchScheduler.swift.
RE_ACTIVE='encrypted prefix cache active'
RE_STORE='wrote [0-9]+ chunks to'                       # EncryptedKVStore.write (debug)
# SSD disk eviction: under the GlobalDiskAccountant (the active authority when
# DARKBLOOM_PREFIX_CACHE_DISK_GB is set) eviction shows as "global disk budget
# exceeded … enforcing" + "signaled owned model … to free". The legacy
# per-model enforceDiskBudget path is silent (no log), so the accountant line is
# the on-log proof of SSD eviction; the disk_kb plateau is the corroborating
# signal. RAM-tier eviction is "evicted prefix cache entry".
RE_SWEEP='global disk budget exceeded|disk sweep: now'  # SSD budget enforcement trigger
RE_EVICT='signaled owned model .* to free|evicted for global budget|deleted unowned model'
RE_RAM_EVICT='evicted prefix cache entry'               # RAM LRU eviction
RE_DECRYPT_FAIL='decrypt failed|prefix read failed'     # corruption / wrong-key
RE_MB1_DROP='MB-1:.*(mismatch|dropping)'                # model/weight binding drop
RE_HASH_MISMATCH='prefix-hash mismatch'                 # index stale/corrupt
RE_DISABLED='prefix cache disabled'                     # should NOT appear mid-soak
RE_EPHEMERAL='EPHEMERAL in-memory KEK'                  # confirms escape hatch active

# ---- CSV header ---------------------------------------------------------------
if [ ! -s "$OUT_CSV" ]; then
  echo "ts,elapsed_s,disk_kb,file_count,rss_kb,cpu_speed_limit,active,store,sweep,evict,ram_evict,decrypt_fail,mb1_drop,hash_mismatch,disabled,ephemeral,hit_rate" > "$OUT_CSV"
fi

# byte offset into RAW_LOG already consumed
RAW_OFFSET=0
# latest cumulative hit rate seen in a "prefix cache stats: ... hitRate=NN.N%"
# line (logged every DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS, default 120s).
# Persisted across ticks since the stats line is sparser than the sample tick.
HIT_RATE=NA

count_new_markers() {
  # $1 = regex; counts matches in the current $WINDOW slice. grep -c exits 1
  # when the count is 0, so we must NOT use `|| echo 0` (that double-prints and
  # corrupts the CSV row). Capture, normalize empty -> 0, always succeed.
  local n
  n=$(printf '%s' "$WINDOW" | grep -E -c "$1" 2>/dev/null)
  [ -z "$n" ] && n=0
  printf '%s' "$n"
}

START_EPOCH=$(date +%s)
END_EPOCH=""
if [ -n "$DURATION_MIN" ]; then
  DUR_SECS=$(awk "BEGIN{printf \"%d\", $DURATION_MIN * 60}")
  END_EPOCH=$(( START_EPOCH + DUR_SECS ))
fi

echo "$(ts) monitor: sampling every ${INTERVAL}s; kv-dir=$KV_DIR proc=$PROC csv=$OUT_CSV" | tee -a "$EVENTS_LOG"

while true; do
  NOW_EPOCH=$(date +%s)
  ELAPSED=$(( NOW_EPOCH - START_EPOCH ))
  if [ -n "$END_EPOCH" ] && [ "$NOW_EPOCH" -ge "$END_EPOCH" ]; then
    echo "$(ts) monitor: duration reached (${DURATION_MIN}min) — exiting" | tee -a "$EVENTS_LOG"
    break
  fi

  # --- on-disk state ---
  if [ -d "$KV_DIR" ]; then
    DISK_KB=$(du -sk "$KV_DIR" 2>/dev/null | awk '{print $1}')
    FILE_COUNT=$(find "$KV_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  else
    DISK_KB=0; FILE_COUNT=0
  fi

  # --- process RSS (KB). Match the serving process, prefer the 'start' one. ---
  PID=$(pgrep -x "$PROC" 2>/dev/null | head -1)
  if [ -z "$PID" ]; then PID=$(pgrep -f "$PROC .*start" 2>/dev/null | head -1); fi
  if [ -n "$PID" ]; then
    RSS_KB=$(ps -o rss= -p "$PID" 2>/dev/null | tr -d ' ')
    [ -z "$RSS_KB" ] && RSS_KB=0
  else
    RSS_KB=0
  fi

  # --- CPU thermal throttle (100 = unthrottled, <100 = throttled). No sudo. ---
  CPU_SPEED_LIMIT=$(pmset -g therm 2>/dev/null | awk -F'= ' '/CPU_Speed_Limit/{print $2; exit}')
  [ -z "$CPU_SPEED_LIMIT" ] && CPU_SPEED_LIMIT=NA

  # --- new log bytes since last tick ---
  RAW_SIZE=$(wc -c < "$RAW_LOG" 2>/dev/null | tr -d ' ')
  [ -z "$RAW_SIZE" ] && RAW_SIZE=0
  if [ "$RAW_SIZE" -gt "$RAW_OFFSET" ]; then
    WINDOW=$(tail -c +$(( RAW_OFFSET + 1 )) "$RAW_LOG" 2>/dev/null)
    RAW_OFFSET=$RAW_SIZE
  else
    WINDOW=""
  fi

  C_ACTIVE=$(count_new_markers "$RE_ACTIVE")
  C_STORE=$(count_new_markers "$RE_STORE")
  C_SWEEP=$(count_new_markers "$RE_SWEEP")
  C_EVICT=$(count_new_markers "$RE_EVICT")
  C_RAMEVICT=$(count_new_markers "$RE_RAM_EVICT")
  C_DECFAIL=$(count_new_markers "$RE_DECRYPT_FAIL")
  C_MB1=$(count_new_markers "$RE_MB1_DROP")
  C_HASH=$(count_new_markers "$RE_HASH_MISMATCH")
  C_DISABLED=$(count_new_markers "$RE_DISABLED")
  C_EPHEM=$(count_new_markers "$RE_EPHEMERAL")

  # latest cumulative hit rate from the periodic "prefix cache stats:" line, if
  # one appeared in this window. Persists across ticks (sparser than the tick).
  NEW_RATE=$(printf '%s' "$WINDOW" | grep -oE 'hitRate=[0-9.]+' | tail -1 | cut -d= -f2)
  [ -n "$NEW_RATE" ] && HIT_RATE=$NEW_RATE

  echo "$(ts),$ELAPSED,$DISK_KB,$FILE_COUNT,$RSS_KB,$CPU_SPEED_LIMIT,$C_ACTIVE,$C_STORE,$C_SWEEP,$C_EVICT,$C_RAMEVICT,$C_DECFAIL,$C_MB1,$C_HASH,$C_DISABLED,$C_EPHEM,$HIT_RATE" >> "$OUT_CSV"

  # --- notable events to the events log ---
  if [ "$C_DECFAIL" -gt 0 ]; then
    echo "$(ts) [WARN] $C_DECFAIL decrypt/read failure(s) in last ${INTERVAL}s — investigate (corruption or wrong key)" | tee -a "$EVENTS_LOG"
    printf '%s' "$WINDOW" | grep -E "$RE_DECRYPT_FAIL" | head -5 >> "$EVENTS_LOG"
  fi
  if [ "$C_MB1" -gt 0 ]; then
    echo "$(ts) [WARN] $C_MB1 MB-1 binding drop(s) in last ${INTERVAL}s" | tee -a "$EVENTS_LOG"
  fi
  if [ "$C_HASH" -gt 0 ]; then
    echo "$(ts) [WARN] $C_HASH prefix-hash mismatch(es) in last ${INTERVAL}s" | tee -a "$EVENTS_LOG"
  fi
  if [ "$C_DISABLED" -gt 0 ]; then
    echo "$(ts) [ERROR] prefix cache reported DISABLED mid-soak — cache not exercising!" | tee -a "$EVENTS_LOG"
    printf '%s' "$WINDOW" | grep -E "$RE_DISABLED" | head -3 >> "$EVENTS_LOG"
  fi

  # progress to stdout
  printf '[%6ss] disk=%sMB files=%s rss=%sMB cpu_lim=%s hit=%s%% | store=%s sweep=%s ssd_evict=%s ram_evict=%s decfail=%s mb1=%s hashmis=%s\n' \
    "$ELAPSED" "$(( DISK_KB / 1024 ))" "$FILE_COUNT" "$(( RSS_KB / 1024 ))" "$CPU_SPEED_LIMIT" "$HIT_RATE" \
    "$C_STORE" "$C_SWEEP" "$C_EVICT" "$C_RAMEVICT" "$C_DECFAIL" "$C_MB1" "$C_HASH"

  sleep "$INTERVAL"
done
