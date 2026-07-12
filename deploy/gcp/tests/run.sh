#!/bin/bash
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
source "$ROOT/deploy/gcp/deploy-common.sh"

passed=0
failed=0

run_test() {
  local name=$1
  shift
  if ("$@"); then
    printf 'ok - %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'not ok - %s\n' "$name" >&2
    failed=$((failed + 1))
  fi
}

test_selector_injection() {
  local marker
  marker=$(mktemp)
  rm -f "$marker"
  local malicious
  malicious="\$(touch $marker)"
  EIGENINFERENCE_COORDINATOR_BINARY="$malicious" \
    sh "$ROOT/coordinator/deploy/start.sh" >/dev/null 2>&1
  local status=$?
  [[ "$status" -eq 64 && ! -e "$marker" ]]
}

test_cloudbuild_selector_reaches_validator_as_data() {
  local config=$ROOT/deploy/gcp/cloudbuild.yaml
  # Literal Cloud Build and shell expansion markers are the assertions.
  # shellcheck disable=SC2016
  grep -Fq -- '- COORDINATOR_BINARY=${_COORDINATOR_BINARY}' "$config" &&
    grep -Fq -- '"$COORDINATOR_BINARY"' "$config" &&
    ! grep -Fq -- '"${_COORDINATOR_BINARY}"' "$config"
}

test_migration_failure_does_not_commit_metadata() {
  local metadata_calls=0
  remote_deploy() {
    return 1
  }
  commit_metadata() {
    metadata_calls=$((metadata_calls + 1))
  }
  deploy_with_metadata_commit candidate go
  local status=$?
  [[ "$status" -ne 0 && "$metadata_calls" -eq 0 ]]
}

test_wrong_image_never_runs_migration() {
  local migrations=0
  validate_candidate_config() { return 1; }
  migrate_candidate() { migrations=$((migrations + 1)); }
  remote_deployment_transaction >/dev/null 2>&1
  local status=$?
  [[ "$status" -ne 0 && "$migrations" -eq 0 ]]
}

test_quiescence_timeout() {
  local fetch_count=0
  fetch_quiescence() {
    local output=$1
    fetch_count=$((fetch_count + 1))
    printf '%s\n' '{"ownership_healthy":true,"http_inference":1}' >"$output"
  }
  sleep_cmd() {
    :
  }
  local auth
  auth=$(mktemp)
  wait_for_quiescence "$auth" 3 0 >/dev/null 2>&1
  local status=$?
  rm -f "$auth"
  [[ "$status" -ne 0 && "$fetch_count" -eq 3 ]]
}

test_quiescence_requires_two_stable_samples() {
  local fetch_count=0
  fetch_quiescence() {
    local output=$1
    fetch_count=$((fetch_count + 1))
    local inference=0
    [[ "$fetch_count" -ne 2 ]] || inference=1
    local quiescent=true
    [[ "$inference" -eq 0 ]] || quiescent=false
    printf '{"quiescent":%s,"ownership_healthy":true,"http_inference":%d,"http_mutations":0,"provider_sessions":0,"providers_connected":0,"pending_attempts":0,"request_queue":0,"writer_data_queue":0,"writer_control_queue":0,"writer_active":0,"completion_queue":0,"completion_active":0,"completion_outstanding":0,"settlement_held":0,"settlement_callbacks":0,"telemetry_queued":0,"background_tasks":0}\n' \
      "$quiescent" "$inference" >"$output"
  }
  sleep_cmd() { :; }
  local auth
  auth=$(mktemp)
  wait_for_quiescence "$auth" 4 0 >/dev/null 2>&1
  local status=$?
  rm -f "$auth"
  [[ "$status" -eq 0 && "$fetch_count" -eq 4 ]]
}

test_detailed_quiescence_rejects_omitted_go_counters() {
  local snapshot
  snapshot=$(mktemp)
  cat >"$snapshot" <<'JSON'
{
  "quiescent": true,
  "ownership_healthy": true,
  "http_inference": 0,
  "http_mutations": 0,
  "provider_sessions": 0,
  "providers_connected": 0,
  "pending_attempts": 0,
  "request_queue": 0,
  "writer_data_queue": 0,
  "writer_control_queue": 0,
  "writer_active": 0,
  "completion_outstanding": 0,
  "completion_queue": 0,
  "completion_active": 0,
  "settlement_held": 0,
  "settlement_callbacks": 0,
  "telemetry_queued": 0,
  "background_tasks": 0
}
JSON
  quiescence_safe_json "$snapshot" &&
    jq '.providers_connected = 1' "$snapshot" >"${snapshot}.busy" &&
    ! quiescence_safe_json "${snapshot}.busy" &&
    jq 'del(.background_tasks)' "$snapshot" >"${snapshot}.missing" &&
    ! quiescence_safe_json "${snapshot}.missing"
  local status=$?
  rm -f "$snapshot" "${snapshot}.busy" "${snapshot}.missing"
  return "$status"
}

test_detailed_quiescence_requires_rust_summary() {
  local snapshot
  snapshot=$(mktemp)
  cat >"$snapshot" <<'JSON'
{
  "quiescent": true,
  "draining": true,
  "external_fenced": true,
  "ownership_healthy": true,
  "supervisor": {"ready": true},
  "fleet": {"active_leases": 0},
  "requests": {
    "active": 0,
    "durable_active": 0,
    "http_inference": 0,
    "http_mutations": 0
  },
  "writers": {"reserved_items": 0},
  "recovery": {
    "pending_terminals": 0,
    "pending_external_events": 0,
    "active_leases": 0,
    "active_external_operations": 0
  },
  "outbox": {"pending": 0, "pending_fee_allocations": 0},
  "durable_telemetry": {"pending": 0}
}
JSON
  quiescence_safe_json "$snapshot" &&
    jq '.quiescent = false' "$snapshot" >"${snapshot}.busy" &&
    ! quiescence_safe_json "${snapshot}.busy"
  local status=$?
  rm -f "$snapshot" "${snapshot}.busy"
  return "$status"
}

test_candidate_failure_rolls_back_to_go() {
  local trace=
  migrate_candidate() { trace+=migrate,; }
  validate_candidate_config() { trace+=config,; }
  drain_current_owner() { trace+=drain,; }
  wait_current_quiescence() { trace+=quiescence,; }
  stop_current_owner() { trace+=stop-old,; }
  check_candidate_invariants() { trace+=invariants,; }
  start_candidate() { trace+=start-candidate,; }
  validate_running_candidate() { trace+=candidate-failed,; return 1; }
  handoff_failed_candidate() { trace+=handoff-candidate,; }
  wait_failed_candidate_quiescence() { trace+=candidate-quiescent,; }
  fence_failed_candidate_ownership() { trace+=fence-candidate,; }
  stop_failed_candidate() { trace+=stop-candidate,; }
  restore_go_fallback_environment() { trace+=restore-old-env,; }
  check_rollback_safe() { trace+=rollback-safe,; }
  start_go_fallback() { trace+=start-go,; }
  validate_go_fallback() { trace+=validate-go,; }
  remote_deployment_transaction
  local status=$?
  [[ "$status" -ne 0 ]] &&
    [[ "$trace" == *"candidate-failed,handoff-candidate,candidate-quiescent,stop-candidate,restore-old-env,rollback-safe,start-go,validate-go,"* ]]
}

test_rollback_unsafe_refuses_fallback() {
  local fallback_started=false
  migrate_candidate() { :; }
  validate_candidate_config() { :; }
  drain_current_owner() { :; }
  wait_current_quiescence() { :; }
  stop_current_owner() { :; }
  check_candidate_invariants() { :; }
  start_candidate() { :; }
  validate_running_candidate() { return 1; }
  handoff_failed_candidate() { :; }
  wait_failed_candidate_quiescence() { :; }
  fence_failed_candidate_ownership() { :; }
  stop_failed_candidate() { :; }
  restore_go_fallback_environment() { :; }
  check_rollback_safe() { return 1; }
  start_go_fallback() { fallback_started=true; }
  remote_deployment_transaction >/dev/null 2>&1
  local status=$?
  [[ "$status" -eq 42 && "$fallback_started" == "false" ]]
}

test_stop_failure_leaves_old_handoff_fenced() {
  local fallback_started=false
  migrate_candidate() { :; }
  validate_candidate_config() { :; }
  drain_current_owner() { :; }
  wait_current_quiescence() { :; }
  stop_current_owner() { return 1; }
  check_no_running_owner() { return 1; }
  start_go_fallback() { fallback_started=true; }
  remote_deployment_transaction >/dev/null 2>&1
  local status=$?
  [[ "$status" -ne 0 && "$fallback_started" == "false" ]]
}

test_failed_candidate_quiescence_refuses_automatic_fallback() {
  local stopped=false
  local fenced=false
  local fallback_started=false
  handoff_failed_candidate() { :; }
  wait_failed_candidate_quiescence() { return 1; }
  fence_failed_candidate_ownership() { fenced=true; }
  stop_failed_candidate() { stopped=true; }
  start_go_fallback() { fallback_started=true; }
  rollback_to_go >/dev/null 2>&1
  local status=$?
  [[ "$status" -eq 43 && "$fenced" == "true" &&
    "$stopped" == "false" && "$fallback_started" == "false" ]]
}

test_one_container_invariant() {
  docker_cmd() {
    if [[ "$*" == *"com.darkbloom.role=serving"* ]]; then
      printf 'one\ntwo\n'
    fi
  }
  ! check_one_container_invariant >/dev/null 2>&1
}

test_multiple_recovery_containers_are_rejected() {
  docker_cmd() {
    if [[ "$*" == *"com.darkbloom.role=recovery"* ]]; then
      printf 'one\ntwo\n'
    fi
  }
  ! check_one_container_invariant >/dev/null 2>&1
}

test_recovery_cannot_overlap_serving() {
  docker_cmd() {
    if [[ "$*" == *"com.darkbloom.role=serving"* ]]; then
      printf 'serving\n'
    elif [[ "$*" == *"com.darkbloom.role=recovery"* ]]; then
      printf 'recovery\n'
    fi
  }
  ! check_one_container_invariant >/dev/null 2>&1
}

test_systemd_never_auto_stops_competing_owner() {
  ! grep -q '^Conflicts=' \
    "$ROOT/deploy/gcp/systemd/d-inference-coordinator.service" &&
    ! grep -q '^Conflicts=' \
      "$ROOT/deploy/gcp/systemd/d-inference-recovery.service" &&
    grep -qx 'RestartPreventExitStatus=75' \
      "$ROOT/deploy/gcp/systemd/d-inference-coordinator.service" &&
    grep -qx 'RestartPreventExitStatus=75' \
      "$ROOT/deploy/gcp/systemd/d-inference-recovery.service" &&
    grep -Fq 'flock -n 9' "$ROOT/deploy/gcp/run-coordinator.sh" &&
    grep -Fq 'flock -n 9' "$ROOT/deploy/gcp/run-recovery.sh" &&
    grep -Fq 'EIGENINFERENCE_COORDINATOR_OWNERSHIP_ENABLED=true' \
      "$ROOT/deploy/gcp/refresh-env.sh" &&
    grep -Fq 'CoordinatorOwnership::configure' \
      "$ROOT/coordinator-rs/crates/server/src/main.rs" &&
    ! grep -Eq 'systemctl( |_cmd )stop|docker stop' \
      "$ROOT/deploy/gcp/run-recovery.sh"
}

test_bootstrap_attaches_precreated_disk() {
  # shellcheck disable=SC2016
  grep -Fq -- '--disk="name=${DATA_DISK},mode=rw,boot=no,auto-delete=no,device-name=${DATA_DISK}"' \
    "$ROOT/deploy/gcp/bootstrap.sh" &&
    grep -Fq 'compute instances attach-disk "$INSTANCE"' \
      "$ROOT/deploy/gcp/bootstrap.sh" &&
    ! grep -Fq -- '--create-disk=' "$ROOT/deploy/gcp/bootstrap.sh"
}

test_gcp_secret_and_sql_operations_are_project_scoped() {
  # shellcheck disable=SC2016
  grep -Fq 'gcloud --project="$PROJECT" "$@"' \
    "$ROOT/deploy/gcp/bootstrap.sh" &&
    grep -Fq 'gcloud --project="$PROJECT" --quiet secrets versions access' \
      "$ROOT/deploy/gcp/refresh-env.sh" &&
    grep -Fq -- '--project="$PROJECT" --format=' \
      "$ROOT/deploy/gcp/vm-startup.sh" &&
    grep -Fq 'DINF_GCP_PROJECT=${PROJECT}' \
      "$ROOT/deploy/gcp/bootstrap.sh"
}

test_p12_preflight_rejects_malformed_and_wrong_password_before_migration() {
  command -v openssl >/dev/null 2>&1 || return 1
  local fixture
  fixture=$(mktemp -d)

  make_identity() {
    local name=$1
    local usage=$2
    local password=$3
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$fixture/$name.key" -out "$fixture/$name.crt" \
      -days 1 -subj "/CN=$name" \
      -addext 'basicConstraints=critical,CA:FALSE' \
      -addext 'keyUsage=critical,digitalSignature' \
      -addext "extendedKeyUsage=$usage" >/dev/null 2>&1 &&
      openssl pkcs12 -export -out "$fixture/$name.p12" \
        -inkey "$fixture/$name.key" -in "$fixture/$name.crt" \
        -passout "pass:$password" >/dev/null 2>&1 &&
      base64 <"$fixture/$name.p12" | tr '+/' '-_' | tr -d '\n='
  }

  local mdm profile wrong_usage expired case_name migrations status
  mdm=$(make_identity mdm clientAuth mdm-password) || {
    rm -rf "$fixture"
    return 1
  }
  profile=$(make_identity profile codeSigning profile-password) || {
    rm -rf "$fixture"
    return 1
  }
  wrong_usage=$(make_identity wrong-usage serverAuth mdm-password) || {
    rm -rf "$fixture"
    return 1
  }
  if ! openssl req -new -newkey rsa:2048 -nodes \
    -keyout "$fixture/expired.key" -out "$fixture/expired.csr" \
    -subj '/CN=expired-mdm' >/dev/null 2>&1 ||
    ! openssl x509 -req -in "$fixture/expired.csr" \
      -signkey "$fixture/expired.key" -days -1 -out "$fixture/expired.crt" \
      -extfile <(printf '%s\n' \
        'basicConstraints=critical,CA:FALSE' \
        'keyUsage=critical,digitalSignature' \
        'extendedKeyUsage=clientAuth') >/dev/null 2>&1 ||
    ! openssl pkcs12 -export -out "$fixture/expired.p12" \
      -inkey "$fixture/expired.key" -in "$fixture/expired.crt" \
      -passout pass:mdm-password >/dev/null 2>&1; then
    rm -rf "$fixture"
    return 1
  fi
  expired=$(base64 <"$fixture/expired.p12" | tr '+/' '-_' | tr -d '\n=')
  if "$ROOT/coordinator/deploy/p12-check.sh" installed mdm \
    "$fixture/mdm.crt" "$fixture/profile.key" >/dev/null 2>&1; then
    rm -rf "$fixture"
    return 1
  fi

  for case_name in malformed-mdm wrong-profile-password wrong-mdm-usage expired-mdm; do
    migrations=0
    validate_candidate_config() {
      case "$case_name" in
        malformed-mdm)
          MDM_PUSH_P12_B64='not-a-p12' \
            MDM_PUSH_P12_PASSWORD=mdm-password \
            PROFILE_SIGNING_P12_B64="$profile" \
            PROFILE_SIGNING_P12_PASSWORD=profile-password \
            "$ROOT/coordinator/deploy/p12-check.sh" bundle mdm
          ;;
        wrong-profile-password)
          MDM_PUSH_P12_B64="$mdm" \
            MDM_PUSH_P12_PASSWORD=mdm-password \
            "$ROOT/coordinator/deploy/p12-check.sh" bundle mdm &&
            PROFILE_SIGNING_P12_B64="$profile" \
              PROFILE_SIGNING_P12_PASSWORD=wrong \
              "$ROOT/coordinator/deploy/p12-check.sh" bundle profile
          ;;
        wrong-mdm-usage)
          MDM_PUSH_P12_B64="$wrong_usage" \
            MDM_PUSH_P12_PASSWORD=mdm-password \
            "$ROOT/coordinator/deploy/p12-check.sh" bundle mdm
          ;;
        expired-mdm)
          MDM_PUSH_P12_B64="$expired" \
            MDM_PUSH_P12_PASSWORD=mdm-password \
            "$ROOT/coordinator/deploy/p12-check.sh" bundle mdm
          ;;
      esac
    }
    migrate_candidate() { migrations=$((migrations + 1)); }
    remote_deployment_transaction >/dev/null 2>&1
    status=$?
    if [[ "$status" -eq 0 || "$migrations" -ne 0 ]]; then
      rm -rf "$fixture"
      return 1
    fi
  done
  rm -rf "$fixture"
}

test_micromdm_curl_preflight_hides_key_and_fails_closed() {
  local fixture api_key expected_header
  fixture=$(mktemp -d)
  api_key='test-key-not-in-argv'
  expected_header=$(printf 'micromdm:%s' "$api_key" | base64 | tr -d '\n')
  cat >"$fixture/mock-curl" <<'SH'
#!/bin/sh
printf '%s\n' "$@" >"$MOCK_CURL_ARGS"
printf '%s\n' "${MICROMDM_API_KEY-<unset>}" >"$MOCK_CURL_ENV"
cat >"$MOCK_CURL_STDIN"
output=
while [ "$#" -gt 0 ]; do
    if [ "$1" = --output ]; then
        shift
        output=${1:-}
        break
    fi
    shift
done
[ "${MOCK_CURL_FAIL:-0}" != 1 ] || exit 22
[ -n "$output" ] || exit 64
printf '{"devices":[]}\n' >"$output"
SH
  chmod 700 "$fixture/mock-curl"

  MOCK_CURL_ARGS="$fixture/args" \
    MOCK_CURL_ENV="$fixture/env" \
    MOCK_CURL_STDIN="$fixture/stdin" \
    COORDINATOR_CURL="$fixture/mock-curl" \
    MICROMDM_API_KEY="$api_key" \
    EIGENINFERENCE_MDM_URL=https://localhost:9002 \
    "$ROOT/coordinator/deploy/micromdm-api-check.sh" >/dev/null 2>&1 || {
    rm -rf "$fixture"
    return 1
  }

  if ! awk '$0 == "--config" { getline; found = ($0 == "-") } END { exit !found }' \
    "$fixture/args" ||
    ! grep -Fxq -- '--fail' "$fixture/args" ||
    ! grep -Fxq -- '--silent' "$fixture/args" ||
    ! grep -Fxq -- '--show-error' "$fixture/args" ||
    ! grep -Fxq -- '--insecure' "$fixture/args" ||
    ! awk '$0 == "--connect-timeout" { getline; found = ($0 == "3") } END { exit !found }' \
      "$fixture/args" ||
    ! awk '$0 == "--max-time" { getline; found = ($0 == "5") } END { exit !found }' \
      "$fixture/args" ||
    ! grep -Fxq "header = \"Authorization: Basic ${expected_header}\"" \
      "$fixture/stdin" ||
    grep -Fq "$api_key" "$fixture/args" ||
    ! grep -Fxq '<unset>' "$fixture/env"; then
    rm -rf "$fixture"
    return 1
  fi

  MOCK_CURL_ARGS="$fixture/failure-args" \
    MOCK_CURL_ENV="$fixture/failure-env" \
    MOCK_CURL_STDIN="$fixture/failure-stdin" \
    MOCK_CURL_FAIL=1 \
    COORDINATOR_CURL="$fixture/mock-curl" \
    MICROMDM_API_KEY="$api_key" \
    EIGENINFERENCE_MDM_URL=https://localhost:9002 \
    "$ROOT/coordinator/deploy/micromdm-api-check.sh" >/dev/null 2>&1
  local status=$?
  rm -rf "$fixture"
  [[ "$status" -ne 0 ]]
}

test_runtime_image_explicitly_contains_curl() {
  grep -Fq 'apk add --no-cache ca-certificates curl' \
    "$ROOT/coordinator/Dockerfile.base" &&
    grep -Fq 'RUN apk add --no-cache curl' "$ROOT/coordinator/Dockerfile" &&
    grep -Fq 'base64 curl install jq' \
      "$ROOT/coordinator/deploy/image-check.sh"
}

test_previous_known_good_restore_is_exact() {
  local fixture snapshot snapshot_name
  fixture=$(mktemp -d)
  mkdir -p "$fixture/secrets" "$fixture/previous-known-good"
  printf 'EIGENINFERENCE_ADMIN_KEY=new\n' >"$fixture/env"
  printf 'new-key\n' >"$fixture/secrets/privy-verification-key"
  snapshot_name=20260712T070000Z-123
  snapshot=$fixture/previous-known-good/$snapshot_name
  mkdir -p "$snapshot/secrets"
  printf 'EIGENINFERENCE_ADMIN_KEY=old\n' >"$snapshot/env"
  printf 'old-key\n' >"$snapshot/secrets/privy-verification-key"
  chmod 0500 "$snapshot" "$snapshot/secrets"
  chmod 0400 "$snapshot/env" "$snapshot/secrets/privy-verification-key"
  printf '%s\n' "$snapshot" >"$fixture/previous-known-good.path"

  restore_previous_known_good_env "$fixture/env" "$fixture/secrets" \
    "$fixture/previous-known-good.path" >/dev/null 2>&1
  local status=$?
  [[ "$status" -eq 0 ]] &&
    grep -qx 'EIGENINFERENCE_ADMIN_KEY=old' "$fixture/env" &&
    grep -qx 'old-key' "$fixture/secrets/privy-verification-key"
  status=$?
  chmod -R u+w "$fixture"
  rm -rf "$fixture"
  return "$status"
}

test_upload_failure_restores_env_before_go_fallback() {
  command -v openssl >/dev/null 2>&1 || return 1
  local fixture snapshot old_cert_hash trace=
  fixture=$(mktemp -d)
  mkdir -p "$fixture/secrets" "$fixture/previous-known-good" "$fixture/mdm"
  printf 'EIGENINFERENCE_ADMIN_KEY=new\nMDM_PUSH_P12_VERSION=new\n' >"$fixture/env"
  printf 'new-key\n' >"$fixture/secrets/privy-verification-key"
  snapshot=$fixture/previous-known-good/20260712T071500Z-456
  mkdir -p "$snapshot/secrets"
  printf 'EIGENINFERENCE_ADMIN_KEY=old\nMDM_PUSH_P12_VERSION=old\n' >"$snapshot/env"
  printf 'old-key\n' >"$snapshot/secrets/privy-verification-key"
  printf '%s\n' "$snapshot" >"$fixture/previous-known-good.path"

  openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$fixture/mdm/push.key" -out "$fixture/mdm/push.crt" \
    -days 1 -subj '/CN=old-mdm' \
    -addext 'basicConstraints=critical,CA:FALSE' \
    -addext 'keyUsage=critical,digitalSignature' \
    -addext 'extendedKeyUsage=clientAuth' >/dev/null 2>&1 || {
    rm -rf "$fixture"
    return 1
  }
  old_cert_hash=$(sha256sum "$fixture/mdm/push.crt" | awk '{print $1}')
  printf 'hash=%064d\nversion=old\n' 0 >"$fixture/mdm/.push_imported"

  validate_candidate_config() { trace+=config,; }
  migrate_candidate() { trace+=migrate,; }
  drain_current_owner() { trace+=drain-old,; }
  wait_current_quiescence() { trace+=old-quiescent,; }
  stop_current_owner() { trace+=stop-old,; }
  check_candidate_invariants() { trace+=invariants,; }
  start_candidate() { trace+=start-candidate,; }
  validate_running_candidate() {
    trace+=rotation-verification-failed,
    return 1
  }
  handoff_failed_candidate() { trace+=handoff-candidate,; }
  wait_failed_candidate_quiescence() { trace+=candidate-quiescent,; }
  stop_failed_candidate() { trace+=stop-candidate,; }
  restore_go_fallback_environment() {
    trace+=restore-old-env,
    restore_previous_known_good_env "$fixture/env" "$fixture/secrets" \
      "$fixture/previous-known-good.path" >/dev/null
  }
  check_rollback_safe() {
    trace+=rollback-safe,
    grep -qx 'EIGENINFERENCE_ADMIN_KEY=old' "$fixture/env"
  }
  start_go_fallback() {
    trace+=start-go,
    grep -qx 'MDM_PUSH_P12_VERSION=old' "$fixture/env" &&
      [[ "$(sha256sum "$fixture/mdm/push.crt" | awk '{print $1}')" == \
        "$old_cert_hash" ]]
  }
  validate_go_fallback() { trace+=validate-go,; }
  fence_failed_candidate_ownership() { trace+=fence,; }

  remote_deployment_transaction >/dev/null 2>&1
  local status=$?
  [[ "$status" -ne 0 &&
    "$trace" == *"migrate,drain-old,old-quiescent,stop-old,invariants,start-candidate,rotation-verification-failed,handoff-candidate,candidate-quiescent,stop-candidate,restore-old-env,rollback-safe,start-go,validate-go,"* ]]
  status=$?
  chmod -R u+w "$fixture"
  rm -rf "$fixture"
  return "$status"
}

test_mdm_cert_rotation_is_atomic_and_retries() {
  command -v openssl >/dev/null 2>&1 || return 1
  local fixture
  fixture=$(mktemp -d)
  mkdir -p "$fixture/bin" "$fixture/mdm"
  cat >"$fixture/bin/mdmctl" <<'SH'
#!/bin/sh
count=0
[ ! -f "$MDMCTL_COUNT_FILE" ] || count=$(cat "$MDMCTL_COUNT_FILE")
count=$((count + 1))
printf '%s\n' "$count" >"$MDMCTL_COUNT_FILE"
[ ! -f "$MDMCTL_FAIL_FILE" ]
SH
  chmod 700 "$fixture/bin/mdmctl"

  make_bundle() {
    local name=$1
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$fixture/$name.key" -out "$fixture/$name.crt" \
      -days 1 -subj "/CN=$name" \
      -addext 'basicConstraints=critical,CA:FALSE' \
      -addext 'keyUsage=critical,digitalSignature' \
      -addext 'extendedKeyUsage=clientAuth' >/dev/null 2>&1 &&
      openssl pkcs12 -export -out "$fixture/$name.p12" \
        -inkey "$fixture/$name.key" -in "$fixture/$name.crt" \
        -passout pass:eigeninference >/dev/null 2>&1 &&
      base64 <"$fixture/$name.p12" | tr '+/' '-_' | tr -d '\n='
  }

  local first second
  first=$(make_bundle first) || {
    rm -rf "$fixture"
    return 1
  }
  second=$(make_bundle second) || {
    rm -rf "$fixture"
    return 1
  }
  export MDMCTL_COUNT_FILE="$fixture/count"
  export MDMCTL_FAIL_FILE="$fixture/fail"
  if ! PATH="$fixture/bin:$PATH" \
    MDM_CERT_DIRECTORY="$fixture/mdm" \
    MDM_PUSH_P12_B64="$first" \
    MDM_PUSH_P12_VERSION=version-1 \
    MDM_CERT_UPLOAD_RETRY_SECONDS=0 \
    COORDINATOR_P12_CHECK="$ROOT/coordinator/deploy/p12-check.sh" \
    sh "$ROOT/coordinator/deploy/mdm-cert-rotate.sh"; then
    rm -rf "$fixture"
    return 1
  fi
  local old_cert old_key old_state old_count
  old_cert=$(sha256sum "$fixture/mdm/push.crt" | awk '{print $1}')
  old_key=$(sha256sum "$fixture/mdm/push.key" | awk '{print $1}')
  old_state=$(sha256sum "$fixture/mdm/.push_imported" | awk '{print $1}')
  old_count=$(cat "$fixture/count")

  touch "$fixture/fail"
  PATH="$fixture/bin:$PATH" \
    MDM_CERT_DIRECTORY="$fixture/mdm" \
    MDM_PUSH_P12_B64="$second" \
    MDM_PUSH_P12_VERSION=version-2 \
    MDM_CERT_UPLOAD_ATTEMPTS=3 \
    MDM_CERT_UPLOAD_RETRY_SECONDS=0 \
    COORDINATOR_P12_CHECK="$ROOT/coordinator/deploy/p12-check.sh" \
    sh "$ROOT/coordinator/deploy/mdm-cert-rotate.sh" >/dev/null 2>&1
  local failed_status=$?
  if [[ "$failed_status" -eq 0 ||
    "$(sha256sum "$fixture/mdm/push.crt" | awk '{print $1}')" != "$old_cert" ||
    "$(sha256sum "$fixture/mdm/push.key" | awk '{print $1}')" != "$old_key" ||
    "$(sha256sum "$fixture/mdm/.push_imported" | awk '{print $1}')" != "$old_state" ||
    "$(cat "$fixture/count")" -ne $((old_count + 3)) ]]; then
    rm -rf "$fixture"
    return 1
  fi

  rm -f "$fixture/fail"
  if ! PATH="$fixture/bin:$PATH" \
    MDM_CERT_DIRECTORY="$fixture/mdm" \
    MDM_PUSH_P12_B64="$second" \
    MDM_PUSH_P12_VERSION=version-2 \
    MDM_CERT_UPLOAD_RETRY_SECONDS=0 \
    COORDINATOR_P12_CHECK="$ROOT/coordinator/deploy/p12-check.sh" \
    sh "$ROOT/coordinator/deploy/mdm-cert-rotate.sh"; then
    rm -rf "$fixture"
    return 1
  fi
  local rotated_count
  rotated_count=$(cat "$fixture/count")
  if [[ "$(sha256sum "$fixture/mdm/push.crt" | awk '{print $1}')" == "$old_cert" ]] ||
    ! grep -qx 'version=version-2' "$fixture/mdm/.push_imported"; then
    rm -rf "$fixture"
    return 1
  fi

  PATH="$fixture/bin:$PATH" \
    MDM_CERT_DIRECTORY="$fixture/mdm" \
    MDM_PUSH_P12_B64="$second" \
    MDM_PUSH_P12_VERSION=version-2 \
    MDM_CERT_UPLOAD_RETRY_SECONDS=0 \
    COORDINATOR_P12_CHECK="$ROOT/coordinator/deploy/p12-check.sh" \
    sh "$ROOT/coordinator/deploy/mdm-cert-rotate.sh" &&
    [[ "$(cat "$fixture/count")" -eq "$rotated_count" ]]
  local status=$?
  rm -rf "$fixture"
  unset MDMCTL_COUNT_FILE MDMCTL_FAIL_FILE
  return "$status"
}

test_state_mount_required() {
  docker_cmd() {
    printf '/mnt/disks/userdata|true\n'
  }
  verify_state_mount fixture &&
    {
      docker_cmd() {
        printf '/tmp/ephemeral|true\n'
      }
      ! verify_state_mount fixture >/dev/null 2>&1
    }
}

test_environment_matrix_has_dual_stack_safety_flags() {
  local file
  for file in \
    "$ROOT/deploy/environments/dev.env" \
    "$ROOT/deploy/environments/prod.env"; do
    grep -qx 'DINF_COORDINATOR_BINARY=go' "$file" &&
      grep -qx 'GO_FALLBACK_REQUIRED=true' "$file" &&
      grep -qx 'EIGENINFERENCE_COORDINATOR_OWNERSHIP_ENABLED=true' "$file" &&
      grep -qx 'EIGENINFERENCE_RUST_FULL_SURFACE_ENABLED=true' "$file" ||
      return 1
  done
}

test_only_digest_refs_are_reboot_pins() {
  validate_pinned_image_ref \
    'us-central1-docker.pkg.dev/project/repo/coordinator@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' &&
    ! validate_pinned_image_ref \
      'us-central1-docker.pkg.dev/project/repo/coordinator:latest'
}

test_caddy_overwrites_untrusted_identity_headers() {
  local file
  for file in \
    "$ROOT/coordinator/Caddyfile" \
    "$ROOT/deploy/gcp/configure-caddy.sh"; do
    grep -Fq 'header_up X-Forwarded-For {remote_host}' "$file" &&
      grep -Fq 'header_up -Forwarded' "$file" &&
      grep -Fq 'header_up -X-Real-IP' "$file" &&
      grep -Fq 'header_up -CF-Connecting-IP' "$file" &&
      grep -Fq 'header_up -True-Client-IP' "$file" ||
      return 1
  done
}

run_test "selector rejects command injection" test_selector_injection
run_test "Cloud Build selector remains inert data" test_cloudbuild_selector_reaches_validator_as_data
run_test "migration failure leaves metadata untouched" test_migration_failure_does_not_commit_metadata
run_test "wrong image is rejected before migration" test_wrong_image_never_runs_migration
run_test "quiescence timeout is bounded" test_quiescence_timeout
run_test "quiescence requires stable consecutive samples" test_quiescence_requires_two_stable_samples
run_test "Go quiescence requires every owner counter" test_detailed_quiescence_rejects_omitted_go_counters
run_test "Rust quiescence requires the computed summary" test_detailed_quiescence_requires_rust_summary
run_test "candidate failure restores pinned Go" test_candidate_failure_rolls_back_to_go
run_test "unsafe Go rollback is refused" test_rollback_unsafe_refuses_fallback
run_test "stop failure leaves old owner handoff-fenced" test_stop_failure_leaves_old_handoff_fenced
run_test "failed candidate must quiesce before rollback" test_failed_candidate_quiescence_refuses_automatic_fallback
run_test "one serving container invariant" test_one_container_invariant
run_test "multiple recovery containers are rejected" test_multiple_recovery_containers_are_rejected
run_test "recovery cannot overlap serving owner" test_recovery_cannot_overlap_serving
run_test "systemd never auto-stops a competing owner" test_systemd_never_auto_stops_competing_owner
run_test "bootstrap attaches the pre-created disk" test_bootstrap_attaches_precreated_disk
run_test "GCP Secret and SQL operations are project-scoped" test_gcp_secret_and_sql_operations_are_project_scoped
run_test "P12 preflight rejects malformed bundles before migration" test_p12_preflight_rejects_malformed_and_wrong_password_before_migration
run_test "MicroMDM curl preflight hides keys and fails closed" test_micromdm_curl_preflight_hides_key_and_fails_closed
run_test "runtime image explicitly contains curl" test_runtime_image_explicitly_contains_curl
run_test "previous-known-good env restore is exact" test_previous_known_good_restore_is_exact
run_test "upload failure restores old env before Go fallback" test_upload_failure_restores_env_before_go_fallback
run_test "MDM certificate rotation is atomic and retryable" test_mdm_cert_rotation_is_atomic_and_retries
run_test "persistent state mount is mandatory" test_state_mount_required
run_test "environment matrix defaults safely to Go" test_environment_matrix_has_dual_stack_safety_flags
run_test "reboot image pins require immutable digests" test_only_digest_refs_are_reboot_pins
run_test "Caddy overwrites untrusted identity headers" test_caddy_overwrites_untrusted_identity_headers

printf '%d passed, %d failed\n' "$passed" "$failed"
(( failed == 0 ))
