FROM golang:1.24-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o coordinator ./cmd/coordinator

# Download MicroMDM and step-ca binaries.
FROM alpine:3.21 AS fetcher
RUN apk add --no-cache curl tar
# MicroMDM v1.12.1
RUN curl -fsSL https://github.com/micromdm/micromdm/releases/download/v1.12.1/micromdm_v1.12.1_linux_amd64.tar.gz \
    | tar -xz -C /tmp && mv /tmp/build/linux/micromdm /usr/local/bin/micromdm \
    && mv /tmp/build/linux/mdmctl /usr/local/bin/mdmctl
# step-ca (Smallstep)
RUN curl -fsSL https://dl.smallstep.com/gh-release/certificates/gh-release-header/v0.28.3/step-ca_linux_0.28.3_amd64.tar.gz \
    | tar -xz -C /tmp && mv /tmp/step-ca_0.28.3/bin/step-ca /usr/local/bin/step-ca
RUN curl -fsSL https://dl.smallstep.com/gh-release/cli/gh-release-header/v0.28.3/step_linux_0.28.3_amd64.tar.gz \
    | tar -xz -C /tmp && mv /tmp/step_0.28.3/bin/step /usr/local/bin/step

FROM alpine:3.21
RUN apk add --no-cache ca-certificates su-exec openssl

# Binaries.
COPY --from=builder /app/coordinator /usr/local/bin/coordinator
COPY --from=fetcher /usr/local/bin/micromdm /usr/local/bin/micromdm
COPY --from=fetcher /usr/local/bin/mdmctl /usr/local/bin/mdmctl
COPY --from=fetcher /usr/local/bin/step-ca /usr/local/bin/step-ca
COPY --from=fetcher /usr/local/bin/step /usr/local/bin/step

# Static files served by Caddy (install script, bundles, enrollment profile).
RUN mkdir -p /var/www/html/dl

# Persistent data directories.
RUN mkdir -p /data/micromdm /data/step-ca

# Apple Enterprise Attestation Root CA — required for device-attest-01 verification.
COPY <<'APPLE_CA' /data/step-ca/apple/Apple_Enterprise_Attestation_Root_CA.pem
-----BEGIN CERTIFICATE-----
MIICJDCCAamgAwIBAgIUQsDCuyxyfFxeq/bxpm8frF15hzcwCgYIKoZIzj0EAwMw
UTEtMCsGA1UEAwwkQXBwbGUgRW50ZXJwcmlzZSBBdHRlc3RhdGlvbiBSb290IENB
MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzAeFw0yMjAyMTYxOTAx
MjRaFw00NzAyMjAwMDAwMDBaMFExLTArBgNVBAMMJEFwcGxlIEVudGVycHJpc2Ug
QXR0ZXN0YXRpb24gUm9vdCBDQTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UE
BhMCVVMwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAAT6Jigq+Ps9Q4CoT8t8q+UnOe2p
oT9nRaUfGhBTbgvqSGXPjVkbYlIWYO+1zPk2Sz9hQ5ozzmLrPmTBgEWRcHjA2/y7
7GEicps9wn2tj+G89l3INNDKETdxSPPIZpPj8VmjQjBAMA8GA1UdEwEB/wQFMAMB
Af8wHQYDVR0OBBYEFPNqTQGd8muBpV5du+UIbVbi+d66MA4GA1UdDwEB/wQEAwIB
BjAKBggqhkjOPQQDAwNpADBmAjEA1xpWmTLSpr1VH4f8Ypk8f3jMUKYz4QPG8mL5
8m9sX/b2+eXpTv2pH4RZgJjucnbcAjEA4ZSB6S45FlPuS/u4pTnzoz632rA+xW/T
ZwFEh9bhKjJ+5VQ9/Do1os0u3LEkgN/r
-----END CERTIFICATE-----
APPLE_CA

# ACME device-attest-01 certificate template.
COPY <<'ACME_TPL' /data/step-ca/templates/acme-device.tpl
{
  "subject": {{ toJson .Insecure.CR.Subject }},
  "sans": {{ toJson .SANs }},
  {{- if typeIs "*rsa.PublicKey" .Insecure.CR.PublicKey }}
  "keyUsage": ["keyEncipherment", "digitalSignature"],
  {{- else }}
  "keyUsage": ["digitalSignature"],
  {{- end }}
  "extKeyUsage": ["serverAuth", "clientAuth"]
}
ACME_TPL

# Coordinator config defaults (DATABASE_URL must be overridden with external RDS).
ENV EIGENINFERENCE_PORT=8080
ENV EIGENINFERENCE_MDM_URL=https://localhost:9002
ENV EIGENINFERENCE_MDM_API_KEY=eigeninference-micromdm-api
ENV EIGENINFERENCE_STEP_CA_ROOT=/data/step-ca/certs/root_ca.crt
ENV EIGENINFERENCE_STEP_CA_INTERMEDIATE=/data/step-ca/certs/intermediate_ca.crt

COPY <<'STARTSCRIPT' /usr/local/bin/start.sh
#!/bin/sh
set -e

# ---- step-ca ----
if [ ! -d "/data/step-ca/config" ]; then
    echo "Initializing step-ca (first boot)..."
    mkdir -p /data/step-ca/secrets
    echo "eigeninference-step-ca" > /data/step-ca/secrets/password
    step ca init \
        --name "EigenInference CA" \
        --dns "${DOMAIN:-localhost}" \
        --address ":9000" \
        --provisioner "eigeninference-admin" \
        --password-file /data/step-ca/secrets/password \
        --deployment-type standalone \
        --path /data/step-ca 2>&1
    echo "step-ca initialized."

    # Add ACME provisioner for device-attest-01 (Apple Secure Enclave attestation)
    echo "Adding ACME device-attest-01 provisioner..."
    STEPPATH=/data/step-ca step ca provisioner add eigeninference-acme \
        --type ACME \
        --challenge device-attest-01 \
        --attestation-format apple \
        --attestation-roots /data/step-ca/apple/Apple_Enterprise_Attestation_Root_CA.pem \
        --x509-template /data/step-ca/templates/acme-device.tpl \
        --admin-provisioner eigeninference-admin \
        --admin-password-file /data/step-ca/secrets/password \
        2>&1 || echo "ACME provisioner may already exist"
    echo "ACME provisioner configured."
fi
echo "Starting step-ca..."
step-ca /data/step-ca/config/ca.json \
    --password-file /data/step-ca/secrets/password \
    >> /data/step-ca.log 2>&1 &
echo "step-ca started (port 9000)."

# ---- MicroMDM ----
if [ -n "$MICROMDM_API_KEY" ]; then
    # Decode push cert from env vars on first boot
    if [ -n "$MDM_PUSH_CERT_B64" ] && [ ! -f /data/micromdm/push.crt ]; then
        echo "Decoding MDM push certificate from env..."
        echo "$MDM_PUSH_CERT_B64" | base64 -d > /data/micromdm/push.crt
        echo "$MDM_PUSH_KEY_B64" | base64 -d > /data/micromdm/push.key
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
STARTSCRIPT

RUN chmod +x /usr/local/bin/start.sh

EXPOSE 8080
CMD ["start.sh"]
