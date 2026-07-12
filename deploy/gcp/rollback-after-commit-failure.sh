#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/deploy-common.sh"

FALLBACK_IMAGE=${1:?usage: rollback-after-commit-failure.sh GO_FALLBACK_IMAGE}
validate_pinned_image_ref "$FALLBACK_IMAGE" ||
  fail "Go fallback image must be an immutable digest"

readonly ENV_FILE=/etc/d-inference/env
readonly SECRET_DIR=/etc/d-inference/secrets
readonly DATA_MOUNT=/mnt/disks/userdata
readonly CANDIDATE_FILE=/run/d-inference/candidate.env
readonly SNAPSHOT_POINTER=/etc/d-inference/previous-known-good.path
[[ -r "$ENV_FILE" ]] || fail "coordinator env file is unavailable"
[[ -d "$SECRET_DIR" ]] || fail "coordinator secret directory is unavailable"
mountpoint -q "$DATA_MOUNT" || fail "persistent state disk is not mounted"
ADMIN_KEY=$(read_env_value "$ENV_FILE" EIGENINFERENCE_ADMIN_KEY)
AUTH_CONFIG=$(mktemp)
make_curl_auth_config "$AUTH_CONFIG" "$ADMIN_KEY"
unset ADMIN_KEY
trap 'rm -f "$AUTH_CONFIG"' EXIT

PREVIOUS_PROVIDERS=$(curl_cmd --silent --show-error --fail \
  http://127.0.0.1:8080/health | jq -er '.providers') ||
  PREVIOUS_PROVIDERS=0
[[ "$PREVIOUS_PROVIDERS" =~ ^[0-9]+$ ]] ||
  fail "running candidate provider count is invalid"

candidate_running() {
  docker_cmd ps --filter name='^/d-inference-coordinator$' --format '{{.ID}}' |
    awk 'NF { found=1 } END { exit !found }'
}

refuse_unsafe_rollback() {
  install -d -m 0755 /run/systemd/system/d-inference-coordinator.service.d
  cat >/run/systemd/system/d-inference-coordinator.service.d/rollback-fence.conf <<'EOF'
[Service]
Restart=no
EOF
  umask 077
  printf 'automatic metadata rollback refused at %s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    >/run/d-inference/automatic-rollback-refused
  systemctl_cmd daemon-reload
  if candidate_running; then
    docker_cmd pause d-inference-coordinator >/dev/null
  fi
}

if candidate_running; then
  log "Handoff-draining uncommitted candidate before metadata rollback"
  if ! set_handoff_drain "$AUTH_CONFIG" ||
    ! wait_for_quiescence "$AUTH_CONFIG" 120 5; then
    if ! refuse_unsafe_rollback; then
      fail "CRITICAL: uncommitted candidate could not be ownership-fenced"
      exit 44
    fi
    fail "metadata rollback refused: candidate is not safely quiescent"
    exit 43
  fi
fi
systemctl_cmd stop d-inference-coordinator.service
if docker_cmd inspect d-inference-coordinator >/dev/null 2>&1; then
  docker_cmd rename d-inference-coordinator \
    "d-inference-coordinator-uncommitted-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi
check_no_running_owner

restore_previous_known_good_env "$ENV_FILE" "$SECRET_DIR" "$SNAPSHOT_POINTER" || {
  fail "metadata failure rollback could not restore previous-known-good env"
  exit 41
}
ADMIN_KEY=$(read_env_value "$ENV_FILE" EIGENINFERENCE_ADMIN_KEY)
make_curl_auth_config "$AUTH_CONFIG" "$ADMIN_KEY"
unset ADMIN_KEY

log "Metadata commit failed; running pinned Go image CheckRollbackSafe"
docker_cmd run --rm \
  --network host \
  --env-file "$ENV_FILE" \
  --mount "type=bind,source=$DATA_MOUNT,target=$DATA_MOUNT" \
  --mount "type=bind,source=$SECRET_DIR,target=/run/d-inference-secrets,readonly" \
  --entrypoint /usr/local/bin/coordinator-go \
  "$FALLBACK_IMAGE" rollback-check |
  jq -e '.rollback_safe == true' >/dev/null || {
  fail "metadata failure rollback refused because CheckRollbackSafe failed"
  exit 42
}

umask 077
temporary="${CANDIDATE_FILE}.tmp.$$"
printf 'DINF_IMAGE=%s\nDINF_COORDINATOR_BINARY=go\n' \
  "$FALLBACK_IMAGE" >"$temporary"
mv "$temporary" "$CANDIDATE_FILE"
rm -f /run/systemd/system/d-inference-coordinator.service.d/rollback-fence.conf \
  /run/d-inference/automatic-rollback-refused
systemctl_cmd daemon-reload
systemctl_cmd start d-inference-coordinator.service
wait_for_candidate "" "$PREVIOUS_PROVIDERS" "$AUTH_CONFIG" 60 5
verify_state_mount d-inference-coordinator
verify_container_selector go d-inference-coordinator
check_one_container_invariant
