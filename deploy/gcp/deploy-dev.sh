#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
source "$ROOT/deploy/gcp/deploy-common.sh"

TAG=${1:?usage: deploy-dev.sh IMAGE_TAG COORDINATOR_BINARY EXPECTED_COMMIT [ADOPT_LEGACY]}
SELECTOR=${2:?usage: deploy-dev.sh IMAGE_TAG COORDINATOR_BINARY EXPECTED_COMMIT [ADOPT_LEGACY]}
EXPECTED_COMMIT=${3:?usage: deploy-dev.sh IMAGE_TAG COORDINATOR_BINARY EXPECTED_COMMIT [ADOPT_LEGACY]}
ADOPT_LEGACY=${4:-false}

validate_tag "$TAG" || fail "invalid image tag"
validate_selector "$SELECTOR" || fail "coordinator binary must be exactly go or rust"
[[ "$EXPECTED_COMMIT" =~ ^[A-Fa-f0-9]{7,64}$ ]] || fail "invalid expected commit"
[[ "$ADOPT_LEGACY" == "true" || "$ADOPT_LEGACY" == "false" ]] ||
  fail "ADOPT_LEGACY must be true or false"

[[ "${PROJECT:-sepolia-ai}" == "sepolia-ai" ]] ||
  fail "dev project is immutable"
[[ "${ZONE:-us-central1-a}" == "us-central1-a" ]] ||
  fail "dev zone is immutable"
[[ "${INSTANCE:-d-inference-dev}" == "d-inference-dev" ]] ||
  fail "dev instance is immutable"
[[ "${IMAGE_REPO:-us-central1-docker.pkg.dev/sepolia-ai/coordinator/coordinator}" == \
  "us-central1-docker.pkg.dev/sepolia-ai/coordinator/coordinator" ]] ||
  fail "dev image repository is immutable"
readonly PROJECT=sepolia-ai
readonly ZONE=us-central1-a
readonly INSTANCE=d-inference-dev
readonly SQL_INSTANCE=d-inference-dev-db
readonly IMAGE_REPO=us-central1-docker.pkg.dev/sepolia-ai/coordinator/coordinator
readonly CANDIDATE_IMAGE="${IMAGE_REPO}:${TAG}"
readonly REMOTE_DIR=/opt/d-inference/deploy

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
  if [[ "$SELECTOR" != "go" ]]; then
    fail "Rust cutover requires a previously pinned DINF_GO_FALLBACK_IMAGE"
  fi
  GO_FALLBACK_IMAGE=$CANDIDATE_IMAGE
fi
validate_image_ref "$GO_FALLBACK_IMAGE" || fail "invalid pinned Go fallback metadata"

log "Installing versioned deployment runtime on dev VM"
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

log "Refreshing dev secrets into the root-only env file"
gcloud_ssh "sudo bash -s -- dev '$PROJECT'" <"$ROOT/deploy/gcp/refresh-env.sh"
log "Validating and installing the dev Caddy proxy configuration"
gcloud_ssh "sudo /usr/local/bin/d-inference-configure-caddy.sh dev"

remote_command=$(printf "sudo '%s/remote-deploy.sh' '%s' '%s' '%s' '%s' '%s'" \
  "$REMOTE_DIR" "$CANDIDATE_IMAGE" "$SELECTOR" "$EXPECTED_COMMIT" \
  "$GO_FALLBACK_IMAGE" "$ADOPT_LEGACY")
if ! gcloud_ssh "$remote_command"; then
  fail "candidate deployment failed; metadata remains unchanged"
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
  fail "remote candidate result is not an immutable image digest"
validate_selector "$PINNED_SELECTOR" || fail "remote candidate result has invalid selector"
validate_pinned_image_ref "$PINNED_GO_FALLBACK" ||
  fail "remote candidate result has no immutable Go fallback digest"
validate_pinned_image_ref "$ROLLBACK_GO_IMAGE" ||
  fail "remote candidate result has no immutable previous Go fallback digest"
[[ "$PINNED_SELECTOR" == "$SELECTOR" ]] || fail "remote selector differs from requested selector"

commit_go_fallback_metadata() {
  gcloud compute instances add-metadata "$INSTANCE" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --metadata="DINF_IMAGE=${ROLLBACK_GO_IMAGE},DINF_COORDINATOR_BINARY=go,DINF_GO_FALLBACK_IMAGE=${ROLLBACK_GO_IMAGE},DINF_ENVIRONMENT=dev,DINF_GCP_PROJECT=${PROJECT},DINF_SQL_INSTANCE=${SQL_INSTANCE}" \
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

log "Committing dev image digest, binary selector, and reboot metadata after success"
if ! gcloud compute instances add-metadata "$INSTANCE" \
  --project="$PROJECT" \
  --zone="$ZONE" \
  --metadata="DINF_IMAGE=${PINNED_IMAGE},DINF_COORDINATOR_BINARY=${PINNED_SELECTOR},DINF_GO_FALLBACK_IMAGE=${PINNED_GO_FALLBACK},DINF_ENVIRONMENT=dev,DINF_GCP_PROJECT=${PROJECT},DINF_SQL_INSTANCE=${SQL_INSTANCE}" \
  --metadata-from-file="startup-script=$ROOT/deploy/gcp/vm-startup.sh,dinf-configure-caddy=$ROOT/deploy/gcp/configure-caddy.sh,dinf-run-coordinator=$ROOT/deploy/gcp/run-coordinator.sh,dinf-run-recovery=$ROOT/deploy/gcp/run-recovery.sh,dinf-coordinator-unit=$ROOT/deploy/gcp/systemd/d-inference-coordinator.service,dinf-recovery-unit=$ROOT/deploy/gcp/systemd/d-inference-recovery.service,dinf-offline-recovery-doc=$ROOT/deploy/gcp/offline-recovery.md,dinf-refresh-env=$ROOT/deploy/gcp/refresh-env.sh"; then
  log "Metadata commit failed; restoring pinned Go image"
  rollback_to_committed_go ||
    log "CRITICAL: Go rollback or fallback metadata commit failed; manual recovery is required"
  exit 1
fi

gcloud_ssh "sudo rm -f /run/d-inference/candidate.env /run/d-inference/deploy-result.env" ||
  log "Warning: committed metadata is active, but temporary deploy files need cleanup."
log "Dev deployment committed successfully"
