# Darkbloom - Decentralized Private Inference

Darkbloom is a decentralized private inference network for Apple Silicon Macs. Consumers use OpenAI-compatible APIs, the coordinator handles routing, auth, billing, attestation, and capacity management, and providers run local inference workloads on macOS hardware using MLX-Swift. All inference is end-to-end encrypted -- the coordinator never sees plaintext prompts.

## Project Structure

```text
coordinator/          Go control plane (packages live at top level, not internal/)
├── cmd/coordinator/  main service entrypoint
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
├── ratelimit/        rate limiting
├── registry/         provider registry, queueing, routing, reputation, token-budget admission
├── saferun/          panic-safe goroutine runners
├── store/            in-memory or Postgres persistence
├── telemetry/        Datadog DogStatsD metrics
├── datadog/          dev dashboard JSON definitions
└── internal/e2e/     coordinator-scoped integration tests

e2e/                  System-level E2E testing framework
├── integration_test.go  12 E2E tests (streaming, billing, encryption, attestation, etc.)
├── profile_test.go      latency profiling tests
├── benchmark_test.go    load benchmarks (posts markdown to PR comments)
└── testbed/             shared test harness
    ├── coordinator.go       Coordinator lifecycle (start/stop, Postgres helpers)
    ├── provider.go          Provider lifecycle (binary discovery, start/stop)
    ├── config.go            Test configuration (model, provider, request settings)
    ├── suite.go             Suite orchestration (multi-provider, user pools)
    ├── events.go            Event system (segments, buffers, fan-out)
    ├── instrument.go        Request-level instrumentation
    ├── load.go              Load generator (concurrency, streaming, metrics)
    ├── assert/              Latency threshold + accounting integrity assertions
    ├── deps/                External dependency lifecycle (ephemeral Postgres)
    └── profile/             Segment stats aggregation, diffing, JSON export

provider-swift/       Swift provider CLI for Apple Silicon Macs
├── Sources/ProviderCore/             coordinator client, protocol, hardware, security, inference, server, telemetry, model downloads
├── Sources/ProviderCoreFoundation/   model manifests, scanner, hashing, publish-safe foundation code
├── Sources/darkbloom/                CLI (`serve`, `start`, `stop`, `models`, `benchmark`, `status`, `doctor`, `login`, etc.)
├── Sources/darkbloom-publish/        registry manifest builder used by publish workflow
├── Sources/darkbloom-enclave-cli/    Secure Enclave attestation/sign helper
└── Tests/                            ProviderCore and ProviderCoreFoundation tests

provider/             Deprecated Rust provider (bridge auto-update to Swift bundles only)

enclave/              Standalone Secure Enclave helper (legacy naming)
├── Sources/EigenInferenceEnclave/      enclave key + attestation library + FFI bridge
├── Sources/EigenInferenceEnclaveCLI/   CLI (attest, sign, info)
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
├── install.sh        end-user installer served from coordinator (hash + codesign verification)
├── admin.sh          admin CLI (Privy auth, release mgmt, API calls)
├── publish-model.sh  model registry publish workflow
├── deploy-acme.sh    nginx/step-ca helper
├── fetch-metallib.sh MLX metallib fetcher
└── entitlements.plist hardened runtime entitlements (hypervisor, network)

docs/                 architecture, deploy runbooks, MDM/ACME notes, threat model
.github/workflows/    CI (ci.yml), integration tests (integration.yml), Swift release (release-swift.yml),
                      Rust bridge release (release-rust-bridge.yml), model registration (register-model.yml),
                      threat model review (threat-model-review.yml)
```

## Current Surface Area

- Coordinator HTTP routes include `POST /v1/chat/completions`, `POST /v1/completions`, `POST /v1/messages`, `POST /v1/audio/transcriptions`, `POST /v1/images/generations`, `GET /v1/models`, `GET /v1/models/capacity`, billing/pricing endpoints, invite flows, stats, enrollment, device authorization, and release registration endpoints.
- Coordinator auth is split between Privy JWTs, API keys, and device-code login (RFC 8628) for provider machines.
- Routing uses token-budget admission with engine-reported capacity, speculative TTFT dispatch, EWMA TPS tracking, and early 429 with Retry-After for OpenRouter compatibility.
- Billing logic is split between `coordinator/payments` (ledger + pricing) and `coordinator/billing` (Stripe, Solana USDC, referrals).
- Providers serve text inference through the Swift `darkbloom` CLI with continuous batching via MLX-Swift.
- Model registry data is DB-backed in the coordinator and points to R2 manifests under `https://models.darkbloom.ai`; model bytes are not hardcoded in the provider or UI.
- Observability: Datadog metrics (DogStatsD) for attestation, routing, billing, fleet version, and provider capacity. X-Timing header decomposes per-request latency.

## Building And Testing

### Coordinator (Go)
```bash
cd coordinator
go test ./...
go build ./cmd/coordinator

# Linux deployment build
GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o coordinator-linux ./cmd/coordinator
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

### E2E Integration Tests
```bash
# Requires Postgres + Swift provider binary + MLX model downloaded
go test ./e2e/... -run TestIntegration -v
go test ./e2e/... -run TestBenchmark -v    # load benchmarks
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
- CI release workflow (`release-swift.yml`) signs binaries with Developer ID Application cert, notarizes with Apple, computes SHA-256 hashes after signing, embeds provisioning profile in .app bundle.

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

- `coordinator/coordinator` is a built binary checked into the tree. Do not model changes from it, and do not commit more built artifacts.
- CI release workflow must compute binary SHA-256 hashes AFTER code signing, not before. Providers verify hashes of the signed binary.
- Model scan uses fast discovery (no hashing) at startup. Weight hashing is on-demand via `compute_weight_hash()` only for the served model. Don't add hashing back to the scan path.
- Provider auto-injects ChatML template for models missing `chat_template` field. This is intentional -- Qwen3.5 base models ship without it.
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
