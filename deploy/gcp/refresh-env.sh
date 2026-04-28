#!/bin/bash
# Regenerate /etc/d-inference/env from Google Secret Manager.
# Called by Cloud Build on every deploy so new env vars take effect
# without a VM reboot. Also called by vm-startup.sh on boot.
#
# Safety: writes to a temp file first, validates that critical secrets
# are non-empty, then atomically moves into place. A failed Secret
# Manager fetch will never blank the existing env file.
set -euo pipefail

ENV_DIR="/etc/d-inference"
ENV_FILE="${ENV_DIR}/env"
ENV_TMP="${ENV_FILE}.tmp.$$"

mkdir -p "$ENV_DIR"
chmod 700 "$ENV_DIR"

fetch() {
  gcloud --quiet secrets versions access latest --secret="$1" 2>/dev/null || true
}

cat > "$ENV_TMP" <<EOF
EIGENINFERENCE_PORT=8080
EIGENINFERENCE_MIN_TRUST=hardware
EIGENINFERENCE_BILLING_MOCK=false
EIGENINFERENCE_BASE_URL=https://api.dev.darkbloom.xyz
EIGENINFERENCE_CONSOLE_URL=https://console.dev.darkbloom.xyz
CORS_ORIGIN=https://console.dev.darkbloom.xyz
EIGENINFERENCE_R2_CDN_URL=$(fetch eigeninference-r2-cdn-url)
EIGENINFERENCE_SOLANA_RPC_URL=https://api.mainnet-beta.solana.com
EIGENINFERENCE_SOLANA_USDC_MINT=EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v
EIGENINFERENCE_ADMIN_EMAILS=gajesh@eigenlabs.org
EIGENINFERENCE_REFERRAL_SHARE_PCT=15
DOMAIN=api.dev.darkbloom.xyz
APP_PORT=8080
EIGENINFERENCE_MDM_URL=https://localhost:9002
EIGENINFERENCE_STEP_CA_ROOT=/data/step-ca/certs/root_ca.crt
EIGENINFERENCE_STEP_CA_INTERMEDIATE=/data/step-ca/certs/intermediate_ca.crt
EIGENINFERENCE_ADMIN_KEY=$(fetch eigeninference-admin-key)
EIGENINFERENCE_RELEASE_KEY=$(fetch eigeninference-release-key)
EIGENINFERENCE_PRIVY_APP_ID=$(fetch eigeninference-privy-app-id)
EIGENINFERENCE_PRIVY_APP_SECRET=$(fetch eigeninference-privy-app-secret)
EIGENINFERENCE_PRIVY_VERIFICATION_KEY=$(fetch eigeninference-privy-verification-key)
EIGENINFERENCE_DATABASE_URL=$(fetch eigeninference-database-url)
MNEMONIC=$(fetch eigeninference-solana-mnemonic)
MICROMDM_API_KEY=$(fetch eigeninference-micromdm-api-key)
EIGENINFERENCE_MDM_API_KEY=$(fetch eigeninference-micromdm-api-key)
MDM_PUSH_P12_B64=$(fetch eigeninference-mdm-push-p12-b64)
EIGENINFERENCE_STRIPE_SECRET_KEY=$(fetch eigeninference-stripe-secret-key)
EIGENINFERENCE_STRIPE_WEBHOOK_SECRET=$(fetch eigeninference-stripe-webhook-secret)
EIGENINFERENCE_STRIPE_SUCCESS_URL=$(fetch eigeninference-stripe-success-url)
EIGENINFERENCE_STRIPE_CANCEL_URL=$(fetch eigeninference-stripe-cancel-url)
EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET=$(fetch eigeninference-stripe-connect-webhook-secret)
EIGENINFERENCE_STRIPE_CONNECT_RETURN_URL=$(fetch eigeninference-stripe-connect-return-url)
EIGENINFERENCE_STRIPE_CONNECT_REFRESH_URL=$(fetch eigeninference-stripe-connect-refresh-url)
DD_API_KEY=$(fetch eigeninference-dd-api-key)
DD_SITE=$(fetch eigeninference-dd-site)
DD_ENV=development
DD_SERVICE=d-inference-coordinator
EOF

# Validate critical secrets before overwriting the live env file.
# A transient Secret Manager outage must never blank security-sensitive
# values — that would disable webhook signature verification and allow
# forged events to credit balances.
CRITICAL_VARS="EIGENINFERENCE_ADMIN_KEY EIGENINFERENCE_DATABASE_URL EIGENINFERENCE_STRIPE_SECRET_KEY EIGENINFERENCE_STRIPE_WEBHOOK_SECRET EIGENINFERENCE_STRIPE_CONNECT_WEBHOOK_SECRET"
MISSING=""
for var in $CRITICAL_VARS; do
  val=$(grep "^${var}=" "$ENV_TMP" | cut -d= -f2-)
  if [ -z "$val" ]; then
    MISSING="$MISSING $var"
  fi
done

if [ -n "$MISSING" ]; then
  echo "FATAL: critical secrets are empty:$MISSING"
  echo "Keeping existing env file to avoid security downgrade."
  rm -f "$ENV_TMP"
  exit 1
fi

chmod 600 "$ENV_TMP"
mv "$ENV_TMP" "$ENV_FILE"
echo "env refreshed: $(wc -l < "$ENV_FILE") lines, $(grep -c STRIPE "$ENV_FILE") Stripe vars"
