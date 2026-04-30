#!/bin/sh
set -e

# EigenCloud persistent storage (survives upgrades via blue-green disk transfer).
PERSIST=${USER_PERSISTENT_DATA_PATH:-/mnt/disks/userdata}
mkdir -p "$PERSIST/step-ca" "$PERSIST/micromdm"

# Symlink /data -> persistent storage so all components use the same paths.
ln -sfn "$PERSIST" /data

# ---- step-ca ----
if [ ! -d "/data/step-ca/config" ]; then
    echo "Initializing step-ca (first boot)..."
    mkdir -p /data/step-ca/secrets
    echo "darkbloom-step-ca" > /data/step-ca/secrets/password

    # Copy Apple attestation root CA and ACME template to persistent storage
    mkdir -p /data/step-ca/apple /data/step-ca/templates
    cp /opt/step-ca-seed/Apple_Enterprise_Attestation_Root_CA.pem /data/step-ca/apple/
    cp /opt/step-ca-seed/acme-device.tpl /data/step-ca/templates/

    STEPPATH=/data/step-ca step ca init \
        --name "Darkbloom CA" \
        --dns "${DOMAIN:-localhost}" \
        --address ":9000" \
        --provisioner "darkbloom-admin" \
        --password-file /data/step-ca/secrets/password \
        --deployment-type standalone \
        --acme 2>&1
    echo "step-ca initialized."

    # Patch ca.json: replace the default ACME provisioner with one configured
    # for device-attest-01 (Apple Secure Enclave attestation), and add a legacy
    # alias provisioner so already-enrolled devices can still renew certs.
    echo "Configuring ACME device-attest-01 provisioner..."
    CA_JSON=/data/step-ca/config/ca.json
    ACME_PROV='{
            "type": "ACME",
            "name": "darkbloom-acme",
            "challenges": ["device-attest-01"],
            "attestationFormats": ["apple"],
            "forceCN": false,
            "options": {
                "x509": {
                    "templateFile": "/data/step-ca/templates/acme-device.tpl"
                }
            }
        }'
    LEGACY_ACME_PROV='{
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
        }'
    jq --argjson acme "$ACME_PROV" --argjson legacy "$LEGACY_ACME_PROV" \
        '(.authority.provisioners[] | select(.type == "ACME")) |= $acme |
         .authority.provisioners += [$legacy]' \
        "$CA_JSON" > /tmp/ca.json && mv /tmp/ca.json "$CA_JSON"
    echo "ACME provisioner configured (darkbloom-acme + eigeninference-acme alias)."
fi
echo "Starting step-ca..."
STEPPATH=/data/step-ca step-ca /data/step-ca/config/ca.json \
    --password-file /data/step-ca/secrets/password \
    >> /data/step-ca.log 2>&1 &
echo "step-ca started (port 9000)."

# ---- MicroMDM ----
if [ -n "$MICROMDM_API_KEY" ]; then
    # Decode push cert from PKCS#12 bundle on first boot
    # P12 is base64url-encoded (no +/) to survive KMS/shell pipeline intact.
    if [ -n "$MDM_PUSH_P12_B64" ] && [ ! -f /data/micromdm/push.crt ]; then
        echo "Decoding MDM push certificate from PKCS#12..."
        printf '%s' "$MDM_PUSH_P12_B64" | tr '_-' '/+' | base64 -d > /tmp/push.p12
        openssl pkcs12 -in /tmp/push.p12 -clcerts -nokeys -passin pass:darkbloom \
            -out /data/micromdm/push.crt 2>/dev/null
        openssl pkcs12 -in /tmp/push.p12 -nocerts -nodes -passin pass:darkbloom \
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

    echo "Starting MicroMDM..."
    micromdm serve \
        -server-url "https://${DOMAIN:-localhost}" \
        -api-key "${MICROMDM_API_KEY:-darkbloom-micromdm-api}" \
        -filerepo /data/micromdm \
        -config-path /data/micromdm \
        -tls-cert /data/micromdm/server.crt \
        -tls-key /data/micromdm/server.key \
        -http-addr :9002 \
        -http-proxy-headers \
        -command-webhook-url http://localhost:8080/v1/mdm/webhook \
        >> /data/micromdm.log 2>&1 &

    # Wait for MicroMDM to be ready, then import push cert if needed
    sleep 2
    if [ -f /data/micromdm/push.crt ] && [ ! -f /data/micromdm/.push_imported ]; then
        echo "Importing MDM push certificate..."
        mdmctl config set \
            -name darkbloom \
            -server-url "https://localhost:9002" \
            -api-token "${MICROMDM_API_KEY:-darkbloom-micromdm-api}" \
            -skip-verify
        mdmctl mdmcert upload \
            -cert /data/micromdm/push.crt \
            -private-key /data/micromdm/push.key \
            2>&1 || echo "Push cert import failed (may already exist)"
        touch /data/micromdm/.push_imported
    fi
    echo "MicroMDM ready (port 9002)."
else
    echo "MICROMDM_API_KEY not set — skipping MicroMDM."
fi

# ---- Coordinator (PID 1 — receives SIGTERM from EigenCloud) ----
echo "Starting coordinator..."
exec coordinator
