# EigenInference - Decentralized Private Inference

EigenInference is a decentralized/private inference stack for Apple Silicon Macs. Consumers use OpenAI-compatible APIs, the coordinator handles routing/auth/billing/attestation, and providers run local text, transcription, and image workloads on macOS hardware.

## Project Structure

```text
coordinator/          Go control plane
├── cmd/coordinator/  main service entrypoint
├── cmd/verify-attestation/
│   └── main.go       verifies attestation blobs from /tmp/eigeninference_attestation.json
└── internal/
    ├── api/          HTTP + WebSocket handlers
    │   ├── consumer.go         OpenAI-compatible chat/completions/messages/transcriptions/images
    │   ├── provider.go         provider registration, heartbeats, attestation, relay
    │   ├── billing_handlers.go Stripe/Solana/referral/pricing endpoints
    │   ├── device_auth.go      device code flow for linking providers to user accounts
    │   ├── enroll.go           MDM + ACME enrollment profile generation
    │   ├── invite_handlers.go  invite code admin/user flows
    │   ├── release_handlers.go binary release registration (GitHub Actions integration)
    │   ├── acme_verify.go      ACME device-attest-01 client cert verification
    │   ├── stats.go            public network stats
    │   └── server.go           route wiring, auth middleware, version gate
    ├── attestation/  Secure Enclave + MDA verification
    ├── auth/         Privy JWT integration
    ├── billing/      Stripe, Solana USDC deposits, referrals
    ├── e2e/          X25519 request-encryption helpers
    ├── mdm/          MicroMDM client + webhook handling
    ├── payments/     internal ledger + pricing
    ├── protocol/     WebSocket message types shared with provider
    ├── registry/     provider registry, queueing, routing, reputation
    └── store/        in-memory or Postgres persistence

provider/             Rust provider agent for Apple Silicon Macs
├── src/
│   ├── main.rs       CLI (`serve`, `start`, `stop`, `models`, `benchmark`, `status`, `doctor`, `login`, etc.)
│   ├── coordinator.rs WebSocket client, registration, heartbeats, request handling
│   ├── proxy.rs      text, transcription, and image proxying to local backends
│   ├── backend/      vllm-mlx backend process management
│   ├── service.rs    launchd install/start/stop helpers
│   ├── server.rs     local-only HTTP server mode
│   ├── config.rs     TOML config + hardware-based defaults
│   ├── hardware.rs   Apple Silicon detection + live system metrics
│   ├── hypervisor.rs Hypervisor.framework Stage 2 page table memory isolation
│   ├── scheduling.rs time-based availability windows
│   ├── security.rs   SIP, Secure Boot, anti-debug (PT_DENY_ATTACH), integrity checks
│   ├── crypto.rs     X25519 keypair management
│   ├── models.rs     local text/image model discovery (fast scan, on-demand hashing)
│   ├── inference.rs  in-process MLX inference (behind "python" feature flag)
│   ├── protocol.rs   message types mirrored from coordinator/internal/protocol
│   └── wallet.rs     legacy provider wallet (secp256k1)
├── stt_server.py     local speech-to-text server script used by bundles
└── Cargo.toml        default `python` feature enables in-process PyO3 inference

image-bridge/         Python FastAPI image generation bridge
├── eigeninference_image_bridge/
│   ├── __main__.py
│   ├── server.py              OpenAI-compatible `/v1/images/generations`
│   ├── drawthings_backend.py  Draw Things gRPC backend adapter
│   ├── generated/             generated protobuf/FlatBuffers glue
│   └── proto/
├── requirements.txt
└── tests/                     pytest coverage for server/backend/integration

app/Darkbloom/                 SwiftUI macOS menu bar app
├── Sources/Darkbloom/
│   ├── DarkbloomApp.swift
│   ├── StatusViewModel.swift
│   ├── ProviderManager.swift
│   ├── CLIRunner.swift
│   ├── ConfigManager.swift
│   ├── LaunchAgentManager.swift
│   ├── SecurityManager.swift
│   ├── ModelManager.swift / ModelCatalog.swift
│   ├── IdleDetector.swift
│   ├── NotificationManager.swift / UpdateManager.swift
│   ├── DesignSystem.swift / GuideAvatar.swift / Illustrations.swift
│   ├── DashboardView.swift / SettingsView.swift
│   ├── MenuBarView.swift / SetupWizardView.swift
│   ├── DoctorView.swift / LogViewerView.swift / ModelCatalogView.swift
│   └── Resources/
└── Tests/DarkbloomTests/

enclave/              Swift Secure Enclave helper + bridge binary
├── Sources/EigenInferenceEnclave/      enclave key + attestation library + FFI bridge
├── Sources/EigenInferenceEnclaveCLI/   `eigeninference-enclave` CLI (attest, sign, info)
├── Tests/EigenInferenceEnclaveTests/
└── include/eigeninference_enclave.h

console-ui/           Next.js 16 / React 19 frontend
├── src/app/          chat, billing, images, models, stats, providers, settings, link, api-console, earn
├── src/app/api/      chat, images, transcribe, auth/keys, payments/*, invite, models, health, pricing
├── src/components/   chat UI, sidebar, top bar, trust badge, verification panel, invite banner
├── src/components/providers/
│   ├── PrivyClientProvider.tsx
│   └── ThemeProvider.tsx
├── src/lib/          API client (api.ts) + Zustand store (store.ts)
├── src/hooks/        auth (useAuth.ts) + toast (useToast.ts)
└── proxy.ts          Next.js 16 proxy (replaces middleware.ts)

scripts/              build, signing, install, and deploy helpers
├── build-bundle.sh   provider/enclave/python/ffmpeg bundle builder (+ optional upload)
├── bundle-app.sh     build Darkbloom.app + DMG
├── install.sh        end-user installer served from coordinator (hash + codesign verification)
├── sign-hardened.sh  hardened runtime signing helper
├── admin.sh          admin CLI (Privy auth, release mgmt, API calls)
├── deploy-acme.sh    nginx/step-ca helper
├── test-stt-e2e.sh   speech-to-text smoke test
└── entitlements.plist hardened runtime entitlements (hypervisor, network)

docs/                 architecture, deploy runbooks, MDM/ACME notes, image/video research
.github/workflows/    CI (ci.yml) and release automation (release.yml) with code signing + notarization
```

## Current Surface Area

- Coordinator HTTP routes include `POST /v1/chat/completions`, `POST /v1/completions`, `POST /v1/messages`, `POST /v1/audio/transcriptions`, `POST /v1/images/generations`, `GET /v1/models`, billing/pricing endpoints, invite flows, stats, enrollment, device authorization, and release registration endpoints.
- Coordinator auth is split between Privy JWTs, API keys, and device-code login (RFC 8628) for provider machines.
- Billing logic is split between `coordinator/internal/payments` (ledger + pricing) and `coordinator/internal/billing` (Stripe, Solana USDC, referrals). Coordinator wallet derived from BIP39 mnemonic via SLIP-0010.
- Providers can serve text models, transcription, and optional image models. Image generation goes through the separate `image-bridge/` process and uploads PNGs back to the coordinator over HTTP.
- The macOS app is a real operational client, not just a wrapper. It manages installation, onboarding, launchd integration, diagnostics, and subprocess supervision for `darkbloom`.

## Building And Testing

### Coordinator (Go)
```bash
cd coordinator
go test ./...
go build ./cmd/coordinator
go build ./cmd/verify-attestation

# Linux deployment build
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o eigeninference-coordinator-linux ./cmd/coordinator
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
cd app/Darkbloom
swift build -c release
swift test
```

### Enclave Helper (Swift)
```bash
cd enclave
swift build -c release
swift test
```

### Console UI (Next.js 16)
```bash
cd console-ui
npm install
npm run build
npx eslint src/       # lint check
npm test              # vitest
```

### Root Python Tests
```bash
python3 -m pytest tests/test_crypto_interop.py
```

## Deploying

Canonical runbook: `docs/coordinator-deploy-runbook.md`

Current release-sensitive pieces:

- Prod coordinator runs on EigenCloud (TEE) as app `d-inference` at `api.darkbloom.dev`. Build target: `coordinator/Dockerfile`. Dev coordinator runs on Google Cloud (see `docs/dev-environment.md`).
- Provider bundle creation lives in `scripts/build-bundle.sh`.
- App bundle + DMG creation lives in `scripts/bundle-app.sh`.
- Installer flow lives in `scripts/install.sh`.
- Provider update checks use `LatestProviderVersion` in `coordinator/internal/api/server.go`, so bundle uploads and version bumps need to stay coordinated.
- CI release workflow (`release.yml`) signs binaries with Developer ID Application cert, notarizes with Apple, computes SHA-256 hashes after signing.

Quick coordinator deploy (prod, EigenCloud):

```bash
# EigenCloud builds from the repo via coordinator/Dockerfile and blue-green deploys.
git push origin master
ecloud compute app deploy d-inference
curl https://api.darkbloom.dev/health
ecloud compute app logs d-inference
```

Dev coordinator deploy (Google Cloud): see `docs/dev-environment.md`.

## Important Sync Points

- Protocol changes must be mirrored in both `provider/src/protocol.rs` and `coordinator/internal/protocol/messages.go`.
- If you change provider bundle semantics, keep `scripts/build-bundle.sh`, `scripts/install.sh`, the app launcher code, and `LatestProviderVersion` in sync.
- If you change install paths or process invocation, update both the CLI/install flow and the Swift app's `CLIRunner` / `ProviderManager`.
- Image generation changes often span three places: coordinator consumer/provider handlers, provider proxying, and `image-bridge/`.
- Device linking changes often span both coordinator device auth endpoints and the provider `login` / `logout` commands.
- Model catalog changes must be reflected in coordinator's catalog, provider's `MODEL_CATALOG` in main.rs, and the Swift app's `ModelCatalog.swift`.

## Common Pitfalls

- The repo contains mixed payment language: current coordinator code implements Privy + Stripe + Solana + referrals, but some provider comments/strings still mention Tempo/pathUSD.
- `coordinator/coordinator` is a built binary checked into the tree. Do not model changes from it, and do not commit more built artifacts.
- The provider's default Cargo feature still pulls in PyO3. Use `--no-default-features` for distributable bundles.
- Provider image serving is opt-in through `EIGENINFERENCE_IMAGE_MODEL` and `EIGENINFERENCE_IMAGE_MODEL_PATH`; if you touch image flows, verify both the coordinator catalog and provider env/config path handling.
- CI release workflow must compute binary SHA-256 hashes AFTER code signing, not before. Providers verify hashes of the signed binary.
- Model scan uses fast discovery (no hashing) at startup. Weight hashing is on-demand via `compute_weight_hash()` only for the served model. Don't add hashing back to the scan path.
- Provider auto-injects ChatML template for models missing `chat_template` field. This is intentional — Qwen3.5 base models ship without it.
- The coordinator uses in-memory store by default. Provider state is lost on restart. Postgres store exists but is not used in production yet.
- Request queue timeout is 120 seconds. Initial attestation challenge is sent immediately on registration, then every 5 minutes.
- Backend idle timeout is 1 hour (not 10 minutes as some comments may say).

## Formatting

A pre-commit hook in `.githooks/pre-commit` checks staged files only. It is enabled via:

```bash
git config core.hooksPath .githooks
```

| Component | Check | Manual fix |
|-----------|-------|------------|
| Go (`coordinator/`) | `gofmt -l` | `gofmt -w <file>` |
| Rust (`provider/`) | `cargo fmt --check` | `cd provider && cargo fmt` |
| TypeScript (`console-ui/`) | `npx eslint src/` | `cd console-ui && npx eslint src/ --fix` |
| Swift (`app/`, `enclave/`) | skipped | no enforced formatter |
| Python (`image-bridge/`, `tests/`) | no hook today | run `pytest` manually as needed |
