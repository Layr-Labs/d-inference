# EigenInference - Decentralized GPU Inference

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

app/EigenInference/            Swift — macOS menu bar app (SwiftUI)
├── Sources/EigenInference/
│   ├── EigenInferenceApp.swift        App entry, menu bar setup
│   ├── StatusViewModel.swift Core state management
│   ├── DashboardView.swift   Main dashboard
│   ├── SettingsView.swift    Preferences
│   ├── CLIRunner.swift       Launches eigeninference-provider as subprocess
│   └── ...                   Other views (Wallet, Benchmark, Doctor, etc.)

enclave/              Swift — Secure Enclave attestation CLI helper
├── Sources/
│   ├── EigenInferenceEnclave/         Library (P-256 key generation, attestation blob signing)
│   └── EigenInferenceEnclaveCLI/      CLI tool (invoked by provider at startup)

scripts/
├── bundle-app.sh     Builds code-signed .app bundle + .dmg
├── install.sh        curl one-liner installer served from coordinator
└── entitlements.plist Hardened Runtime entitlements

console-ui/           Next.js frontend (dashboard + billing)
landing/              Static landing page (index.html)
```

## Building & Testing

### Coordinator (Go)
```bash
cd coordinator
go test ./...
# Cross-compile for AWS (Linux amd64):
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o eigeninference-coordinator-linux ./cmd/coordinator
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
cd app/EigenInference
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
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o eigeninference-coordinator-linux ./cmd/coordinator && \
scp -i ~/.ssh/eigeninference-infra eigeninference-coordinator-linux ubuntu@34.197.17.112:/tmp/eigeninference-coordinator && \
ssh -i ~/.ssh/eigeninference-infra ubuntu@34.197.17.112 \
  'sudo systemctl stop eigeninference-coordinator && \
   sudo mv /tmp/eigeninference-coordinator /usr/local/bin/eigeninference-coordinator && \
   sudo chmod +x /usr/local/bin/eigeninference-coordinator && \
   sudo systemctl start eigeninference-coordinator'
```

### Provider bundle (quick upload)
```bash
# After building provider + enclave:
scp -i ~/.ssh/eigeninference-infra /tmp/eigeninference-bundle/eigeninference-bundle-macos-arm64.tar.gz \
  ubuntu@34.197.17.112:/var/www/html/dl/
```

## Infrastructure

| Component | Location | Details |
|-----------|----------|---------|
| Coordinator | AWS EC2 `eigeninference-mdm` | t3.small, `34.197.17.112` (Elastic IP), systemd service |
| Domain | `inference-test.openinnovation.dev` | nginx → localhost:8080, Let's Encrypt TLS |
| SSH | `ssh -i ~/.ssh/eigeninference-infra ubuntu@34.197.17.112` | Key name: `eigeninference-infra` |
| AWS Profile | `admin` | Account 084828557146 |
| Provider install | `curl -fsSL https://inference-test.openinnovation.dev/install.sh \| bash` | Downloads tarball from `/dl/` |

## Key Design Decisions

- **Provider scoring**: decode TPS × trust multiplier × reputation × warm model bonus × health factor. Health factor uses live system metrics (memory pressure, CPU usage, thermal state) reported in heartbeats.
- **Request cancellation**: In-flight inference requests are tracked by request_id with CancellationToken. On coordinator disconnect, all in-flight requests are cancelled and the HTTP connection to vllm-mlx is dropped so it stops generating.
- **Idle GPU timeout**: Backend (vllm-mlx) process is killed after 10 minutes of no requests to free GPU memory. Lazy-reloaded when the next request arrives (cold-start penalty of ~10-30s for model reload).
- **E2E encryption**: Consumer requests encrypted with provider's X25519 public key (NaCl box). Coordinator never sees plaintext prompts. Decryption only inside the hardened provider process.
- **Attestation chain**: Secure Enclave P-256 key → signs attestation blob → coordinator verifies signature (self_signed) → MDM SecurityInfo cross-check (hardware trust) → Apple Enterprise Attestation Root CA signs device cert chain via MDA (mda_verified). Full chain exposed at `GET /v1/providers/attestation` for user-side verification.
- **Protocol symmetry**: `provider/src/protocol.rs` and `coordinator/internal/protocol/messages.go` define the same WebSocket message types. Changes to one must be mirrored in the other.

## Common Pitfalls

- Protocol changes require updating both `provider/src/protocol.rs` (Rust) AND `coordinator/internal/protocol/messages.go` (Go). They must stay in sync.
- Attestation tests need `AuthenticatedRootEnabled: true` in test blobs or the ARV check fails and overwrites earlier error messages (the checks run sequentially, last failure wins).
- The `python` feature flag in the provider Cargo.toml links PyO3. Use `--no-default-features` when building for distribution to avoid Python linking issues.
- The coordinator uses in-memory store by default. Provider state is lost on restart. Postgres store exists but is not used in production yet.
- Binary files like `coordinator/eigeninference-coordinator` and `coordinator/eigeninference-coordinator-linux` should NOT be committed to git (15MB+ each).

## Formatting

A pre-commit hook in `.githooks/pre-commit` checks formatting on staged files only. It is enabled via `git config core.hooksPath .githooks` (already set for this repo).

| Component | Check | Manual fix |
|-----------|-------|------------|
| Go (coordinator/) | `gofmt -l` | `gofmt -w <file>` |
| Rust (provider/) | `cargo fmt --check` | `cd provider && cargo fmt` |
| TypeScript (console-ui/) | `npx next lint` | `cd console-ui && npx next lint --fix` |
| Swift (app/, enclave/) | skipped | no enforced formatter |

If you clone fresh, activate the hook with:
```bash
git config core.hooksPath .githooks
```
