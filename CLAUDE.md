# DGInf - Decentralized GPU Inference

Decentralized inference network for Apple Silicon Macs. Providers offer GPU compute, consumers send OpenAI-compatible requests, the coordinator matches them.

## Project Structure

```
coordinator/          Go — central matchmaking server (runs on AWS)
├── cmd/coordinator/  entrypoint
├── internal/
│   ├── api/          HTTP + WebSocket handlers (consumer.go, provider.go, server.go)
│   ├── attestation/  Secure Enclave + MDA attestation verification
│   ├── e2e/          End-to-end encryption (X25519 key exchange)
│   ├── mdm/          MicroMDM integration for device attestation
│   ├── payments/     Token billing and pricing (pathUSD on Tempo blockchain)
│   ├── protocol/     WebSocket message types shared with provider
│   ├── registry/     Provider registry, scoring, reputation, request queue
│   └── store/        Persistence (in-memory or Postgres)

provider/             Rust — runs on Apple Silicon Macs
├── src/
│   ├── main.rs       CLI entry, serve command, event loop, idle timeout
│   ├── coordinator.rs WebSocket client with auto-reconnect
│   ├── proxy.rs      Forwards requests to local vllm-mlx via HTTP (with CancellationToken)
│   ├── hardware.rs   Apple Silicon detection, system metrics (memory/CPU/thermal)
│   ├── protocol.rs   Message types (mirrors coordinator/internal/protocol)
│   ├── backend/      Backend process management (vllm_mlx.rs, health checks)
│   ├── crypto.rs     X25519 key pair (NaCl), E2E decryption
│   ├── security.rs   SIP checks, binary self-hash, anti-debug
│   ├── models.rs     Scans ~/.cache/huggingface for available models
│   ├── wallet.rs     Tempo blockchain wallet (secp256k1)
│   ├── config.rs     TOML config + hardware-based defaults
│   ├── inference.rs  In-process MLX inference (behind "python" feature flag)
│   └── server.rs     Local HTTP server (standalone mode without coordinator)

app/DGInf/            Swift — macOS menu bar app (SwiftUI)
├── Sources/DGInf/
│   ├── DGInfApp.swift        App entry, menu bar setup
│   ├── StatusViewModel.swift Core state management
│   ├── DashboardView.swift   Main dashboard
│   ├── SettingsView.swift    Preferences
│   ├── CLIRunner.swift       Launches dginf-provider as subprocess
│   └── ...                   Other views (Wallet, Benchmark, Doctor, etc.)

enclave/              Swift — Secure Enclave attestation CLI helper
├── Sources/
│   ├── DGInfEnclave/         Library (P-256 key generation, attestation blob signing)
│   └── DGInfEnclaveCLI/      CLI tool (invoked by provider at startup)

scripts/
├── bundle-app.sh     Builds code-signed .app bundle + .dmg
├── install.sh        curl one-liner installer served from coordinator
└── entitlements.plist Hardened Runtime entitlements

web/                  Next.js frontend (verification panel)
```

## Building & Testing

### Coordinator (Go)
```bash
cd coordinator
go test ./...
# Cross-compile for AWS (Linux amd64):
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dginf-coordinator-linux ./cmd/coordinator
```

### Provider (Rust)
```bash
cd provider
PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 cargo test
PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 cargo build --release
```
The `PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1` env var is required when local Python version exceeds PyO3's max supported version (e.g. Python 3.14 with PyO3 0.24).

To build without the Python in-process inference feature (needed for the distributed bundle):
```bash
cargo build --release --no-default-features
```

### macOS App (Swift)
```bash
cd app/DGInf
swift build -c release
swift test
```

### Enclave Helper (Swift)
```bash
cd enclave
swift build -c release
```

## Deploying

Full deploy runbook: **[docs/coordinator-deploy-runbook.md](docs/coordinator-deploy-runbook.md)**

Covers coordinator deploy, provider CLI bundling, macOS app distribution, and install.sh updates.

### Coordinator (quick deploy)
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

### Provider bundle (quick upload)
```bash
# After building provider + enclave:
scp -i ~/.ssh/dginf-infra /tmp/dginf-bundle/dginf-bundle-macos-arm64.tar.gz \
  ubuntu@34.197.17.112:/var/www/html/dl/
```

## Infrastructure

| Component | Location | Details |
|-----------|----------|---------|
| Coordinator | AWS EC2 `dginf-mdm` | t3.small, `34.197.17.112` (Elastic IP), systemd service |
| Domain | `inference-test.openinnovation.dev` | nginx → localhost:8080, Let's Encrypt TLS |
| SSH | `ssh -i ~/.ssh/dginf-infra ubuntu@34.197.17.112` | Key name: `dginf-infra` |
| AWS Profile | `admin` | Account 084828557146 |
| Provider install | `curl -fsSL https://inference-test.openinnovation.dev/install.sh \| bash` | Downloads tarball from `/dl/` |

## Key Design Decisions

- **Provider scoring**: decode TPS × trust multiplier × reputation × warm model bonus × health factor. Health factor uses live system metrics (memory pressure, CPU usage, thermal state) reported in heartbeats.
- **Request cancellation**: In-flight inference requests are tracked by request_id with CancellationToken. On coordinator disconnect, all in-flight requests are cancelled and the HTTP connection to vllm-mlx is dropped so it stops generating.
- **Idle GPU timeout**: Backend (vllm-mlx) process is killed after 10 minutes of no requests to free GPU memory. Lazy-reloaded when the next request arrives (cold-start penalty of ~10-30s for model reload).
- **E2E encryption**: Consumer requests encrypted with provider's X25519 public key (NaCl box). Coordinator never sees plaintext prompts. Decryption only inside the hardened provider process.
- **Attestation chain**: Secure Enclave P-256 key → signs attestation blob (hardware, SIP, Secure Boot, ARV status) → coordinator verifies signature + issues periodic challenge-response to detect key/posture changes.
- **Protocol symmetry**: `provider/src/protocol.rs` and `coordinator/internal/protocol/messages.go` define the same WebSocket message types. Changes to one must be mirrored in the other.

## Common Pitfalls

- Protocol changes require updating both `provider/src/protocol.rs` (Rust) AND `coordinator/internal/protocol/messages.go` (Go). They must stay in sync.
- Attestation tests need `AuthenticatedRootEnabled: true` in test blobs or the ARV check fails and overwrites earlier error messages (the checks run sequentially, last failure wins).
- The `python` feature flag in the provider Cargo.toml links PyO3. Use `--no-default-features` when building for distribution to avoid Python linking issues.
- The coordinator uses in-memory store by default. Provider state is lost on restart. Postgres store exists but is not used in production yet.
- Binary files like `coordinator/dginf-coordinator` and `coordinator/dginf-coordinator-linux` should NOT be committed to git (15MB+ each).
