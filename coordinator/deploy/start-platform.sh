#!/bin/sh
set -e

# ============================================================================
# start-platform.sh — long-lived "platform" half of the blue-green split.
# (DAR-327 Phase 2)
#
# Owns the stateful, NON-swappable services so they survive a coordinator
# color flip untouched:
#   - the persistent /mnt/disks/userdata volume + the /data symlink
#   - step-ca (ACME device-attest-01 CA) on :9000, incl. first-boot init
#   - MicroMDM (SCEP + MDM checkin/connect) on :9002
#
# It does NOT start the coordinator. The coordinator runs in its own
# per-color container via start-coordinator.sh and is swapped behind Caddy.
#
# This is a faithful factoring of coordinator/deploy/start.sh (lines 1-125):
# the combined start.sh is intentionally LEFT UNCHANGED as the EigenCloud
# entrypoint. Keep this file diff-able against start.sh so the two stay in sync.
#
# MDM webhook coupling fix: start.sh hardcodes the command-webhook URL to
# http://localhost:8080/v1/mdm/webhook, which only works when the coordinator
# shares the container on :8080. In the split the active coordinator may be on
# :8080 (blue) or :8081 (green), so the webhook target is now configurable via
# EIGENINFERENCE_MDM_WEBHOOK_URL. In the GCE blue-green deployment the platform
# unit points it at a stable loopback Caddy listener
# (http://127.0.0.1:8090/v1/mdm/webhook) that imports the same (coordinator_routes)
# snippet as the public sites, so the SINGLE upstream swap in that snippet
# reroutes the webhook to the active color automatically. Default below keeps
# legacy localhost:8080 behavior for any combined-style use.
# ============================================================================

# EigenCloud / GCE persistent storage (survives upgrades + color swaps).
PERSIST=${USER_PERSISTENT_DATA_PATH:-/mnt/disks/userdata}
mkdir -p "$PERSIST/step-ca" "$PERSIST/micromdm"

# Symlink /data -> persistent storage so all components use the same paths.
ln -sfn "$PERSIST" /data

# ---- step-ca ----
if [ ! -d "/data/step-ca/config" ]; then
    echo "Initializing step-ca (first boot)..."
    mkdir -p /data/step-ca/secrets
    echo "eigeninference-step-ca" > /data/step-ca/secrets/password

    # Copy Apple attestation root CA and ACME template to persistent storage
    mkdir -p /data/step-ca/apple /data/step-ca/templates
    cp /opt/step-ca-seed/acme-device.tpl /data/step-ca/templates/

    STEPPATH=/data/step-ca step ca init \
        --name "Darkbloom CA" \
        --dns "${DOMAIN:-localhost}" \
        --address ":9000" \
        --provisioner "eigeninference-admin" \
        --password-file /data/step-ca/secrets/password \
        --deployment-type standalone \
        --acme 2>&1
    echo "step-ca initialized."

    # Patch ca.json: replace the default ACME provisioner with one configured
    # for device-attest-01 (Apple Secure Enclave attestation).
    echo "Configuring ACME device-attest-01 provisioner..."
    CA_JSON=/data/step-ca/config/ca.json
    jq '(.authority.provisioners[] | select(.type == "ACME")) |=
        {
            "type": "ACME",
            "name": "eigeninference-acme",
            "challenges": ["device-attest-01"],
            "attestationFormats": ["apple"],
            "forceCN": false,
            "options": {
                "x509": {
                    "templateFile": "/data/step-ca/templates/acme-device.tpl"
                }
            }
        }' "$CA_JSON" > /tmp/ca.json && mv /tmp/ca.json "$CA_JSON"
    echo "ACME provisioner configured."
fi
echo "Starting step-ca..."
STEPPATH=/data/step-ca step-ca /data/step-ca/config/ca.json \
    --password-file /data/step-ca/secrets/password \
    >> /data/step-ca.log 2>&1 &
STEP_CA_PID=$!
echo "step-ca started (port 9000, pid $STEP_CA_PID)."

# ---- MicroMDM ----
MICROMDM_PID=""
if [ -n "$MICROMDM_API_KEY" ]; then
    # Decode push cert from PKCS#12 bundle on first boot
    # P12 is base64url-encoded (no +/) to survive KMS/shell pipeline intact.
    if [ -n "$MDM_PUSH_P12_B64" ] && [ ! -f /data/micromdm/push.crt ]; then
        echo "Decoding MDM push certificate from PKCS#12..."
        printf '%s' "$MDM_PUSH_P12_B64" | tr '_-' '/+' | base64 -d > /tmp/push.p12
        openssl pkcs12 -in /tmp/push.p12 -clcerts -nokeys -passin pass:eigeninference \
            -out /data/micromdm/push.crt 2>/dev/null
        openssl pkcs12 -in /tmp/push.p12 -nocerts -nodes -passin pass:eigeninference \
            -out /tmp/push_pkcs8.key 2>/dev/null
        openssl rsa -in /tmp/push_pkcs8.key -traditional -out /data/micromdm/push.key 2>/dev/null
        rm -f /tmp/push.p12 /tmp/push_pkcs8.key
        chmod 600 /data/micromdm/push.key
        echo "Key format: $(head -1 /data/micromdm/push.key)"
    fi

    # Generate self-signed TLS cert for MicroMDM on first boot (internal only)
    if [ ! -f /data/micromdm/server.crt ]; then
        echo "Generating MicroMDM self-signed TLS cert..."
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout /data/micromdm/server.key \
            -out /data/micromdm/server.crt \
            -days 3650 -subj "/CN=localhost" 2>/dev/null
    fi

    # If the coordinator is configured with EIGENINFERENCE_MDM_WEBHOOK_SECRET it
    # rejects any MDM callback that doesn't present that secret. MicroMDM has no
    # option to set a header on the command webhook, so the shared secret rides
    # as a ?token= query param (the coordinator also accepts the X-Webhook-Token
    # header — see HandleMDMWebhook). These MUST stay in sync: setting the secret
    # on the coordinator without this token would 403 every legitimate
    # SecurityInfo/MDA callback and stall provider hardware-trust verification.
    #
    # Blue-green: the base URL is configurable so MicroMDM reaches the ACTIVE
    # coordinator color. Default stays localhost:8080 (legacy/combined). In the
    # split, the platform unit sets EIGENINFERENCE_MDM_WEBHOOK_URL to the stable
    # loopback Caddy webhook listener (http://127.0.0.1:8090/v1/mdm/webhook).
    MDM_WEBHOOK_URL="${EIGENINFERENCE_MDM_WEBHOOK_URL:-http://localhost:8080/v1/mdm/webhook}"
    if [ -n "${EIGENINFERENCE_MDM_WEBHOOK_SECRET:-}" ]; then
        MDM_WEBHOOK_URL="${MDM_WEBHOOK_URL}?token=${EIGENINFERENCE_MDM_WEBHOOK_SECRET}"
    fi

    echo "Starting MicroMDM (webhook -> ${EIGENINFERENCE_MDM_WEBHOOK_URL:-http://localhost:8080/v1/mdm/webhook})..."
    micromdm serve \
        -server-url "https://${DOMAIN:-localhost}" \
        -api-key "${MICROMDM_API_KEY:-eigeninference-micromdm-api}" \
        -filerepo /data/micromdm \
        -config-path /data/micromdm \
        -tls-cert /data/micromdm/server.crt \
        -tls-key /data/micromdm/server.key \
        -http-addr :9002 \
        -http-proxy-headers \
        -command-webhook-url "${MDM_WEBHOOK_URL}" \
        >> /data/micromdm.log 2>&1 &
    MICROMDM_PID=$!

    # Wait for MicroMDM to be ready, then import push cert if needed
    sleep 2
    if [ -f /data/micromdm/push.crt ] && [ ! -f /data/micromdm/.push_imported ]; then
        echo "Importing MDM push certificate..."
        mdmctl config set \
            -name eigeninference \
            -server-url "https://localhost:9002" \
            -api-token "${MICROMDM_API_KEY:-eigeninference-micromdm-api}" \
            -skip-verify
        mdmctl mdmcert upload \
            -cert /data/micromdm/push.crt \
            -private-key /data/micromdm/push.key \
            2>&1 || echo "Push cert import failed (may already exist)"
        touch /data/micromdm/.push_imported
    fi
    echo "MicroMDM ready (port 9002, pid $MICROMDM_PID)."
else
    echo "MICROMDM_API_KEY not set — skipping MicroMDM."
fi

# ---- Supervise (PID 1) ----
# The platform has no foreground process of its own (step-ca + MicroMDM run in
# the background above), so block here to keep the container alive and to
# forward termination signals. Exit non-zero if a critical child dies so the
# supervisor (systemd Restart=always, or EigenCloud) restarts the platform.
# shellcheck disable=SC2329  # invoked indirectly via `trap term TERM INT` below
term() {
    echo "platform: signal received — shutting down children..."
    kill "$STEP_CA_PID" 2>/dev/null || true
    if [ -n "${MICROMDM_PID:-}" ]; then
        kill "$MICROMDM_PID" 2>/dev/null || true
    fi
    exit 0
}
trap term TERM INT

echo "Platform ready (step-ca :9000$( [ -n "${MICROMDM_PID:-}" ] && printf ', MicroMDM :9002' )). Supervising..."
while kill -0 "$STEP_CA_PID" 2>/dev/null; do
    if [ -n "${MICROMDM_PID:-}" ]; then
        if ! kill -0 "$MICROMDM_PID" 2>/dev/null; then
            echo "platform: MicroMDM (pid $MICROMDM_PID) exited — restarting platform." >&2
            kill "$STEP_CA_PID" 2>/dev/null || true
            exit 1
        fi
    fi
    sleep 5
done

echo "platform: step-ca (pid $STEP_CA_PID) exited — restarting platform." >&2
exit 1
