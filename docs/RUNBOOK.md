# DGInf Runbook

## Architecture Overview

```
Consumer (browser)          Provider (Mac)              Coordinator (Linux)
  web/ (Next.js)              provider/ (Rust)            coordinator/ (Go)
       |                           |                           |
       |-- /api/* proxy ---------->|                           |
       |                           |-- WebSocket ------------->|
       |                           |   (register, heartbeat,   |
       |                           |    inference chunks)       |
       |                           |                           |
       |                           |-- Secure Enclave -------->| (attestation verify)
       |                           |                           |
       |                           |                           |-- MicroMDM (port 9002)
       |                           |                           |   (SecurityInfo verify)
       |                           |                           |
       |                           |<-- vllm-mlx (port 8100)  |
       |                           |   (in-process or subprocess)|
```

## Servers

| Server | IP | SSH | Purpose |
|--------|------|-----|---------|
| MDM/Coordinator | 34.197.17.112 | `ssh -i ~/.ssh/dginf-infra ubuntu@34.197.17.112` | Coordinator + MicroMDM + nginx |
| Mac M2 Provider | 54.90.55.137 | `ssh -i ~/.ssh/dginf-infra ec2-user@54.90.55.137` | Test provider (AWS mac2-m2.metal) |

## Building

### Provider (Rust, macOS ARM only)
```bash
cd provider
PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 cargo build --release
# Output: target/release/dginf-provider
```

### Enclave CLI (Swift, macOS only)
```bash
cd enclave
swift build -c release
# Output: .build/release/dginf-enclave
```

### Coordinator (Go, cross-compile for Linux)
```bash
cd coordinator
GOOS=linux GOARCH=amd64 go build -o dginf-coordinator-linux ./cmd/coordinator
```

### Web Frontend (Next.js)
```bash
cd web
npm install
npm run dev          # development
npx next build       # production build
```

## Deploying Coordinator

```bash
# Build
cd coordinator
GOOS=linux GOARCH=amd64 go build -o dginf-coordinator-linux ./cmd/coordinator

# Upload
scp -i ~/.ssh/dginf-infra dginf-coordinator-linux ubuntu@34.197.17.112:/tmp/dginf-coordinator

# Deploy
ssh -i ~/.ssh/dginf-infra ubuntu@34.197.17.112 '
  sudo fuser -k 8080/tcp 2>/dev/null
  sleep 1
  sudo cp /tmp/dginf-coordinator /usr/local/bin/dginf-coordinator
  sudo chmod +x /usr/local/bin/dginf-coordinator
  sudo bash -c "DGINF_PORT=8080 \
    DGINF_MDM_URL=https://localhost:9002 \
    DGINF_MDM_API_KEY=dginf-micromdm-api \
    nohup /usr/local/bin/dginf-coordinator > /var/log/dginf-coordinator.log 2>&1 &"
'

# Verify
curl -s http://34.197.17.112:8080/health
```

## Building & Uploading Provider Bundle

The provider bundle is a self-contained tarball with:
- `dginf-provider` (Rust binary, built with `--no-default-features` to avoid PyO3 linking)
- `dginf-enclave` (Swift Secure Enclave CLI)
- `ffmpeg` (static binary for audio transcription — no Homebrew needed)
- `stt_server.py` (speech-to-text server script)
- `python/` (Python 3.12 venv with vllm-mlx, mlx, mlx-lm, transformers, huggingface_hub)

### Automated build (recommended)

```bash
# Build everything and create tarball
./scripts/build-bundle.sh

# Build and upload to server
./scripts/build-bundle.sh --upload

# Skip Rust/Swift builds (reuse existing binaries)
./scripts/build-bundle.sh --skip-build --upload
```

The script handles: building binaries, creating the Python venv, stripping bloat,
including ffmpeg and stt_server.py, creating the tarball, and optionally uploading.

**ffmpeg:** Place a static macOS arm64 binary at `vendor/ffmpeg` or `/tmp/ffmpeg-macos-arm64`
before running `build-bundle.sh`. If not found, the script falls back to the system ffmpeg.
The installer will also attempt to download ffmpeg from the CDN if not bundled.

### Manual build (reference)

```bash
# 1. Build binaries (must be on macOS ARM)
cd provider && cargo build --release --no-default-features
cd ../enclave && swift build -c release

# 2. Create Python venv with inference deps
BUNDLE_DIR="/tmp/dginf-bundle"
rm -rf "$BUNDLE_DIR"
python3.12 -m venv "$BUNDLE_DIR/python"
source "$BUNDLE_DIR/python/bin/activate"
pip install vllm-mlx
deactivate

# 3. Strip unnecessary packages (torch, gradio, opencv, etc.)
cd "$BUNDLE_DIR/python/lib/python3.12/site-packages"
rm -rf torch* gradio* opencv* cv2* pandas* pyarrow* PIL* pillow* \
       sympy* networkx* mcp* miniaudio* pydub* datasets* Pillow*
find "$BUNDLE_DIR/python" -name __pycache__ -type d -exec rm -rf {} + 2>/dev/null || true

# 4. Copy binaries + assets into bundle
cp provider/target/release/dginf-provider "$BUNDLE_DIR/dginf-provider"
cp enclave/.build/release/dginf-enclave "$BUNDLE_DIR/dginf-enclave"
cp provider/stt_server.py "$BUNDLE_DIR/stt_server.py"
cp vendor/ffmpeg "$BUNDLE_DIR/ffmpeg"  # static macOS arm64 binary

# 5. Create tarball
cd /tmp && tar czf dginf-bundle-macos-arm64.tar.gz -C dginf-bundle .

# 6. Upload bundle + install script to server
./scripts/build-bundle.sh --skip-build --upload
```

### What happens on install

```bash
curl -fsSL https://inference-test.openinnovation.dev/install.sh | bash
```

The installer automatically: downloads the bundle, verifies the runtime, sets up
Secure Enclave identity, opens the MDM enrollment profile, downloads the best model
for the user's hardware, and starts the provider in the background.

## Provider Trust Levels

| Level | How it's assigned | Can serve inference? |
|-------|-------------------|---------------------|
| `none` | No attestation blob sent | No |
| `self_signed` | Secure Enclave P-256 signature verified | No |
| `hardware` | MDM independently confirmed SIP + SecureBoot | Yes |

Only `hardware` trust providers are routed requests.

### Trust upgrade flow:
1. Provider sends Secure Enclave attestation at WebSocket registration
2. Coordinator verifies P-256 signature → `self_signed`
3. Coordinator calls MicroMDM `/v1/devices` with serial number
4. MicroMDM sends SecurityInfo command to device
5. Device responds with SIP/SecureBoot/AuthRootVolume status
6. MicroMDM sends webhook to coordinator (`POST /v1/mdm/webhook`)
7. Coordinator cross-checks → upgrades to `hardware`

### Common issues:
- **"signature verification failed"**: Enclave key is stale. Delete `~/.dginf/enclave_key.data` and restart provider. (Auto-fixed in latest build.)
- **"device lookup failed"**: MDM can't reach MicroMDM. Check `DGINF_MDM_URL` is `https://localhost:9002` (not the public domain).
- **"no hardware-trusted provider"**: Provider didn't get upgraded. Check coordinator logs for MDM verification result.

## Provider Reconnection

- Provider uses exponential backoff: 1s, 2s, 4s, 8s, ... up to 60s max
- Backoff resets on clean WebSocket close (coordinator restart)
- Backoff does NOT reset on error (network issue) — grows until reconnect succeeds
- After coordinator restart, providers take ~1-60s to reconnect depending on backoff state

## SSE Streaming

The coordinator writes SSE chunks with `\n\n` separators:
```
data: {"choices":[{"delta":{"content":"Hi"}}]}\n\n
data: {"choices":[{"delta":{"content":"!"}}]}\n\n
data: [DONE]\n\n
```

The web frontend proxies through `/api/chat` (Next.js API route) to avoid CORS.
The proxy sets `X-Accel-Buffering: no` and streams chunks without buffering.

## Web Frontend (.env.local)

```
NEXT_PUBLIC_COORDINATOR_URL=http://34.197.17.112:8080
```

Code defaults to `http://localhost:8080`. The `.env.local` overrides for your machine.
The env var is used by both client-side code and API proxy routes.

## Key Files

| File | Purpose |
|------|---------|
| `coordinator/internal/api/consumer.go` | Chat completions, SSE streaming, trust headers |
| `coordinator/internal/api/provider.go` | WebSocket handler, attestation, MDM verification |
| `coordinator/internal/registry/registry.go` | Provider routing (hardware-trust filter) |
| `coordinator/internal/mdm/mdm.go` | MicroMDM API client |
| `provider/src/main.rs` | CLI, install, serve, model download, attestation generation |
| `provider/src/coordinator.rs` | WebSocket client with auto-reconnect |
| `provider/src/security.rs` | SIP check, PT_DENY_ATTACH, memory wiping |
| `provider/src/inference.rs` | In-process MLX inference via PyO3 |
| `provider/src/proxy.rs` | Subprocess inference proxy (vllm-mlx HTTP) |
| `enclave/Sources/DGInfEnclave/Attestation.swift` | Secure Enclave P-256 signing |
| `web/src/app/page.tsx` | Chat page with auto-key-generation |
| `web/src/lib/api.ts` | API client (all calls through /api/* proxy) |
| `scripts/install.sh` | One-line provider installer |
| `scripts/bundle-app.sh` | macOS .app bundle builder (production) |

## nginx Routes (inference-test.openinnovation.dev)

| Path | Backend |
|------|---------|
| `/install.sh` | Static file |
| `/dl/*` | Static files (binaries, bundle tarball) |
| `/health` | Coordinator :8080 |
| `/ws/` | Coordinator :8080 (WebSocket, proxy_read_timeout 86400) |
| `/v1/chat/` | Coordinator :8080 (proxy_buffering off) |
| `/v1/models` | Coordinator :8080 |
| `/v1/auth/` | Coordinator :8080 |
| `/v1/payments/` | Coordinator :8080 |
| `/v1/mdm/` | Coordinator :8080 |
| `/mdm/` | MicroMDM :9002 (TLS, proxy_ssl_verify off) |
| `/scep` | MicroMDM :9002 |
