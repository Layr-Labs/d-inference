FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o coordinator ./cmd/coordinator

# Pre-built base with MicroMDM v1.13.1, step-ca v0.28.3, step CLI v0.28.3.
# Rebuild base only when tool versions change: docker build -f Dockerfile.base -t eigengajesh/d-inference-base:latest . && docker push
FROM eigengajesh/d-inference-base:v1-amd64

COPY --from=builder /app/coordinator /usr/local/bin/coordinator

RUN mkdir -p /var/www/html/dl

COPY deploy/Apple_Enterprise_Attestation_Root_CA.pem /opt/step-ca-seed/Apple_Enterprise_Attestation_Root_CA.pem
COPY deploy/acme-device.tpl /opt/step-ca-seed/acme-device.tpl

COPY Caddyfile /Caddyfile

COPY deploy/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

ENV EIGENINFERENCE_PORT=8080
ENV EIGENINFERENCE_MDM_URL=https://localhost:9002
ENV EIGENINFERENCE_MDM_API_KEY=eigeninference-micromdm-api
ENV EIGENINFERENCE_STEP_CA_ROOT=/data/step-ca/certs/root_ca.crt
ENV EIGENINFERENCE_STEP_CA_INTERMEDIATE=/data/step-ca/certs/intermediate_ca.crt

EXPOSE 8080
CMD ["start.sh"]
