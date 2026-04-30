#!/usr/bin/env bash
# calibrate-routing.sh — empirical measurement of routing constants.
#
# Run against a running vllm-mlx backend on an Apple Silicon machine.
# Outputs measured values that should replace the defaults in
# coordinator/internal/registry/scheduler.go:
#
#   effectiveTPSLoadFactor  (Phase 4)
#   kvCacheBytesPerToken    (Phase 1)
#
# Usage:
#   scripts/calibrate-routing.sh load-factor
#   scripts/calibrate-routing.sh kv-size
#   scripts/calibrate-routing.sh all
#
# Env:
#   VLLM_URL     base URL of the vllm-mlx server (default: http://localhost:8000)
#   MODEL        primary model to benchmark       (required)
#   PROMPT_FILE  path to a long prompt file       (default: /usr/share/dict/words)
#
# Requires: curl, jq, python3.

set -euo pipefail

VLLM_URL="${VLLM_URL:-http://localhost:8000}"
MODEL="${MODEL:-}"
PROMPT_FILE="${PROMPT_FILE:-}"

LOG() { printf '\033[36m[calibrate]\033[0m %s\n' "$*" >&2; }
WARN() { printf '\033[33m[warn]\033[0m %s\n' "$*" >&2; }
ERR() { printf '\033[31m[error]\033[0m %s\n' "$*" >&2; }

need() { command -v "$1" >/dev/null || { ERR "$1 is required"; exit 1; }; }
need curl
need jq
need python3

# ---------- helpers ---------------------------------------------------

check_reachable() {
  if ! curl -fsS --max-time 3 "$VLLM_URL/v1/status" >/dev/null 2>&1; then
    ERR "vllm-mlx not reachable at $VLLM_URL (tried /v1/status)"
    ERR "start it with: vllm-mlx serve <model> --port 8000"
    exit 1
  fi
}

status_json() {
  curl -fsS --max-time 5 "$VLLM_URL/v1/status"
}

active_memory_gb() {
  status_json | jq -r '.metal.active_memory_gb // 0'
}

num_running() {
  status_json | jq -r '.num_running // 0'
}

# Generate a prompt of approximately N tokens. Uses ~4 chars/token as a
# rough estimate; exact token count is read back from the usage field.
# Implemented in python3 to sidestep `yes | head -c` tripping pipefail
# on SIGPIPE when head closes the pipe.
synthesize_prompt() {
  local target_tokens="$1"
  local char_count=$((target_tokens * 4))
  local source_file="${PROMPT_FILE:-/usr/share/dict/words}"
  python3 - "$char_count" "$source_file" <<'PY'
import os, sys
n = int(sys.argv[1])
src = sys.argv[2]
base = ""
if os.path.isfile(src):
    with open(src, "r", errors="ignore") as f:
        base = " ".join(f.read().split()[:200])
if not base:
    base = ("The quick brown fox jumps over the lazy dog while the sun sets "
            "behind the hills and stars begin to glimmer in the deepening sky. ")
# Repeat until we have enough chars, then truncate.
if len(base) < n:
    base = (base + " ") * (n // len(base) + 1)
sys.stdout.write(base[:n])
PY
}

# Fire one inference request. Streams not used (simpler).
# Outputs "TOTAL_SECONDS PROMPT_TOKENS COMPLETION_TOKENS" on success.
run_request() {
  local prompt="$1"
  local max_tokens="$2"
  local start end
  start=$(python3 -c 'import time; print(time.time())')
  local body
  body=$(curl -fsS --max-time 600 \
    -X POST "$VLLM_URL/v1/chat/completions" \
    -H 'Content-Type: application/json' \
    -d "$(jq -n --arg model "$MODEL" --arg prompt "$prompt" --argjson max "$max_tokens" '
      { model: $model,
        messages: [{role:"user", content:$prompt}],
        max_tokens: $max,
        stream: false
      }')")
  end=$(python3 -c 'import time; print(time.time())')
  local elapsed
  elapsed=$(python3 -c "print($end - $start)")
  local prompt_t completion_t
  prompt_t=$(jq -r '.usage.prompt_tokens // 0' <<<"$body")
  completion_t=$(jq -r '.usage.completion_tokens // 0' <<<"$body")
  echo "$elapsed $prompt_t $completion_t"
}

# ---------- load factor (Phase 4) -------------------------------------

calibrate_load_factor() {
  LOG "=== Load factor calibration (Phase 4) ==="
  [[ -z "$MODEL" ]] && { ERR "set MODEL env var"; exit 1; }
  check_reachable

  local short_prompt
  short_prompt=$(synthesize_prompt 64)
  local max_tokens=256

  # Warm the model with one request so the first concurrent batch isn't
  # penalized by cold-start JIT.
  LOG "warming model..."
  run_request "$short_prompt" 32 >/dev/null

  local Ns=(1 2 4 8)
  declare -a tps_results
  for N in "${Ns[@]}"; do
    LOG "running $N concurrent decode requests, max_tokens=$max_tokens..."
    local tmp
    tmp=$(mktemp -d)
    local pids=()
    for i in $(seq 1 "$N"); do
      ( run_request "$short_prompt" "$max_tokens" >"$tmp/req_$i.out" ) &
      pids+=($!)
    done
    local failed=0
    for pid in "${pids[@]}"; do
      wait "$pid" || failed=1
    done
    if [[ $failed -ne 0 ]]; then
      WARN "one or more requests failed at N=$N; skipping"
      rm -rf "$tmp"; tps_results+=("$N 0"); continue
    fi
    # Compute per-request tokens/sec and average.
    local avg
    avg=$(python3 - "$tmp" <<'PY'
import glob, sys
rates=[]
for p in glob.glob(sys.argv[1] + '/req_*.out'):
    line=open(p).read().strip().split()
    if len(line) != 3: continue
    elapsed, prompt_t, comp_t = float(line[0]), int(line[1]), int(line[2])
    if comp_t <= 0 or elapsed <= 0: continue
    rates.append(comp_t / elapsed)
if not rates: print(0); sys.exit()
print(f"{sum(rates)/len(rates):.3f}")
PY
)
    rm -rf "$tmp"
    LOG "  N=$N  avg_per_req_tps=$avg"
    tps_results+=("$N $avg")
  done

  # Fit k: tps(N) = tps(1) / (1 + k*N)  →  k = (tps(1)/tps(N) - 1) / N
  local tps1
  tps1=$(awk '$1==1 {print $2}' <<<"$(printf '%s\n' "${tps_results[@]}")")
  if [[ -z "$tps1" || "$tps1" == "0" ]]; then
    ERR "baseline TPS at N=1 is zero; aborting fit"
    return
  fi
  LOG "fitting k for tps(N) = tps(1)/(1 + k*N)  [tps(1)=$tps1]"
  # Write samples to a file so the python heredoc doesn't shadow stdin.
  # Pass tps1 as an env var (TPS1) rather than interpolating into the
  # heredoc so the python block can be quoted verbatim.
  local samples_file
  samples_file=$(mktemp)
  printf '%s\n' "${tps_results[@]}" >"$samples_file"
  TPS1="$tps1" SAMPLES="$samples_file" python3 - <<'PY'
import os, statistics
tps1 = float(os.environ["TPS1"])
ks = []
with open(os.environ["SAMPLES"]) as f:
    for line in f:
        parts = line.strip().split()
        if len(parts) != 2: continue
        try: n, tps = int(parts[0]), float(parts[1])
        except ValueError: continue
        if n <= 1 or tps <= 0: continue
        k = (tps1 / tps - 1) / n
        ks.append((n, k))
        print(f"  at N={n}, implied k={k:.3f}")
if ks:
    median_k = statistics.median(k for _, k in ks)
    print(f"\nRECOMMENDED effectiveTPSLoadFactor = {median_k:.2f}")
else:
    print("no valid samples; keep the default")
PY
  rm -f "$samples_file"
}

# ---------- KV cache bytes/token (Phase 1) ----------------------------

calibrate_kv_size() {
  LOG "=== KV cache bytes/token calibration (Phase 1) ==="
  [[ -z "$MODEL" ]] && { ERR "set MODEL env var"; exit 1; }
  check_reachable

  # Baseline: active memory with model loaded but no requests running.
  LOG "ensuring no requests are in flight..."
  local running
  running=$(num_running)
  if [[ "$running" -gt 0 ]]; then
    WARN "backend has $running running requests; baseline will be inflated"
  fi
  local baseline_gb
  baseline_gb=$(active_memory_gb)
  LOG "baseline active_memory_gb=$baseline_gb"

  # Fire a long request; sample peak active memory mid-flight.
  local prompt_tokens=2048
  local max_tokens=2048
  local prompt
  prompt=$(synthesize_prompt "$prompt_tokens")

  LOG "firing request: prompt≈$prompt_tokens, max_tokens=$max_tokens"
  local peak=0
  ( run_request "$prompt" "$max_tokens" >/tmp/kv_probe_resp.out ) &
  local req_pid=$!

  # Sample active memory for up to 60 s or until the request finishes.
  local deadline=$((SECONDS + 60))
  while kill -0 "$req_pid" 2>/dev/null && [[ $SECONDS -lt $deadline ]]; do
    local cur
    cur=$(active_memory_gb)
    python3 -c "import sys; print(1 if float('$cur') > float('$peak') else 0)" \
      | grep -q 1 && peak=$cur
    sleep 0.5
  done
  wait "$req_pid" || true

  local line prompt_t comp_t
  line=$(cat /tmp/kv_probe_resp.out 2>/dev/null || true)
  if [[ -z "$line" ]]; then
    ERR "no response captured"
    return
  fi
  prompt_t=$(awk '{print $2}' <<<"$line")
  comp_t=$(awk '{print $3}' <<<"$line")
  LOG "peak_active_memory_gb=$peak  prompt_tokens=$prompt_t  completion_tokens=$comp_t"

  python3 - <<PY
peak = $peak
base = $baseline_gb
prompt_t = $prompt_t
comp_t = $comp_t
total_tokens = prompt_t + comp_t
if total_tokens <= 0:
    print("no tokens observed; aborting")
else:
    delta_gb = peak - base
    # delta_gb accounts for KV for all tokens held in cache at peak.
    # Typical vllm-mlx keeps full context; divide by total.
    bytes_per_tok = delta_gb * (1 << 30) / total_tokens
    print(f"delta_active_memory_gb = {delta_gb:.3f}")
    print(f"tokens_in_cache_at_peak = {total_tokens}")
    print(f"\nRECOMMENDED kvCacheBytesPerToken = {int(bytes_per_tok):,}  ({bytes_per_tok/1024/1024:.2f} MB/token)")
PY
  rm -f /tmp/kv_probe_resp.out
}

# ---------- orchestration ---------------------------------------------

usage() {
  sed -n '2,22p' "$0"
}

cmd="${1:-help}"
case "$cmd" in
  load-factor) calibrate_load_factor ;;
  kv-size) calibrate_kv_size ;;
  all)
    calibrate_load_factor
    echo
    calibrate_kv_size
    ;;
  help|--help|-h|*) usage ;;
esac
