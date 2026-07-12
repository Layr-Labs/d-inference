#!/bin/bash
# Idempotent GCE startup for dev and prod coordinator VMs. Serving migrations
# are deliberately absent: every schema change is an external deploy step.
set -euo pipefail
exec > >(tee /var/log/d-inference-startup.log) 2>&1

readonly META_ATTR="http://metadata.google.internal/computeMetadata/v1/instance/attributes"
readonly DATA_MOUNT=/mnt/disks/userdata
readonly ENV_DIR=/etc/d-inference

metadata_value() {
  curl -fsSL -H "Metadata-Flavor: Google" "$META_ATTR/$1"
}

metadata_value_optional() {
  metadata_value "$1" 2>/dev/null || true
}

install_metadata_file() {
  local attribute=$1
  local destination=$2
  local mode=$3
  local temporary
  temporary=$(mktemp)
  metadata_value "$attribute" >"$temporary"
  install -m "$mode" "$temporary" "$destination"
  rm -f "$temporary"
}

ENVIRONMENT=$(metadata_value_optional DINF_ENVIRONMENT)
ENVIRONMENT=${ENVIRONMENT:-dev}
[[ "$ENVIRONMENT" == "dev" || "$ENVIRONMENT" == "prod" ]] || {
  echo "invalid DINF_ENVIRONMENT metadata" >&2
  exit 1
}
PROJECT=$(metadata_value DINF_GCP_PROJECT)
[[ "$PROJECT" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || {
  echo "invalid DINF_GCP_PROJECT metadata" >&2
  exit 1
}
readonly PROJECT

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gnupg jq apt-transport-https util-linux

if ! command -v gcloud >/dev/null; then
  curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg |
    gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
    >/etc/apt/sources.list.d/google-cloud-sdk.list
  apt-get update
  apt-get install -y google-cloud-cli
fi

if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg |
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io
fi

if ! command -v caddy >/dev/null; then
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key |
    gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version main" \
    >/etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y caddy
fi

mkdir -p "$DATA_MOUNT"
if ! mountpoint -q "$DATA_MOUNT"; then
  DATA_DEV=$(metadata_value_optional DINF_DATA_DEVICE)
  if [[ -z "$DATA_DEV" && "$ENVIRONMENT" == "dev" ]]; then
    DATA_DEV=/dev/disk/by-id/google-d-inference-dev-data
  fi
  [[ -n "$DATA_DEV" && -b "$DATA_DEV" ]] || {
    echo "persistent data device metadata is required before startup" >&2
    exit 1
  }
  if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
    mkfs.ext4 -F "$DATA_DEV"
  fi
  mount -o noatime,discard "$DATA_DEV" "$DATA_MOUNT"
  grep -qF "$DATA_DEV $DATA_MOUNT " /etc/fstab ||
    echo "$DATA_DEV $DATA_MOUNT ext4 noatime,discard 0 2" >>/etc/fstab
fi

install -d -m 0700 "$ENV_DIR"
install -d -m 0755 /opt/d-inference/deploy
install -d -m 0755 /usr/share/doc/d-inference
install_metadata_file dinf-run-coordinator /opt/d-inference/deploy/run-coordinator.sh 0755
install_metadata_file dinf-run-recovery /opt/d-inference/deploy/run-recovery.sh 0755
install_metadata_file dinf-coordinator-unit \
  /opt/d-inference/deploy/d-inference-coordinator.service 0644
install_metadata_file dinf-recovery-unit \
  /opt/d-inference/deploy/d-inference-recovery.service 0644
install_metadata_file dinf-offline-recovery-doc \
  /usr/share/doc/d-inference/offline-recovery.md 0644
install_metadata_file dinf-configure-caddy \
  /usr/local/bin/d-inference-configure-caddy.sh 0755
install_metadata_file dinf-refresh-env /usr/local/bin/d-inference-refresh-env.sh 0755

install -m 0755 /opt/d-inference/deploy/run-coordinator.sh /usr/local/bin/d-inference-run.sh
install -m 0755 /opt/d-inference/deploy/run-recovery.sh /usr/local/bin/d-inference-recovery-run.sh
install -m 0644 /opt/d-inference/deploy/d-inference-coordinator.service \
  /etc/systemd/system/d-inference-coordinator.service
install -m 0644 /opt/d-inference/deploy/d-inference-recovery.service \
  /etc/systemd/system/d-inference-recovery.service

/usr/local/bin/d-inference-refresh-env.sh "$ENVIRONMENT" "$PROJECT"

if [[ "$ENVIRONMENT" == "dev" ]]; then
  if ! command -v cloud-sql-proxy >/dev/null; then
    curl -fsSL -o /usr/local/bin/cloud-sql-proxy \
      https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.11.0/cloud-sql-proxy.linux.amd64
    chmod 0755 /usr/local/bin/cloud-sql-proxy
  fi
  SQL_INSTANCE=$(metadata_value DINF_SQL_INSTANCE)
  [[ "$SQL_INSTANCE" =~ ^[a-z][a-z0-9-]{0,96}[a-z0-9]$ ]] || {
    echo "invalid DINF_SQL_INSTANCE metadata" >&2
    exit 1
  }
  SQL_CONN=$(gcloud sql instances describe "$SQL_INSTANCE" \
    --project="$PROJECT" --format='value(connectionName)')
  [[ -n "$SQL_CONN" ]] || {
    echo "failed to resolve dev Cloud SQL connection name" >&2
    exit 1
  }
  cat >/etc/systemd/system/cloud-sql-proxy.service <<EOF
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
  systemctl enable cloud-sql-proxy.service
fi

read_env_value() {
  local key=$1
  awk -v key="$key" '
    index($0, key "=") == 1 {
      print substr($0, length(key) + 2)
      found=1
      exit
    }
    END { if (!found) exit 1 }
  ' "$ENV_DIR/env"
}

DD_API_KEY_VALUE=$(read_env_value DD_API_KEY || true)
DD_SITE_VALUE=$(read_env_value DD_SITE || true)
if [[ -n "$DD_API_KEY_VALUE" ]]; then
  if ! command -v datadog-agent >/dev/null 2>&1; then
    DD_API_KEY="$DD_API_KEY_VALUE" DD_SITE="${DD_SITE_VALUE:-datadoghq.com}" \
      bash -c "$(curl -fsSL https://s3.amazonaws.com/dd-agent/scripts/install_script_agent7.sh)"
  fi
  usermod -a -G systemd-journal dd-agent
  install -d -m 0755 /etc/datadog-agent/conf.d/journald.d
  cat >/etc/datadog-agent/conf.d/journald.d/conf.yaml <<EOF
logs:
  - type: journald
    include_units:
      - d-inference-coordinator.service
      - d-inference-recovery.service
    service: d-inference-coordinator
    source: coordinator
    tags:
      - env:${ENVIRONMENT}
EOF
fi
unset DD_API_KEY_VALUE DD_SITE_VALUE

systemctl daemon-reload
systemctl enable docker.service caddy.service d-inference-coordinator.service
systemctl disable d-inference-recovery.service >/dev/null 2>&1 || true
[[ "$ENVIRONMENT" != "dev" ]] || systemctl restart cloud-sql-proxy.service
/usr/local/bin/d-inference-configure-caddy.sh "$ENVIRONMENT"
if [[ -n "$(metadata_value_optional DINF_IMAGE)" ]]; then
  systemctl restart d-inference-coordinator.service
else
  echo "DINF_IMAGE is not committed; coordinator remains stopped"
fi
