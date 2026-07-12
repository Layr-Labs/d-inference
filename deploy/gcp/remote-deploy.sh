#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091 # SCRIPT_DIR is resolved from this script's absolute path.
source "$SCRIPT_DIR/deploy-common.sh"

[[ $# -eq 5 || $# -eq 6 ]] || {
  echo "usage: remote-deploy.sh IMAGE SELECTOR EXPECTED_COMMIT GO_FALLBACK_IMAGE ADOPT_LEGACY [CUTOVER_ENVIRONMENT_ID]" >&2
  exit 64
}

CANDIDATE_INPUT=$1
CANDIDATE_SELECTOR=$2
EXPECTED_COMMIT=$3
GO_FALLBACK_INPUT=$4
ADOPT_LEGACY=$5
CUTOVER_ENVIRONMENT_ID=${6:-$(printf '%064d' 0)}
readonly ENV_FILE=/etc/d-inference/env
readonly SECRET_DIR=/etc/d-inference/secrets
readonly DATA_MOUNT=/mnt/disks/userdata
readonly CANDIDATE_FILE=/run/d-inference/candidate.env
readonly RESULT_FILE=/run/d-inference/deploy-result.env
readonly SNAPSHOT_POINTER=/etc/d-inference/previous-known-good.path

validate_image_ref "$CANDIDATE_INPUT" || fail "invalid candidate image"
validate_selector "$CANDIDATE_SELECTOR" || fail "invalid coordinator selector"
validate_image_ref "$GO_FALLBACK_INPUT" || fail "invalid pinned Go fallback image"
[[ "$EXPECTED_COMMIT" =~ ^[A-Fa-f0-9]{7,64}$ ]] || fail "invalid expected commit"
[[ "$ADOPT_LEGACY" == "true" || "$ADOPT_LEGACY" == "false" ]] ||
  fail "ADOPT_LEGACY must be true or false"
[[ "$CUTOVER_ENVIRONMENT_ID" =~ ^[a-f0-9]{64}$ ]] ||
  fail "CUTOVER_ENVIRONMENT_ID must be a lowercase SHA-256"
[[ -r "$ENV_FILE" ]] || fail "coordinator env file is unavailable"
[[ -d "$SECRET_DIR" ]] || fail "coordinator secret directory is unavailable"
mountpoint -q "$DATA_MOUNT" || fail "persistent state disk is not mounted"

install -d -m 0755 /run/d-inference
exec 9>/run/d-inference/deploy.lock
flock -n 9 || fail "another coordinator deployment transaction is active"
[[ ! -e "$RESULT_FILE" ]] ||
  fail "a validated candidate is still awaiting metadata commit or rollback"

ADMIN_KEY=$(read_env_value "$ENV_FILE" EIGENINFERENCE_ADMIN_KEY) ||
  fail "admin key is missing from coordinator env file"
AUTH_CONFIG=$(mktemp)
make_curl_auth_config "$AUTH_CONFIG" "$ADMIN_KEY" ||
  fail "admin key cannot be represented safely"
unset ADMIN_KEY
READ_ONLY_KEY=$(read_env_value "$ENV_FILE" EIGENINFERENCE_READ_ONLY_KEY) ||
  fail "read-only operations key is missing from coordinator env file"
READ_ONLY_AUTH_CONFIG=$(mktemp)
make_curl_auth_config "$READ_ONLY_AUTH_CONFIG" "$READ_ONLY_KEY" ||
  fail "read-only operations key cannot be represented safely"
unset READ_ONLY_KEY
trap 'rm -f "$AUTH_CONFIG" "$READ_ONLY_AUTH_CONFIG"' EXIT

refresh_auth_config() {
  local admin_key read_only_key auth_temporary read_temporary
  admin_key=$(read_env_value "$ENV_FILE" EIGENINFERENCE_ADMIN_KEY) ||
    fail "admin key is missing from restored coordinator env file" ||
    return 1
  auth_temporary=$(mktemp)
  if ! make_curl_auth_config "$auth_temporary" "$admin_key"; then
    unset admin_key
    rm -f "$auth_temporary"
    return 1
  fi
  unset admin_key
  mv "$auth_temporary" "$AUTH_CONFIG"
  read_only_key=$(read_env_value "$ENV_FILE" EIGENINFERENCE_READ_ONLY_KEY) ||
    fail "read-only operations key is missing from restored coordinator env file" ||
    return 1
  read_temporary=$(mktemp)
  if ! make_curl_auth_config "$read_temporary" "$read_only_key"; then
    unset read_only_key
    rm -f "$read_temporary"
    return 1
  fi
  unset read_only_key
  mv "$read_temporary" "$READ_ONLY_AUTH_CONFIG"
}

registry_login() {
  local image=$1
  local registry=${image%%/*}
  local token
  token=$(curl -fsSL -H "Metadata-Flavor: Google" \
    "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" |
    jq -er '.access_token') ||
    return 1
  printf '%s' "$token" | docker_cmd login \
    -u oauth2accesstoken --password-stdin "$registry" >/dev/null ||
    return 1
  unset token
}

pull_and_resolve() {
  local image=$1
  registry_login "$image" || return 1
  docker_cmd pull "$image" >/dev/null || return 1
  if [[ "$image" == *"@sha256:"* ]]; then
    printf '%s\n' "$image"
    return
  fi
  local repository=${image%:*}
  local digest
  digest=$(docker_cmd image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$image" |
    awk -v prefix="${repository}@sha256:" 'index($0, prefix) == 1 { print; exit }') ||
    return 1
  validate_image_ref "$digest" || {
    fail "registry did not provide an immutable digest for $image"
    return 1
  }
  printf '%s\n' "$digest"
}

CANDIDATE_IMAGE=$(pull_and_resolve "$CANDIDATE_INPUT")
GO_FALLBACK_IMAGE=$(pull_and_resolve "$GO_FALLBACK_INPUT")
validate_pinned_image_ref "$CANDIDATE_IMAGE" ||
  fail "candidate image was not resolved to an immutable digest"
validate_pinned_image_ref "$GO_FALLBACK_IMAGE" ||
  fail "Go fallback image was not resolved to an immutable digest"

OLD_RUNNING=false
OLD_CONTAINER_NAME=
OLD_CONTAINER_AUTO_REMOVE=false
OLD_PRESERVED_NAME=
PREVIOUS_PROVIDERS=0
existing_serving_names=$(
  {
    docker_cmd ps --filter label=com.darkbloom.role=serving --format '{{.Names}}'
    docker_cmd ps --filter name='^/d-inference-coordinator$' --format '{{.Names}}'
    docker_cmd ps --filter name='^/coordinator$' --format '{{.Names}}'
  } | awk 'NF && !seen[$0]++'
) || fail "cannot enumerate serving coordinator containers"
existing_serving_containers=()
if [[ -n "$existing_serving_names" ]]; then
  mapfile -t existing_serving_containers <<<"$existing_serving_names"
fi
(( ${#existing_serving_containers[@]} <= 1 )) ||
  fail "multiple legacy/current serving containers are running"
if (( ${#existing_serving_containers[@]} == 1 )); then
  OLD_RUNNING=true
  OLD_CONTAINER_NAME=${existing_serving_containers[0]}
fi
EXISTING_RECOVERY_CONTAINERS=$(recovery_container_count) ||
  fail "cannot enumerate offline recovery containers"
(( EXISTING_RECOVERY_CONTAINERS == 0 )) ||
  fail "offline recovery must be stopped before deployment"
if [[ "$OLD_RUNNING" == "true" ]]; then
  PREVIOUS_PROVIDERS=$(curl_cmd --silent --show-error --fail \
    http://127.0.0.1:8080/health | jq -er '.providers')
  [[ "$PREVIOUS_PROVIDERS" =~ ^[0-9]+$ ]] || fail "old health provider count is invalid"
fi

migrate_candidate() {
  local -a args=(-lock-timeout=10s -statement-timeout=30m)
  [[ "$ADOPT_LEGACY" == "true" ]] && args+=(-adopt-legacy)
  log "Applying external schema migration from candidate image"
  docker_cmd run --rm \
    --network host \
    --env-file "$ENV_FILE" \
    --entrypoint /usr/local/bin/coordinator-migrate \
    "$CANDIDATE_IMAGE" "${args[@]}"
}

validate_candidate_config() {
  log "Validating candidate image, selector, configuration, and state mount"
  docker_cmd run --rm \
    --entrypoint /usr/local/bin/coordinator-image-check \
    "$CANDIDATE_IMAGE" smoke ||
    return 1
  docker_cmd run --rm \
    --entrypoint "/usr/local/bin/coordinator-${CANDIDATE_SELECTOR}" \
    "$CANDIDATE_IMAGE" version |
    jq -e --arg binary "$CANDIDATE_SELECTOR" --arg commit "$EXPECTED_COMMIT" '
      .binary == $binary and .build_commit == $commit
    ' >/dev/null ||
    return 1
  if ! docker_cmd run --rm \
    --network host \
    --env-file "$ENV_FILE" \
    --env "EIGENINFERENCE_COORDINATOR_BINARY=$CANDIDATE_SELECTOR" \
    --mount "type=bind,source=$DATA_MOUNT,target=$DATA_MOUNT" \
    --mount "type=bind,source=$SECRET_DIR,target=/run/d-inference-secrets,readonly" \
    --entrypoint /usr/local/bin/coordinator-image-check \
    "$CANDIDATE_IMAGE" config; then
    if [[ "$OLD_RUNNING" == "true" || -r "$SNAPSHOT_POINTER" ]]; then
      restore_go_fallback_environment ||
        fail "candidate preflight failed and previous env restore also failed"
    fi
    return 1
  fi
  check_one_container_invariant
}

drain_current_owner() {
  [[ "$OLD_RUNNING" == "true" ]] || return 0
  log "Entering irreversible handoff drain; mutations and provider sessions are fenced"
  set_handoff_drain "$AUTH_CONFIG"
}

wait_current_quiescence() {
  [[ "$OLD_RUNNING" == "true" ]] || return 0
  log "Waiting for detailed coordinator quiescence"
  if wait_for_quiescence "$READ_ONLY_AUTH_CONFIG" "${DINF_QUIESCENCE_ATTEMPTS:-120}" \
    "${DINF_POLL_INTERVAL_SECONDS:-5}"; then
    return 0
  fi
  log "Quiescence failed after irreversible handoff; old owner remains fenced"
  return 1
}

preserve_named_container() {
  local name=$1
  local suffix=$2
  docker_cmd inspect "$name" >/dev/null 2>&1 || return 1
  docker_cmd rename "$name" \
    "d-inference-coordinator-${suffix}-$(date -u +%Y%m%dT%H%M%SZ)-$$"
}

prepare_auto_remove_container_preservation() {
  local name=$1
  OLD_CONTAINER_AUTO_REMOVE=$(docker_cmd inspect --format \
    '{{.HostConfig.AutoRemove}}' "$name") ||
    return 1
  case "$OLD_CONTAINER_AUTO_REMOVE" in
    false)
      return 0
      ;;
    true)
      local suffix snapshot_image
      suffix="$(date -u +%Y%m%dT%H%M%SZ)-$$"
      snapshot_image="darkbloom/coordinator-preserved:${suffix,,}"
      OLD_PRESERVED_NAME="d-inference-coordinator-old-${suffix}"
      docker_cmd commit "$name" "$snapshot_image" >/dev/null || return 1
      docker_cmd create \
        --name "$OLD_PRESERVED_NAME" \
        --label com.darkbloom.role=preserved \
        "$snapshot_image" >/dev/null ||
        return 1
      ;;
    *)
      fail "old coordinator AutoRemove state is invalid"
      return 1
      ;;
  esac
}

stop_current_owner() {
  if [[ "$OLD_RUNNING" == "true" ]]; then
    log "Stopping old coordinator and releasing PostgreSQL ownership"
    prepare_auto_remove_container_preservation "$OLD_CONTAINER_NAME" || return 1
    if [[ "$OLD_CONTAINER_NAME" == "d-inference-coordinator" ]]; then
      systemctl_cmd stop d-inference-coordinator.service || return 1
      if docker_cmd ps --filter "name=^/${OLD_CONTAINER_NAME}$" \
        --format '{{.ID}}' | awk 'NF { found=1 } END { exit !found }'; then
        docker_cmd stop -t 45 "$OLD_CONTAINER_NAME" || return 1
      fi
    else
      docker_cmd stop -t 45 "$OLD_CONTAINER_NAME" || return 1
    fi
    if [[ "$OLD_CONTAINER_AUTO_REMOVE" == "true" ]]; then
      docker_cmd inspect "$OLD_PRESERVED_NAME" >/dev/null 2>&1 || return 1
    else
      preserve_named_container "$OLD_CONTAINER_NAME" old || return 1
    fi
  fi
  check_no_running_owner
}

run_one_shot() {
  local image=$1
  local entrypoint=$2
  shift 2
  docker_cmd run --rm \
    --network host \
    --env-file "$ENV_FILE" \
    --mount "type=bind,source=$DATA_MOUNT,target=$DATA_MOUNT" \
    --mount "type=bind,source=$SECRET_DIR,target=/run/d-inference-secrets,readonly" \
    --entrypoint "$entrypoint" \
    "$image" "$@"
}

check_candidate_invariants() {
  log "Checking candidate database invariants under exclusive ownership"
  if [[ "$CANDIDATE_SELECTOR" == "go" ]]; then
    run_one_shot "$CANDIDATE_IMAGE" /usr/local/bin/coordinator-go rollback-check |
      jq -e '.rollback_safe == true' >/dev/null
    return
  fi
  local output report
  output=$(run_one_shot "$CANDIDATE_IMAGE" /usr/local/bin/coordinator-rs invariant-scan) ||
    return 1
  report=$(printf '%s\n' "$output" | sed -n '$p')
  printf '%s\n' "$report" | jq -e '.healthy == true' >/dev/null
}

write_candidate_file() {
  local image=$1
  local selector=$2
  local temporary
  temporary="${CANDIDATE_FILE}.tmp.$$"
  umask 077
  printf 'DINF_IMAGE=%s\nDINF_COORDINATOR_BINARY=%s\nDINF_CUTOVER_ENVIRONMENT_ID=%s\n' \
    "$image" "$selector" "$CUTOVER_ENVIRONMENT_ID" >"$temporary" ||
    return 1
  mv "$temporary" "$CANDIDATE_FILE"
}

start_candidate() {
  check_no_running_owner || return 1
  rm -f /run/systemd/system/d-inference-coordinator.service.d/rollback-fence.conf \
    /run/d-inference/automatic-rollback-refused
  systemctl_cmd daemon-reload || return 1
  write_candidate_file "$CANDIDATE_IMAGE" "$CANDIDATE_SELECTOR" || return 1
  log "Starting exactly one candidate serving container"
  systemctl_cmd start d-inference-coordinator.service
}

validate_running_candidate() {
  wait_for_candidate "$EXPECTED_COMMIT" "$PREVIOUS_PROVIDERS" "$AUTH_CONFIG" \
    "${DINF_CANDIDATE_ATTEMPTS:-60}" "${DINF_POLL_INTERVAL_SECONDS:-5}" ||
    return 1
  local configured_image labeled_image
  configured_image=$(docker_cmd inspect --format '{{.Config.Image}}' \
    d-inference-coordinator) ||
    return 1
  labeled_image=$(docker_cmd inspect --format \
    '{{index .Config.Labels "com.darkbloom.image-digest"}}' \
    d-inference-coordinator) ||
    return 1
  [[ "$configured_image" == "$CANDIDATE_IMAGE" &&
    "$labeled_image" == "$CANDIDATE_IMAGE" ]] ||
    return 1
  curl_cmd --silent --show-error --fail http://127.0.0.1:8080/health |
    jq -e --arg digest "$CANDIDATE_IMAGE" '.image_digest == $digest' >/dev/null ||
    return 1
  verify_state_mount d-inference-coordinator || return 1
  verify_container_selector "$CANDIDATE_SELECTOR" d-inference-coordinator ||
    return 1
  docker_cmd run --rm \
    --env-file "$ENV_FILE" \
    --env "EIGENINFERENCE_COORDINATOR_BINARY=$CANDIDATE_SELECTOR" \
    --mount "type=bind,source=$DATA_MOUNT,target=$DATA_MOUNT" \
    --mount "type=bind,source=$SECRET_DIR,target=/run/d-inference-secrets,readonly" \
    --entrypoint /usr/local/bin/coordinator-image-check \
    "$CANDIDATE_IMAGE" rotation ||
    return 1
  check_one_container_invariant
}

stop_failed_candidate() {
  systemctl_cmd stop d-inference-coordinator.service || return 1
  if docker_cmd inspect d-inference-coordinator >/dev/null 2>&1; then
    docker_cmd rename d-inference-coordinator \
      "d-inference-coordinator-failed-$(date -u +%Y%m%dT%H%M%SZ)-$$" ||
      return 1
  fi
  check_no_running_owner
}

restore_go_fallback_environment() {
  if [[ ! -r "$SNAPSHOT_POINTER" ]]; then
    [[ "$OLD_RUNNING" != "true" ]] || {
      fail "running owner has no previous-known-good env snapshot"
      return 1
    }
    return 0
  fi
  restore_previous_known_good_env "$ENV_FILE" "$SECRET_DIR" "$SNAPSHOT_POINTER" ||
    return 1
  refresh_auth_config
}

failed_candidate_running() {
  docker_cmd ps --filter name='^/d-inference-coordinator$' --format '{{.ID}}' |
    awk 'NF { found=1 } END { exit !found }'
}

handoff_failed_candidate() {
  failed_candidate_running || return 0
  log "Handoff-draining failed candidate before rollback"
  set_handoff_drain "$AUTH_CONFIG"
}

wait_failed_candidate_quiescence() {
  failed_candidate_running || return 0
  wait_for_quiescence "$READ_ONLY_AUTH_CONFIG" "${DINF_QUIESCENCE_ATTEMPTS:-120}" \
    "${DINF_POLL_INTERVAL_SECONDS:-5}"
}

fence_failed_candidate_ownership() {
  install -d -m 0755 /run/systemd/system/d-inference-coordinator.service.d
  cat >/run/systemd/system/d-inference-coordinator.service.d/rollback-fence.conf <<'EOF'
[Service]
Restart=no
EOF
  umask 077
  printf 'automatic rollback refused at %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >/run/d-inference/automatic-rollback-refused
  systemctl_cmd daemon-reload || return 1
  if failed_candidate_running; then
    docker_cmd pause d-inference-coordinator >/dev/null || return 1
    check_one_container_invariant || return 1
    log "Failed candidate is paused as the sole fenced owner; manual recovery is required"
  fi
}

check_rollback_safe() {
  log "Running pinned Go image CheckRollbackSafe before rollback"
  run_one_shot "$GO_FALLBACK_IMAGE" /usr/local/bin/coordinator-go rollback-check |
    jq -e '.rollback_safe == true' >/dev/null
}

start_go_fallback() {
  rm -f /run/systemd/system/d-inference-coordinator.service.d/rollback-fence.conf \
    /run/d-inference/automatic-rollback-refused
  systemctl_cmd daemon-reload || return 1
  write_candidate_file "$GO_FALLBACK_IMAGE" go || return 1
  systemctl_cmd start d-inference-coordinator.service
}

validate_go_fallback() {
  wait_for_candidate "" "$PREVIOUS_PROVIDERS" "$AUTH_CONFIG" \
    "${DINF_CANDIDATE_ATTEMPTS:-60}" "${DINF_POLL_INTERVAL_SECONDS:-5}" ||
    return 1
  verify_state_mount d-inference-coordinator || return 1
  verify_container_selector go d-inference-coordinator || return 1
  check_one_container_invariant || return 1
  log "Candidate failed; pinned Go image was restored safely"
}

if remote_deployment_transaction; then
  :
else
  status=$?
  exit "$status"
fi

umask 077
cat >"$RESULT_FILE" <<EOF
DINF_IMAGE=$CANDIDATE_IMAGE
DINF_COORDINATOR_BINARY=$CANDIDATE_SELECTOR
DINF_GO_FALLBACK_IMAGE=$([[ "$CANDIDATE_SELECTOR" == "go" ]] && printf '%s' "$CANDIDATE_IMAGE" || printf '%s' "$GO_FALLBACK_IMAGE")
DINF_PREVIOUS_GO_FALLBACK_IMAGE=$GO_FALLBACK_IMAGE
DINF_CUTOVER_ENVIRONMENT_ID=$CUTOVER_ENVIRONMENT_ID
EOF
log "Candidate passed all deployment checks; awaiting metadata commit"
