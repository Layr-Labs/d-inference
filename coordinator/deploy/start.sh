#!/bin/sh
set -e

# ---- step-ca ----
if [ ! -d "/data/step-ca/config" ]; then
    echo "Initializing step-ca (first boot)..."
    mkdir -p /data/step-ca/secrets
    echo "eigeninference-step-ca" > /data/step-ca/secrets/password
    STEPPATH=/data/step-ca step ca init \
        --name "EigenInference CA" \
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
echo "step-ca started (port 9000)."

# ---- MicroMDM ----
if [ -n "$MICROMDM_API_KEY" ]; then
    # Decode push cert from env vars on first boot
    if [ -n "$MDM_PUSH_CERT_B64" ] && [ ! -f /data/micromdm/push.crt ]; then
        echo "Decoding MDM push certificate from env..."
        echo "$MDM_PUSH_CERT_B64" | base64 -d > /data/micromdm/push.crt
        echo "$MDM_PUSH_KEY_B64" | base64 -d > /tmp/push_raw.key
        # Convert PKCS#8 to traditional RSA format (mdmctl requires PKCS#1)
        openssl rsa -in /tmp/push_raw.key -out /data/micromdm/push.key 2>/dev/null || \
            cp /tmp/push_raw.key /data/micromdm/push.key
        rm -f /tmp/push_raw.key
        chmod 600 /data/micromdm/push.key
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
        -api-key "${MICROMDM_API_KEY:-eigeninference-micromdm-api}" \
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
    echo "MicroMDM ready (port 9002)."
else
    echo "MICROMDM_API_KEY not set — skipping MicroMDM."
fi

# ---- Coordinator (PID 1 — receives SIGTERM from EigenCloud) ----
echo "Starting coordinator..."
exec coordinator
