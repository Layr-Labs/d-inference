#!/bin/bash
# One-shot GCP bootstrap for the d-inference DEV environment.
#
# Creates: Artifact Registry repos, Cloud SQL (Postgres), a GCE VM running the
# coordinator container (with a persistent data disk for MicroMDM), service
# accounts, Secret Manager entries (placeholders), and firewall rules.
# Console UI is provisioned separately on Vercel. Idempotent: safe to re-run.
#
# Why GCE VM for the coordinator: MicroMDM uses
# BoltDB. Both need reliable local filesystem semantics, so the coordinator
# mounts a persistent disk at /mnt/disks/userdata (the same path as prod).
#
# Prereqs:
#   - `gcloud` authenticated (pass PROJECT or use the immutable default below)
#   - Billing enabled on the project
#   - Owner/Editor on the project (for initial bootstrap only; downgrade after)
#
# After running this, populate every Secret Manager entry consumed by
# refresh-env.sh. The canonical mapping and generation notes are in
# docs/operations/dev-environment.md; placeholder secrets intentionally make
# coordinator startup fail closed until all critical values are present.

set -euo pipefail

readonly PROJECT="${PROJECT:-sepolia-ai}"
readonly REGION="${REGION:-us-central1}"
readonly ZONE="${ZONE:-us-central1-a}"
readonly INSTANCE="${INSTANCE:-d-inference-dev}"
readonly MACHINE_TYPE="${MACHINE_TYPE:-e2-small}"
readonly DATA_DISK="${DATA_DISK:-d-inference-dev-data}"
readonly DATA_DISK_SIZE="${DATA_DISK_SIZE:-30GB}"
readonly SQL_INSTANCE="${SQL_INSTANCE:-d-inference-dev-db}"
readonly SQL_DB="${SQL_DB:-coordinator}"
readonly SQL_USER="${SQL_USER:-coordinator}"
readonly COORD_SA="d-inference-dev"
# Console UI runs on Vercel (not Cloud Run) — no GCP provisioning needed.

echo "==> Using GCP project: $PROJECT (zone: $ZONE)"
gcloud_project() {
  gcloud --project="$PROJECT" "$@"
}

echo "==> Enabling required APIs"
gcloud_project services enable \
  compute.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  sqladmin.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  iap.googleapis.com \
  cloudkms.googleapis.com

echo "==> Creating Artifact Registry repos"
gcloud_project artifacts repositories describe coordinator --location="$REGION" >/dev/null 2>&1 || \
  gcloud_project artifacts repositories create coordinator \
    --repository-format=docker \
    --location="$REGION" \
    --description="Dev coordinator container images"

echo "==> Creating service account"
gcloud_project iam service-accounts describe "${COORD_SA}@${PROJECT}.iam.gserviceaccount.com" >/dev/null 2>&1 || \
  gcloud_project iam service-accounts create "$COORD_SA" \
    --display-name="Service account for $COORD_SA"

COORD_SA_EMAIL="${COORD_SA}@${PROJECT}.iam.gserviceaccount.com"

for ROLE in roles/secretmanager.secretAccessor roles/cloudsql.client \
            roles/logging.logWriter roles/artifactregistry.reader; do
  gcloud_project projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:$COORD_SA_EMAIL" \
    --role="$ROLE" \
    --condition=None \
    --quiet >/dev/null
done

echo "==> Granting Cloud Build SA permission to SSH via IAP + update instance metadata"
PROJECT_NUM=$(gcloud_project projects describe "$PROJECT" --format='value(projectNumber)')
# New GCP projects (post-late-2024) default Cloud Build to the compute default
# SA (not the legacy cloudbuild.gserviceaccount.com). Grant roles to both so
# the script works regardless of project vintage.
for CB_SA in "${PROJECT_NUM}@cloudbuild.gserviceaccount.com" \
             "${PROJECT_NUM}-compute@developer.gserviceaccount.com"; do
  for ROLE in roles/iap.tunnelResourceAccessor \
              roles/compute.instanceAdmin.v1 \
              roles/iam.serviceAccountUser \
              roles/artifactregistry.writer \
              roles/logging.logWriter \
              roles/compute.osAdminLogin; do
    gcloud_project projects add-iam-policy-binding "$PROJECT" \
      --member="serviceAccount:$CB_SA" \
      --role="$ROLE" \
      --condition=None \
      --quiet >/dev/null 2>&1 || true
  done
done

echo "==> Creating Cloud KMS key ring + CMEK for high-sensitivity secrets"
# CMEK = customer-managed encryption key. Used only for the MDM push cert +
# Solana mnemonic — keys where destroying the CMEK instantly kills access,
# and rotation doesn't require copying data around. Cheap (~$0.06/mo/key) and
# worth it for the two most dangerous secrets in dev.
KMS_RING="d-inference-dev"
KMS_KEY_MDM="mdm-push-cert"
KMS_KEY_SOLANA="solana-mnemonic"
gcloud_project kms keyrings describe "$KMS_RING" --location="$REGION" >/dev/null 2>&1 || \
  gcloud_project kms keyrings create "$KMS_RING" --location="$REGION"
for K in "$KMS_KEY_MDM" "$KMS_KEY_SOLANA"; do
  gcloud_project kms keys describe "$K" --keyring="$KMS_RING" --location="$REGION" >/dev/null 2>&1 || \
    gcloud_project kms keys create "$K" \
      --keyring="$KMS_RING" \
      --location="$REGION" \
      --purpose=encryption \
      --rotation-period=90d \
      --next-rotation-time="$(date -u -v+90d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '+90 days' +%Y-%m-%dT%H:%M:%SZ)"
done

# Explicitly provision Secret Manager's service agent. Without this, the first
# IAM binding on the CMEK key below fails with "Service account does not exist"
# because the agent is created lazily on first API use. We call the REST API
# directly to avoid depending on `gcloud beta` (which needs an interactive
# component install) or the placeholder-secret trick.
curl -sS -X POST \
  -H "Authorization: Bearer $(gcloud_project auth print-access-token)" \
  -H "Content-Type: application/json" \
  "https://serviceusage.googleapis.com/v1beta1/projects/${PROJECT_NUM}/services/secretmanager.googleapis.com:generateServiceIdentity" \
  >/dev/null
SM_AGENT="service-${PROJECT_NUM}@gcp-sa-secretmanager.iam.gserviceaccount.com"

# IAM propagation can take a few seconds after the agent is created.
for _ in 1 2 3 4 5 6; do
  if gcloud_project iam service-accounts describe "$SM_AGENT" >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
for K in "$KMS_KEY_MDM" "$KMS_KEY_SOLANA"; do
  gcloud_project kms keys add-iam-policy-binding "$K" \
    --keyring="$KMS_RING" --location="$REGION" \
    --member="serviceAccount:$SM_AGENT" \
    --role="roles/cloudkms.cryptoKeyEncrypterDecrypter" \
    --condition=None \
    --quiet >/dev/null
done

echo "==> Creating Secret Manager entries"
# Most secrets use Google-managed encryption (default). Two high-sensitivity
# ones use CMEK so we can revoke by destroying the KMS key.
CMEK_MDM="projects/${PROJECT}/locations/${REGION}/keyRings/${KMS_RING}/cryptoKeys/${KMS_KEY_MDM}"
CMEK_SOLANA="projects/${PROJECT}/locations/${REGION}/keyRings/${KMS_RING}/cryptoKeys/${KMS_KEY_SOLANA}"

create_secret() {
  local name="$1"
  local kms="${2:-}"
  gcloud_project secrets describe "$name" >/dev/null 2>&1 && return 0
  if [ -n "$kms" ]; then
    # Single-region CMEK requires user-managed replication, which the CLI
    # expects as a policy file (not a --kms-key-name flag).
    local policy_file
    policy_file=$(mktemp)
    cat > "$policy_file" <<POLICY
{
  "userManaged": {
    "replicas": [
      {
        "location": "${REGION}",
        "customerManagedEncryption": {
          "kmsKeyName": "${kms}"
        }
      }
    ]
  }
}
POLICY
    gcloud_project secrets create "$name" --replication-policy-file="$policy_file"
    rm -f "$policy_file"
  else
    gcloud_project secrets create "$name" --replication-policy=automatic
  fi
}

create_secret eigeninference-admin-key
create_secret eigeninference-release-key
create_secret eigeninference-solana-mnemonic "$CMEK_SOLANA"
create_secret eigeninference-privy-app-id
create_secret eigeninference-privy-app-secret
create_secret eigeninference-privy-verification-key
create_secret eigeninference-database-url
create_secret eigeninference-micromdm-api-key
create_secret eigeninference-mdm-webhook-secret
create_secret eigeninference-mdm-push-p12-b64 "$CMEK_MDM"
create_secret eigeninference-mdm-push-p12-password
create_secret eigeninference-r2-cdn-url
create_secret eigeninference-profile-signing-p12-b64
create_secret eigeninference-profile-signing-p12-password
create_secret eigeninference-stripe-secret-key
create_secret eigeninference-stripe-webhook-secret
create_secret eigeninference-stripe-success-url
create_secret eigeninference-stripe-cancel-url
create_secret eigeninference-stripe-connect-webhook-secret
create_secret eigeninference-stripe-connect-return-url
create_secret eigeninference-stripe-connect-refresh-url
create_secret eigeninference-rust-x25519-key-id
create_secret eigeninference-rust-x25519-private-key
create_secret eigeninference-rust-x25519-public-key
create_secret eigeninference-ipapi-key
create_secret eigeninference-dd-api-key
create_secret eigeninference-dd-site

echo "==> Grant coord SA decrypt on the CMEK keys (scoped to the two keys only)"
for K in "$KMS_KEY_MDM" "$KMS_KEY_SOLANA"; do
  gcloud_project kms keys add-iam-policy-binding "$K" \
    --keyring="$KMS_RING" --location="$REGION" \
    --member="serviceAccount:$COORD_SA_EMAIL" \
    --role="roles/cloudkms.cryptoKeyDecrypter" \
    --condition=None \
    --quiet >/dev/null
done

echo "==> Enabling Data Access audit logs for Secret Manager (logs every read)"
# Data Access logs are OFF by default. Turn them on for Secret Manager so any
# read of eigeninference-mdm-push-p12-b64 shows up in Cloud Logging, and we
# can alert on unexpected readers (anyone other than the coord SA).
AUDIT_TMP=$(mktemp)
gcloud_project projects get-iam-policy "$PROJECT" --format=json > "$AUDIT_TMP"
python3 - <<'PY' "$AUDIT_TMP"
import json, sys
path = sys.argv[1]
with open(path) as f:
    policy = json.load(f)
policy.setdefault("auditConfigs", [])
sm = next((c for c in policy["auditConfigs"] if c.get("service") == "secretmanager.googleapis.com"), None)
want = [{"logType": "DATA_READ"}, {"logType": "DATA_WRITE"}, {"logType": "ADMIN_READ"}]
if sm is None:
    policy["auditConfigs"].append({"service": "secretmanager.googleapis.com", "auditLogConfigs": want})
else:
    sm["auditLogConfigs"] = want
with open(path, "w") as f:
    json.dump(policy, f)
PY
gcloud_project projects set-iam-policy "$PROJECT" "$AUDIT_TMP" --quiet >/dev/null
rm -f "$AUDIT_TMP"

echo "==> Scope Secret Manager access per-secret (tighter than project-level)"
# Project-level secretAccessor was granted earlier as a fallback for operational
# simplicity. Override the MDM push cert secret specifically so only the coord
# SA can read it — no human, no other service. Revoke here if we ever had wider
# bindings.
gcloud_project secrets add-iam-policy-binding eigeninference-mdm-push-p12-b64 \
  --member="serviceAccount:$COORD_SA_EMAIL" \
  --role="roles/secretmanager.secretAccessor" \
  --condition=None \
  --quiet >/dev/null

echo "==> Creating Cloud SQL Postgres instance (5-10 min on first run)"
if ! gcloud_project sql instances describe "$SQL_INSTANCE" >/dev/null 2>&1; then
  # Enterprise edition allows the shared-core db-f1-micro tier. Enterprise Plus
  # (the new default in some regions) only supports perf-optimized tiers which
  # start around $200/mo — overkill for dev.
  gcloud_project sql instances create "$SQL_INSTANCE" \
    --database-version=POSTGRES_16 \
    --edition=enterprise \
    --tier=db-f1-micro \
    --region="$REGION" \
    --storage-auto-increase \
    --backup-start-time=03:00
fi

gcloud_project sql databases describe "$SQL_DB" --instance="$SQL_INSTANCE" >/dev/null 2>&1 || \
  gcloud_project sql databases create "$SQL_DB" --instance="$SQL_INSTANCE"

if ! gcloud_project sql users list --instance="$SQL_INSTANCE" --format='value(name)' | grep -qx "$SQL_USER"; then
  PW=$(openssl rand -hex 16)
  gcloud_project sql users create "$SQL_USER" --instance="$SQL_INSTANCE" --password="$PW"
  # Coordinator connects via Cloud SQL Auth Proxy sidecar on the VM (see below).
  URL="postgres://${SQL_USER}:${PW}@127.0.0.1:5432/${SQL_DB}?sslmode=disable"
  echo "$URL" | gcloud_project secrets versions add eigeninference-database-url --data-file=-
  echo "==> DB URL stored in Secret Manager eigeninference-database-url"
fi

echo "==> Creating persistent data disk for MicroMDM state"
gcloud_project compute disks describe "$DATA_DISK" --zone="$ZONE" >/dev/null 2>&1 || \
  gcloud_project compute disks create "$DATA_DISK" \
    --zone="$ZONE" \
    --size="$DATA_DISK_SIZE" \
    --type=pd-balanced

echo "==> Creating firewall rule for :443"
gcloud_project compute firewall-rules describe allow-https-dev >/dev/null 2>&1 || \
  gcloud_project compute firewall-rules create allow-https-dev \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:443,tcp:80 \
    --target-tags=d-inference-dev \
    --source-ranges=0.0.0.0/0

echo "==> Reserving static external IP"
gcloud_project compute addresses describe d-inference-dev-ip --region="$REGION" >/dev/null 2>&1 || \
  gcloud_project compute addresses create d-inference-dev-ip --region="$REGION"
EXTERNAL_IP=$(gcloud_project compute addresses describe d-inference-dev-ip --region="$REGION" --format='value(address)')
echo "External IP: $EXTERNAL_IP  (point api.dev.darkbloom.xyz here in Vercel DNS)"

if ! gcloud_project compute instances describe "$INSTANCE" --zone="$ZONE" >/dev/null 2>&1; then
  echo "==> Creating GCE VM (Ubuntu + Docker + systemd)"
  # Ubuntu (not COS) because we need to inject secrets from Secret Manager
  # into the container's env file at boot — COS's declarative container model
  # doesn't support reading an SM-fetched env file. The startup script handles
  # Docker install, disk mount, secret fetch, and systemd unit creation.
  gcloud_project compute instances create "$INSTANCE" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --service-account="$COORD_SA_EMAIL" \
    --scopes=cloud-platform \
    --tags=d-inference-dev \
    --address="$EXTERNAL_IP" \
    --image-family=ubuntu-2404-lts-amd64 \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=20GB \
    --disk="name=${DATA_DISK},mode=rw,boot=no,auto-delete=no,device-name=${DATA_DISK}" \
    --metadata="DINF_ENVIRONMENT=dev,DINF_GCP_PROJECT=${PROJECT},DINF_SQL_INSTANCE=${SQL_INSTANCE},DINF_DATA_DEVICE=/dev/disk/by-id/google-${DATA_DISK}" \
    --metadata-from-file="startup-script=$(dirname "$0")/vm-startup.sh,dinf-configure-caddy=$(dirname "$0")/configure-caddy.sh,dinf-run-coordinator=$(dirname "$0")/run-coordinator.sh,dinf-run-recovery=$(dirname "$0")/run-recovery.sh,dinf-coordinator-unit=$(dirname "$0")/systemd/d-inference-coordinator.service,dinf-recovery-unit=$(dirname "$0")/systemd/d-inference-recovery.service,dinf-offline-recovery-doc=$(dirname "$0")/offline-recovery.md,dinf-refresh-env=$(dirname "$0")/refresh-env.sh"
  echo "==> VM created. Startup script will run on first boot (~2-3 min)."
  echo "    Tail progress:"
  echo "      gcloud compute ssh $INSTANCE --project=$PROJECT --zone=$ZONE -- 'sudo tail -f /var/log/d-inference-startup.log'"
else
  echo "==> VM $INSTANCE already exists (skipping create)"
  if ! gcloud_project compute instances describe "$INSTANCE" \
    --zone="$ZONE" --format='value(disks.deviceName)' |
    tr ';' '\n' | grep -qx "$DATA_DISK"; then
    echo "==> Attaching existing persistent data disk"
    gcloud_project compute instances attach-disk "$INSTANCE" \
      --zone="$ZONE" \
      --disk="$DATA_DISK" \
      --device-name="$DATA_DISK" \
      --mode=rw
  fi
  gcloud_project compute instances add-metadata "$INSTANCE" \
    --zone="$ZONE" \
    --metadata="DINF_ENVIRONMENT=dev,DINF_GCP_PROJECT=${PROJECT},DINF_SQL_INSTANCE=${SQL_INSTANCE},DINF_DATA_DEVICE=/dev/disk/by-id/google-${DATA_DISK}"
  echo "    To refresh startup-script metadata after edits:"
  echo "      gcloud compute instances add-metadata $INSTANCE --project=$PROJECT --zone=$ZONE \\"
  echo "        --metadata-from-file=startup-script=$(dirname "$0")/vm-startup.sh"
fi

cat <<EOF

==> Bootstrap complete.

Next steps:
  1. Populate secrets:
       for S in eigeninference-admin-key eigeninference-release-key \\
                eigeninference-micromdm-api-key; do
         echo -n "\$(openssl rand -hex 32)" | gcloud --project=$PROJECT secrets versions add \$S --data-file=-
       done
     Then add Privy values, Solana mnemonic (generated fresh for dev — not prod's),
     the dev R2 CDN URL (public URL of d-inf-app-dev), and the MDM push PKCS#12.

  1a. MDM push cert — reusing prod's cert as a time-bound bridge:
      Export the prod PKCS#12 from prod's KMS. On a trusted machine:
        echo -n "<prod-p12-base64url>" \\
          | gcloud --project=$PROJECT secrets versions add eigeninference-mdm-push-p12-b64 --data-file=-
        echo -n "<p12-password>" \\
          | gcloud --project=$PROJECT secrets versions add eigeninference-mdm-push-p12-password --data-file=-
      This secret is CMEK-encrypted with projects/$PROJECT/.../cryptoKeys/mdm-push-cert.
      IAM is scoped to only $COORD_SA_EMAIL — no humans, no other SAs.
      Target: rotate to a dev-specific cert within 30 days once Apple issues
      the MDM Vendor CSR signing certificate.

  2. Add DNS records on Vercel Domains:
       api.dev.darkbloom.xyz      A     $EXTERNAL_IP
       console.dev.darkbloom.xyz  CNAME cname.vercel-dns.com   (after step 4)

  3. Push the first coordinator image (triggers startup-script to come to life):
       gcloud builds submit --config=deploy/gcp/cloudbuild.yaml --project=$PROJECT

  4. Deploy the console UI on **Vercel** (NOT on GCP):
       - In the Vercel dashboard, import the d-inference repo as a separate
         project (e.g. "darkbloom-console-dev"), set the root to console-ui/.
       - Configure environment variables:
           NEXT_PUBLIC_COORDINATOR_URL = https://api.dev.darkbloom.xyz
       - Add the custom domain console.dev.darkbloom.xyz — Vercel will show
         the CNAME target (usually cname.vercel-dns.com); add it at step 2.

  5. Connect this repo to Cloud Build (one-time, in Cloud Console) so future
     master pushes auto-deploy the coordinator:
       - Trigger: coordinator/** + deploy/gcp/** -> cloudbuild.yaml

  6. Upload the MDM enrollment profile and link it to the dev Privy app.
     (Same process as prod; uses the MDM push cert from step 1.)
EOF
