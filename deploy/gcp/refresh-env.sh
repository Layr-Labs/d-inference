#!/bin/bash
# Atomically materialize the coordinator's root-only Docker env file from
# Google Secret Manager. Secret values are never printed.
set -euo pipefail

readonly METADATA_ATTRIBUTES=http://metadata.google.internal/computeMetadata/v1/instance/attributes
PROJECT=${2:-}
if [[ -z "$PROJECT" ]]; then
  PROJECT=$(curl -fsSL -H "Metadata-Flavor: Google" \
    "${METADATA_ATTRIBUTES}/DINF_GCP_PROJECT")
fi
[[ "$PROJECT" =~ ^[a-z][a-z0-9-]{4,28}[a-z0-9]$ ]] || {
  echo "FATAL: invalid DINF_GCP_PROJECT metadata" >&2
  exit 1
}
readonly PROJECT

ENVIRONMENT=${1:-dev}
case "$ENVIRONMENT" in
  dev)
    DOMAIN=api.dev.darkbloom.xyz
    CONSOLE_DOMAIN=console.dev.darkbloom.xyz
    DD_ENVIRONMENT=development
    ;;
  prod)
    DOMAIN=api.darkbloom.dev
    CONSOLE_DOMAIN=console.darkbloom.dev
    DD_ENVIRONMENT=production
    ;;
  *)
    echo "usage: refresh-env.sh {dev|prod}" >&2
    exit 64
    ;;
esac

readonly ENV_DIR=/etc/d-inference
readonly ENV_FILE=$ENV_DIR/env
readonly ENV_TMP=$ENV_FILE.tmp.$$
readonly SECRET_DIR=$ENV_DIR/secrets
readonly PRIVY_KEY_FILE=$SECRET_DIR/privy-verification-key
readonly PRIVY_KEY_TMP=$ENV_DIR/.privy-verification-key.$$
readonly SNAPSHOT_ROOT=$ENV_DIR/previous-known-good
readonly SNAPSHOT_POINTER=$ENV_DIR/previous-known-good.path
SNAPSHOT_PENDING=
SNAPSHOT_PATH=
mkdir -p "$ENV_DIR"
mkdir -p "$SECRET_DIR"
mkdir -p "$SNAPSHOT_ROOT"
chmod 700 "$ENV_DIR"
chmod 700 "$SECRET_DIR"
chmod 700 "$SNAPSHOT_ROOT"

cleanup() {
  rm -f "$ENV_TMP" "$PRIVY_KEY_TMP" "${SNAPSHOT_POINTER}.tmp.$$"
  if [[ -n "$SNAPSHOT_PENDING" ]]; then
    chmod -R u+w "$SNAPSHOT_PENDING" 2>/dev/null || true
    rm -rf "$SNAPSHOT_PENDING"
  fi
}
trap cleanup EXIT

fetch() {
  local name=$1
  local value
  value=$(gcloud --project="$PROJECT" --quiet secrets versions access latest \
    --secret="$name" 2>/dev/null || true)
  if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
    echo "FATAL: Secret Manager value $name must be a single line" >&2
    return 1
  fi
  printf '%s' "$value"
}

fetch_version() {
  local name=$1
  gcloud --project="$PROJECT" --quiet secrets versions describe latest \
    --secret="$name" --format='value(name)' 2>/dev/null || true
}

snapshot_previous_known_good() {
  [[ -r "$ENV_FILE" && -d "$SECRET_DIR" ]] || return 0
  local timestamp final entry
  timestamp=$(date -u +%Y%m%dT%H%M%SZ)
  final=$SNAPSHOT_ROOT/${timestamp}-$$
  [[ ! -e "$final" ]] || {
    echo "FATAL: previous-known-good snapshot path already exists" >&2
    return 1
  }
  SNAPSHOT_PENDING=$(mktemp -d "$SNAPSHOT_ROOT/.pending.XXXXXX")
  chmod 700 "$SNAPSHOT_PENDING"
  install -m 0600 "$ENV_FILE" "$SNAPSHOT_PENDING/env"
  mkdir -m 0700 "$SNAPSHOT_PENDING/secrets"
  cp -a "$SECRET_DIR/." "$SNAPSHOT_PENDING/secrets/"
  chmod -R a-w "$SNAPSHOT_PENDING"
  for entry in "$SNAPSHOT_PENDING/env" "$SNAPSHOT_PENDING/secrets"/* \
    "$SNAPSHOT_PENDING/secrets"/.[!.]*; do
    [[ ! -f "$entry" ]] || chmod 0400 "$entry"
  done
  chmod 0500 "$SNAPSHOT_PENDING/secrets" "$SNAPSHOT_PENDING"
  mv "$SNAPSHOT_PENDING" "$final"
  SNAPSHOT_PENDING=
  SNAPSHOT_PATH=$final
}

gcloud --project="$PROJECT" --quiet secrets versions access latest \
  --secret=eigeninference-privy-verification-key \
  >"$PRIVY_KEY_TMP" 2>/dev/null || true
chmod 600 "$PRIVY_KEY_TMP"

MDM_API_KEY=$(fetch eigeninference-micromdm-api-key)
MDM_PUSH_VERSION=$(fetch_version eigeninference-mdm-push-p12-b64)
MDM_PUSH_PASSWORD=$(fetch eigeninference-mdm-push-p12-password)
MDM_PUSH_PASSWORD=${MDM_PUSH_PASSWORD:-eigeninference}
cat >"$ENV_TMP" <<EOF
EIGENINFERENCE_PORT=8080
EIGENINFERENCE_RUST_BIND_ADDRESS=0.0.0.0:8080
EIGENINFERENCE_COORDINATOR_OWNERSHIP_ENABLED=true
EIGENINFERENCE_RUST_FULL_SURFACE_ENABLED=true
EIGENINFERENCE_RUST_PILOT_ENABLED=false
EIGENINFERENCE_RUST_PILOT_TRUST_FLOOR=hardware
EIGENINFERENCE_RUST_PILOT_STATE_DIRECTORY=/mnt/disks/userdata/rust-pilot
EIGENINFERENCE_RUST_TRUSTED_PROXY_CIDRS=127.0.0.1/32,::1/128
EIGENINFERENCE_RUST_STRIPE_ENABLED=true
EIGENINFERENCE_RUST_ENROLLMENT_ENABLED=false
EIGENINFERENCE_MIN_TRUST=hardware
EIGENINFERENCE_BILLING_MOCK=false
EIGENINFERENCE_BASE_URL=https://${DOMAIN}
EIGENINFERENCE_CONSOLE_URL=https://${CONSOLE_DOMAIN}
CORS_ORIGIN=https://${CONSOLE_DOMAIN}
DOMAIN=${DOMAIN}
APP_PORT=8080
EIGENINFERENCE_MDM_URL=https://localhost:9002
EIGENINFERENCE_ADMIN_EMAILS=gajesh@eigenlabs.org
EIGENINFERENCE_REFERRAL_SHARE_PCT=15
EIGENINFERENCE_R2_CDN_URL=$(fetch eigeninference-r2-cdn-url)
EIGENINFERENCE_ADMIN_KEY=$(fetch eigeninference-admin-key)
EIGENINFERENCE_RELEASE_KEY=$(fetch eigeninference-release-key)
EIGENINFERENCE_PRIVY_APP_ID=$(fetch eigeninference-privy-app-id)
EIGENINFERENCE_PRIVY_APP_SECRET=$(fetch eigeninference-privy-app-secret)
EIGENINFERENCE_PRIVY_VERIFICATION_KEY_FILE=/run/d-inference-secrets/privy-verification-key
EIGENINFERENCE_DATABASE_URL=$(fetch eigeninference-database-url)
MNEMONIC=$(fetch eigeninference-solana-mnemonic)
MICROMDM_API_KEY=${MDM_API_KEY}
EIGENINFERENCE_MDM_API_KEY=${MDM_API_KEY}
EIGENINFERENCE_MDM_WEBHOOK_SECRET=$(fetch eigeninference-mdm-webhook-secret)
MDM_PUSH_P12_B64=$(fetch eigeninference-mdm-push-p12-b64)
MDM_PUSH_P12_VERSION=${MDM_PUSH_VERSION}
MDM_PUSH_P12_PASSWORD=${MDM_PUSH_PASSWORD}
PROFILE_SIGNING_P12_B64=$(fetch eigeninference-profile-signing-p12-b64)
PROFILE_SIGNING_P12_PASSWORD=$(fetch eigeninference-profile-signing-p12-password)
EIGENINFERENCE_STRIPE_SECRET_KEY=$(fetch eigeninference-stripe-secret-key)
EIGENINFERENCE_STRIPE_WEBHOOK_SECRET=$(fetch eigeninference-stripe-webhook-secret)
EIGENINFERENCE_STRIPE_SUCCESS_URL=$(fetch eigeninference-stripe-success-url)
EIGENINFERENCE_STRIPE_CANCEL_URL=$(fetch eigeninference-stripe-cancel-url)
EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET=$(fetch eigeninference-stripe-connect-webhook-secret)
EIGENINFERENCE_STRIPE_CONNECT_RETURN_URL=$(fetch eigeninference-stripe-connect-return-url)
EIGENINFERENCE_STRIPE_CONNECT_REFRESH_URL=$(fetch eigeninference-stripe-connect-refresh-url)
EIGENINFERENCE_RUST_PROCESS_X25519_KEY_ID=$(fetch eigeninference-rust-x25519-key-id)
EIGENINFERENCE_RUST_PROCESS_X25519_PRIVATE_KEY=$(fetch eigeninference-rust-x25519-private-key)
EIGENINFERENCE_RUST_PROCESS_X25519_PUBLIC_KEY=$(fetch eigeninference-rust-x25519-public-key)
EIGENINFERENCE_IPAPI_KEY=$(fetch eigeninference-ipapi-key)
DD_API_KEY=$(fetch eigeninference-dd-api-key)
DD_SITE=$(fetch eigeninference-dd-site)
DD_ENV=${DD_ENVIRONMENT}
DD_SERVICE=d-inference-coordinator
DD_AGENT_HOST=localhost
EOF
unset MDM_API_KEY MDM_PUSH_VERSION MDM_PUSH_PASSWORD

CRITICAL_VARS=(
  EIGENINFERENCE_ADMIN_KEY
  EIGENINFERENCE_RELEASE_KEY
  EIGENINFERENCE_PRIVY_APP_ID
  EIGENINFERENCE_PRIVY_APP_SECRET
  EIGENINFERENCE_PRIVY_VERIFICATION_KEY_FILE
  EIGENINFERENCE_DATABASE_URL
  MNEMONIC
  MICROMDM_API_KEY
  EIGENINFERENCE_MDM_API_KEY
  EIGENINFERENCE_MDM_WEBHOOK_SECRET
  MDM_PUSH_P12_B64
  MDM_PUSH_P12_VERSION
  MDM_PUSH_P12_PASSWORD
  EIGENINFERENCE_STRIPE_SECRET_KEY
  EIGENINFERENCE_STRIPE_WEBHOOK_SECRET
  EIGENINFERENCE_STRIPE_SUCCESS_URL
  EIGENINFERENCE_STRIPE_CANCEL_URL
  EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET
  EIGENINFERENCE_STRIPE_CONNECT_RETURN_URL
  EIGENINFERENCE_STRIPE_CONNECT_REFRESH_URL
  EIGENINFERENCE_RUST_PROCESS_X25519_KEY_ID
  EIGENINFERENCE_RUST_PROCESS_X25519_PRIVATE_KEY
  EIGENINFERENCE_RUST_PROCESS_X25519_PUBLIC_KEY
)
MISSING=()
for var in "${CRITICAL_VARS[@]}"; do
  value=$(awk -v key="$var" '
    index($0, key "=") == 1 { print substr($0, length(key) + 2); found=1; exit }
    END { if (!found) exit 1 }
  ' "$ENV_TMP" || true)
  [[ -n "$value" ]] || MISSING+=("$var")
done

if [[ ! -s "$PRIVY_KEY_TMP" ]]; then
  MISSING+=(EIGENINFERENCE_PRIVY_VERIFICATION_KEY_FILE)
fi

if (( ${#MISSING[@]} > 0 )); then
  printf 'FATAL: required Secret Manager values are empty:' >&2
  printf ' %s' "${MISSING[@]}" >&2
  printf '\nExisting env file was left unchanged.\n' >&2
  exit 1
fi

snapshot_previous_known_good
if ! mv "$PRIVY_KEY_TMP" "$PRIVY_KEY_FILE"; then
  echo "FATAL: failed to install refreshed verification key" >&2
  exit 1
fi
chmod 600 "$ENV_TMP"
if ! mv "$ENV_TMP" "$ENV_FILE"; then
  if [[ -n "$SNAPSHOT_PATH" ]]; then
    install -m 0600 "$SNAPSHOT_PATH/secrets/privy-verification-key" \
      "$PRIVY_KEY_FILE"
  fi
  echo "FATAL: failed to install refreshed coordinator env" >&2
  exit 1
fi
if [[ -n "$SNAPSHOT_PATH" ]]; then
  pointer_tmp=$SNAPSHOT_POINTER.tmp.$$
  umask 077
  printf '%s\n' "$SNAPSHOT_PATH" >"$pointer_tmp"
  chmod 0400 "$pointer_tmp"
  mv "$pointer_tmp" "$SNAPSHOT_POINTER"
else
  rm -f "$SNAPSHOT_POINTER"
fi
trap - EXIT
echo "Coordinator env refreshed from Secret Manager for ${ENVIRONMENT}."
