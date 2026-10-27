#!/bin/bash
# One isolated server session (M3 Ultra): `darkbloom start --local`, a "Hi"/1-token self-test proxy,
# then the first-request plan, one request at a time. Run inside the M3U GPU lock.
# Usage: session.sh <bin> <model> <outdir> <tag> [plan]
# env: SETTLE (s after the listener answers, default 20), PORT (default 8461), GAP (default 3),
#      MAXTOK (default 16), plus server env (DARKBLOOM_TTFT_SHAPE_WARMUP).
set -u
BIN="$1"; MODEL="$2"; OUT="$3"; TAG="$4"; PLAN="${5:-8192,8192,8192}"
PORT="${PORT:-8461}"
W=/Users/gaj/ttft-bench/agents/warmup
PY=/usr/bin/python3
mkdir -p "$OUT"
LOG="$OUT/server-$TAG.log"; CL="$OUT/client-$TAG.jsonl"; : > "$CL"
# Private provider state: never touches ~/.darkbloom or another server. Prefix cache off.
ISO=$(mktemp -d "$OUT/iso.$TAG.XXXXXX")
export DARKBLOOM_PID_FILE=$ISO/provider.pid DARKBLOOM_STATE_FILE=$ISO/provider-state.json \
  DARKBLOOM_LOADED_MODELS_FILE=$ISO/loaded-models.json DARKBLOOM_WATCHDOG_STATE=$ISO/watchdog.json \
  DARKBLOOM_KV_BACKEND_GUARD=$ISO/kv-guard.json DARKBLOOM_LOCAL_DIR=$ISO/local DARKBLOOM_NO_UPDATE_CHECK=1 \
  DARKBLOOM_PREFIX_CACHE=0 DARKBLOOM_PREFIX_CACHE_MEMORY=0
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t >/dev/null 2>&1; then echo "[$TAG] port $PORT busy; refusing"; exit 2; fi
if pgrep -f "darkbloom (start|benchmark)" >/dev/null 2>&1; then
  echo "[$TAG] another darkbloom server/benchmark runs; refusing"; pgrep -fl "darkbloom (start|benchmark)" | cut -c1-160; exit 2
fi
now() { $PY -I -c 'import time; print(time.time())'; }
T0=$(now)
"$BIN" start --config /Users/gaj/ttft-bench/provider.toml --local --model "$MODEL" --port "$PORT" > "$LOG" 2>&1 &
SPID=$!
trap 'kill -INT $SPID 2>/dev/null; for i in $(seq 1 60); do kill -0 $SPID 2>/dev/null || break; sleep 1; done; kill -9 $SPID 2>/dev/null; wait $SPID 2>/dev/null' EXIT
KEY=""
for i in $(seq 1 900); do
  if curl -s -m 2 "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1; then
    KEY=$("$BIN" local --json 2>/dev/null | $PY -I -c "import json,sys; print(json.load(sys.stdin).get('api_key',''))" 2>/dev/null)
    [ -n "$KEY" ] && break
  fi
  if ! kill -0 $SPID 2>/dev/null; then echo "[$TAG] server died"; tail -30 "$LOG"; exit 1; fi
  sleep 0.5
done
LPID=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1)
if [ -z "$KEY" ] || [ "$LPID" != "$SPID" ]; then echo "[$TAG] port $PORT answered by pid ${LPID:-none}, not $SPID"; exit 1; fi
T1=$(now)
echo "[$TAG] ready after $($PY -I -c "print(round($T1-$T0,1))")s"
sleep "${SETTLE:-20}"
H=$($PY -I $W/hi.py --base "http://127.0.0.1:$PORT/v1" --key "$KEY" --model "$MODEL")
echo "[$TAG] hi $H"
sleep 1
IFS=',' read -ra LENS <<< "$PLAN"
idx=0
for L in "${LENS[@]}"; do
  [ $idx -gt 0 ] && sleep "${GAP:-3}"
  R=$($PY -I $W/first_ttft.py --base "http://127.0.0.1:$PORT/v1" --key "$KEY" --model "$MODEL" \
     --plan "$L" --max-tokens "${MAXTOK:-16}" --tag "$TAG-r$idx" | head -1)
  echo "$R" >> "$CL"
  echo "[$TAG] r$idx ttft_ms=$(echo "$R" | $PY -I -c 'import json,sys; d=json.load(sys.stdin); print(d["ttft_ms"], "prompt", d["prompt_tokens"], "dec", d["decode_chunks_per_s"])')"
  idx=$((idx+1))
done
grep -E "Shape warmup" "$LOG" | cut -c1-300
