#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck disable=SC1091 # ROOT is resolved from this script's absolute path.
source "$ROOT/deploy/gcp/deploy-common.sh"

if [[ -n "${CI:-}" || -n "${BUILD_ID:-}" || -n "${CLOUD_BUILD_BUILD_ID:-}" ||
  -n "${CURSOR_CLOUD_AGENT:-}" || -n "${CURSOR_AGENT_ID:-}" ]]; then
  fail "production deploys are human-only and are refused in agent/CI environments"
  exit 1
fi
[[ -t 0 && -t 1 ]] || {
  fail "production deploy requires an interactive terminal"
  exit 1
}
[[ "${DINF_HUMAN_PROD_DEPLOY:-}" == "I_AM_A_HUMAN" ]] || {
  fail "set DINF_HUMAN_PROD_DEPLOY=I_AM_A_HUMAN after reading the prod runbook"
  exit 1
}

readonly USAGE="usage: deploy-prod.sh CANDIDATE_IMAGE_DIGEST COORDINATOR_BINARY EXPECTED_COMMIT GO_FALLBACK_IMAGE_DIGEST FULL_CUTOVER_AUTHORIZATION"
CANDIDATE_IMAGE=${1:?$USAGE}
SELECTOR=${2:?$USAGE}
EXPECTED_COMMIT=${3:?$USAGE}
REQUESTED_GO_FALLBACK_IMAGE=${4:?$USAGE}
AUTHORIZATION_ARTIFACT=${5:?$USAGE}
[[ "$#" -eq 5 ]] || fail "$USAGE"
validate_pinned_image_ref "$CANDIDATE_IMAGE" ||
  fail "candidate must be an immutable repository image digest"
validate_selector "$SELECTOR" || fail "coordinator binary must be exactly go or rust"
[[ "$EXPECTED_COMMIT" =~ ^[a-f0-9]{40}$ ]] ||
  fail "expected commit must be a full lowercase 40-character SHA"
validate_pinned_image_ref "$REQUESTED_GO_FALLBACK_IMAGE" ||
  fail "Go fallback must be an immutable repository image digest"
CUTOVER_ENVIRONMENT_ID=$(printf '%064d' 0)

readonly PROJECT=darkbloom-mainnet
readonly ZONE=us-east4-a
readonly INSTANCE=darkbloom-coordinator
readonly IMAGE_REPO=us-east4-docker.pkg.dev/darkbloom-mainnet/coordinator/coordinator
readonly REMOTE_DIR=/opt/d-inference/deploy
readonly CUTOVER_GATE_PUBLIC_KEY=/etc/darkbloom/cutover/gate-public.pem
readonly CUTOVER_APPROVER_PUBLIC_KEY=/etc/darkbloom/cutover/approver-public.pem

[[ "$CANDIDATE_IMAGE" == "$IMAGE_REPO@sha256:"* ]] ||
  fail "candidate image must use the production coordinator repository"
[[ "$REQUESTED_GO_FALLBACK_IMAGE" == "$IMAGE_REPO@sha256:"* ]] ||
  fail "Go fallback image must use the production coordinator repository"

validate_trust_key() {
  local path=$1
  [[ -f "$path" && ! -L "$path" ]] || return 1
  [[ "$(stat -c '%u' "$path")" == "0" ]] || return 1
  local mode
  mode=$(stat -c '%a' "$path")
  (( (8#$mode & 8#022) == 0 ))
}

verify_full_cutover_authorization() {
  python3 "$ROOT/scripts/cutover-readiness.py" verify-deploy-authorization \
    --authorization "$AUTHORIZATION_ARTIFACT" \
    --policy "$ROOT/deploy/cutover/gates.json" \
    --trusted-gate-key "$CUTOVER_GATE_PUBLIC_KEY" \
    --trusted-approver-key "$CUTOVER_APPROVER_PUBLIC_KEY" \
    --commit "$EXPECTED_COMMIT" \
    --candidate-image "$CANDIDATE_IMAGE" \
    --fallback-image "$REQUESTED_GO_FALLBACK_IMAGE" >/dev/null
}

if [[ "$SELECTOR" == "rust" ]]; then
  [[ "$CANDIDATE_IMAGE" != "$REQUESTED_GO_FALLBACK_IMAGE" ]] ||
    fail "Rust candidate and Go fallback image digests must be distinct"
  [[ -f "$AUTHORIZATION_ARTIFACT" ]] ||
    fail "Rust deployment requires a full-cutover authorization artifact"
  if ! validate_trust_key "$CUTOVER_GATE_PUBLIC_KEY" ||
    ! validate_trust_key "$CUTOVER_APPROVER_PUBLIC_KEY"; then
    fail "configured cutover verification keys must be root-owned and non-writable"
  fi
  verify_full_cutover_authorization ||
    fail "full-cutover authorization verification failed"
  CUTOVER_ENVIRONMENT_ID=$(jq -er '.payload.environment_id' "$AUTHORIZATION_ARTIFACT")
  [[ "$CUTOVER_ENVIRONMENT_ID" =~ ^[a-f0-9]{64}$ ]] ||
    fail "full-cutover authorization has no valid environment_id"
elif [[ "$AUTHORIZATION_ARTIFACT" != "-" ]]; then
  fail "Go deployment must use '-' instead of a Rust full-cutover authorization"
fi

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' | sed -n '1p')
[[ -n "$ACTIVE_ACCOUNT" ]] || fail "no active gcloud account"
gcloud artifacts docker images describe "$CANDIDATE_IMAGE" \
  --project="$PROJECT" >/dev/null

gcloud_ssh() {
  gcloud compute ssh "$INSTANCE" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --tunnel-through-iap \
    --command="$1"
}

metadata_value() {
  local key=$1
  gcloud compute instances describe "$INSTANCE" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --flatten=metadata.items \
    --filter="metadata.items.key=${key}" \
    --format='value(metadata.items.value)'
}

if [[ "$SELECTOR" == "go" ]]; then
  EXISTING_ENVIRONMENT_ID=$(metadata_value DINF_CUTOVER_ENVIRONMENT_ID)
  [[ "$EXISTING_ENVIRONMENT_ID" =~ ^[a-f0-9]{64}$ ]] ||
    fail "Go deployment requires existing cutover environment metadata"
  CUTOVER_ENVIRONMENT_ID=$EXISTING_ENVIRONMENT_ID
fi

GO_FALLBACK_IMAGE=$(metadata_value DINF_GO_FALLBACK_IMAGE)
if [[ -z "$GO_FALLBACK_IMAGE" ]]; then
  [[ "$SELECTOR" == "go" ]] ||
    fail "Rust cutover requires a previously pinned DINF_GO_FALLBACK_IMAGE"
  GO_FALLBACK_IMAGE=$REQUESTED_GO_FALLBACK_IMAGE
fi
validate_image_ref "$GO_FALLBACK_IMAGE" || fail "invalid pinned Go fallback metadata"
[[ "$GO_FALLBACK_IMAGE" == "$REQUESTED_GO_FALLBACK_IMAGE" ]] ||
  fail "authorized Go fallback differs from the metadata-pinned fallback"
remote_command=$(printf "sudo '%s/remote-deploy.sh' '%s' '%s' '%s' '%s' false '%s'" \
  "$REMOTE_DIR" "$CANDIDATE_IMAGE" "$SELECTOR" "$EXPECTED_COMMIT" \
  "$GO_FALLBACK_IMAGE" "$CUTOVER_ENVIRONMENT_ID")
printf -v remote_plan_command '%q ' \
  gcloud compute ssh "$INSTANCE" \
  "--project=$PROJECT" \
  "--zone=$ZONE" \
  --tunnel-through-iap \
  "--command=$remote_command"
remote_plan_command=${remote_plan_command% }

cat <<PLAN
Production deployment plan (no mutating command has been executed):
  account:       $ACTIVE_ACCOUNT
  project/zone:  $PROJECT / $ZONE
  instance:      $INSTANCE
  candidate:     $CANDIDATE_IMAGE
  Go fallback:   $GO_FALLBACK_IMAGE
  binary:        $SELECTOR
  expected SHA:  $EXPECTED_COMMIT
  authorization: $AUTHORIZATION_ARTIFACT

The script will install reviewed runtime files, refresh the root-only env from
Secret Manager, migrate externally, drain to 429, wait for detailed
quiescence, stop the sole owner, validate invariants, start one host-network
candidate, and commit metadata only after all checks pass. Candidate failure
can roll back only to the metadata-pinned Go image after CheckRollbackSafe.

Validated remote transaction command:
  $remote_plan_command

The final command is a gcloud compute instances add-metadata operation using
only the immutable digest, binary selector, and Go fallback digest returned by
that validated transaction. It is printed by this script immediately before
the separate COMMIT-METADATA confirmation.
PLAN

read -r -p "Type the project name ($PROJECT): " confirm_project
[[ "$confirm_project" == "$PROJECT" ]] || fail "project confirmation failed"
read -r -p "Type the candidate image digest: " confirm_image
[[ "$confirm_image" == "$CANDIDATE_IMAGE" ]] || fail "image confirmation failed"
read -r -p "Type the binary selector ($SELECTOR): " confirm_selector
[[ "$confirm_selector" == "$SELECTOR" ]] || fail "selector confirmation failed"
read -r -p "Type DEPLOY to execute the printed production plan: " confirm_deploy
[[ "$confirm_deploy" == "DEPLOY" ]] || fail "deployment cancelled"

tar -C "$ROOT/deploy/gcp" -czf - \
  configure-caddy.sh \
  deploy-common.sh \
  install-runtime.sh \
  offline-recovery.md \
  remote-deploy.sh \
  rollback-after-commit-failure.sh \
  run-coordinator.sh \
  run-recovery.sh \
  systemd |
  gcloud_ssh "sudo install -d -m 0755 '$REMOTE_DIR' && sudo tar -xzf - -C '$REMOTE_DIR' && sudo '$REMOTE_DIR/install-runtime.sh' '$REMOTE_DIR'"

gcloud_ssh "sudo bash -s -- prod '$PROJECT'" <"$ROOT/deploy/gcp/refresh-env.sh"
gcloud_ssh "sudo /usr/local/bin/d-inference-configure-caddy.sh prod"
if [[ "$SELECTOR" == "rust" ]]; then
  verify_full_cutover_authorization ||
    fail "full-cutover authorization expired before migration/drain"
fi
if ! gcloud_ssh "$remote_command"; then
  fail "production candidate failed; boot metadata remains unchanged"
  exit 1
fi

RESULT=$(gcloud_ssh "sudo sed -n '1,5p' /run/d-inference/deploy-result.env")
RESULT_FILE=$(mktemp)
trap 'rm -f "$RESULT_FILE"' EXIT
printf '%s\n' "$RESULT" >"$RESULT_FILE"
PINNED_IMAGE=$(read_env_value "$RESULT_FILE" DINF_IMAGE)
PINNED_SELECTOR=$(read_env_value "$RESULT_FILE" DINF_COORDINATOR_BINARY)
PINNED_GO_FALLBACK=$(read_env_value "$RESULT_FILE" DINF_GO_FALLBACK_IMAGE)
ROLLBACK_GO_IMAGE=$(read_env_value "$RESULT_FILE" DINF_PREVIOUS_GO_FALLBACK_IMAGE)
PINNED_ENVIRONMENT_ID=$(read_env_value "$RESULT_FILE" DINF_CUTOVER_ENVIRONMENT_ID)
validate_pinned_image_ref "$PINNED_IMAGE" ||
  fail "remote result is not an immutable image digest"
validate_selector "$PINNED_SELECTOR" || fail "remote result has invalid selector"
validate_pinned_image_ref "$PINNED_GO_FALLBACK" ||
  fail "remote result has no immutable Go fallback digest"
validate_pinned_image_ref "$ROLLBACK_GO_IMAGE" ||
  fail "remote result has no immutable previous Go fallback digest"
[[ "$PINNED_SELECTOR" == "$SELECTOR" ]] ||
  fail "remote selector differs from requested selector"
[[ "$PINNED_ENVIRONMENT_ID" == "$CUTOVER_ENVIRONMENT_ID" ]] ||
  fail "remote environment_id differs from the signed authorization"

commit_go_fallback_metadata() {
  gcloud compute instances add-metadata "$INSTANCE" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --metadata="DINF_IMAGE=${ROLLBACK_GO_IMAGE},DINF_COORDINATOR_BINARY=go,DINF_GO_FALLBACK_IMAGE=${ROLLBACK_GO_IMAGE},DINF_CUTOVER_ENVIRONMENT_ID=${CUTOVER_ENVIRONMENT_ID},DINF_ENVIRONMENT=prod,DINF_GCP_PROJECT=${PROJECT}" \
    --metadata-from-file="startup-script=$ROOT/deploy/gcp/vm-startup.sh,dinf-configure-caddy=$ROOT/deploy/gcp/configure-caddy.sh,dinf-run-coordinator=$ROOT/deploy/gcp/run-coordinator.sh,dinf-run-recovery=$ROOT/deploy/gcp/run-recovery.sh,dinf-coordinator-unit=$ROOT/deploy/gcp/systemd/d-inference-coordinator.service,dinf-recovery-unit=$ROOT/deploy/gcp/systemd/d-inference-recovery.service,dinf-offline-recovery-doc=$ROOT/deploy/gcp/offline-recovery.md,dinf-refresh-env=$ROOT/deploy/gcp/refresh-env.sh"
}

rollback_to_committed_go() {
  local rollback_command
  rollback_command=$(printf "sudo '%s/rollback-after-commit-failure.sh' '%s'" \
    "$REMOTE_DIR" "$ROLLBACK_GO_IMAGE")
  gcloud_ssh "$rollback_command" || return 1
  commit_go_fallback_metadata || return 1
  gcloud_ssh "sudo rm -f /run/d-inference/candidate.env /run/d-inference/deploy-result.env"
}

metadata_command=(
  gcloud compute instances add-metadata "$INSTANCE"
  "--project=$PROJECT"
  "--zone=$ZONE"
  "--metadata=DINF_IMAGE=${PINNED_IMAGE},DINF_COORDINATOR_BINARY=${PINNED_SELECTOR},DINF_GO_FALLBACK_IMAGE=${PINNED_GO_FALLBACK},DINF_CUTOVER_ENVIRONMENT_ID=${PINNED_ENVIRONMENT_ID},DINF_ENVIRONMENT=prod,DINF_GCP_PROJECT=${PROJECT}"
  "--metadata-from-file=startup-script=$ROOT/deploy/gcp/vm-startup.sh,dinf-configure-caddy=$ROOT/deploy/gcp/configure-caddy.sh,dinf-run-coordinator=$ROOT/deploy/gcp/run-coordinator.sh,dinf-run-recovery=$ROOT/deploy/gcp/run-recovery.sh,dinf-coordinator-unit=$ROOT/deploy/gcp/systemd/d-inference-coordinator.service,dinf-recovery-unit=$ROOT/deploy/gcp/systemd/d-inference-recovery.service,dinf-offline-recovery-doc=$ROOT/deploy/gcp/offline-recovery.md,dinf-refresh-env=$ROOT/deploy/gcp/refresh-env.sh"
)
printf -v metadata_plan_command '%q ' "${metadata_command[@]}"
metadata_plan_command=${metadata_plan_command% }
cat <<COMMAND
Validated metadata commit command:
  $metadata_plan_command
COMMAND
read -r -p "Candidate passed. Type COMMIT-METADATA to make it reboot-persistent: " confirm_metadata
if [[ "$confirm_metadata" != "COMMIT-METADATA" ]]; then
  rollback_to_committed_go ||
    log "CRITICAL: Go rollback or fallback metadata commit failed; manual recovery is required"
  fail "metadata commit cancelled; pinned Go rollback requested"
  exit 1
fi

if ! "${metadata_command[@]}"; then
  rollback_to_committed_go ||
    log "CRITICAL: Go rollback or fallback metadata commit failed; manual recovery is required"
  exit 1
fi

gcloud_ssh "sudo rm -f /run/d-inference/candidate.env /run/d-inference/deploy-result.env" ||
  log "Warning: committed metadata is active, but temporary deploy files need cleanup."
log "Production deployment committed after explicit human confirmation"
