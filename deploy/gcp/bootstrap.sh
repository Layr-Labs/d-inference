#!/bin/bash
# One-shot GCP bootstrap for the d-inference DEV environment.
#
# Creates: Artifact Registry repos, Cloud SQL (Postgres), a GCE VM running the
# coordinator container (with a persistent data disk for step-ca/MicroMDM),
# Cloud Run for console-ui, service accounts, Secret Manager entries
# (placeholders), firewall rules. Idempotent: safe to re-run.
#
# Why GCE VM for the coordinator: step-ca writes CA state and MicroMDM uses
# BoltDB. Both need reliable local filesystem semantics, so the coordinator
# mounts a persistent disk at /mnt/disks/userdata (same path as EigenCloud).
#
# Prereqs:
#   - `gcloud` authenticated, project sepolia-ai selected (or pass PROJECT)
#   - Billing enabled on the project
#   - Owner/Editor on the project (for initial bootstrap only; downgrade after)
#
# After running this, populate Secret Manager:
#   - eigeninference-admin-key               (openssl rand -hex 32)
#   - eigeninference-release-key             (openssl rand -hex 32)
#   - eigeninference-solana-mnemonic         (new BIP39 mnemonic for dev)
#   - eigeninference-privy-app-id            (dev Privy app)
#   - eigeninference-privy-app-secret        (dev Privy app)
#   - eigeninference-privy-verification-key  (dev Privy app)
#   - eigeninference-micromdm-api-key        (openssl rand -hex 32)
#   - eigeninference-mdm-push-p12-b64        (base64url-encoded MDM push PKCS#12)

set -euo pipefail

PROJECT="${PROJECT:-sepolia-ai}"
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
INSTANCE="${INSTANCE:-d-inference-dev}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-small}"
DATA_DISK="${DATA_DISK:-d-inference-dev-data}"
DATA_DISK_SIZE="${DATA_DISK_SIZE:-30GB}"
SQL_INSTANCE="${SQL_INSTANCE:-d-inference-dev-db}"
SQL_DB="${SQL_DB:-coordinator}"
SQL_USER="${SQL_USER:-coordinator}"
COORD_SA="d-inference-dev"
# Console UI runs on Vercel (not Cloud Run) — no GCP provisioning needed.

echo "==> Using GCP project: $PROJECT (zone: $ZONE)"
gcloud config set project "$PROJECT"

echo "==> Enabling required APIs"
gcloud services enable \
  compute.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  secretmanager.googleapis.com \
  sqladmin.googleapis.com \
  logging.googleapis.com \
  monitoring.googleapis.com \
  iap.googleapis.com

echo "==> Creating Artifact Registry repos"
gcloud artifacts repositories describe coordinator --location="$REGION" >/dev/null 2>&1 || \
  gcloud artifacts repositories create coordinator \
    --repository-format=docker \
    --location="$REGION" \
    --description="Dev coordinator container images"

echo "==> Creating service account"
gcloud iam service-accounts describe "${COORD_SA}@${PROJECT}.iam.gserviceaccount.com" >/dev/null 2>&1 || \
  gcloud iam service-accounts create "$COORD_SA" \
    --display-name="Service account for $COORD_SA"

COORD_SA_EMAIL="${COORD_SA}@${PROJECT}.iam.gserviceaccount.com"

for ROLE in roles/secretmanager.secretAccessor roles/cloudsql.client \
            roles/logging.logWriter roles/artifactregistry.reader; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:$COORD_SA_EMAIL" \
    --role="$ROLE" \
    --condition=None \
    --quiet >/dev/null
done

echo "==> Granting Cloud Build SA permission to SSH via IAP + update instance metadata"
PROJECT_NUM=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
CB_SA="${PROJECT_NUM}@cloudbuild.gserviceaccount.com"
for ROLE in roles/iap.tunnelResourceAccessor roles/compute.instanceAdmin.v1 \
            roles/iam.serviceAccountUser; do
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:$CB_SA" \
    --role="$ROLE" \
    --condition=None \
    --quiet >/dev/null
done

echo "==> Creating Secret Manager entries (empty — fill in next)"
for SECRET in \
  eigeninference-admin-key \
  eigeninference-release-key \
  eigeninference-solana-mnemonic \
  eigeninference-privy-app-id \
  eigeninference-privy-app-secret \
  eigeninference-privy-verification-key \
  eigeninference-database-url \
  eigeninference-micromdm-api-key \
  eigeninference-mdm-push-p12-b64 \
  eigeninference-r2-cdn-url; do
  gcloud secrets describe "$SECRET" >/dev/null 2>&1 || \
    gcloud secrets create "$SECRET" --replication-policy=automatic
done

echo "==> Creating Cloud SQL Postgres instance (5-10 min on first run)"
if ! gcloud sql instances describe "$SQL_INSTANCE" >/dev/null 2>&1; then
  gcloud sql instances create "$SQL_INSTANCE" \
    --database-version=POSTGRES_16 \
    --tier=db-f1-micro \
    --region="$REGION" \
    --storage-auto-increase \
    --backup-start-time=03:00
fi

gcloud sql databases describe "$SQL_DB" --instance="$SQL_INSTANCE" >/dev/null 2>&1 || \
  gcloud sql databases create "$SQL_DB" --instance="$SQL_INSTANCE"

if ! gcloud sql users list --instance="$SQL_INSTANCE" --format='value(name)' | grep -qx "$SQL_USER"; then
  PW=$(openssl rand -hex 16)
  gcloud sql users create "$SQL_USER" --instance="$SQL_INSTANCE" --password="$PW"
  CONN_NAME=$(gcloud sql instances describe "$SQL_INSTANCE" --format='value(connectionName)')
  # Coordinator connects via Cloud SQL Auth Proxy sidecar on the VM (see below).
  URL="postgres://${SQL_USER}:${PW}@127.0.0.1:5432/${SQL_DB}?sslmode=disable"
  echo "$URL" | gcloud secrets versions add eigeninference-database-url --data-file=-
  echo "==> DB URL stored in Secret Manager eigeninference-database-url"
fi

echo "==> Creating persistent data disk for step-ca + MicroMDM state"
gcloud compute disks describe "$DATA_DISK" --zone="$ZONE" >/dev/null 2>&1 || \
  gcloud compute disks create "$DATA_DISK" \
    --zone="$ZONE" \
    --size="$DATA_DISK_SIZE" \
    --type=pd-balanced

echo "==> Creating firewall rule for :443"
gcloud compute firewall-rules describe allow-https-dev >/dev/null 2>&1 || \
  gcloud compute firewall-rules create allow-https-dev \
    --direction=INGRESS \
    --action=ALLOW \
    --rules=tcp:443,tcp:80 \
    --target-tags=d-inference-dev \
    --source-ranges=0.0.0.0/0

echo "==> Reserving static external IP"
gcloud compute addresses describe d-inference-dev-ip --region="$REGION" >/dev/null 2>&1 || \
  gcloud compute addresses create d-inference-dev-ip --region="$REGION"
EXTERNAL_IP=$(gcloud compute addresses describe d-inference-dev-ip --region="$REGION" --format='value(address)')
echo "External IP: $EXTERNAL_IP  (point api.dev.darkbloom.dev here in Vercel DNS)"

if ! gcloud compute instances describe "$INSTANCE" --zone="$ZONE" >/dev/null 2>&1; then
  echo "==> Creating GCE VM (Ubuntu + Docker + systemd)"
  # Ubuntu (not COS) because we need to inject secrets from Secret Manager
  # into the container's env file at boot — COS's declarative container model
  # doesn't support reading an SM-fetched env file. The startup script handles
  # Docker install, disk mount, secret fetch, and systemd unit creation.
  gcloud compute instances create "$INSTANCE" \
    --zone="$ZONE" \
    --machine-type="$MACHINE_TYPE" \
    --service-account="$COORD_SA_EMAIL" \
    --scopes=cloud-platform \
    --tags=d-inference-dev \
    --address="$EXTERNAL_IP" \
    --image-family=ubuntu-2404-lts-amd64 \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=20GB \
    --create-disk="name=${DATA_DISK},mode=rw,boot=no,auto-delete=no,device-name=${DATA_DISK}" \
    --metadata-from-file=startup-script="$(dirname "$0")/vm-startup.sh"
  echo "==> VM created. Startup script will run on first boot (~2-3 min)."
  echo "    Tail progress:"
  echo "      gcloud compute ssh $INSTANCE --zone=$ZONE -- 'sudo tail -f /var/log/d-inference-startup.log'"
else
  echo "==> VM $INSTANCE already exists (skipping create)"
  echo "    To refresh startup-script metadata after edits:"
  echo "      gcloud compute instances add-metadata $INSTANCE --zone=$ZONE \\"
  echo "        --metadata-from-file=startup-script=$(dirname "$0")/vm-startup.sh"
fi

cat <<EOF

==> Bootstrap complete.

Next steps:
  1. Populate secrets:
       for S in eigeninference-admin-key eigeninference-release-key \\
                eigeninference-micromdm-api-key; do
         echo -n "\$(openssl rand -hex 32)" | gcloud secrets versions add \$S --data-file=-
       done
     Then add Privy values, Solana mnemonic (NEW — never reuse prod), the MDM
     push PKCS#12 (base64url-encoded), and the dev R2 CDN URL
     (eigeninference-r2-cdn-url — the public URL of the d-inf-app-dev bucket).

  2. Add DNS records on Vercel Domains:
       api.dev.darkbloom.dev      A     $EXTERNAL_IP
       console.dev.darkbloom.dev  CNAME cname.vercel-dns.com   (after step 4)

  3. Push the first coordinator image (triggers startup-script to come to life):
       gcloud builds submit --config=deploy/gcp/cloudbuild.yaml --project=$PROJECT

  4. Deploy the console UI on **Vercel** (NOT on GCP):
       - In the Vercel dashboard, import the d-inference repo as a separate
         project (e.g. "darkbloom-console-dev"), set the root to console-ui/.
       - Configure environment variables:
           NEXT_PUBLIC_COORDINATOR_URL = https://api.dev.darkbloom.dev
       - Add the custom domain console.dev.darkbloom.dev — Vercel will show
         the CNAME target (usually cname.vercel-dns.com); add it at step 2.

  5. Connect this repo to Cloud Build (one-time, in Cloud Console) so future
     master pushes auto-deploy the coordinator:
       - Trigger: coordinator/** + deploy/gcp/** -> cloudbuild.yaml

  6. Upload the MDM enrollment profile and link it to the dev Privy app.
     (Same process as prod; uses the MDM push cert from step 1.)
EOF
