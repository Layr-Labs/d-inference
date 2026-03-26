# DGInf - Decentralized GPU Inference

Decentralized inference network for Apple Silicon Macs. Providers offer GPU compute, consumers send OpenAI-compatible requests, coordinator matches them.

## Architecture

- **coordinator/** — Go. Central matchmaking server. Routes inference requests to providers. Runs on AWS (see deploy runbook below).
- **provider/** — Rust. Runs on Apple Silicon Macs. Connects to coordinator via WebSocket, proxies requests to local vllm-mlx/mlx-lm backend.
- **app/** — Swift (macOS). Menu bar app for managing the provider.
- **web/** — Next.js frontend served at `inference-test.openinnovation.dev`.

## Building & Testing

### Coordinator (Go)
```bash
cd coordinator
go test ./...
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dginf-coordinator-linux ./cmd/coordinator
```

### Provider (Rust)
```bash
cd provider
PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 cargo test
PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 cargo build --release
```
Note: `PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1` is needed if your Python version is newer than PyO3's max supported version.

## Deploying the Coordinator

The coordinator runs on AWS EC2 instance `dginf-mdm` at `inference-test.openinnovation.dev`.

Full deploy instructions: **[docs/coordinator-deploy-runbook.md](docs/coordinator-deploy-runbook.md)**

Quick deploy:
```bash
cd coordinator && \
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dginf-coordinator-linux ./cmd/coordinator && \
scp -i ~/.ssh/dginf-infra dginf-coordinator-linux ubuntu@34.197.17.112:/tmp/dginf-coordinator && \
ssh -i ~/.ssh/dginf-infra ubuntu@34.197.17.112 \
  'sudo systemctl stop dginf-coordinator && \
   sudo mv /tmp/dginf-coordinator /usr/local/bin/dginf-coordinator && \
   sudo chmod +x /usr/local/bin/dginf-coordinator && \
   sudo systemctl start dginf-coordinator'
```

## Key Design Decisions

- Providers are scored by decode TPS, trust level, reputation, warm model bonus, and live system health metrics (memory pressure, CPU, thermal state).
- In-flight inference requests are cancelled when the coordinator WebSocket disconnects (CancellationToken pattern).
- Backend (vllm-mlx) is idle-shutdown after 10 minutes of no requests to free GPU memory; lazy-reloaded on next request.
- E2E encryption: consumer requests are encrypted with provider's X25519 public key. Decryption happens inside the hardened provider process.
- Attestation: Secure Enclave signing + SIP/Secure Boot checks + periodic challenge-response verification.
