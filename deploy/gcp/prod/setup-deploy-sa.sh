#!/bin/bash
# One-time setup of the service account used by the prod coordinator deploy
# trigger. Grants are scoped to the single VM, its runtime SA, and the
# coordinator Artifact Registry repo. Additive only; revokes nothing.
#
# Idempotent. DRY_RUN=true to preview.

set -euo pipefail

PROJECT="${PROJECT:-darkbloom-mainnet}"
INSTANCE="${INSTANCE:-darkbloom-coordinator}"
ZONE="${ZONE:-us-east4-a}"
AR_REPO="${AR_REPO:-coordinator}"
AR_LOCATION="${AR_LOCATION:-us-east4}"
SA_NAME="cloudbuild-coordinator-deploy"
DRY_RUN="${DRY_RUN:-false}"

SA_EMAIL="${SA_NAME}@${PROJECT}.iam.gserviceaccount.com"

run() {
  echo "+ $*"
  if [ "$DRY_RUN" != "true" ]; then
    "$@"
  fi
}

echo "==> Project: $PROJECT, instance: $INSTANCE ($ZONE)"

echo "==> Create deploy SA"
if gcloud iam service-accounts describe "$SA_EMAIL" --project "$PROJECT" &>/dev/null; then
  echo "SA $SA_EMAIL already exists, skipping create"
else
  run gcloud iam service-accounts create "$SA_NAME" \
    --project "$PROJECT" \
    --display-name "Cloud Build: coordinator prod deploy (instance-scoped)"
fi

echo "==> Project-level: logging + IAP tunnel only"
for ROLE in roles/logging.logWriter roles/iap.tunnelResourceAccessor; do
  run gcloud projects add-iam-policy-binding "$PROJECT" \
    --member "serviceAccount:${SA_EMAIL}" \
    --role "$ROLE" \
    --condition None \
    --quiet
done

echo "==> Instance-level: instanceAdmin on ${INSTANCE} only"
run gcloud compute instances add-iam-policy-binding "$INSTANCE" \
  --project "$PROJECT" \
  --zone "$ZONE" \
  --member "serviceAccount:${SA_EMAIL}" \
  --role roles/compute.instanceAdmin.v1

echo "==> SA-level: actAs the VM runtime SA only (required for SSH)"
VM_SA=$(gcloud compute instances describe "$INSTANCE" --project "$PROJECT" --zone "$ZONE" \
  --format 'value(serviceAccounts[0].email)')
if [ -n "$VM_SA" ]; then
  run gcloud iam service-accounts add-iam-policy-binding "$VM_SA" \
    --project "$PROJECT" \
    --member "serviceAccount:${SA_EMAIL}" \
    --role roles/iam.serviceAccountUser
else
  echo "NOTE: $INSTANCE has no service account attached; skipping serviceAccountUser grant"
fi

echo "==> Repo-level: Artifact Registry writer on ${AR_REPO} only"
run gcloud artifacts repositories add-iam-policy-binding "$AR_REPO" \
  --project "$PROJECT" \
  --location "$AR_LOCATION" \
  --member "serviceAccount:${SA_EMAIL}" \
  --role roles/artifactregistry.writer

echo "Done. Service account: $SA_EMAIL"
