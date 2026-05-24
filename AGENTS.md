# EigenInference - Decentralized Private Inference

EigenInference is a decentralized/private inference stack for Apple Silicon Macs. Consumers use OpenAI-compatible APIs, the coordinator handles routing/auth/billing/attestation, and providers run local text, transcription, and image workloads on macOS hardware.

## Project Structure

```text
coordinator/          Go control plane (packages live at top level, not internal/)
├── cmd/coordinator/  main service entrypoint
├── cmd/verify-attestation/
│   └── main.go       verifies attestation blobs from /tmp/eigeninference_attestation.json
├── api/              HTTP + WebSocket handlers
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
├── attestation/      Secure Enclave + MDA verification
├── auth/             Privy JWT integration
├── billing/          Stripe, Solana USDC deposits, referrals
├── e2e/              X25519 request-encryption helpers
├── mdm/              MicroMDM client + webhook handling
├── payments/         ledger + pricing
├── protocol/         WebSocket message types shared with provider
├── registry/         provider registry, queueing, routing, reputation
└── store/            in-memory or Postgres persistence

testbed/              System-level testing framework (shared Go module with coordinator)
├── coordinator.go    Coordinator lifecycle (start/stop, Postgres helpers)
├── provider.go       Provider lifecycle (binary discovery, start/stop)
├── config.go         Test configuration (model, provider, request settings)
├── events.go         Event system (segments, buffers, fan-out)
├── instrument.go     Request-level instrumentation
├── assert/           Assertion framework
│   ├── assert.go           Latency threshold assertions
│   └── accounting.go       Postgres-backed accounting integrity checks
├── deps/             External dependency lifecycle
│   └── postgres.go         Ephemeral Docker Postgres
├── profile/          Profiling and regression detection
│   └── profile.go          Segment stats aggregation, diffing, JSON export
└── integration/      Integration test suite (Docker Postgres + real coordinator)

provider-swift/       Current Swift provider CLI for Apple Silicon Macs
├── Sources/ProviderCore/             coordinator client, protocol, hardware, security, inference, server, telemetry, model downloads
├── Sources/ProviderCoreFoundation/   model manifests, scanner, hashing, publish-safe foundation code
├── Sources/darkbloom/                CLI (`serve`, `start`, `stop`, `models`, `benchmark`, `status`, `doctor`, `login`, etc.)
├── Sources/darkbloom-publish/        registry manifest builder used by publish workflow
└── Tests/                            ProviderCore and ProviderCoreFoundation tests

provider/             Deprecated Rust provider retained for historical/reference work only

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
├── build-bundle.sh   provider/enclave bundle builder (+ optional upload)
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
- Billing logic is split between `coordinator/payments` (ledger + pricing) and `coordinator/billing` (Stripe, Solana USDC, referrals). Coordinator wallet derived from BIP39 mnemonic via SLIP-0010.
- Providers currently serve text inference through the Swift `darkbloom` CLI.
- Model registry data is DB-backed in the coordinator and points to R2 manifests under `https://models.darkbloom.ai`; model bytes are not hardcoded in the provider or UI.

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

### Provider (Swift)
```bash
cd provider-swift
swift build
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
- Provider update checks use `LatestProviderVersion` in `coordinator/api/server.go`, so bundle uploads and version bumps need to stay coordinated.
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

- Protocol changes must be mirrored in both `provider-swift/Sources/ProviderCore/Protocol/` and `coordinator/protocol/messages.go`.
- Telemetry wire types live in three places and MUST stay aligned:
  - `coordinator/protocol/telemetry.go` (canonical),
  - `provider-swift/Sources/ProviderCore/Telemetry/` (Swift mirror),
  - `console-ui/src/lib/telemetry-types.ts` (TS mirror).
  Symmetry tests in each language pin enum casing and optional-field omission.
  Field allowlist additions need parallel updates in
  `coordinator/api/telemetry_handlers.go`,
  `provider-swift/Sources/ProviderCore/Telemetry/`, and the TS set above.
- If you change provider bundle semantics, keep `scripts/build-bundle.sh`, `scripts/install.sh`, and `LatestProviderVersion` in sync.
- If you change install paths or process invocation, update both the CLI and install flow.
- Device linking changes often span both coordinator device auth endpoints and the provider `login` / `logout` commands.
- Model registry changes span coordinator registry schema/endpoints, `provider-swift` manifest download/publish code, `scripts/publish-model.sh`, and the console UI. Do not add hardcoded provider `MODEL_CATALOG` lists.

## Common Pitfalls

- The repo contains mixed payment language: current coordinator code implements Privy + Stripe + Solana + referrals, but some provider comments/strings still mention Tempo/pathUSD.
- `coordinator/coordinator` is a built binary checked into the tree. Do not model changes from it, and do not commit more built artifacts.
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
| Swift (`provider-swift/`) | no enforced formatter | `cd provider-swift && swift test` |
| TypeScript (`console-ui/`) | `npx eslint src/` | `cd console-ui && npx eslint src/ --fix` |
| Swift (`app/`, `enclave/`) | skipped | no enforced formatter |
| Python (`tests/`) | no hook today | run `pytest` manually as needed |
