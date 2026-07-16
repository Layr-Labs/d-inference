FROM rust:1.88.0-alpine AS prompt-sidecar-builder
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
        http://promptsidecar/health | grep -q '"status":"ok"'; then break; fi; \
      [ "$attempt" -lt 10 ]; \
      sleep 0.1; \
    done; \
    kill -TERM "$pid"; \
    wait "$pid"; \
    trap - EXIT

FROM golang:1.25-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -a -o /app/coordinator-bin ./coordinator/cmd/coordinator

# Pre-built base with MicroMDM v1.13.1 (also carries step-ca/step CLI, unused
# since the dormant ACME device-attest leg was removed).
# Rebuild base only when tool versions change: docker build -f Dockerfile.base -t eigengajesh/d-inference-base:latest . && docker push
FROM eigengajesh/d-inference-base:v1-amd64

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
