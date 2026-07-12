#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly ROOT
readonly DEFAULT_POSTGRES_IMAGE="postgres:16@sha256:be01cf82fc7dbba824acf0a82e150b4b360f3ff93c6631d7844af431e841a95c"
readonly ADMIN_KEY="rollback-rehearsal-admin"
readonly READ_ONLY_KEY="rollback-rehearsal-read-only"

fail() {
  echo "rollback-rehearsal: $*" >&2
  exit 2
}

reject_runtime_credentials() {
  [[ -z "${DATABASE_URL:-}" ]] || fail "DATABASE_URL is forbidden"
  [[ -z "${EIGENINFERENCE_DATABASE_URL:-}" ]] ||
    fail "EIGENINFERENCE_DATABASE_URL is forbidden"
  [[ -z "${PGSERVICE:-}" ]] || fail "PGSERVICE is forbidden"
}

immutable_local_image() {
  [[ "$1" =~ ^sha256:[a-f0-9]{64}$ ||
    "$1" =~ ^[a-zA-Z0-9._/:@-]+@sha256:[a-f0-9]{64}$ ]]
}

image_revision() {
  docker image inspect \
    --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' \
    "$1"
}

wait_health() {
  local port=$1
  local expected_binary=$2
  local expected_commit=$3
  local expected_environment_id=$4
  local expected_image_digest=$5
  local attempt
  for attempt in $(seq 1 90); do
    if curl --silent --show-error --fail \
      "http://127.0.0.1:${port}/health" |
      jq -e \
        --arg binary "$expected_binary" \
        --arg commit "$expected_commit" \
        --arg environment_id "$expected_environment_id" \
        --arg image_digest "$expected_image_digest" '
        (.status == "ok" or .status == "healthy") and
        .environment_id == $environment_id and
        .image_digest == $image_digest and
        (if $binary == "go" then
           ((.binary == null or .binary == "go") and .build_commit == $commit)
         else
           (.binary == $binary and
            (.build_commit == $commit or .build.commit == $commit))
         end)
      ' >/dev/null 2>&1; then
      return 0
    fi
    [[ "$attempt" -lt 90 ]] || return 1
    sleep 1
  done
}

container_port() {
  local container=$1
  local value
  value=$(docker port "$container" 8080/tcp)
  value=${value##*:}
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$value"
}

assert_single_owner() {
  local suffix=$1
  local count
  count=$(docker ps \
    --filter "label=com.darkbloom.rehearsal=${suffix}" \
    --filter "label=com.darkbloom.role=serving" \
    --format '{{.ID}}' | awk 'NF { count++ } END { print count + 0 }')
  [[ "$count" -le 1 ]] || fail "rehearsal started multiple database owners"
}

run_coordinator() {
  local name=$1
  local image=$2
  local binary=$3
  local database_url=$4
  local network=$5
  local suffix=$6
  local environment_id=$7
  local entrypoint
  case "$binary" in
    go) entrypoint=/usr/local/bin/coordinator-go ;;
    rust) entrypoint=/usr/local/bin/coordinator-rs ;;
    *) fail "unsupported coordinator binary $binary" ;;
  esac
  docker run --detach --pull never \
    --name "$name" \
    --network "$network" \
    --publish 127.0.0.1::8080 \
    --label "com.darkbloom.rehearsal=${suffix}" \
    --label com.darkbloom.role=serving \
    --label "com.darkbloom.image-digest=${image}" \
    --env "APP_PORT=8080" \
    --env "EIGENINFERENCE_COORDINATOR_BINARY=${binary}" \
    --env "EIGENINFERENCE_DATABASE_URL=${database_url}" \
    --env "EIGENINFERENCE_ENVIRONMENT_ID=${environment_id}" \
    --env "EIGENINFERENCE_IMAGE_DIGEST=${image}" \
    --env EIGENINFERENCE_LISTENER_IDENTITY=rollback-rehearsal-loopback \
    --env EIGENINFERENCE_COORDINATOR_OWNERSHIP_ID=rollback-rehearsal-owner \
    --env EIGENINFERENCE_COORDINATOR_OWNERSHIP_ENABLED=true \
    --env EIGENINFERENCE_RUST_FULL_SURFACE_ENABLED=true \
    --env EIGENINFERENCE_PRIVY_APP_ID=rollback-rehearsal \
    --env "EIGENINFERENCE_ADMIN_KEY=${ADMIN_KEY}" \
    --env "EIGENINFERENCE_READ_ONLY_KEY=${READ_ONLY_KEY}" \
    --env EIGENINFERENCE_RELEASE_KEY=rollback-rehearsal-release \
    --env EIGENINFERENCE_MDM_WEBHOOK_SECRET=rollback-rehearsal-mdm \
    --env EIGENINFERENCE_ALLOW_MEMORY_STORE=false \
    --env EIGENINFERENCE_BILLING_MOCK=true \
    --entrypoint "$entrypoint" \
    "$image" serve >/dev/null
  [[ "$(docker inspect --format '{{.Config.Image}}' "$name")" == "$image" ]] ||
    fail "$name did not start from its configured immutable image"
  [[ "$(docker inspect --format \
    '{{index .Config.Labels "com.darkbloom.image-digest"}}' "$name")" == "$image" ]] ||
    fail "$name does not expose its inspected immutable image metadata"
  assert_single_owner "$suffix"
}

handoff_and_stop() {
  local container=$1
  local port=$2
  local read_key=$3
  curl --silent --show-error --fail \
    --header "Authorization: Bearer ${ADMIN_KEY}" \
    --header "Content-Type: application/json" \
    --data '{"mode":"handoff"}' \
    "http://127.0.0.1:${port}/v1/admin/drain" |
    jq -e '.draining == true and .mode == "handoff"' >/dev/null
  wait_quiescence "$port" "$read_key" ||
    fail "$container did not become quiescent"
  docker stop --time 30 "$container" >/dev/null
}

wait_quiescence() {
  local port=$1
  local read_key=$2
  local attempt
  for attempt in $(seq 1 90); do
    if curl --silent --show-error --fail \
      --header "Authorization: Bearer ${read_key}" \
      "http://127.0.0.1:${port}/v1/admin/quiescence" |
      jq -e '.quiescent == true and .ownership_healthy == true' >/dev/null 2>&1; then
      return 0
    fi
    [[ "$attempt" -lt 90 ]] || return 1
    sleep 1
  done
}

run_rehearsal() {
  local candidate_image=$1
  local fallback_image=$2
  local postgres_image=$3
  local environment_id=$4
  local suffix="$$-${RANDOM}"
  local network="darkbloom-rollback-${suffix}"
  local database="darkbloom-rollback-db-${suffix}"
  local fallback="darkbloom-rollback-go-${suffix}"
  local candidate="darkbloom-rollback-rust-${suffix}"
  local database_url
  local host_port

  reject_runtime_credentials
  command -v docker >/dev/null || fail "docker is required"
  command -v cargo >/dev/null || fail "cargo is required"
  command -v curl >/dev/null || fail "curl is required"
  command -v git >/dev/null || fail "git is required"
  command -v jq >/dev/null || fail "jq is required"
  immutable_local_image "$candidate_image" ||
    fail "candidate image must be an immutable digest"
  immutable_local_image "$fallback_image" ||
    fail "fallback image must be an immutable digest"
  [[ "$candidate_image" != "$fallback_image" ]] ||
    fail "candidate and fallback image digests must be distinct"
  docker image inspect "$candidate_image" >/dev/null 2>&1 ||
    fail "candidate image must already exist locally"
  docker image inspect "$fallback_image" >/dev/null 2>&1 ||
    fail "fallback image must already exist locally"
  docker image inspect "$postgres_image" >/dev/null 2>&1 ||
    fail "PostgreSQL image must already exist locally"
  local candidate_revision fallback_revision source_revision
  candidate_revision=$(image_revision "$candidate_image")
  fallback_revision=$(image_revision "$fallback_image")
  source_revision=$(git -C "$ROOT" rev-parse HEAD)
  [[ "$candidate_revision" =~ ^[a-f0-9]{40}$ &&
    "$candidate_revision" == "$source_revision" ]] ||
    fail "candidate image revision must match the tested repository commit"
  [[ "$fallback_revision" =~ ^[a-f0-9]{40}$ ]] ||
    fail "fallback image must bind a full source revision"

  cleanup() {
    docker rm -f "$candidate" "$fallback" "$database" >/dev/null 2>&1 || true
    docker network rm "$network" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT INT TERM

  docker network create \
    --label "com.darkbloom.rehearsal=${suffix}" \
    "$network" >/dev/null
  docker run --detach --pull never \
    --name "$database" \
    --network "$network" \
    --label "com.darkbloom.rehearsal=${suffix}" \
    --publish 127.0.0.1::5432 \
    --env POSTGRES_USER=cutover \
    --env POSTGRES_PASSWORD=cutover \
    --env POSTGRES_DB=cutover \
    "$postgres_image" >/dev/null

  local attempt
  for attempt in $(seq 1 60); do
    if docker exec "$database" pg_isready -U cutover -d cutover >/dev/null 2>&1; then
      break
    fi
    [[ "$attempt" -lt 60 ]] || fail "local PostgreSQL did not become ready"
    sleep 1
  done

  database_url="postgresql://cutover:cutover@${database}:5432/cutover?sslmode=disable"
  docker run --rm --pull never \
    --network "$network" \
    --entrypoint /usr/local/bin/coordinator-migrate \
    "$fallback_image" -database-url "$database_url"

  run_coordinator "$fallback" "$fallback_image" go "$database_url" "$network" "$suffix" "$environment_id"
  local fallback_port
  fallback_port=$(container_port "$fallback")
  wait_health "$fallback_port" go "$fallback_revision" "$environment_id" \
    "$fallback_image" ||
    fail "initial Go fallback did not serve its pinned revision"
  handoff_and_stop "$fallback" "$fallback_port" "$READ_ONLY_KEY"
  assert_single_owner "$suffix"

  docker run --rm --pull never \
    --network "$network" \
    --entrypoint /usr/local/bin/coordinator-migrate \
    "$candidate_image" -database-url "$database_url"
  docker run --rm --pull never \
    --network "$network" \
    --env "EIGENINFERENCE_DATABASE_URL=$database_url" \
    --env EIGENINFERENCE_COORDINATOR_OWNERSHIP_ENABLED=true \
    --entrypoint /usr/local/bin/coordinator-go \
    "$fallback_image" rollback-check |
    jq -e '.rollback_safe == true' >/dev/null

  run_coordinator "$candidate" "$candidate_image" rust "$database_url" "$network" "$suffix" "$environment_id"
  local candidate_port
  candidate_port=$(container_port "$candidate")
  wait_health "$candidate_port" rust "$candidate_revision" "$environment_id" \
    "$candidate_image" ||
    fail "Rust candidate did not serve its pinned revision"
  wait_quiescence "$candidate_port" "$READ_ONLY_KEY" ||
    fail "Rust candidate read-only quiescence did not converge"
  docker kill --signal KILL "$candidate" >/dev/null
  docker wait "$candidate" >/dev/null
  assert_single_owner "$suffix"

  host_port="$(docker port "$database" 5432/tcp)"
  host_port="${host_port##*:}"
  [[ "$host_port" =~ ^[0-9]+$ ]] || fail "cannot resolve local PostgreSQL port"
  (
    cd "$ROOT/coordinator-rs"
    DARKBLOOM_TEST_DATABASE_URL="postgresql://cutover:cutover@127.0.0.1:${host_port}/cutover?sslmode=disable" \
      cargo test --locked -p darkbloom-coordinator-server \
      replacement_replay_ack_historical_terminal_and_v2_to_v1_are_fenced \
      -- --test-threads=1
    DARKBLOOM_TEST_DATABASE_URL="postgresql://cutover:cutover@127.0.0.1:${host_port}/cutover?sslmode=disable" \
      cargo test --locked -p darkbloom-coordinator-server \
      full_surface_db_key_request_commits_once_before_terminal_ack_and_replay \
      -- --test-threads=1
  )

  docker run --rm --pull never \
    --network "$network" \
    --env "EIGENINFERENCE_DATABASE_URL=$database_url" \
    --env EIGENINFERENCE_COORDINATOR_OWNERSHIP_ENABLED=true \
    --entrypoint /usr/local/bin/coordinator-go \
    "$fallback_image" rollback-check |
    jq -e '.rollback_safe == true' >/dev/null
  docker rm "$fallback" "$candidate" >/dev/null
  run_coordinator "$fallback" "$fallback_image" go "$database_url" "$network" "$suffix" "$environment_id"
  fallback_port=$(container_port "$fallback")
  wait_health "$fallback_port" go "$fallback_revision" "$environment_id" \
    "$fallback_image" ||
    fail "Go fallback did not serve its pinned revision after rollback"
  assert_single_owner "$suffix"
}

main() {
  reject_runtime_credentials
  if [[ "${1:-}" == "__execute" ]]; then
    [[ "$#" -eq 5 ]] || fail "invalid internal invocation"
    run_rehearsal "$2" "$3" "$4" "$5"
    return
  fi

  local candidate_image=""
  local fallback_image=""
  local postgres_image="$DEFAULT_POSTGRES_IMAGE"
  local output=""
  local signing_key=""
  local environment_manifest=""
  local trusted_environment_key=""
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --candidate-image)
        [[ "$#" -ge 2 ]] || fail "--candidate-image requires a value"
        candidate_image="$2"
        shift 2
        ;;
      --fallback-image)
        [[ "$#" -ge 2 ]] || fail "--fallback-image requires a value"
        fallback_image="$2"
        shift 2
        ;;
      --postgres-image)
        [[ "$#" -ge 2 ]] || fail "--postgres-image requires a value"
        postgres_image="$2"
        shift 2
        ;;
      --output)
        [[ "$#" -ge 2 ]] || fail "--output requires a value"
        output="$2"
        shift 2
        ;;
      --signing-key)
        [[ "$#" -ge 2 ]] || fail "--signing-key requires a value"
        signing_key="$2"
        shift 2
        ;;
      --environment-manifest)
        [[ "$#" -ge 2 ]] || fail "--environment-manifest requires a value"
        environment_manifest="$2"
        shift 2
        ;;
      --trusted-environment-key)
        [[ "$#" -ge 2 ]] || fail "--trusted-environment-key requires a value"
        trusted_environment_key="$2"
        shift 2
        ;;
      *)
        fail "unknown argument $1"
        ;;
    esac
  done
  [[ -n "$candidate_image" ]] || fail "--candidate-image is required"
  [[ -n "$fallback_image" ]] || fail "--fallback-image is required"
  [[ -n "$output" ]] || fail "--output is required"
  [[ -n "$environment_manifest" ]] || fail "--environment-manifest is required"
  [[ -n "$trusted_environment_key" ]] ||
    fail "--trusted-environment-key is required"
  local environment_json environment_id authorized_candidate authorized_fallback
  environment_json=$(python3 "$ROOT/scripts/cutover-readiness.py" \
    verify-environment-manifest \
    --manifest "$environment_manifest" \
    --trusted-key "$trusted_environment_key")
  environment_id=$(jq -er '.environment_id' <<<"$environment_json")
  authorized_candidate=$(jq -er \
    '.payload.environment_binding.descriptor.candidate_image' \
    "$environment_manifest")
  authorized_fallback=$(jq -er \
    '.payload.environment_binding.descriptor.fallback_image' \
    "$environment_manifest")
  [[ "$candidate_image" == "$authorized_candidate" ]] ||
    fail "candidate image is not authorized by the environment manifest"
  [[ "$fallback_image" == "$authorized_fallback" ]] ||
    fail "fallback image is not authorized by the environment manifest"

  local -a report_arguments=(
    run-check
    --name rollback-rehearsal
    --timeout-seconds 7200
    --output "$output"
    --environment-manifest "$environment_manifest"
    --trusted-environment-key "$trusted_environment_key"
  )
  if [[ -n "$signing_key" ]]; then
    report_arguments+=(--signing-key "$signing_key")
  fi
  python3 "$ROOT/scripts/cutover-readiness.py" "${report_arguments[@]}" \
    -- \
    "$ROOT/scripts/rehearse-coordinator-rollback.sh" __execute \
    "$candidate_image" "$fallback_image" "$postgres_image" "$environment_id"
}

main "$@"
