#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
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

TAG=${1:?usage: deploy-prod.sh IMAGE_TAG COORDINATOR_BINARY EXPECTED_COMMIT}
SELECTOR=${2:?usage: deploy-prod.sh IMAGE_TAG COORDINATOR_BINARY EXPECTED_COMMIT}
EXPECTED_COMMIT=${3:?usage: deploy-prod.sh IMAGE_TAG COORDINATOR_BINARY EXPECTED_COMMIT}
validate_tag "$TAG" || fail "invalid image tag"
validate_selector "$SELECTOR" || fail "coordinator binary must be exactly go or rust"
[[ "$EXPECTED_COMMIT" =~ ^[A-Fa-f0-9]{7,64}$ ]] || fail "invalid expected commit"

readonly PROJECT=darkbloom-mainnet
readonly ZONE=us-east4-a
readonly INSTANCE=darkbloom-coordinator
readonly IMAGE_REPO=us-east4-docker.pkg.dev/darkbloom-mainnet/coordinator/coordinator
readonly CANDIDATE_IMAGE="${IMAGE_REPO}:${TAG}"
readonly REMOTE_DIR=/opt/d-inference/deploy

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

GO_FALLBACK_IMAGE=$(metadata_value DINF_GO_FALLBACK_IMAGE)
if [[ -z "$GO_FALLBACK_IMAGE" ]]; then
  [[ "$SELECTOR" == "go" ]] ||
    fail "Rust cutover requires a previously pinned DINF_GO_FALLBACK_IMAGE"
  GO_FALLBACK_IMAGE=$CANDIDATE_IMAGE
fi
validate_image_ref "$GO_FALLBACK_IMAGE" || fail "invalid pinned Go fallback metadata"
remote_command=$(printf "sudo '%s/remote-deploy.sh' '%s' '%s' '%s' '%s' false" \
  "$REMOTE_DIR" "$CANDIDATE_IMAGE" "$SELECTOR" "$EXPECTED_COMMIT" "$GO_FALLBACK_IMAGE")
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
read -r -p "Type the image tag ($TAG): " confirm_tag
[[ "$confirm_tag" == "$TAG" ]] || fail "image confirmation failed"
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
if ! gcloud_ssh "$remote_command"; then
  fail "production candidate failed; boot metadata remains unchanged"
  exit 1
fi

RESULT=$(gcloud_ssh "sudo sed -n '1,4p' /run/d-inference/deploy-result.env")
RESULT_FILE=$(mktemp)
trap 'rm -f "$RESULT_FILE"' EXIT
printf '%s\n' "$RESULT" >"$RESULT_FILE"
PINNED_IMAGE=$(read_env_value "$RESULT_FILE" DINF_IMAGE)
PINNED_SELECTOR=$(read_env_value "$RESULT_FILE" DINF_COORDINATOR_BINARY)
PINNED_GO_FALLBACK=$(read_env_value "$RESULT_FILE" DINF_GO_FALLBACK_IMAGE)
ROLLBACK_GO_IMAGE=$(read_env_value "$RESULT_FILE" DINF_PREVIOUS_GO_FALLBACK_IMAGE)
validate_pinned_image_ref "$PINNED_IMAGE" ||
  fail "remote result is not an immutable image digest"
validate_selector "$PINNED_SELECTOR" || fail "remote result has invalid selector"
validate_pinned_image_ref "$PINNED_GO_FALLBACK" ||
  fail "remote result has no immutable Go fallback digest"
validate_pinned_image_ref "$ROLLBACK_GO_IMAGE" ||
  fail "remote result has no immutable previous Go fallback digest"
[[ "$PINNED_SELECTOR" == "$SELECTOR" ]] ||
  fail "remote selector differs from requested selector"

commit_go_fallback_metadata() {
  gcloud compute instances add-metadata "$INSTANCE" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --metadata="DINF_IMAGE=${ROLLBACK_GO_IMAGE},DINF_COORDINATOR_BINARY=go,DINF_GO_FALLBACK_IMAGE=${ROLLBACK_GO_IMAGE},DINF_ENVIRONMENT=prod,DINF_GCP_PROJECT=${PROJECT}" \
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
  "--metadata=DINF_IMAGE=${PINNED_IMAGE},DINF_COORDINATOR_BINARY=${PINNED_SELECTOR},DINF_GO_FALLBACK_IMAGE=${PINNED_GO_FALLBACK},DINF_ENVIRONMENT=prod,DINF_GCP_PROJECT=${PROJECT}"
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
