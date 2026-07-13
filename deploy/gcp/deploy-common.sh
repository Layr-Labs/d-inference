#!/bin/bash

log() {
  printf '%s\n' "$*"
}

fail() {
  log "FATAL: $*" >&2
  return 1
}

validate_selector() {
  [[ "${1:-}" == "go" || "${1:-}" == "rust" ]]
}

validate_image_ref() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9._/@:-]+$ ]] &&
    [[ "$1" == *":"* || "$1" == *"@sha256:"* ]]
}

validate_pinned_image_ref() {
  [[ "${1:-}" =~ ^[a-zA-Z0-9._/:@-]+@sha256:[a-fA-F0-9]{64}$ ]]
}

validate_tag() {
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

read_env_value() {
  local file=$1
  local key=$2
  awk -v key="$key" '
    index($0, key "=") == 1 {
      print substr($0, length(key) + 2)
      found = 1
      exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}

restore_previous_known_good_env() {
  local env_file=${1:-/etc/d-inference/env}
  local secret_dir=${2:-/etc/d-inference/secrets}
  local pointer=${3:-/etc/d-inference/previous-known-good.path}
  local snapshot_root snapshot snapshot_name env_stage secret_stage old_secret
  snapshot_root=$(dirname "$pointer")/previous-known-good
  if [[ ! -r "$pointer" ]]; then
    fail "previous-known-good snapshot pointer is unavailable"
    return 1
  fi
  snapshot=$(sed -n '1p' "$pointer") || return 1
  snapshot_name=$(basename "$snapshot")
  if [[ "$(dirname "$snapshot")" != "$snapshot_root" ||
    ! "$snapshot_name" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]; then
    fail "previous-known-good snapshot pointer is invalid"
    return 1
  fi
  if [[ ! -d "$snapshot" || -L "$snapshot" ||
    ! -f "$snapshot/env" || -L "$snapshot/env" ||
    ! -d "$snapshot/secrets" || -L "$snapshot/secrets" ]]; then
    fail "previous-known-good snapshot is incomplete"
    return 1
  fi

  env_stage=$(mktemp "$(dirname "$env_file")/.restore-env.XXXXXX") || return 1
  secret_stage=$(mktemp -d "$(dirname "$secret_dir")/.restore-secrets.XXXXXX") || {
    rm -f "$env_stage"
    return 1
  }
  old_secret="$(dirname "$secret_dir")/.candidate-secrets.$$"
  rm -rf "$old_secret"
  if ! install -m 0600 "$snapshot/env" "$env_stage" ||
    ! cp -a "$snapshot/secrets/." "$secret_stage/"; then
    rm -f "$env_stage"
    rm -rf "$secret_stage"
    return 1
  fi
  chmod 0700 "$secret_stage"

  if ! mv "$secret_dir" "$old_secret"; then
    rm -f "$env_stage"
    rm -rf "$secret_stage"
    return 1
  fi
  if ! mv "$secret_stage" "$secret_dir"; then
    mv "$old_secret" "$secret_dir" || true
    rm -f "$env_stage"
    return 1
  fi
  if ! mv "$env_stage" "$env_file"; then
    rm -rf "$secret_dir"
    mv "$old_secret" "$secret_dir" || true
    rm -f "$env_stage"
    return 1
  fi
  rm -rf "$old_secret"
  log "Restored immutable previous-known-good coordinator env and secrets"
}

make_curl_auth_config() {
  local file=$1
  local admin_key=$2
  local escaped
  [[ -n "$admin_key" && "$admin_key" != *$'\n'* && "$admin_key" != *$'\r'* ]] ||
    return 1
  escaped=${admin_key//\\/\\\\}
  escaped=${escaped//\"/\\\"}
  umask 077
  printf 'header = "Authorization: Bearer %s"\n' "$escaped" >"$file"
}

docker_cmd() {
  /usr/bin/docker "$@"
}

systemctl_cmd() {
  /usr/bin/systemctl "$@"
}

curl_cmd() {
  curl "$@"
}

sleep_cmd() {
  sleep "$1"
}

serving_container_count() {
  {
    docker_cmd ps --filter label=com.darkbloom.role=serving --format '{{.ID}}'
    docker_cmd ps --filter name='^/d-inference-coordinator$' --format '{{.ID}}'
    docker_cmd ps --filter name='^/coordinator$' --format '{{.ID}}'
  } | awk 'NF && !seen[$0]++ { count++ } END { print count + 0 }'
}

recovery_container_count() {
  {
    docker_cmd ps --filter label=com.darkbloom.role=recovery --format '{{.ID}}'
    docker_cmd ps --filter name='^/d-inference-recovery$' --format '{{.ID}}'
  } | awk 'NF && !seen[$0]++ { count++ } END { print count + 0 }'
}

check_one_container_invariant() {
  local serving recovery
  serving=$(serving_container_count) || return 1
  recovery=$(recovery_container_count) || return 1
  (( serving <= 1 )) ||
    fail "more than one serving coordinator container is running" ||
    return 1
  (( recovery <= 1 )) ||
    fail "more than one offline recovery container is running" ||
    return 1
  (( serving + recovery <= 1 )) ||
    fail "more than one coordinator database owner container is running" ||
    return 1
}

check_no_running_owner() {
  local serving recovery
  serving=$(serving_container_count) || return 1
  recovery=$(recovery_container_count) || return 1
  (( serving == 0 && recovery == 0 )) ||
    fail "a coordinator database owner is still running" ||
    return 1
}

verify_state_mount() {
  local container=${1:-d-inference-coordinator}
  local mount
  mount=$(docker_cmd inspect --format \
    '{{range .Mounts}}{{if eq .Destination "/mnt/disks/userdata"}}{{.Source}}|{{.RW}}{{end}}{{end}}' \
    "$container") || return 1
  [[ "$mount" == "/mnt/disks/userdata|true" ]] ||
    fail "coordinator persistent state mount is missing or read-only" ||
    return 1
}

verify_container_selector() {
  local expected=$1
  local container=${2:-d-inference-coordinator}
  local actual
  actual=$(docker_cmd inspect --format \
    '{{index .Config.Labels "com.darkbloom.binary"}}' "$container") ||
    return 1
  [[ "$actual" == "$expected" ]] ||
    fail "running coordinator binary selector does not match $expected" ||
    return 1
}

quiescence_safe_json() {
  local file=$1
  jq -e '
    if has("requests") then
      .quiescent == true and
      .draining == true and
      .external_fenced == true and
      .ownership_healthy == true and
      .supervisor.ready == true and
      .fleet.active_leases == 0 and
      .requests.active == 0 and
      .requests.durable_active == 0 and
      .requests.http_inference == 0 and
      .requests.http_mutations == 0 and
      .writers.reserved_items == 0 and
      .recovery.pending_terminals == 0 and
      .recovery.pending_external_events == 0 and
      .recovery.active_leases == 0 and
      .recovery.active_external_operations == 0 and
      .outbox.pending == 0 and
      .outbox.pending_fee_allocations == 0 and
      .durable_telemetry.pending == 0
    else
      .quiescent == true and
      .ownership_healthy == true and
      .http_inference == 0 and
      .http_mutations == 0 and
      .provider_sessions == 0 and
      .providers_connected == 0 and
      .pending_attempts == 0 and
      .request_queue == 0 and
      .writer_data_queue == 0 and
      .writer_control_queue == 0 and
      .writer_active == 0 and
      .completion_queue == 0 and
      .completion_active == 0 and
      .completion_outstanding == 0 and
      .settlement_held == 0 and
      .settlement_callbacks == 0 and
      .telemetry_queued == 0 and
      .background_tasks == 0
    end
  ' "$file" >/dev/null
}

fetch_quiescence() {
  local output=$1
  local auth_config=$2
  curl_cmd --silent --show-error --fail \
    --config "$auth_config" \
    --output "$output" \
    http://127.0.0.1:8080/v1/admin/quiescence
}

wait_for_quiescence() {
  local auth_config=$1
  local attempts=${2:-120}
  local interval=${3:-5}
  local output
  output=$(mktemp)
  chmod 600 "$output"
  local attempt
  local consecutive=0
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if fetch_quiescence "$output" "$auth_config" && quiescence_safe_json "$output"; then
      consecutive=$((consecutive + 1))
      if (( consecutive >= 2 )); then
        rm -f "$output"
        return 0
      fi
    else
      consecutive=0
    fi
    if (( attempt < attempts )); then
      sleep_cmd "$interval"
    fi
  done
  log "quiescence timeout after ${attempts} attempts" >&2
  if [[ -s "$output" ]]; then
    jq -c . "$output" >&2 2>/dev/null || true
  fi
  rm -f "$output"
  return 1
}

set_drain() {
  local auth_config=$1
  local draining=$2
  local output
  output=$(mktemp)
  chmod 600 "$output"
  local body='{"draining":true}'
  [[ "$draining" == "true" ]] || body='{"draining":false}'
  if ! curl_cmd --silent --show-error --fail \
    --config "$auth_config" \
    --header 'Content-Type: application/json' \
    --data "$body" \
    --output "$output" \
    http://127.0.0.1:8080/v1/admin/drain; then
    rm -f "$output"
    return 1
  fi
  local result
  if jq -e --argjson draining "$draining" \
    '.draining == $draining' "$output" >/dev/null; then
    result=0
  else
    result=$?
  fi
  rm -f "$output"
  return "$result"
}

set_handoff_drain() {
  local auth_config=$1
  local timeout=${DINF_HANDOFF_HTTP_TIMEOUT_SECONDS:-60}
  [[ "$timeout" =~ ^[1-9][0-9]*$ ]] ||
    fail "DINF_HANDOFF_HTTP_TIMEOUT_SECONDS must be a positive integer" ||
    return 1
  local output
  output=$(mktemp)
  chmod 600 "$output"
  if ! curl_cmd --silent --show-error --fail \
    --connect-timeout 5 \
    --max-time "$timeout" \
    --config "$auth_config" \
    --header 'Content-Type: application/json' \
    --data '{"mode":"handoff"}' \
    --output "$output" \
    http://127.0.0.1:8080/v1/admin/drain; then
    rm -f "$output"
    return 1
  fi
  local result=0
  jq -e '.draining == true and .mode == "handoff"' "$output" >/dev/null ||
    result=$?
  rm -f "$output"
  return "$result"
}

candidate_ready() {
  local expected_commit=$1
  local previous_providers=$2
  local auth_config=$3
  local directory=$4

  curl_cmd --silent --show-error --fail \
    --output "$directory/ready.json" http://127.0.0.1:8080/readyz &&
    jq -e '.ready == true and .draining == false' "$directory/ready.json" >/dev/null ||
    return 1

  curl_cmd --silent --show-error --fail \
    --output "$directory/health.json" http://127.0.0.1:8080/health &&
    jq -e --arg commit "$expected_commit" '
      .status == "ok" and .draining != true and
      (.providers | type == "number") and
      ($commit == "" or .build_commit == $commit)
    ' "$directory/health.json" >/dev/null ||
    return 1

  curl_cmd --silent --show-error --fail \
    --config "$auth_config" \
    --output "$directory/routes.json" http://127.0.0.1:8080/v1/admin/routes &&
    jq -e '(.count | type == "number") and .count >= 0 and (.data | type == "array")' \
      "$directory/routes.json" >/dev/null ||
    return 1

  curl_cmd --silent --show-error --fail \
    --output "$directory/trust.json" http://127.0.0.1:8080/v1/providers/attestation &&
    jq -e '(.providers | type == "array")' "$directory/trust.json" >/dev/null ||
    return 1

  if (( previous_providers > 0 )); then
    jq -e '.providers >= 1' "$directory/health.json" >/dev/null &&
      jq -e '[.providers[] | select(.trust_level == "hardware")] | length >= 1' \
        "$directory/trust.json" >/dev/null ||
      return 1
  fi
}

wait_for_candidate() {
  local expected_commit=$1
  local previous_providers=$2
  local auth_config=$3
  local attempts=${4:-60}
  local interval=${5:-5}
  local directory
  directory=$(mktemp -d)
  chmod 700 "$directory"
  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if candidate_ready "$expected_commit" "$previous_providers" "$auth_config" "$directory"; then
      rm -rf "$directory"
      return 0
    fi
    if (( attempt < attempts )); then
      sleep_cmd "$interval"
    fi
  done
  log "candidate validation timeout after ${attempts} attempts" >&2
  rm -rf "$directory"
  return 1
}

deployment_hook_unconfigured() {
  fail "deployment transaction hook $1 is not configured"
}

migrate_candidate() {
  deployment_hook_unconfigured migrate_candidate
}

validate_candidate_config() {
  deployment_hook_unconfigured validate_candidate_config
}

drain_current_owner() {
  deployment_hook_unconfigured drain_current_owner
}

wait_current_quiescence() {
  deployment_hook_unconfigured wait_current_quiescence
}

stop_current_owner() {
  deployment_hook_unconfigured stop_current_owner
}

check_candidate_invariants() {
  deployment_hook_unconfigured check_candidate_invariants
}

start_candidate() {
  deployment_hook_unconfigured start_candidate
}

validate_running_candidate() {
  deployment_hook_unconfigured validate_running_candidate
}

stop_failed_candidate() {
  deployment_hook_unconfigured stop_failed_candidate
}

restore_go_fallback_environment() {
  deployment_hook_unconfigured restore_go_fallback_environment
}

handoff_failed_candidate() {
  deployment_hook_unconfigured handoff_failed_candidate
}

wait_failed_candidate_quiescence() {
  deployment_hook_unconfigured wait_failed_candidate_quiescence
}

fence_failed_candidate_ownership() {
  deployment_hook_unconfigured fence_failed_candidate_ownership
}

check_rollback_safe() {
  deployment_hook_unconfigured check_rollback_safe
}

start_go_fallback() {
  deployment_hook_unconfigured start_go_fallback
}

validate_go_fallback() {
  deployment_hook_unconfigured validate_go_fallback
}

rollback_to_go() {
  if ! handoff_failed_candidate; then
    if ! fence_failed_candidate_ownership; then
      fail "CRITICAL: failed candidate could not be ownership-fenced"
      return 44
    fi
    fail "automatic Go rollback refused: failed candidate could not enter handoff"
    return 43
  fi
  if ! wait_failed_candidate_quiescence; then
    if ! fence_failed_candidate_ownership; then
      fail "CRITICAL: non-quiescent candidate could not be ownership-fenced"
      return 44
    fi
    fail "automatic Go rollback refused: failed candidate did not become quiescent"
    return 43
  fi
  stop_failed_candidate || return 1
  restore_go_fallback_environment || return 1
  if ! check_rollback_safe; then
    fail "automatic Go rollback refused because CheckRollbackSafe failed"
    return 42
  fi
  start_go_fallback || return 1
  validate_go_fallback || return 1
}

rollback_failed_candidate() {
  local rollback_status
  if rollback_to_go; then
    return 1
  else
    rollback_status=$?
    return "$rollback_status"
  fi
}

remote_deployment_transaction() {
  validate_candidate_config || return 1
  migrate_candidate || return 1
  if ! drain_current_owner; then
    return 1
  fi
  if ! wait_current_quiescence; then
    return 1
  fi
  if ! stop_current_owner; then
    if check_no_running_owner; then
      rollback_failed_candidate
      return $?
    fi
    return 1
  fi
  if ! check_candidate_invariants; then
    rollback_failed_candidate
    return $?
  fi
  if ! start_candidate; then
    rollback_failed_candidate
    return $?
  fi
  if ! validate_running_candidate; then
    rollback_failed_candidate
    return $?
  fi
}

remote_deploy() {
  deployment_hook_unconfigured remote_deploy
}

commit_metadata() {
  deployment_hook_unconfigured commit_metadata
}

finalize_remote_deploy() {
  deployment_hook_unconfigured finalize_remote_deploy
}

rollback_after_commit_failure() {
  deployment_hook_unconfigured rollback_after_commit_failure
}

deploy_with_metadata_commit() {
  if ! remote_deploy "$@"; then
    return 1
  fi
  if ! commit_metadata "$@"; then
    rollback_after_commit_failure "$@" || true
    return 1
  fi
  finalize_remote_deploy "$@"
}
