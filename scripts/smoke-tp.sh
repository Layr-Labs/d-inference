#!/usr/bin/env bash
# smoke-tp.sh — end-to-end smoke test for two-Mac cluster inference (TP or PP).
#
# HARDWARE REQUIREMENT: This script must be run on a real two-Mac Thunderbolt 5
# setup. It will NOT work in CI (no Thunderbolt link, no Apple Silicon RDMA).
# To validate the request routing logic without hardware, run:
#   swift test --filter "ClusterRequestRouting"   (in provider-swift/)
#   go test ./registry/ -run TestClusterRank1     (in coordinator/)
#
# USAGE:
#   # From one Mac (this script coordinates both sides):
#   ./scripts/smoke-tp.sh [tp|pp] <coordinator-url> <model-id>
#
#   # Defaults:
#   MODE=tp (tensor-parallel; use pp for pipeline-parallel)
#   COORDINATOR_URL=wss://localhost:8080
#   MODEL_ID=mlx-community/Llama-3.2-1B-Instruct-4bit
#
# WHAT IT DOES:
#   1. Builds the darkbloom binary from provider-swift/ (swift build -c release).
#   2. Launches two darkbloom processes with --rdma-enabled on the current Mac.
#      (In a real two-Mac setup, you would run each half on its own Mac.)
#   3. Waits up to 60 s for the "Cluster session ready" / "jaccl DistributedGroup
#      ready" log line to appear, indicating the SE handshake + jaccl bootstrap
#      completed.
#   4. Sends a single inference request via curl and checks for a non-empty
#      response stream.
#   5. Tears down both processes and exits 0 on success, 1 on failure.
#
# LIMITATIONS:
#   - Single-Mac simulation mode (both processes on one machine) cannot exercise
#     the real RDMA link. Use this script on actual TB5-connected hardware.
#   - The script assumes `darkbloom login` has already been run and a valid
#     auth token is cached at ~/.config/darkbloom/config.toml.
#   - Does NOT test E2E encryption (the smoke request uses a plaintext body
#     for simplicity; production traffic is always encrypted).
#
# EXIT CODES:
#   0 — inference response received successfully
#   1 — build failed, cluster session not established, or no tokens returned

set -euo pipefail

MODE="${1:-tp}"
COORDINATOR_URL="${2:-wss://localhost:8080}"
MODEL_ID="${3:-mlx-community/Llama-3.2-1B-Instruct-4bit}"
BINARY="$(dirname "$0")/../provider-swift/.build/release/darkbloom"
LOGDIR="$(mktemp -d)"
SESSION_READY_PATTERN="jaccl DistributedGroup ready"
TIMEOUT_SECS=60

log() { echo "[smoke-tp] $*"; }
fail() { echo "[smoke-tp] FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Build
# ---------------------------------------------------------------------------
log "Building darkbloom (release)..."
(cd "$(dirname "$0")/../provider-swift" && swift build -c release 2>&1) \
    || fail "swift build failed"
[[ -x "$BINARY" ]] || fail "binary not found at $BINARY"

# ---------------------------------------------------------------------------
# 2. Launch two provider processes
# ---------------------------------------------------------------------------
log "Launching provider rank-0 process (logs: $LOGDIR/rank0.log)"
"$BINARY" serve \
    --coordinator-url "$COORDINATOR_URL" \
    --rdma-enabled \
    --parallelism "$MODE" \
    2>&1 | tee "$LOGDIR/rank0.log" &
RANK0_PID=$!

log "Launching provider rank-1 process (logs: $LOGDIR/rank1.log)"
"$BINARY" serve \
    --coordinator-url "$COORDINATOR_URL" \
    --rdma-enabled \
    --parallelism "$MODE" \
    2>&1 | tee "$LOGDIR/rank1.log" &
RANK1_PID=$!

cleanup() {
    log "Cleaning up processes..."
    kill "$RANK0_PID" 2>/dev/null || true
    kill "$RANK1_PID" 2>/dev/null || true
    wait "$RANK0_PID" 2>/dev/null || true
    wait "$RANK1_PID" 2>/dev/null || true
    log "Logs saved to $LOGDIR"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 3. Wait for cluster session ready
# ---------------------------------------------------------------------------
log "Waiting up to ${TIMEOUT_SECS}s for cluster session..."
DEADLINE=$(( $(date +%s) + TIMEOUT_SECS ))
CLUSTER_READY=0

while [[ $(date +%s) -lt $DEADLINE ]]; do
    if grep -q "$SESSION_READY_PATTERN" "$LOGDIR/rank0.log" 2>/dev/null \
       && grep -q "$SESSION_READY_PATTERN" "$LOGDIR/rank1.log" 2>/dev/null; then
        CLUSTER_READY=1
        break
    fi
    sleep 2
done

if [[ $CLUSTER_READY -eq 0 ]]; then
    fail "Cluster session not established within ${TIMEOUT_SECS}s. Check Thunderbolt link and provider logs at $LOGDIR"
fi
log "Cluster session ready."

# ---------------------------------------------------------------------------
# 4. Send inference request
# ---------------------------------------------------------------------------
# Resolve the coordinator's HTTP URL (replace wss:// with https://).
HTTP_URL="${COORDINATOR_URL/wss:\/\//https://}"
HTTP_URL="${HTTP_URL/ws:\/\//http://}"

log "Sending inference request to $HTTP_URL ..."
RESPONSE=$(curl --silent --max-time 60 \
    -X POST "${HTTP_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $(grep -oP '(?<=token = ")[^"]+' ~/.config/darkbloom/config.toml 2>/dev/null || echo 'smoke-token')" \
    -d "{
      \"model\": \"$MODEL_ID\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Say \\\"cluster works\\\" and nothing else.\"}],
      \"max_tokens\": 20,
      \"stream\": false
    }" 2>&1) || fail "curl request failed"

log "Response: $RESPONSE"

# Check that we got at least one content token back.
if echo "$RESPONSE" | grep -q '"content"'; then
    log "SUCCESS: inference response received from cluster engine."
else
    fail "No content in response. Response was: $RESPONSE"
fi

log "smoke-tp.sh passed for mode=$MODE"
exit 0
