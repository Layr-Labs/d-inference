# EigenInference - Decentralized Private Inference

EigenInference is a decentralized/private inference stack for Apple Silicon Macs. Consumers use OpenAI-compatible APIs, the coordinator handles routing/auth/billing/attestation, and providers run local text-inference workloads on macOS hardware.

## Project Structure

```text
coordinator/          Go control plane
├── cmd/coordinator/  main service entrypoint
├── cmd/verify-attestation/
│   └── main.go       verifies attestation blobs from /tmp/eigeninference_attestation.json
└── internal/
    ├── api/          HTTP + WebSocket handlers
    │   ├── consumer.go         OpenAI-compatible chat/completions/messages/responses
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

provider/             Rust provider agent for Apple Silicon Macs (legacy, retired at Swift cutover)
├── src/
│   ├── main.rs       CLI (`serve`, `start`, `stop`, `models`, `benchmark`, `status`, `doctor`, `login`, etc.)
│   ├── coordinator.rs WebSocket client, registration, heartbeats, request handling
│   ├── proxy.rs      text proxying to local backends
│   ├── service.rs    launchd install/start/stop helpers
│   ├── server.rs     local-only HTTP server mode
│   ├── config.rs     TOML config + hardware-based defaults
│   ├── hardware.rs   Apple Silicon detection + live system metrics
│   ├── scheduling.rs time-based availability windows
│   ├── security.rs   SIP, Secure Boot, anti-debug (PT_DENY_ATTACH), integrity checks
│   ├── crypto.rs     X25519 keypair management
│   ├── models.rs     local text/image model discovery (fast scan, on-demand hashing)
│   ├── protocol.rs   message types mirrored from coordinator/internal/protocol
│   └── wallet.rs     legacy provider wallet (secp256k1)
└── Cargo.toml

provider-swift/                Swift CLI port of the provider (replacing `provider/` at cutover)
├── Package.swift              SwiftPM manifest, depends on libs/mlx-swift{,-lm}
├── Sources/
│   ├── ProviderCore/                  shared library: protocol, hardware, crypto (libsodium NaCl box), security, attestation, inference, coordinator client, scheduling, server, telemetry, models
│   ├── darkbloom/                     CLI executable (serve, start, stop, status, doctor, models, login, logout, benchmark, update, verify)
│   └── darkbloom-enclave-cli/    Secure Enclave attestation/sign helper
└── Tests/ProviderCoreTests/

console-ui/           Next.js 16 / React 19 frontend
├── src/app/          chat, billing, images, models, stats, providers, settings, link, api-console, earn
├── src/app/api/      chat, auth/keys, payments/*, invite, models, health, pricing
├── src/components/   chat UI, sidebar, top bar, trust badge, verification panel, invite banner
├── src/components/providers/
│   ├── PrivyClientProvider.tsx
│   └── ThemeProvider.tsx
├── src/lib/          API client (api.ts) + Zustand store (store.ts)
├── src/hooks/        auth (useAuth.ts) + toast (useToast.ts)
└── proxy.ts          Next.js 16 proxy (replaces middleware.ts)

scripts/              install + deploy helpers
├── install.sh        end-user installer served from coordinator (hash + codesign verification)
├── admin.sh          admin CLI (Privy auth, release mgmt, API calls)
├── deploy-acme.sh    nginx/step-ca helper
├── smoke-dev.sh      dev-coordinator smoke test
├── benchmark-*.py    benchmark utilities
└── entitlements.plist hardened runtime entitlements (hypervisor, network)

docs/                 architecture, deploy runbooks, MDM/ACME notes, image/video research
.github/workflows/    CI (ci.yml) and Swift release automation (release-swift.yml) with code signing + notarization
```

## Current Surface Area

- Coordinator HTTP routes include `POST /v1/chat/completions`, `POST /v1/completions`, `POST /v1/messages`, `POST /v1/responses`, `GET /v1/models`, billing/pricing endpoints, invite flows, stats, enrollment, device authorization, and release registration endpoints. Image generation and audio transcription are not part of the platform.
- Coordinator auth is split between Privy JWTs, API keys, and device-code login (RFC 8628) for provider machines.
- Billing logic is split between `coordinator/internal/payments` (ledger + pricing) and `coordinator/internal/billing` (Stripe, Solana USDC, referrals). Coordinator wallet derived from BIP39 mnemonic via SLIP-0010.
- Providers serve text models only. Audio transcription and image generation are not part of the platform.
- The Swift provider is **CLI-only**. There is no menu bar app and no SwiftUI surface — the legacy `app/EigenInference/` and `enclave/` directories were deleted as part of the CLI-only migration. Operators interact with `darkbloom` directly: `darkbloom serve` for foreground, `darkbloom start`/`stop` for launchd, plus `status`/`doctor`/`models`/`login`/`logout`/`benchmark`/`update`/`verify`.

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

### Provider (Rust, legacy)
```bash
cd provider
cargo test
cargo build --release
```

### Provider (Swift, replacing Rust at cutover)
```bash
cd provider-swift
swift test
swift build -c release
# Outputs:
#   .build/release/darkbloom              provider CLI
#   .build/release/darkbloom-enclave  Secure Enclave helper
```

The package depends on `../libs/mlx-swift` and `../libs/mlx-swift-lm` (both
git submodules). Ensure they are checked out (`git submodule update --init
--recursive`). For local runs, the matching `mlx.metallib` must sit next to
the binary; the release CI handles this automatically by extracting it from
the matching `mlx==0.31.x` Python wheel.

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
- Provider bundle creation lives entirely in `.github/workflows/release-swift.yml` (no shell-script equivalent post-cutover).
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
- Telemetry wire types live in three places and MUST stay aligned:
  - `coordinator/internal/protocol/telemetry.go` (canonical),
  - `provider/src/telemetry/event.rs` (Rust mirror),
  - `console-ui/src/lib/telemetry-types.ts` (TS mirror).
  Symmetry tests in each language pin enum casing and optional-field omission.
  Field allowlist additions need parallel updates in
  `coordinator/internal/api/telemetry_handlers.go`,
  `provider/src/telemetry/layer.rs`, and the TS set above.
- If you change provider bundle semantics, keep `.github/workflows/release-swift.yml`, `scripts/install.sh`, and `LatestProviderVersion` in sync.
- If you change install paths or process invocation, update both the CLI/install flow and the Swift app's `CLIRunner` / `ProviderManager`.
- Image generation and audio transcription are not supported. The platform serves only text inference; the model catalog filter (`coordinator/internal/api/model_catalog_filter.go`) rejects any `ModelType` other than `text`.
- Device linking changes often span both coordinator device auth endpoints and the provider `login` / `logout` commands.
- Model catalog changes must be reflected in coordinator's catalog, provider's `MODEL_CATALOG` in main.rs, and the Swift app's `ModelCatalog.swift`.

## Common Pitfalls

- The repo contains mixed payment language: current coordinator code implements Privy + Stripe + Solana + referrals, but some provider comments/strings still mention Tempo/pathUSD.
- `coordinator/coordinator` is a built binary checked into the tree. Do not model changes from it, and do not commit more built artifacts.
- The provider's default Cargo feature pulls in PyO3. Use `--no-default-features` for distributable bundles if needed.
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
| Swift (`provider-swift/`) | skipped | no enforced formatter |
| Python (`tests/`) | no hook today | run `pytest tests/test_crypto_interop.py` manually as needed |
