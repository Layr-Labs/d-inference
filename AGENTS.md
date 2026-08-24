# Darkbloom - Decentralized Private Inference

Darkbloom is a decentralized private inference network for Apple Silicon Macs. Consumers use OpenAI-compatible APIs, the coordinator handles routing, auth, billing, attestation, and capacity management, and providers run local inference workloads on macOS hardware using MLX-Swift. All inference is end-to-end encrypted -- the coordinator never sees plaintext prompts.

## Project Structure

```text
coordinator/          Go control plane (packages live at top level, not internal/)
├── cmd/coordinator/  main service entrypoint
├── api/              HTTP + WebSocket handlers
│   ├── consumer.go         OpenAI-compatible chat/completions/responses + Anthropic messages
│   ├── provider.go         provider registration, heartbeats, attestation, relay
│   ├── billing_handlers.go Stripe/referral/pricing endpoints
│   ├── device_auth.go      device code flow for linking providers to user accounts
│   ├── enroll.go           MDM enrollment profile generation
│   ├── invite_handlers.go  invite code admin/user flows
│   ├── release_handlers.go binary release registration (GitHub Actions integration)
│   ├── chunk_key_cache.go  per-request X25519 shared-key memoization for chunk decrypt
│   ├── stats.go            public network stats
│   ├── types/              canonical JSON shapes for consumer-facing endpoints
│   └── server.go           route wiring, auth middleware, version gate
├── apns/             APNs-push code-identity attestation
├── attestation/      Secure Enclave + MDA verification
├── auth/             Privy JWT integration
├── billing/          Stripe (deposits + Connect payouts), referrals
├── config/           AppConfig aggregation of per-package configs
├── env/              shared env-var helpers/constants
├── mdm/              MicroMDM client + webhook handling
├── payments/         ledger + pricing (+ baserewards/)
├── profilesign/      CMS-signing of .mobileconfig enrollment profiles
├── protocol/         WebSocket message types shared with provider (type_scan.go: single-parse frame decode)
├── ratelimit/        rate limiting
├── registry/         provider registry, queueing, routing, reputation, token-budget admission,
│                     warm-pool controller, two-lane provider WS writer (provider_writer.go),
│                     routingsim/ (trace-driven routing simulation harness)
├── saferun/          panic-safe goroutine runners
├── stateexport/      consistent encrypted archive of MicroMDM (+ legacy step-ca) state (migration)
├── store/            in-memory or Postgres persistence
├── telemetry/        telemetry event emitter (process logs + Datadog forwarding)
├── datadog/          Datadog APM / DogStatsD / Logs API client
├── deploy/           container entrypoint (start.sh)
└── internal/e2e/     X25519 request-encryption helpers (+ cross-compat/tamper tests)

e2e/                  System-level E2E testing framework
├── integration_test.go  14 E2E tests (streaming, billing, encryption, attestation, etc.)
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
├── Sources/ProviderCoreFoundation/   model manifests, scanner, weight hashing, template render check, daemon-state
│                                     schema (`DaemonState`/`DaemonStateFile`), local-endpoint discovery record
│                                     (`LocalEndpointInfo`), launchd labels (`DarkbloomServiceLabels`) — no-MLX,
│                                     Linux-buildable; the ONLY provider layer the macOS app links
├── Sources/DarkbloomApp/             SwiftUI macOS app (window + menu bar). Views stay fixture-driven for
│                                     deterministic previews; real launches are a UI wrapper over machine-readable
│                                     CLI/file contracts. Fresh setup runs readiness → account → enrollment →
│                                     model download/start → live trust verification with no Terminal. Release apps
│                                     relocate to ~/.darkbloom/Darkbloom.app before setup. NO MLX/ProviderCore dependency.
├── Sources/darkbloom/                CLI (`start`, `stop`, `status`, `models`, `benchmark`, `doctor --json`,
│                                     `login --json`, `logout`, `config get|set schedule`, `earnings`, `local`, etc. —
│                                     every machine-readable mode the app consumes)
├── Sources/darkbloom-publish/        registry manifest builder used by publish workflow
├── Sources/darkbloom-enclave-cli/    Secure Enclave attestation/sign helper
├── Sources/ProviderBenchmark*, kv-*  benchmark + KV-cache self-test executables
└── Tests/                            ProviderCore, ProviderCoreFoundation, CLI, app (incl. hermetic fresh-install), and publish tests

console-ui/           Next.js 16 / React 19 frontend
├── src/app/          chat (/), billing, models, stats, providers, settings, link, api-console, earn, login
├── src/app/api/      chat, auth/keys, keys, payments/*, invite, models, health, pricing, stats,
│                     telemetry, attestation, device, encryption-key, leaderboard, me, network, admin
├── src/components/   chat UI, sidebar, top bar, trust badge, verification panel, invite banner
├── src/components/providers/
│   ├── PrivyClientProvider.tsx
│   └── ThemeProvider.tsx
├── src/lib/          API client (src/lib/api/) + Zustand store (store.ts)
├── src/hooks/        auth (useAuth.ts), toast (useToast.ts), chat streaming (useChatStream.ts)
└── src/proxy.ts      Next.js 16 proxy (replaces middleware.ts)

admin-ui/             Next.js 16 internal read-only ops dashboard (SELECT-only queries against the
                      prod read replica; Basic Auth via src/proxy.ts; has vitest tests, not in CI)

landing/              static landing page (index.html, earn calculator, network stats)

scripts/              build, signing, install, and deploy helpers
├── install.sh        end-user installer served from coordinator (hash + codesign verification, ownership-aware Darkbloom.app swap)
├── admin.sh          admin CLI (Privy auth, release mgmt, API calls)
├── publish-model.sh  model registry publish workflow
├── bundle-macos-app.sh Darkbloom.app assembly (CLI + GUI binaries, fonts, metallib) shared by CI and local builds
├── fetch-metallib.sh MLX metallib builder (cmake from libs/mlx-swift source)
├── smoke-dev.sh      dev-coordinator smoke test
├── test-macos-app-unsigned-debug-lifecycle.sh hermetic unsigned DEBUG bundle/window + fresh-user lifecycle smoke (not signing/relocation)
├── qualify-signed-macos-app.sh non-destructive Developer ID/notary/Gatekeeper qualification for a real artifact
├── benchmark-models.py, load_soak.py, …  benchmark + soak helpers
└── entitlements.plist DarkbloomApp GUI main-executable entitlements (network only; the CLI keeps its own under provider-swift/)

deploy/               infra config: gcp/ (Cloud Build + VM bootstrap), environments/ (dev/prod env),
                      datadog/ (dashboard JSON), provider-fleet/ (fleet update helper)

docs/                 architecture, deploy runbooks, MDM notes, threat model
.github/workflows/    CI (ci.yml), integration tests (integration.yml), Swift release (release-swift.yml),
                      model registration (register-model.yml), threat model review (threat-model-review.yml)
```

## Current Surface Area

- Coordinator HTTP routes include `POST /v1/chat/completions`, `POST /v1/responses`, `POST /v1/completions`, `POST /v1/messages`, `GET /v1/models`, `GET /v1/models/capacity`, billing/pricing endpoints, invite flows, stats, enrollment, device authorization, and release registration endpoints.
- Coordinator auth is split between Privy JWTs, API keys, and device-code login (RFC 8628) for provider machines.
- Routing uses token-budget admission with engine-reported capacity, speculative TTFT dispatch, EWMA TPS tracking, and early 429 with Retry-After for OpenRouter compatibility.
- Billing logic is split between `coordinator/payments` (ledger + pricing) and `coordinator/billing` (Stripe, referrals).
- Providers serve text inference through the Swift `darkbloom` CLI with continuous batching via MLX-Swift.
- Model registry data is DB-backed in the coordinator and points to R2 manifests under `https://models.darkbloom.ai`; model bytes are not hardcoded in the provider or UI.
- Streaming hot path: provider frames are decoded in a single parse (`coordinator/protocol/type_scan.go` scans the `type` key; malformed input falls back to a full envelope decode); per-request X25519 shared keys are memoized for chunk decryption and forgotten on request terminal (`coordinator/api/chunk_key_cache.go`); all writes to a provider WebSocket go through a two-lane writer (`coordinator/registry/provider_writer.go`) with a per-connection write watchdog — control frames (challenges, cancels, trust status) take strict (non-preemptive) priority over data frames, FIFO holds only within a lane, and `WriteText` blocks until the frame is on the wire.
- Observability: Datadog metrics (DogStatsD) for attestation, routing, billing, fleet version, and provider capacity. X-Timing header decomposes per-request latency.

## Building And Testing

Toolchain versions (Go, Node, Swift, Python, plus `jq`/`gh`/`awscli`/`gcloud`)
are pinned in [`mise.toml`](mise.toml). Build/test commands are wrapped in the
root [`Makefile`](Makefile) — run `make` with no args to list all targets.

### One-time setup
```bash
mise install            # installs every tool pinned in mise.toml
make ui-install         # console-ui npm deps
```

### Coordinator (Go)
```bash
make coordinator-test         # cd coordinator && go test ./...
make coordinator-build        # cd coordinator && go build ./cmd/coordinator
make coordinator-build-linux  # GOOS=linux GOARCH=amd64 CGO_ENABLED=0 build (GCP prod container)
make coordinator              # test + build
```

### Provider (Swift)
```bash
make provider-build           # cd provider-swift && swift build
make provider-test            # cd provider-swift && swift test
make provider                 # build + test
```

### Console UI (Next.js 16)
```bash
make ui-install               # npm install
make ui-build                 # npm run build
make ui-lint                  # npx eslint src/
make ui-test                  # vitest (npm test)
make ui                       # install + lint + test + build
```

### E2E Integration Tests
```bash
# Requires Postgres + Swift provider binary + MLX model downloaded.
make e2e-integration          # go test ./e2e/... -run TestIntegration -v
make e2e-benchmark            # go test ./e2e/... -run TestBenchmark -v
```

### Aggregates
```bash
make test                     # all unit tests (coordinator + provider + ui)
make build                    # build all components
make all                      # test + build everything
make clean                    # remove built artifacts
```

## Deploying

Canonical runbook: `docs/operations/coordinator-deploy.md`

Production GCP deploys, VM/container/service/config/secret mutations, and traffic
changes require explicit human approval for the specific operation. A human
operator or human-approved agent may execute them. Without that approval, agents
may only prepare and push reviewed code and perform read-only health inspection.

Current release-sensitive pieces:

- Prod coordinator runs on the GCE VM `darkbloom-coordinator` in the
  `darkbloom-mainnet` project at `api.darkbloom.dev`. Build target:
  `coordinator/Dockerfile`. Dev runs in the separate `sepolia-ai` project.
- Provider bundle creation (staging, .app wrapping, signing, notarization) lives in `.github/workflows/release-swift.yml`, with `Darkbloom.app` assembly factored into `scripts/bundle-macos-app.sh` (shared by CI and local runs). The release bundle co-bundles the GUI: `Contents/MacOS/{DarkbloomApp,darkbloom,darkbloom-enclave}`; the app's CLI locator probes its own bundle first, then `~/.darkbloom/bin`, then PATH symlinks. Human-facing releases upload the POST-STAPLE `Darkbloom-macOS-arm64.zip`; the legacy tar remains the coordinator/self-update artifact.
- Installer flow lives in `scripts/install.sh`. The canonical actual bundle is `~/.darkbloom/Darkbloom.app`; `~/Applications/Darkbloom.app` is a guarded symlink for discoverability. Direct downloads authenticate the pinned Team/designated requirement, relocate to the canonical bundle, relaunch, and only then begin onboarding. Never run launchd from Downloads or use `~/Applications` as the SelfUpdater root (its `bin/`/`recovery/` layout requires the dedicated `~/.darkbloom` root).
- Provider update checks read the latest registered release from the store (CI registers via `POST /v1/releases`). The installer and `darkbloom update` hit `GET /v1/releases/latest`, which returns **404 when no release row exists** — a missing/mis-registered release row breaks installs and self-updates and is fixed by registering the release, not by bumping code. `LatestProviderVersion` in `coordinator/api/server.go` is only the no-release-row fallback for the version *display* path and must stay in sync with `ProviderCore.version`.
- CI release workflow (`release-swift.yml`) signs binaries with Developer ID Application cert, notarizes with Apple, computes SHA-256 hashes after signing, embeds provisioning profile in .app bundle.

Production coordinator build and human-approved deploy:

```bash
# The repository trigger builds/pushes the exact master commit. Direct local
# gcloud builds submit is rejected by the production config.
git push origin master
gcloud builds list --project=darkbloom-mainnet --limit=5
# The human-approved container-swap procedure is in the runbook.
curl https://api.darkbloom.dev/health
```

Dev coordinator deploy (Google Cloud): see `docs/operations/dev-environment.md`.

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
- If you change provider bundle semantics, keep the bundle steps in `.github/workflows/release-swift.yml`, `scripts/install.sh`, and `LatestProviderVersion` in sync.
- If you change install paths or process invocation, update both the CLI and install flow.
- Device linking changes often span both coordinator device auth endpoints and the provider `login` / `logout` commands.
- Model registry changes span coordinator registry schema/endpoints, `provider-swift` manifest download/publish code, `scripts/publish-model.sh`, and the console UI. Do not add hardcoded provider `MODEL_CATALOG` lists.
- `~/.darkbloom/daemon-state.json` is a four-consumer contract: the daemon (writer, `ProviderLoop+Trust.swift`), `darkbloom status`/`doctor`, `darkbloom config` (schedule display), and **DarkbloomApp** (`Services/DaemonRuntimeService`, verification gating). Its schema lives ONCE in `provider-swift/Sources/ProviderCoreFoundation/DaemonState.swift` — never re-declare it app-side; new fields must be ADDITIVE + optional (nil = not reported; `slots`/`schedule` are the precedent) and `DaemonState.currentSchema` bumps stay deliberate (readers reject forward versions).
- Same single-source rule for the other app/CLI shared contracts: `~/.darkbloom/local.json` (`ProviderCoreFoundation/LocalEndpointInfo.swift`), launchd labels (`ProviderCoreFoundation/ProviderServiceLabels.swift`), and **`~/.darkbloom/provider_account`** (`ProviderCore/Auth/ProviderAccountStore.swift`): the coordinator account id captured at `darkbloom login` — earnings (`darkbloom earnings`) and daemon-state `identity` key on it, and `logout` must clear it (tested).
- App↔CLI machine interfaces (the app is a UI wrapper: reads shared files, drives `darkbloom` subprocesses for actions — never reimplements daemon policy app-side). Their shapes are pinned by golden tests on BOTH sides and must change together:
  - `darkbloom models download --json` NDJSON events (CLI: `ModelsCommand.swift` `ModelsDownloadEventEmitter` ← `ModelDownloader.DownloadEvent`; app: `Services/ModelCatalogCLI.swift`).
  - `darkbloom login --json` NDJSON events (emission seam in `ProviderCore/Auth/DeviceAuth.swift`; app: `Services/AccountLinkCLI.swift`).
  - `darkbloom enroll --json` schema-1 one-shot result (`already_enrolled` / `profile_opened` / `profile_downloaded`; CLI: `EnrollCommand.swift`; app: `Services/EnrollmentCLI.swift`). JSON mode never claims `profile_opened` unless LaunchServices actually accepted the profile.
  - `darkbloom doctor --json` `DoctorReport` (schema in `ProviderCore/Diagnostics/DoctorReport.swift`, one-truth-two-renderers with the human output; app mirror: `Services/DiagnosticsCLI.swift`).
  - `darkbloom config get|set schedule ... --json` (`darkbloom/ConfigCommand.swift`; app: `Services/AvailabilityCLI.swift`).
  - `darkbloom earnings --json` (`darkbloom/EarningsCommand.swift` ← authenticated coordinator `GET /v1/provider/account-earnings`; app shares `ProviderAccountEarningsReport` from `ProviderCoreFoundation` via `Services/ContributionsCLI.swift`; `--wallet` alone keeps the legacy unlinked endpoint).
  - Fresh onboarding starts the provider only through exact noninteractive argv `darkbloom start --model <catalog-id> --local-endpoint`; completion requires fresh daemon state, live matching daemon/endpoint PIDs, selected model current/warm, and verified hardware trust. A successful launchd bootstrap alone is NOT setup success.
- Account-scoped app data is the documented wrapper exception: the app talks to the coordinator directly with a Privy JWT minted via the console handoff page (`console-ui/src/app/auth/app-link/page.tsx` → `darkbloom://auth/callback#token=…` fragment-only, stored in the keychain): `FleetClient` + `AccountSessionManager` app-side. Changes to `/v1/me/*` response shapes need the console decoder AND `FleetClient`.
- The app must never gain a ProviderCore/MLX dependency: it links only `ProviderCoreFoundation`. Shared wire/file types belong in the foundation layer (Linux-buildable, Foundation-only); anything inference-adjacent stays out (e.g. `DaemonSlotPostureBuilder` remains in ProviderCore because it consults `EngineV2KVBackendPolicy`; `DoctorReport` stays in ProviderCore since only the CLI emits it).
- `scripts/test-macos-app-unsigned-debug-lifecycle.sh` assembles an unsigned release-ID fixture but launches the DEBUG executable with the DEBUG-only relocation bypass under `env -i`; it must reach the exact settled `main`/`Darkbloom` 1040×680 welcome window and `.ready` install state. Any installation-error window is a failure. It does not test signing or relocation; `scripts/qualify-signed-macos-app.sh` and the manual clean-Mac checklist cover the real protected artifact.

## Common Pitfalls

- `coordinator/coordinator` may exist locally as a build artifact (it is gitignored, not tracked). Do not model changes from it, and never commit binaries or other built artifacts.
- CI release workflow must compute binary SHA-256 hashes AFTER code signing, not before. Providers verify hashes of the signed binary.
- Model scan uses fast discovery (no hashing) at startup (`ModelScanner`). Weight hashing is on-demand via `WeightHasher.computeHash(for:)` only for models that need attestation/verification. Don't add hashing back to the scan path.
- Models with broken chat templates are not auto-repaired. The provider runs a scan-time chat-template render self-check (`TemplateRenderCheck`) and reports `template_render_ok=false`; the coordinator then fences **all** requests (plain text, tools, multimodal alike) away from that (provider, model) pair — a crashing template breaks every request shape (`providerEligibleForTraitsLocked`, `registry/request_traits.go`). Only the capability *version floors* are tool-scoped.
- The vision tower is driven **one image at a time** (`EngineV2VisionTowerRun.qwenPerImageVisionFeatures`). Qwen3-VL's tower attends over whatever it is handed as one sequence with an N×N intermediate, so batching a request's images made peak device memory quadratic in the image count and asked Metal for buffers many times `MTLDevice.maxBufferLength`. Do not "optimize" the loop back into a single call. `VisionTowerBudget` predicts that peak from the processor's grids and the model's own vision config — the N² multiple is 1 when MLX can fuse the head dim (64/80/128, `sdpa_full_supported_head_dim`) and `numHeads` when it falls back and materializes `[1, H, N, N]` scores — and the whole prefill runs under `MLX.withError` because MLX's default handler is `fatalError`. That handler **records and returns**, so every `eval` site must check the box (`throwIfMLXFaulted`); checking only on block exit lets the code run on after a refused allocation and lets a later Swift throw hide the cause.
- Store selection (`cmd/coordinator/main.go`): the coordinator uses the **Postgres** store whenever `EIGENINFERENCE_DATABASE_URL` is set (prod does — durable across restarts/deploys), and refuses to start without it unless `EIGENINFERENCE_ALLOW_MEMORY_STORE=true`. The in-memory store is the dev/test fallback only (state lost on restart). Note: the live provider *registry* (WebSocket connections/attestation) is always in-process and is rebuilt on reconnect regardless of store.
- Request queue timeout is 120 seconds. Initial attestation challenge is sent immediately on registration, then every 5 minutes.
- Backend idle timeout is 1 hour (not 10 minutes as some comments may say).
- `handleChunk` never silently drops streamed chunks: when a consumer's chunk buffer is full it gets one 250ms grace window (`chunkOverflowGrace`), then the request is failed with 499 and the provider's generation is cancelled.
- `hypervisor_active` is retired (#492): current providers no longer send it, but `AttestationResponseMessage.HypervisorActive` and the canonical-status support must keep decoding so signed payloads from older (< v0.6.31) providers still verify. Remove only once the fleet version floor passes v0.6.31.

### Coordinator State Model — Multiple Overlapping Views

Provider state lives in several fields that are read by different code paths with different precedence rules. When mutating any of these, trace every reader:

- `BackendCapacity.Slots` is **authoritative** for the scheduler when present (Swift providers). The scheduler derives `slotState`, `modelLoaded`, token budgets, and observed TPS from it. `WarmModels` is only a fallback for legacy providers without `BackendCapacity`.
- `WarmModels` is updated by heartbeats. It is NOT consulted by `snapshotProviderLocked` or `buildCandidateWithReason` when `BackendCapacity` is non-nil. `TriggerModelSwaps` / `hasWarmProviderLocked` checks it as a fallback, and `/v1/me/providers` copies it into API responses.
- `CurrentModel` is set from heartbeat `active_model`. A nil/omitted `active_model` means no model is loaded. Stale `CurrentModel` can cause attestation hash mismatches.
- `pendingModelLoads` is checked by `TriggerModelSwaps` planning, cold-spill eligibility (`registry/cold_dispatch.go`), and the warm-pool controller's target math. It is NOT checked by `QuickCapacityCheck`, `ReserveProviderEx`, or `freeMemoryAdmits` — do not assume pending-load state affects routing admission.
- Provider-reported slot states include `"running"` (active requests), `"idle"` (loaded, no requests), `"crashed"`, `"reloading"`, and `"idle_shutdown"`. The `"idle"` state means the model IS loaded — treat it the same as `"running"` for warm detection, not as `"unknown"`.
- Providers can hold up to `maxModelSlots` models simultaneously (default 3). Do not assume a model swap evicts all other models.
- The provider's memory model is `UnifiedMemoryCap` (`provider-swift/Sources/ProviderCore/Inference/UnifiedMemoryCap.swift`): hard cap = 0.90 × physical RAM (always leaving ≥ 2 GiB for the OS; `DARKBLOOM_MEM_CAP_FRACTION` override). The model-load gate requires resident weights + incoming weights + ~6.5 GiB headroom (5.5 GiB activation reserve plus 1 GiB minimum KV) ≤ the cap, and a post-load guard unloads a freshly-loaded model whose measured live KV headroom is below the minimum serveable KV. The `DARKBLOOM_ACTIVATION_RESERVE_GB` env override is **raise-only**: values below the 5.5 GiB default are clamped up to it (a lower reserve recreates the B=8 OOM the default was measured against, while the coordinator keeps predicting 5.5); only programmatic `activationReserveBytes` values (tests) are honored as given. The coordinator's `freeMemoryAdmits` mirrors this exactly when the provider reports `freeForLoadGB` (already net of cap, reserves, and evictable idle models); only legacy providers without that field fall back to a coarser total-memory heuristic, where a model the coordinator admits can still fail on the provider side.
- The activation reserve inside that cap is **flat**: 5.5 GiB for every model, every attention posture, every batch (raised from 3 GiB for v0.8.0 — B=8 continuous-batching measurements peaked ~5.2 GiB of transient activation memory; the old figure was sized for B=4). `coordinator/registry/servability.go` mirrors it as `servabilityActivationFloorGB`, selected **per provider version** by `servabilityActivationFloorForVersion` so `coldTokenBudgetEstimate` can predict a not-yet-loaded slot's post-load token budget — a cold slot sends no heartbeat, so there is nothing to read instead: 5.5 GiB for ≥ 0.8.0 providers, and the legacy 3 GiB for pre-0.8.0 or unknown-version providers (fail-open: over-predicting a legacy budget risks one provider-side refusal the retry machinery absorbs, while under-predicting produces terminal client-visible 429s during a staged rollout). The provider figure and the coordinator's ≥ 0.8.0 floor are equal only because someone moves both; retuning the reserve on one side alone silently desyncs admission. That has happened once: the coordinator briefly charged a per-token score-tensor surcharge the provider never held back, making it strictly tighter than the gate it mirrors and 429ing prompts the fleet could serve. Do not re-introduce a per-model or per-shape reserve on either side without the other.

### Coordinator Mutation Checklist

When adding code that mutates provider state or sends commands (`load_model`, etc.):

1. Enumerate every reader of the fields you're mutating (`BackendCapacity.Slots`, `WarmModels`, `CurrentModel`, `pendingModelLoads`).
2. Check what happens on the failure path — does state get cleaned up on disconnect, timeout, and load failure?
3. Check concurrent access — heartbeats arrive per-provider on separate goroutines; `TriggerModelSwaps` can race with `drainQueuedRequestsForModels`.
4. Check the cleanup path — `Disconnect()` must clear any per-provider state you add.
5. Verify pre-existing invariants: `maxModelSlots`, heartbeat field omission semantics (`nil` vs empty), and the `UnifiedMemoryCap` load gate on the provider side.

## Code Structure & Modularity

Keep the codebase modular, never monolithic.

- Prefer small, single-responsibility files over large catch-all ones. Split by concern: types, pure helpers, data/IO hooks, UI pieces, and a thin orchestrator that wires them together.
- Group a feature's files into a dedicated module/folder with a thin entry point. Examples: the coordinator's top-level Go packages (`registry/`, `billing/`, `store/`), and `console-ui/src/components/api-keys/` (`constants`, `format`, `limits`, `Modal`, `KeyForm`, `KeyCard`, a `useApiKeys` data hook, and a thin `ApiKeysManager` orchestrator).
- One file/component should do one thing. If a file mixes several concerns or grows past a few hundred lines, that's a signal to split it.
- **At the end of every large piece of work, do a refactor pass to make it modular before calling it done.** Extract helpers/types/hooks into focused files, delete dead code, and keep the public entry point thin. The refactor must be behavior-preserving — build, lint, and tests stay green.

## Pull Requests

**Every PR MUST include a before-and-after diagram (Mermaid) in its description** that details what changed — covering BOTH:

- **Behavior**: the request/response flow, states, and outcomes a user or caller observes (e.g. dispatch → retry → 429/503/200).
- **Code**: which functions/components changed and how control flows through them.

Use two clearly labeled diagrams — a **Before** and an **After** — (or one side-by-side comparison) so a reviewer sees the delta at a glance. Scope it to what the PR changes; it is not a full-system map. A PR without a before/after diagram is not ready for review.

````markdown
```mermaid
flowchart LR
  subgraph Before
    A1[request] --> B1[old behavior / code path]
  end
  subgraph After
    A2[request] --> B2[new behavior / code path]
  end
```
````

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
