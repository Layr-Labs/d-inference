#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNNER="$ROOT/scripts/run-fault-matrix.sh"
MANIFEST="$ROOT/coordinator-rs/Cargo.toml"
PACKAGE="darkbloom-coordinator-server"

readonly -a LIB_TESTS=(
  "signed_fault_receipts_cover_real_paid_http_postgres_websocket_lifecycle"
  "network_proxy_faults_wrap_real_coordinator_and_provider_peers"
  "child_kill_and_crash_recover_active_paid_request_on_same_lease"
)

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/run-fault-matrix.sh \
    --output PATH --signing-key PATH --trusted-key PATH
  scripts/run-fault-matrix.sh --print-shard
EOF
  exit 2
}

print_shard() {
  local test_name
  for test_name in "${LIB_TESTS[@]}"; do
    printf 'lib:%s\n' "$test_name"
  done
  printf 'integration:fault_injection\n'
}

run_shard() {
  local test_name
  for test_name in "${LIB_TESTS[@]}"; do
    cargo test --manifest-path "$MANIFEST" --locked \
      -p "$PACKAGE" --features fault-injection --lib \
      "$test_name" -- --test-threads=1
  done
  cargo test --manifest-path "$MANIFEST" --locked \
    -p "$PACKAGE" --features fault-injection \
    --test fault_injection -- --test-threads=1
}

if [[ "${1:-}" == "__run-shard" ]]; then
  [[ $# -eq 1 ]] || usage
  cd "$ROOT"
  run_shard
  exit 0
fi

if [[ "${1:-}" == "--print-shard" ]]; then
  [[ $# -eq 1 ]] || usage
  print_shard
  exit 0
fi

output=""
signing_key=""
trusted_key=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || usage
      output="$2"
      shift 2
      ;;
    --signing-key)
      [[ $# -ge 2 ]] || usage
      signing_key="$2"
      shift 2
      ;;
    --trusted-key)
      [[ $# -ge 2 ]] || usage
      trusted_key="$2"
      shift 2
      ;;
    *)
      usage
      ;;
  esac
done

[[ -n "$output" && -n "$signing_key" && -n "$trusted_key" ]] || usage

cd "$ROOT"
rm -f -- "$output"
env -u DATABASE_URL python3 scripts/fault-matrix.py run \
  --output "$output" \
  --signing-key "$signing_key" \
  --trusted-key "$trusted_key" \
  -- "$RUNNER" __run-shard
python3 scripts/fault-matrix.py validate \
  --source "$output" \
  --trusted-key "$trusted_key"
