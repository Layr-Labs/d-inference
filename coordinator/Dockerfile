FROM rust:1.88.0-alpine@sha256:9dfaae478ecd298b6b5a039e1f2cc4fc040fc818a2de9aa78fa714dea036574d AS prompt-sidecar-builder
ARG BUILDARCH
ARG TARGETARCH
RUN apk add --no-cache curl file musl-dev
WORKDIR /app/coordinator/promptsidecar
COPY coordinator/promptsidecar/Cargo.toml coordinator/promptsidecar/Cargo.lock ./
COPY coordinator/promptsidecar/src ./src
RUN rustup target add x86_64-unknown-linux-musl
RUN cargo build --locked --release --target x86_64-unknown-linux-musl --bin promptsidecar
RUN file target/x86_64-unknown-linux-musl/release/promptsidecar | grep -Eq "statically linked|static-pie linked"
RUN if [ "$BUILDARCH" != "$TARGETARCH" ]; then \
      echo "cross-architecture runtime smoke deferred to native linux/amd64 CI"; \
      exit 0; \
    fi; \
    set -eux; \
    mkdir -m 0700 /run/prompt-sidecar-test /tmp/prompt-artifacts; \
    target/x86_64-unknown-linux-musl/release/promptsidecar \
      --socket /run/prompt-sidecar-test/prompt.sock \
      --artifact-root /tmp/prompt-artifacts & \
    pid=$!; \
    trap 'kill -TERM "$pid" 2>/dev/null || true' EXIT; \
    for attempt in 1 2 3 4 5 6 7 8 9 10; do \
      if curl --fail --silent --unix-socket /run/prompt-sidecar-test/prompt.sock \
        http://promptsidecar/health | grep -q '"status":"starting","ready":false'; then break; fi; \
      [ "$attempt" -lt 10 ]; \
      sleep 0.1; \
    done; \
    kill -TERM "$pid"; \
    wait "$pid"; \
    trap - EXIT

FROM golang:1.25-alpine@sha256:56961d79ea8129efddcc0b8643fd8a5416b4e6228cfd477e3fd61deb2672c587 AS builder
ARG BUILD_VERSION=dev
ARG BUILD_COMMIT=unknown
ARG BUILD_DATE=unknown
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN test -n "$BUILD_VERSION" && test -n "$BUILD_COMMIT" && test -n "$BUILD_DATE" && \
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a \
      -ldflags="-s -w \
        -X github.com/eigeninference/d-inference/coordinator/api.BuildVersion=$BUILD_VERSION \
        -X github.com/eigeninference/d-inference/coordinator/api.BuildCommit=$BUILD_COMMIT \
        -X github.com/eigeninference/d-inference/coordinator/api.BuildDate=$BUILD_DATE \
        -X github.com/eigeninference/d-inference/coordinator/telemetry.CoordinatorVersion=$BUILD_VERSION" \
      -o /app/coordinator-bin ./coordinator/cmd/coordinator

# Pre-built base with MicroMDM v1.13.1 (also carries step-ca/step CLI, unused
# since the dormant ACME device-attest leg was removed).
# Rebuild base only when tool versions change: docker build -f Dockerfile.base -t eigengajesh/d-inference-base:latest . && docker push
FROM eigengajesh/d-inference-base:v1-amd64@sha256:4ea05ea089ac61f8d5999f175fbfaeb20171f74cf721dac7ce278a4f28fe9671
ARG BUILD_VERSION=dev
ARG BUILD_COMMIT=unknown
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.source="https://github.com/Layr-Labs/d-inference" \
      org.opencontainers.image.version="$BUILD_VERSION" \
      org.opencontainers.image.revision="$BUILD_COMMIT" \
      org.opencontainers.image.created="$BUILD_DATE"

COPY --from=builder /app/coordinator-bin /usr/local/bin/coordinator
COPY --from=prompt-sidecar-builder /app/coordinator/promptsidecar/target/x86_64-unknown-linux-musl/release/promptsidecar /usr/local/bin/promptsidecar
RUN chmod +x /usr/local/bin/coordinator

RUN mkdir -p /var/www/html/dl

COPY coordinator/Caddyfile /Caddyfile

COPY coordinator/deploy/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

ENV EIGENINFERENCE_PORT=8080
ENV EIGENINFERENCE_MDM_URL=https://localhost:9002
ENV EIGENINFERENCE_MDM_API_KEY=eigeninference-micromdm-api
ENV EIGENINFERENCE_PROMPT_SIDECAR_BINARY=/usr/local/bin/promptsidecar

EXPOSE 8080
CMD ["start.sh"]
