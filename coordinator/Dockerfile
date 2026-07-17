FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .

# Build metadata stamped into the binary so /health is traceable to a commit.
# Cloud Build passes GIT_COMMIT/GIT_VERSION=$SHORT_SHA (deploy/gcp/cloudbuild.yaml);
# they default to dev/unknown for plain `docker build` so local images still work.
ARG GIT_COMMIT=unknown
ARG GIT_VERSION=dev
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a \
    -ldflags="-X github.com/eigeninference/d-inference/coordinator/api.BuildVersion=${GIT_VERSION} \
              -X github.com/eigeninference/d-inference/coordinator/api.BuildCommit=${GIT_COMMIT} \
              -X github.com/eigeninference/d-inference/coordinator/api.BuildDate=$(date -u +%Y-%m-%dT%H:%M:%SZ) \
              -X github.com/eigeninference/d-inference/coordinator/telemetry.CoordinatorVersion=${GIT_VERSION}" \
    -o /app/coordinator-bin ./coordinator/cmd/coordinator

# Pre-built base with MicroMDM v1.13.1 (also carries step-ca/step CLI, unused
# since the dormant ACME device-attest leg was removed).
# Rebuild base only when tool versions change: docker build -f Dockerfile.base -t eigengajesh/d-inference-base:latest . && docker push
FROM eigengajesh/d-inference-base:v1-amd64

COPY --from=builder /app/coordinator-bin /usr/local/bin/coordinator
RUN chmod +x /usr/local/bin/coordinator

RUN mkdir -p /var/www/html/dl

COPY coordinator/Caddyfile /Caddyfile

COPY coordinator/deploy/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

ENV EIGENINFERENCE_PORT=8080
ENV EIGENINFERENCE_MDM_URL=https://localhost:9002
ENV EIGENINFERENCE_MDM_API_KEY=eigeninference-micromdm-api

EXPOSE 8080
CMD ["start.sh"]
