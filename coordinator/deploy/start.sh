#!/bin/sh
set -e

COORDINATOR_BINARY=${EIGENINFERENCE_COORDINATOR_BINARY:-go}
case "$COORDINATOR_BINARY" in
    go)
        COORDINATOR_EXEC=/usr/local/bin/coordinator-go
        ;;
    rust)
        COORDINATOR_EXEC=/usr/local/bin/coordinator-rs
        ;;
    *)
        echo "EIGENINFERENCE_COORDINATOR_BINARY must be exactly go or rust" >&2
        exit 64
        ;;
esac
if [ ! -x "$COORDINATOR_EXEC" ]; then
    echo "selected coordinator binary is unavailable" >&2
    exit 70
fi

# EigenCloud persistent storage (survives upgrades via blue-green disk transfer).
PERSIST=${USER_PERSISTENT_DATA_PATH:-/mnt/disks/userdata}
mkdir -p "$PERSIST/micromdm"

# Symlink /data -> persistent storage so all components use the same paths.
ln -sfn "$PERSIST" /data

P12_CHECK=${COORDINATOR_P12_CHECK:-/usr/local/bin/coordinator-p12-check}
MDM_ROTATION_FAILURE=/data/micromdm/.push_rotation_failed

has_valid_uploaded_mdm_identity() {
    state=/data/micromdm/.push_imported
    [ -r "$state" ] &&
        [ -r /data/micromdm/push.crt ] &&
        [ -r /data/micromdm/push.key ] ||
        return 1
    state_hash=$(awk -F= '$1 == "hash" { print substr($0, 6); exit }' "$state")
    state_version=$(awk -F= '$1 == "version" { print substr($0, 9); exit }' "$state")
    case "$state_hash" in
        ''|*[!0-9a-f]*) return 1 ;;
    esac
    [ "${#state_hash}" -eq 64 ] && [ -n "$state_version" ] ||
        return 1
    "$P12_CHECK" installed mdm /data/micromdm/push.crt \
        /data/micromdm/push.key >/dev/null 2>&1
}

# ---- MicroMDM ----
if [ -n "$MICROMDM_API_KEY" ]; then
    EXISTING_MDM_IDENTITY=false
    if has_valid_uploaded_mdm_identity; then
        EXISTING_MDM_IDENTITY=true
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
    MDM_WEBHOOK_URL="http://localhost:8080/v1/mdm/webhook"
    if [ -n "${EIGENINFERENCE_MDM_WEBHOOK_SECRET:-}" ]; then
        MDM_WEBHOOK_URL="${MDM_WEBHOOK_URL}?token=${EIGENINFERENCE_MDM_WEBHOOK_SECRET}"
    fi

    echo "Starting MicroMDM..."
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

    # Wait for MicroMDM to be ready, then upload a new push certificate only
    # when its Secret Manager version or decoded content hash changed.
    sleep 2
    if [ -n "${MDM_PUSH_P12_B64:-}" ]; then
        mdmctl config set \
            -name eigeninference \
            -server-url "https://localhost:9002" \
            -api-token "${MICROMDM_API_KEY:-eigeninference-micromdm-api}" \
            -skip-verify
        if /usr/local/bin/mdm-cert-rotate; then
            rm -f "$MDM_ROTATION_FAILURE"
        else
            rotation_status=$?
            failure_tmp=${MDM_ROTATION_FAILURE}.tmp.$$
            umask 077
            printf 'failed_at=%s\nstatus=%s\n' \
                "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                "$rotation_status" >"$failure_tmp"
            mv "$failure_tmp" "$MDM_ROTATION_FAILURE"
            echo "MicroMDM push certificate rotation failed; metric=mdm.push_certificate_rotation_failure value=1" >&2
            if [ "$EXISTING_MDM_IDENTITY" != true ]; then
                echo "No valid previously uploaded MDM identity exists; refusing first-install startup" >&2
                exit "$rotation_status"
            fi
            echo "Preserving the valid uploaded MDM identity so rollback remains available." >&2
        fi
    fi
    echo "MicroMDM ready (port 9002)."
else
    echo "MICROMDM_API_KEY not set — skipping MicroMDM."
fi

# ---- Coordinator (PID 1 — receives SIGTERM from EigenCloud) ----
# Optional profile signing: the coordinator reads PROFILE_SIGNING_P12_B64 (+
# _PASSWORD) straight from the env and CMS-signs the /v1/enroll .mobileconfig.
# Inject via KMS like MDM_PUSH_P12_B64; unset/invalid → profiles served unsigned.
echo "Starting ${COORDINATOR_BINARY} coordinator..."
exec "$COORDINATOR_EXEC"
