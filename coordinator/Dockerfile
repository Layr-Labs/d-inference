ARG GO_VERSION=1.25.0
ARG ALPINE_VERSION=3.21
ARG RUST_VERSION=1.97.0
ARG BUILD_VERSION=dev
ARG BUILD_COMMIT=unknown
ARG BUILD_DATE=unknown

FROM --platform=linux/amd64 golang:${GO_VERSION}-alpine${ALPINE_VERSION}@sha256:c8e1680f8002c64ddfba276a3c1f763097cb182402673143a89dcca4c107cf17 AS go-builder
ARG BUILD_VERSION
ARG BUILD_COMMIT
ARG BUILD_DATE
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY coordinator ./coordinator
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -trimpath -buildvcs=false \
    -ldflags="-s -w \
      -X github.com/eigeninference/d-inference/coordinator/api.BuildVersion=${BUILD_VERSION} \
      -X github.com/eigeninference/d-inference/coordinator/api.BuildCommit=${BUILD_COMMIT} \
      -X github.com/eigeninference/d-inference/coordinator/api.BuildDate=${BUILD_DATE}" \
    -o /out/coordinator-go ./coordinator/cmd/coordinator
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -trimpath -buildvcs=false -ldflags="-s -w" \
    -o /out/coordinator-migrate ./coordinator/cmd/migrate

FROM --platform=linux/amd64 rust:${RUST_VERSION}-alpine${ALPINE_VERSION}@sha256:8a34d94926e597c8755508a468ece234b6dbbe21d80c28ed77630f21e4b8e987 AS rust-builder
ARG BUILD_VERSION
ARG BUILD_COMMIT
ARG BUILD_DATE
RUN apk add --no-cache build-base clang cmake lld musl-dev ninja perl
WORKDIR /src/coordinator-rs
COPY coordinator-rs/Cargo.toml coordinator-rs/Cargo.lock ./
COPY coordinator-rs/crates ./crates
COPY coordinator-rs/.sqlx ./.sqlx
COPY tests/contracts /src/tests/contracts
COPY coordinator/api/install.sh /src/coordinator/api/install.sh
ENV CARGO_PROFILE_RELEASE_LTO=true \
    CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 \
    CARGO_PROFILE_RELEASE_STRIP=symbols \
    SQLX_OFFLINE=true \
    DARKBLOOM_BUILD_VERSION=${BUILD_VERSION} \
    DARKBLOOM_BUILD_COMMIT=${BUILD_COMMIT} \
    DARKBLOOM_BUILD_DATE=${BUILD_DATE}
RUN cargo build --release --locked --package darkbloom-coordinator-server \
    && cp target/release/darkbloom-coordinator-server /out-coordinator-rs

# Pre-built base with MicroMDM v1.13.1 (also carries step-ca/step CLI, unused
# since the dormant ACME device-attest leg was removed).
# Rebuild base only when tool versions change: docker build -f Dockerfile.base -t eigengajesh/d-inference-base:latest . && docker push
FROM --platform=linux/amd64 eigengajesh/d-inference-base:v1-amd64@sha256:4ea05ea089ac61f8d5999f175fbfaeb20171f74cf721dac7ce278a4f28fe9671

# The pinned v1 base predates the authenticated MicroMDM curl preflight. Keep
# this explicit until the next pinned base revision includes Dockerfile.base.
RUN apk add --no-cache curl

COPY --from=go-builder /out/coordinator-go /usr/local/bin/coordinator-go
COPY --from=go-builder /out/coordinator-migrate /usr/local/bin/coordinator-migrate
COPY --from=rust-builder /out-coordinator-rs /usr/local/bin/coordinator-rs
RUN chmod 0755 \
      /usr/local/bin/coordinator-go \
      /usr/local/bin/coordinator-rs \
      /usr/local/bin/coordinator-migrate \
    && ln -s coordinator-go /usr/local/bin/coordinator

RUN mkdir -p /var/www/html/dl

COPY coordinator/Caddyfile /Caddyfile

COPY coordinator/deploy/start.sh /usr/local/bin/start.sh
COPY coordinator/deploy/image-check.sh /usr/local/bin/coordinator-image-check
COPY coordinator/deploy/healthcheck.sh /usr/local/bin/coordinator-healthcheck
COPY coordinator/deploy/mdm-cert-rotate.sh /usr/local/bin/mdm-cert-rotate
COPY coordinator/deploy/p12-check.sh /usr/local/bin/coordinator-p12-check
COPY coordinator/deploy/micromdm-api-check.sh /usr/local/bin/micromdm-api-check
RUN chmod 0755 \
      /usr/local/bin/start.sh \
      /usr/local/bin/coordinator-image-check \
      /usr/local/bin/coordinator-healthcheck \
      /usr/local/bin/mdm-cert-rotate \
      /usr/local/bin/coordinator-p12-check \
      /usr/local/bin/micromdm-api-check \
    && /usr/local/bin/coordinator-image-check smoke

ENV EIGENINFERENCE_PORT=8080
ENV EIGENINFERENCE_MDM_URL=https://localhost:9002
ENV EIGENINFERENCE_MDM_API_KEY=eigeninference-micromdm-api
ENV EIGENINFERENCE_COORDINATOR_BINARY=go

EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=6s --start-period=60s --retries=3 \
    CMD ["/usr/local/bin/coordinator-healthcheck"]
CMD ["/usr/local/bin/start.sh"]
