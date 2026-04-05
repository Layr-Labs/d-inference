# DGInf - Decentralized Private Inference

DGInf is a decentralized/private inference stack for Apple Silicon Macs. Consumers use OpenAI-compatible APIs, the coordinator handles routing/auth/billing/attestation, and providers run local text, transcription, and image workloads on macOS hardware.

## Project Structure

```text
coordinator/          Go control plane
├── cmd/coordinator/  main service entrypoint
├── cmd/verify-attestation/
│   └── main.go       verifies attestation blobs from /tmp/dginf_attestation.json
├── deploy/
│   └── docker-compose.yml
└── internal/
    ├── api/          HTTP + WebSocket handlers
    │   ├── consumer.go         OpenAI-compatible chat/completions/messages/transcriptions/images
    │   ├── provider.go         provider registration, heartbeats, attestation, relay
    │   ├── billing_handlers.go Stripe/Solana/referral/pricing endpoints
    │   ├── device_auth.go      device code flow for linking providers to user accounts
    │   ├── enroll.go           MDM + ACME enrollment profile generation
    │   ├── invite_handlers.go  invite code admin/user flows
    │   ├── stats.go            public network stats
    │   └── server.go           route wiring, auth middleware, version gate
    ├── attestation/  Secure Enclave + MDA verification
    ├── auth/         Privy JWT integration
    ├── billing/      Stripe, Solana, referrals
    ├── e2e/          X25519 request-encryption helpers
    ├── mdm/          MicroMDM client + webhook handling
    ├── payments/     internal ledger + pricing
    ├── protocol/     WebSocket message types shared with provider
    ├── registry/     provider registry, queueing, routing, reputation
    └── store/        in-memory or Postgres persistence

provider/             Rust provider agent for Apple Silicon Macs
├── src/
│   ├── main.rs       CLI (`serve`, `start`, `install`, `login`, `models`, etc.)
│   ├── coordinator.rs WebSocket client, registration, heartbeats, request handling
│   ├── proxy.rs      text, transcription, and image proxying to local backends
│   ├── backend/      vllm-mlx backend process management
│   ├── service.rs    launchd install/start/stop helpers
│   ├── server.rs     local-only HTTP server mode
│   ├── config.rs     TOML config + hardware-based defaults
│   ├── hardware.rs   Apple Silicon detection + live system metrics
│   ├── hypervisor.rs hypervisor / RDMA checks
│   ├── security.rs   SIP, Secure Boot, anti-debug, integrity checks
│   ├── crypto.rs     X25519 keypair management
│   ├── models.rs     local text/image model discovery
│   ├── protocol.rs   message types mirrored from coordinator/internal/protocol
│   └── wallet.rs     local provider wallet handling
├── stt_server.py     local speech-to-text server script used by bundles
└── Cargo.toml        default `python` feature enables in-process PyO3 inference

image-bridge/         Python FastAPI image generation bridge
├── dginf_image_bridge/
│   ├── __main__.py
│   ├── server.py              OpenAI-compatible `/v1/images/generations`
│   ├── drawthings_backend.py  Draw Things gRPC backend adapter
│   ├── generated/             generated protobuf/FlatBuffers glue
│   └── proto/
├── requirements.txt
└── tests/                     pytest coverage for server/backend/integration

app/DGInf/            SwiftUI macOS menu bar app
├── Sources/DGInf/
│   ├── DGInfApp.swift
│   ├── StatusViewModel.swift
│   ├── ProviderManager.swift
│   ├── CLIRunner.swift
│   ├── LaunchAgentManager.swift
│   ├── SetupWizardView.swift
│   ├── SecurityManager.swift
│   ├── ModelManager.swift / ModelCatalog.swift
│   ├── DashboardView.swift / SettingsView.swift / WalletView.swift
│   ├── DoctorView.swift / BenchmarkView.swift / LogViewerView.swift
│   ├── MenuBarView.swift / NotificationManager.swift / UpdateManager.swift
│   └── Resources/
└── Tests/DGInfTests/

enclave/              Swift Secure Enclave helper + bridge binary
├── Sources/DGInfEnclave/      enclave key + attestation library
├── Sources/DGInfEnclaveCLI/   `dginf-enclave` CLI + WebSocket bridge
├── Tests/DGInfEnclaveTests/
└── include/dginf_enclave.h

web/                  Next.js 15 / React 19 frontend
├── src/app/          chat, billing, images, models, stats, providers, settings, login, link
├── src/app/api/      chat, images, transcribe, auth keys, billing, invite, models, health
├── src/components/   chat UI, verification panel, trust badge, shell, top bar, sidebar
├── src/components/providers/
│   ├── PrivyClientProvider.tsx
│   └── ThemeProvider.tsx
├── src/lib/          fetch helpers + Zustand store
└── src/hooks/        auth + toast hooks

scripts/              build, signing, install, and deploy helpers
├── build-bundle.sh   provider/enclave/python/ffmpeg bundle builder (+ optional upload)
├── build-bridge-app.sh build signed DGInfBridge app wrapper for the bridge binary
├── bundle-app.sh     build DGInf.app + DMG
├── install.sh        end-user installer served from coordinator
├── sign-hardened.sh  hardened runtime signing helper
├── deploy-acme.sh    nginx/step-ca helper
├── test-stt-e2e.sh   speech-to-text smoke test
└── entitlements.plist

docs/                 architecture, deploy runbooks, MDM/ACME notes, image/video research
tests/                root Python tests (`test_crypto_interop.py`, plus a stale integration script)
```

## Current Surface Area

- Coordinator HTTP routes currently include `POST /v1/chat/completions`, `POST /v1/completions`, `POST /v1/messages`, `POST /v1/audio/transcriptions`, `POST /v1/images/generations`, `GET /v1/models`, billing/pricing endpoints, invite flows, stats, enrollment, and device authorization endpoints.
- Coordinator auth is now split between Privy JWTs, API keys, and device-code login for provider machines.
- Billing logic is split between `coordinator/internal/payments` (ledger + pricing) and `coordinator/internal/billing` (Stripe, Solana, referrals).
- Providers can serve text models, transcription, and optional image models. Image generation goes through the separate `image-bridge/` process and uploads PNGs back to the coordinator over HTTP.
- The macOS app is a real operational client, not just a wrapper. It manages installation, onboarding, launchd integration, diagnostics, and subprocess supervision for `dginf-provider`.

## Building And Testing

### Coordinator (Go)
```bash
cd coordinator
go test ./...
go build ./cmd/coordinator
go build ./cmd/verify-attestation

# Linux deployment build
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dginf-coordinator-linux ./cmd/coordinator
```

### Provider (Rust)
```bash
cd provider
PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 cargo test
PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 cargo build --release

# Distribution bundle build (no embedded Python link)
cargo build --release --no-default-features
```

The `PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1` env var is still the safe default when local Python is newer than the PyO3 support window.

### Image Bridge (Python)
```bash
cd image-bridge
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt pytest httpx
PYTHONPATH=. pytest
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
swift test
```

### Web Frontend (Next.js)
```bash
cd web
npm install
npm run lint
npm run build
```

### Root Python Tests
```bash
python3 -m pytest tests/test_crypto_interop.py
```

## Deploying

Canonical runbook: `docs/coordinator-deploy-runbook.md`

Current release-sensitive pieces:

- Coordinator deploy target in the runbook is still AWS EC2 `34.197.17.112` (`inference-test.openinnovation.dev`).
- Provider bundle creation lives in `scripts/build-bundle.sh`.
- App bundle + DMG creation lives in `scripts/bundle-app.sh`.
- Installer flow lives in `scripts/install.sh`.
- Provider update checks use `LatestProviderVersion` in `coordinator/internal/api/server.go`, so bundle uploads and version bumps need to stay coordinated.

Quick coordinator deploy:

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

## Important Sync Points

- Protocol changes must be mirrored in both `provider/src/protocol.rs` and `coordinator/internal/protocol/messages.go`.
- If you change provider bundle semantics, keep `scripts/build-bundle.sh`, `scripts/install.sh`, the app launcher code, and `LatestProviderVersion` in sync.
- If you change install paths or process invocation, update both the CLI/install flow and the Swift app's `CLIRunner` / `ProviderManager`.
- Image generation changes often span three places: coordinator consumer/provider handlers, provider proxying, and `image-bridge/`.
- Device linking changes often span both coordinator device auth endpoints and the provider `login` / `logout` commands.

## Common Pitfalls

- The repo contains mixed infra language: coordinator comments/docs mention a GCP Confidential VM, while the active deploy runbook still targets AWS EC2. Treat that as unresolved repo drift, not settled truth.
- The repo also contains mixed payment language: current coordinator code implements Privy + Stripe + Solana + referrals, but some provider comments/strings still mention Tempo/pathUSD.
- `tests/integration_test.py` is stale: it references `sdk/` and `coordinator/bin/coordinator`, neither of which exists in this checkout. Do not rely on it without updating the paths first.
- `web/README.md` is still the default create-next-app scaffold and is not authoritative for this repo.
- `coordinator/coordinator` is a built binary checked into the tree. Do not model changes from it, and do not commit more built artifacts.
- The provider's default Cargo feature still pulls in PyO3. Use `--no-default-features` for distributable bundles.
- Provider image serving is opt-in through `DGINF_IMAGE_MODEL` and `DGINF_IMAGE_MODEL_PATH`; if you touch image flows, verify both the coordinator catalog and provider env/config path handling.

## Formatting

A pre-commit hook in `.githooks/pre-commit` checks staged files only. It is enabled via:

```bash
git config core.hooksPath .githooks
```

| Component | Check | Manual fix |
|-----------|-------|------------|
| Go (`coordinator/`) | `gofmt -l` | `gofmt -w <file>` |
| Rust (`provider/`) | `cargo fmt --check` | `cd provider && cargo fmt` |
| TypeScript (`web/`) | `npx next lint` | `cd web && npx next lint --fix` |
| Swift (`app/`, `enclave/`) | skipped | no enforced formatter |
| Python (`image-bridge/`, `tests/`) | no hook today | run `pytest` manually as needed |
