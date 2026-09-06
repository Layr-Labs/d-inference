#!/bin/bash
# Native side of the benchmark: drives the SHIPPED darkbloom provider binary
# against the stub coordinator (Docker) and the isolated R2 hostname.
# usage: run-bench.sh <chunked|large> <cold|warm>
set -euo pipefail
KIND=$1; PASS=$2
S=${BENCH_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
DB=${DARKBLOOM_BIN:-"$HOME/.darkbloom/Darkbloom.app/Contents/MacOS/darkbloom"}
RUN_ID=${RUN_ID:-2026-09-01-r1}; CDN=${CDN:-https://model-download-bench.darkbloom.ai}; COORD=${COORD:-http://127.0.0.1:8799}
MODEL="bench-$KIND-$RUN_ID"; OUT="$S/out/$KIND-$PASS"; mkdir -p "$OUT"
IFACE=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')
# per-second aggregate throughput sampler (interface byte counters)
( prev=$(netstat -ibn | awk -v i="$IFACE" '$1==i && $3 ~ /Link/ {print $7; exit}'); t0=$(date +%s)
  while :; do sleep 1; cur=$(netstat -ibn | awk -v i="$IFACE" '$1==i && $3 ~ /Link/ {print $7; exit}'); echo "$(( $(date +%s) - t0 )) $(( (cur - prev) / 1048576 ))"; prev=$cur; done ) > "$OUT/throughput-MiBps.log" &
SAMPLER=$!
"$DB" models remove "$MODEL" >/dev/null 2>&1 || true
rm -rf "$HOME/.cache/huggingface/hub/models--$MODEL"
START=$(date +%s.%N); echo "start $(date -u +%FT%TZ)" > "$OUT/timing.log"
"$DB" models download "$MODEL" --coordinator "$COORD" --r2-cdn "$CDN" 2>&1 | while IFS= read -r line; do printf '%s %s\n' "$(date +%s.%N)" "$line"; done | tee "$OUT/download.log"
STATUS=${PIPESTATUS[0]}
END=$(date +%s.%N); kill $SAMPLER 2>/dev/null || true
echo "end $(date -u +%FT%TZ) status=$STATUS wall=$(echo "$END - $START" | bc)" >> "$OUT/timing.log"
SNAP="$HOME/.cache/huggingface/hub/models--$MODEL/snapshots/local"
ls -la "$SNAP" > "$OUT/files.log" 2>&1 || true
# edge cache state per object AFTER the pass
PREFIX="runs/$RUN_ID/$KIND"
for f in $(python3 -c "import json;print(' '.join(x['path'] for x in json.load(open('$S/out/manifest-$MODEL.json'))['files']))"); do
  curl -sSI --max-time 30 "$CDN/$PREFIX/$f" | tr -d '\r' | awk -v f="$f" 'tolower($1)=="cf-cache-status:"{cs=$2} tolower($1)=="cf-ray:"{ray=$2} tolower($1)=="content-length:"{len=$2} tolower($1)=="cache-control:"{cc=$0} END{print f, len, cs, ray, cc}'
done > "$OUT/cache-status.log"
# byte-identical reconstruction check (in Docker)
docker run --rm -v "$S/out:/harness/out" -v "$SNAP:/snap:ro" darkbloom-bench-harness node verify.mjs "$KIND" /snap > "$OUT/verify.json" || true
cat "$OUT/timing.log"; echo "cache:"; awk '{print $3}' "$OUT/cache-status.log" | sort | uniq -c; python3 -c "import json;d=json.load(open('$OUT/verify.json'));print('allMatch',d['allMatch'])"
