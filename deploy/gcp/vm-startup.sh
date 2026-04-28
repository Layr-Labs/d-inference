#!/bin/bash
# Startup script for the dev coordinator GCE VM (Ubuntu 24.04 LTS + Docker).
# Runs on every boot via the instance's `startup-script` metadata. Idempotent.
#
# Responsibilities on first boot:
#   1. Install Docker, gcloud, cloud-sql-proxy
#   2. Format + mount the attached persistent data disk at /mnt/disks/userdata
#      (same path as EigenCloud prod, so the container's start.sh works unchanged)
#   3. Install a systemd unit for cloud-sql-proxy (Cloud SQL on 127.0.0.1:5432)
#   4. Install a systemd unit for the coordinator container
#   5. Fetch secrets from Secret Manager, write /etc/d-inference/env
#
# On subsequent boots:
#   - Re-fetch secrets (picks up rotations)
#   - Re-pull latest container image
#   - Restart systemd units
#
# Redeploys from Cloud Build do NOT go through this script — they SSH in and
# `systemctl restart d-inference-coordinator`, which re-pulls the pinned image.

set -euo pipefail
exec > >(tee /var/log/d-inference-startup.log) 2>&1
echo "==> Startup at $(date -Iseconds)"

REGISTRY_HOST="us-central1-docker.pkg.dev"
IMAGE_REPO="${REGISTRY_HOST}/sepolia-ai/coordinator/coordinator"

DATA_DEV="/dev/disk/by-id/google-d-inference-dev-data"
DATA_MOUNT="/mnt/disks/userdata"
ENV_DIR="/etc/d-inference"
ENV_FILE="${ENV_DIR}/env"

# ---- 1. Packages ----
# Install gcloud + Docker + cloud-sql-proxy FIRST. Nothing later in this script
# can call `gcloud` before this block completes (Ubuntu 24.04 ships no gcloud
# by default — it would fail silently and break secret fetching).
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg jq apt-transport-https

if ! command -v gcloud >/dev/null; then
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
    gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    > /etc/apt/sources.list.d/google-cloud-sdk.list
  apt-get update
  apt-get install -y google-cloud-cli
fi

if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io
fi

if ! command -v cloud-sql-proxy >/dev/null; then
  curl -fsSL -o /usr/local/bin/cloud-sql-proxy \
    https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.11.0/cloud-sql-proxy.linux.amd64
  chmod +x /usr/local/bin/cloud-sql-proxy
fi

# Caddy for TLS termination + reverse proxy to the coordinator on :8080.
# In prod, EigenCloud injects Caddy next to the container; on our GCE VM we
# run it as a host-level systemd service. Auto-TLS via Let's Encrypt
# HTTP-01 challenge (port 80 allowed by firewall).
if ! command -v caddy >/dev/null; then
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | \
    gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y caddy
fi

# Now it is safe to invoke gcloud.
SQL_CONN=$(gcloud sql instances describe d-inference-dev-db --format='value(connectionName)')
if [ -z "$SQL_CONN" ]; then
  echo "!! failed to resolve Cloud SQL connection name — aborting"
  exit 1
fi

# ---- 2. Persistent data disk ----
mkdir -p "$DATA_MOUNT"
if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
  mkfs.ext4 -F "$DATA_DEV"
fi
mountpoint -q "$DATA_MOUNT" || mount -o noatime,discard "$DATA_DEV" "$DATA_MOUNT"
grep -q "$DATA_DEV" /etc/fstab || \
  echo "$DATA_DEV $DATA_MOUNT ext4 noatime,discard 0 2" >> /etc/fstab

# ---- 3. Fetch secrets ----
mkdir -p "$ENV_DIR"
chmod 700 "$ENV_DIR"

fetch() {
  gcloud --quiet secrets versions access latest --secret="$1" 2>/dev/null || true
}

cat > "$ENV_FILE" <<EOF
EIGENINFERENCE_PORT=8080
EIGENINFERENCE_MIN_TRUST=hardware
EIGENINFERENCE_BILLING_MOCK=false
EIGENINFERENCE_BASE_URL=https://api.dev.darkbloom.xyz
EIGENINFERENCE_CONSOLE_URL=https://console.dev.darkbloom.xyz
CORS_ORIGIN=https://console.dev.darkbloom.xyz
EIGENINFERENCE_R2_CDN_URL=$(fetch darkbloom-r2-cdn-url)
EIGENINFERENCE_SOLANA_RPC_URL=https://api.mainnet-beta.solana.com
EIGENINFERENCE_SOLANA_USDC_MINT=EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v
EIGENINFERENCE_ADMIN_EMAILS=gajesh@eigenlabs.org
EIGENINFERENCE_REFERRAL_SHARE_PCT=15
DOMAIN=api.dev.darkbloom.xyz
APP_PORT=8080
EIGENINFERENCE_MDM_URL=https://localhost:9002
EIGENINFERENCE_STEP_CA_ROOT=/data/step-ca/certs/root_ca.crt
EIGENINFERENCE_STEP_CA_INTERMEDIATE=/data/step-ca/certs/intermediate_ca.crt
EIGENINFERENCE_ADMIN_KEY=$(fetch darkbloom-admin-key)
EIGENINFERENCE_RELEASE_KEY=$(fetch darkbloom-release-key)
EIGENINFERENCE_PRIVY_APP_ID=$(fetch darkbloom-privy-app-id)
EIGENINFERENCE_PRIVY_APP_SECRET=$(fetch darkbloom-privy-app-secret)
EIGENINFERENCE_PRIVY_VERIFICATION_KEY=$(fetch darkbloom-privy-verification-key)
EIGENINFERENCE_DATABASE_URL=$(fetch darkbloom-database-url)
MNEMONIC=$(fetch darkbloom-solana-mnemonic)
MICROMDM_API_KEY=$(fetch darkbloom-micromdm-api-key)
EIGENINFERENCE_MDM_API_KEY=$(fetch darkbloom-micromdm-api-key)
MDM_PUSH_P12_B64=$(fetch darkbloom-mdm-push-p12-b64)
EIGENINFERENCE_STRIPE_SECRET_KEY=$(fetch darkbloom-stripe-secret-key)
EIGENINFERENCE_STRIPE_WEBHOOK_SECRET=$(fetch darkbloom-stripe-webhook-secret)
EIGENINFERENCE_STRIPE_SUCCESS_URL=$(fetch darkbloom-stripe-success-url)
EIGENINFERENCE_STRIPE_CANCEL_URL=$(fetch darkbloom-stripe-cancel-url)
EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET=$(fetch darkbloom-stripe-connect-webhook-secret)
EIGENINFERENCE_STRIPE_CONNECT_RETURN_URL=$(fetch darkbloom-stripe-connect-return-url)
EIGENINFERENCE_STRIPE_CONNECT_REFRESH_URL=$(fetch darkbloom-stripe-connect-refresh-url)
DD_API_KEY=$(fetch darkbloom-dd-api-key)
DD_SITE=$(fetch darkbloom-dd-site)
DD_ENV=development
DD_SERVICE=d-inference-coordinator
EOF
chmod 600 "$ENV_FILE"

# ---- 4. cloud-sql-proxy systemd unit ----
cat > /etc/systemd/system/cloud-sql-proxy.service <<EOF
[Unit]
Description=Cloud SQL Auth Proxy
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/cloud-sql-proxy --address 127.0.0.1 --port 5432 ${SQL_CONN}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# ---- 5. Coordinator startup wrapper + systemd unit ----
# Wrapper resolves the image tag from instance metadata at each start so
# Cloud Build can pin a specific SHA by writing DINF_IMAGE_TAG. Auth to
# Artifact Registry uses the VM's service-account access token from the
# metadata server — no gcloud dependency, so the wrapper works even if
# google-cloud-cli isn't present at /usr/bin/gcloud.
cat > /usr/local/bin/d-inference-run.sh <<'WRAPPER'
#!/bin/bash
set -euo pipefail
META="http://metadata.google.internal/computeMetadata/v1/instance"
TAG=$(curl -fsSL -H "Metadata-Flavor: Google" "$META/attributes/DINF_IMAGE_TAG" 2>/dev/null || echo latest)
IMAGE="us-central1-docker.pkg.dev/sepolia-ai/coordinator/coordinator:${TAG}"
echo "Starting coordinator with image $IMAGE"

# Fetch an access token for the VM's default SA and docker login.
TOKEN=$(curl -fsSL -H "Metadata-Flavor: Google" \
  "$META/service-accounts/default/token" \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
printf '%s' "$TOKEN" | /usr/bin/docker login -u oauth2accesstoken --password-stdin us-central1-docker.pkg.dev
unset TOKEN

/usr/bin/docker pull "$IMAGE"
exec /usr/bin/docker run --rm --name d-inference-coordinator \
  --network host \
  --env-file /etc/d-inference/env \
  --mount type=bind,source=/mnt/disks/userdata,target=/mnt/disks/userdata \
  "$IMAGE"
WRAPPER
chmod +x /usr/local/bin/d-inference-run.sh

cat > /etc/systemd/system/d-inference-coordinator.service <<EOF
[Unit]
Description=d-inference dev coordinator
After=docker.service cloud-sql-proxy.service
Requires=docker.service cloud-sql-proxy.service

[Service]
Restart=always
RestartSec=5
TimeoutStopSec=45
ExecStartPre=-/usr/bin/docker stop d-inference-coordinator
ExecStartPre=-/usr/bin/docker rm d-inference-coordinator
ExecStart=/usr/local/bin/d-inference-run.sh
ExecStop=/usr/bin/docker stop -t 30 d-inference-coordinator

[Install]
WantedBy=multi-user.target
EOF

# ---- 6. Caddy config (TLS terminator + path routing for coordinator/step-ca/MicroMDM) ----
# Mirrors the prod coordinator/Caddyfile routes:
#   /scep, /mdm/*  -> MicroMDM (127.0.0.1:9002, HTTPS self-signed)
#   /acme/*        -> step-ca  (127.0.0.1:9000, HTTPS self-signed)
#   everything else -> coordinator (127.0.0.1:8080, HTTP)
# Without these routes, Mac enrollment fails with "SCEP server rejected."
cat > /etc/caddy/Caddyfile <<'CADDYFILE'
api.dev.darkbloom.xyz {
  # step-ca ACME proxy (device-attest-01 challenges)
  handle /acme/* {
    reverse_proxy https://127.0.0.1:9000 {
      transport http {
        tls_insecure_skip_verify
      }
      header_up Host {host}
    }
  }

  # MicroMDM — SCEP + MDM checkin/connect
  handle /scep {
    reverse_proxy https://127.0.0.1:9002 {
      transport http {
        tls_insecure_skip_verify
      }
    }
  }
  handle /mdm/* {
    reverse_proxy https://127.0.0.1:9002 {
      transport http {
        tls_insecure_skip_verify
      }
    }
  }

  # All other traffic -> coordinator (HTTP + WebSocket)
  reverse_proxy 127.0.0.1:8080 {
    health_uri /health
    health_interval 30s
    health_timeout 5s
    health_status 200
  }

  request_body {
    max_size 25MB
  }

  log {
    output stdout
    format console
    level INFO
  }
}
CADDYFILE

systemctl daemon-reload
systemctl enable cloud-sql-proxy.service d-inference-coordinator.service caddy.service
systemctl restart cloud-sql-proxy.service
systemctl restart d-inference-coordinator.service
systemctl restart caddy.service

echo "==> Startup complete at $(date -Iseconds)"
