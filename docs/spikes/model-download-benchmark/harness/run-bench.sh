#!/bin/bash
# Native side of the benchmark: shipped provider, stub coordinator, isolated R2.
# usage: run-bench.sh <chunked|large> <cold|warm|warmN>
set -euo pipefail
if [[ $# -ne 2 || ! $1 =~ ^(chunked|large)$ || ! $2 =~ ^(cold|warm[0-9]*)$ ]]; then
  echo "usage: $0 <chunked|large> <cold|warm|warmN>" >&2
  exit 2
fi
KIND=$1; PASS=$2
S=${BENCH_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}
DB=${DARKBLOOM_BIN:-"$HOME/.darkbloom/Darkbloom.app/Contents/MacOS/darkbloom"}
RUN_ID=${RUN_ID:-2026-09-01-r1}
if [[ ! $RUN_ID =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]]; then
  echo "RUN_ID must contain only letters, digits, underscores and hyphens" >&2
  exit 2
fi
CDN=${CDN:-https://model-download-bench.darkbloom.ai}; COORD=${COORD:-http://127.0.0.1:8799}
MODEL="bench-$KIND-$RUN_ID"; OUT="$S/out/$KIND-$PASS"
MANIFEST="$S/out/manifest-$MODEL.json"
mkdir -p "$OUT"
echo "stage=setup status=running" > "$OUT/status.log"
# Do not let artifacts from an earlier pass masquerade as this run's results.
for artifact in timing.log cache-status.log verify.json verify.log files.log; do
  : > "$OUT/$artifact"
done
SAMPLER=""; STAGE=setup
stop_sampler() {
  if [[ -n $SAMPLER ]]; then
    kill "$SAMPLER" 2>/dev/null || true
    wait "$SAMPLER" 2>/dev/null || true
    SAMPLER=""
  fi
}
cleanup() {
  local result=$?
  trap - EXIT
  stop_sampler
  echo "stage=$STAGE status=$result" > "$OUT/status.log"
  exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Validate inputs before deleting the previous local download. Pass filenames as
# arguments, not interpolated Python source (BENCH_ROOT can contain quotes).
OBJECTS=$(python3 - "$MANIFEST" <<'PY'
import json, re, sys
files = json.load(open(sys.argv[1]))['files']
if not isinstance(files, list) or not files:
    raise ValueError('manifest must contain files')
for file in files:
    path = file['path']
    if not isinstance(path, str) or not re.fullmatch(r'[A-Za-z0-9_-]+\.bin', path):
        raise ValueError('benchmark object path must be a simple .bin filename')
    print(path)
PY
)
IFACE=$(route -n get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')
[[ -n $IFACE ]] || { echo "Cannot determine network interface" >&2; exit 1; }
# Sampler owns its sleeping child and is always reaped, including on failures.
(
  SLEEPER=""
  trap 'if [[ -n $SLEEPER ]]; then kill "$SLEEPER" 2>/dev/null || true; wait "$SLEEPER" 2>/dev/null || true; fi' EXIT
  trap 'exit 0' TERM INT
  prev=$(netstat -ibn | awk -v i="$IFACE" '$1==i && $3 ~ /Link/ {print $7; exit}')
  t0=$(date +%s)
  while :; do
    sleep 1 & SLEEPER=$!; wait "$SLEEPER"; SLEEPER=""
    cur=$(netstat -ibn | awk -v i="$IFACE" '$1==i && $3 ~ /Link/ {print $7; exit}')
    echo "$(( $(date +%s) - t0 )) $(( (cur - prev) / 1048576 ))"
    prev=$cur
  done
) > "$OUT/throughput-MiBps.log" &
SAMPLER=$!
"$DB" models remove "$MODEL" >/dev/null 2>&1 || true
rm -rf "$HOME/.cache/huggingface/hub/models--$MODEL"
STAGE=download
START=$(python3 -c 'import time; print(time.monotonic())')
echo "start $(date -u +%FT%TZ)" > "$OUT/timing.log"
# Capture all pipeline statuses before errexit can skip timing and cleanup.
set +e
"$DB" models download "$MODEL" --coordinator "$COORD" --r2-cdn "$CDN" 2>&1 |
  python3 -u -c 'import sys,time
for line in sys.stdin: print(f"{time.time():.9f} {line.rstrip()}", flush=True)' |
  tee "$OUT/download.log"
PIPE_STATUSES=("${PIPESTATUS[@]}")
set -e
STATUS=${PIPE_STATUSES[0]}
for result in "${PIPE_STATUSES[@]}"; do
  if [[ $STATUS -eq 0 && $result -ne 0 ]]; then STATUS=$result; fi
done
WALL=$(python3 -c 'import sys,time; print(time.monotonic()-float(sys.argv[1]))' "$START")
stop_sampler
echo "end $(date -u +%FT%TZ) status=$STATUS wall=$WALL" >> "$OUT/timing.log"
SNAP="$HOME/.cache/huggingface/hub/models--$MODEL/snapshots/local"
ls -la "$SNAP" > "$OUT/files.log" 2>&1 || true
cat "$OUT/timing.log"
if [[ $STATUS -ne 0 ]]; then exit "$STATUS"; fi
STAGE=cache
PREFIX="runs/$RUN_ID/$KIND"
while IFS= read -r f; do
  curl -fsSI --max-time 30 "$CDN/$PREFIX/$f" | tr -d '\r' |
    awk -v f="$f" 'tolower($1)=="cf-cache-status:"{cs=$2} tolower($1)=="cf-ray:"{ray=$2} tolower($1)=="content-length:"{len=$2} tolower($1)=="cache-control:"{cc=$0} END{print f, len, cs, ray, cc}'
done <<< "$OBJECTS" > "$OUT/cache-status.log"
echo "cache:"; awk '{print $3}' "$OUT/cache-status.log" | sort | uniq -c
STAGE=verify
if docker run --rm -v "$S/out:/harness/out" -v "$SNAP:/snap:ro" darkbloom-bench-harness node verify.mjs "$KIND" /snap > "$OUT/verify.json" 2> "$OUT/verify.log"; then
  VERIFY_STATUS=0
else
  VERIFY_STATUS=$?
fi
cat "$OUT/verify.json"
if [[ $VERIFY_STATUS -ne 0 ]]; then
  cat "$OUT/verify.log" >&2
  exit "$VERIFY_STATUS"
fi
python3 - "$OUT/verify.json" <<'PY'
import json, sys
result = json.load(open(sys.argv[1]))
if result.get('allMatch') is not True:
    sys.exit('Reconstruction did not verify')
PY
STAGE=complete
