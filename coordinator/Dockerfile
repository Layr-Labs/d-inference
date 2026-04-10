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
COPY deploy/Apple_Enterprise_Attestation_Root_CA.pem /data/step-ca/apple/Apple_Enterprise_Attestation_Root_CA.pem

# ACME device-attest-01 certificate template.
COPY deploy/acme-device.tpl /data/step-ca/templates/acme-device.tpl

# Entrypoint.
COPY deploy/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

# Coordinator config defaults (DATABASE_URL must be overridden with external RDS).
ENV EIGENINFERENCE_PORT=8080
ENV EIGENINFERENCE_MDM_URL=https://localhost:9002
ENV EIGENINFERENCE_MDM_API_KEY=eigeninference-micromdm-api
ENV EIGENINFERENCE_STEP_CA_ROOT=/data/step-ca/certs/root_ca.crt
ENV EIGENINFERENCE_STEP_CA_INTERMEDIATE=/data/step-ca/certs/intermediate_ca.crt

EXPOSE 8080
CMD ["start.sh"]
