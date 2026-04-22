# EigenInference - Decentralized GPU Inference

Decentralized inference network for Apple Silicon Macs. Providers offer GPU compute, consumers send OpenAI-compatible requests, the coordinator matches them.

## Project Structure

```
coordinator/          Go — central matchmaking server (runs on EigenCloud in prod)
├── cmd/coordinator/  entrypoint
├── cmd/verify-attestation/  attestation blob verification utility
├── internal/
│   ├── api/          HTTP + WebSocket handlers (consumer.go, provider.go, billing_handlers.go, device_auth.go, invite_handlers.go, release_handlers.go, enroll.go, stats.go, server.go)
│   ├── attestation/  Secure Enclave + MDA attestation verification
│   ├── auth/         Privy JWT verification + user provisioning
│   ├── billing/      Stripe, Solana USDC deposits, referral system
│   ├── e2e/          End-to-end encryption (X25519 key exchange)
│   ├── mdm/          MicroMDM integration for device attestation
│   ├── payments/     Internal ledger, pricing tables, payout tracking
│   ├── protocol/     WebSocket message types shared with provider
│   ├── registry/     Provider registry, scoring, reputation, request queue
│   └── store/        Persistence (in-memory or Postgres)

provider/             Rust — runs on Apple Silicon Macs
├── src/
│   ├── main.rs       CLI entry (serve, start, stop, models, benchmark, status, doctor, login, etc.)
│   ├── coordinator.rs WebSocket client with auto-reconnect
│   ├── proxy.rs      Forwards text/transcription/image requests to local backends
│   ├── hardware.rs   Apple Silicon detection, system metrics (memory/CPU/thermal)
│   ├── protocol.rs   Message types (mirrors coordinator/internal/protocol)
│   ├── backend/      Backend process management (vllm_mlx.rs, health checks)
│   ├── crypto.rs     X25519 key pair (NaCl), E2E decryption
│   ├── security.rs   SIP checks, binary self-hash, anti-debug (PT_DENY_ATTACH)
│   ├── models.rs     Scans ~/.cache/huggingface for available models (fast discovery, on-demand hashing)
│   ├── config.rs     TOML config + hardware-based defaults
│   ├── inference.rs  In-process MLX inference (behind "python" feature flag)
│   ├── server.rs     Local HTTP server (standalone mode without coordinator)
│   ├── hypervisor.rs Hypervisor.framework memory isolation (Stage 2 page tables)
│   ├── scheduling.rs Time-based availability windows
│   ├── service.rs    launchd user agent management
│   └── wallet.rs     Legacy provider wallet (secp256k1)
├── stt_server.py     Local speech-to-text server script

image-bridge/         Python FastAPI image generation bridge
├── eigeninference_image_bridge/
│   ├── server.py     OpenAI-compatible /v1/images/generations
│   └── drawthings_backend.py  Draw Things gRPC backend adapter
├── requirements.txt
└── tests/

app/Darkbloom/        Swift — macOS menu bar app (SwiftUI)
├── Sources/Darkbloom/
│   ├── DarkbloomApp.swift         App entry, menu bar setup
│   ├── StatusViewModel.swift      Core state management
│   ├── ProviderManager.swift      Provider subprocess lifecycle
│   ├── CLIRunner.swift            Launches darkbloom
│   ├── ConfigManager.swift        TOML config read/write
│   ├── SecurityManager.swift      Trust level checks (SIP, SE, MDM, Secure Boot)
│   ├── ModelManager.swift         HuggingFace model scanning
│   ├── ModelCatalog.swift         Static model catalog
│   ├── LaunchAgentManager.swift   macOS launch agent
│   ├── NotificationManager.swift  System notifications
│   ├── UpdateManager.swift        Version checking
│   ├── IdleDetector.swift         User idle detection
│   ├── DesignSystem.swift         Colors, typography, UI primitives
│   ├── DashboardView.swift        Main dashboard
│   ├── SettingsView.swift         Preferences (General, Availability, Model, Security tabs)
│   ├── MenuBarView.swift          Menu bar dropdown
│   ├── SetupWizardView.swift      6-step onboarding wizard
│   ├── DoctorView.swift           Diagnostics display
│   ├── LogViewerView.swift        Log viewer with live streaming
│   ├── ModelCatalogView.swift     Model browser with RAM fit indicators
│   ├── GuideAvatar.swift          Animated mascot (mood-based PNGs)
│   └── Illustrations.swift        Procedural Mac illustration
├── Tests/DarkbloomTests/

enclave/              Swift — Secure Enclave attestation CLI helper
├── Sources/
│   ├── EigenInferenceEnclave/     Library (P-256 key gen, attestation blob, FFI bridge for Rust)
│   └── EigenInferenceEnclaveCLI/  CLI tool (attest, sign, info, wallet-address)
├── Tests/EigenInferenceEnclaveTests/
└── include/eigeninference_enclave.h

console-ui/           Next.js 16 / React 19 frontend (chat, billing, models, images)
├── src/app/          Pages: chat (/), billing, images, models, stats, providers, settings, link, api-console, earn
├── src/app/api/      Proxy routes: chat, models, images, transcribe, auth/keys, payments/*, invite, health, pricing
├── src/components/   Chat UI, sidebar, top bar, trust badges, invite banner, verification panel
├── src/lib/          API client (api.ts), Zustand store (store.ts)
├── src/hooks/        Auth (useAuth.ts), toast notifications (useToast.ts)
└── proxy.ts          Next.js 16 proxy (replaces middleware.ts)

scripts/
├── build-bundle.sh   Provider/enclave/python/ffmpeg bundle builder (+ optional upload)
├── bundle-app.sh     macOS .app bundle + DMG
├── install.sh        curl one-liner installer (fetches release, verifies SHA-256 + code signature)
├── sign-hardened.sh  Hardened runtime signing helper
├── admin.sh          Admin CLI (Privy auth, release mgmt, API calls)
├── deploy-acme.sh    nginx/step-ca helper
├── test-stt-e2e.sh   Speech-to-text smoke test
└── entitlements.plist Hardened Runtime entitlements (hypervisor, network)

docs/                 Architecture docs, deploy runbook, MDM/ACME notes
landing/              Static landing page (index.html)
.github/workflows/    CI (ci.yml) and release automation (release.yml)

.external/            Git-ignored; holds external forks used by the project (NOT part of this repo)
└── vllm-mlx/         Our fork of vllm-mlx (github.com/Gajesh2007/vllm-mlx)
```

### External Dependencies (`.external/`)

The `.external/` directory contains our fork of [vllm-mlx](https://github.com/Gajesh2007/vllm-mlx) — the MLX inference backend that the provider spawns as `vllm-mlx serve <model>`. This is a separate git repo and **must never be committed to d-inference** (it is git-ignored). Changes to vllm-mlx should be made in that repo directly, not here.

## Building & Testing

### Coordinator (Go)
```bash
cd coordinator
go test ./...
# Cross-compile for the EigenCloud container (Linux amd64):
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

### Image Bridge (Python)
```bash
cd image-bridge
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt pytest httpx
PYTHONPATH=. pytest
```

## Releases

**Never create a release unless explicitly asked by the user.** When asked:

1. **Squash push**: All local commits since the last tag should be squash-pushed into a single commit on master.
2. **Bump version**: Update `provider/Cargo.toml` version.
3. **Create annotated tag** with a description summarizing all changes:
   ```bash
   git tag -a v0.X.Y -m "v0.X.Y: one-line summary

   - Change 1
   - Change 2
   - ..."
   ```
4. **Push** the commit and tag: `git push origin master --tags`
5. The CI release workflow (`.github/workflows/release.yml`) is triggered by the tag push.

## Deploying

Full deploy runbook: **[docs/coordinator-deploy-runbook.md](docs/coordinator-deploy-runbook.md)**

Covers coordinator deploy, provider CLI bundling, macOS app distribution, and install.sh updates.

### Coordinator (prod, EigenCloud)

> **AI agents must NOT deploy to EigenCloud.** Prod deploys (`ecloud compute app deploy …`, any mutation of the `d-inference` EigenCloud app, any write to EigenCloud KMS or prod secrets) are a human-only action. If asked to ship to prod, stop and hand off — prepare the PR, the tag, or the exact commands, but do not execute them. This applies even when the user says "deploy"; confirm they mean *they* will run it, not you. Read-only commands like `ecloud compute app logs d-inference` or `curl https://api.darkbloom.dev/health` are fine.

The prod coordinator runs on EigenCloud (TEE). Build target is `coordinator/Dockerfile`; EigenCloud builds from the repo and injects Caddy + TLS. Deploy is blue-green with persistent disk transfer (`/mnt/disks/userdata`).

Human-only deploy flow (for reference — do not run this as the agent):

```bash
# 1. Push your changes (agent may do this if explicitly asked)
git push origin master

# 2. Trigger EigenCloud deploy — HUMAN ONLY
ecloud compute app deploy d-inference

# 3. Verify (agent may do this)
curl https://api.darkbloom.dev/health
ecloud compute app logs d-inference
```

Deploy time: ~5-7 minutes. Env vars/secrets are managed via EigenCloud KMS — see `docs/coordinator-deploy-runbook.md` for the full list.

### Coordinator (dev, Google Cloud)

The dev coordinator runs on GCP (project `sepolia-ai`) — separate domain (`api.dev.darkbloom.xyz`), separate R2 bucket (`d-inf-app-dev`), **same** trust level as prod (`MIN_TRUST=hardware`, full MDM + step-ca stack). Mainnet Solana with a dev-only BIP39 mnemonic. **Never** used for prod traffic. Full wiring in [docs/dev-environment.md](docs/dev-environment.md).

Shape: GCE Ubuntu VM + Docker + systemd (coordinator + step-ca + MicroMDM need persistent disk state), Cloud SQL Postgres via cloud-sql-proxy, **Vercel**-hosted console UI, Cloud Build auto-deploys on master push. ~2–4 min coordinator upgrades.

### Provider bundle

CI (`.github/workflows/release.yml`) builds, signs, notarizes, and uploads bundles to Cloudflare R2 (`s3://d-inf-app/releases/v{VERSION}/`), then registers the release with the coordinator via `POST /v1/releases`. Providers fetch via `install.sh` served by the coordinator. There is no SSH-to-a-VM step.

## Infrastructure

| Component | Prod | Dev |
|-----------|------|-----|
| Coordinator host | EigenCloud app `d-inference` | GCE VM `d-inference-dev` (us-central1-a, Ubuntu + Docker + systemd) |
| Console UI | EigenCloud app | Vercel (separate dev project, `NEXT_PUBLIC_COORDINATOR_URL=https://api.dev.darkbloom.xyz`) |
| Domain | `api.darkbloom.dev` | `api.dev.darkbloom.xyz` |
| TLS | Caddy + EigenCloud-injected certs | Caddy in-container (step-ca or Let's Encrypt ACME, VM :443) |
| Database | AWS RDS PostgreSQL (managed) | Cloud SQL Postgres 16 `d-inference-dev-db` via cloud-sql-proxy sidecar |
| Persistent storage | `/mnt/disks/userdata` (EigenCloud blue-green) | GCE persistent disk `d-inference-dev-data`, 30 GB, mounted at `/mnt/disks/userdata` |
| Logs | `ecloud compute app logs d-inference` | `gcloud logging read ...` (VM + Cloud SQL in Cloud Logging) |
| Release bucket | R2 `d-inf-app` | R2 `d-inf-app-dev` |
| Trust level | `hardware` (MDM enrollment required) | `hardware` (same — full MDM + step-ca stack) |
| Provider install | `curl -fsSL https://api.darkbloom.dev/install.sh \| bash` | `curl -fsSL https://api.dev.darkbloom.xyz/install.sh \| bash` |

## Key Design Decisions

- **Provider scoring**: decode TPS × trust multiplier × reputation × warm model bonus × health factor. Health factor uses live system metrics (memory pressure, CPU usage, thermal state) reported in heartbeats.
- **Request cancellation**: In-flight inference requests are tracked by request_id with CancellationToken. On coordinator disconnect, all in-flight requests are cancelled and the HTTP connection to vllm-mlx is dropped so it stops generating.
- **Idle GPU timeout**: Backend (vllm-mlx) process is killed after 1 hour of no requests to free GPU memory. Lazy-reloaded when the next request arrives (cold-start penalty of ~10-30s for model reload).
- **E2E encryption**: Consumer requests encrypted with provider's X25519 public key (NaCl box). Coordinator never sees plaintext prompts. Decryption only inside the hardened provider process.
- **Attestation chain**: Secure Enclave P-256 key → signs attestation blob → coordinator verifies signature (self_signed) → MDM SecurityInfo cross-check (hardware trust) → Apple Enterprise Attestation Root CA signs device cert chain via MDA (mda_verified). Full chain exposed at `GET /v1/providers/attestation` for user-side verification.
- **Protocol symmetry**: `provider/src/protocol.rs` and `coordinator/internal/protocol/messages.go` define the same WebSocket message types. Changes to one must be mirrored in the other.
- **Model catalog**: Coordinator maintains a catalog of supported models. Provider CLI filters local models against this catalog for serving and display. Only catalog models are served.
- **Billing**: Solana USDC deposits verified on-chain. Coordinator wallet derived from BIP39 mnemonic via SLIP-0010 (m/44'/501'/0'/0'). Stripe wired but inactive. Referral system gives referrers a share of platform fees.
- **Request queue**: When all providers are busy, requests queue with 120s timeout. Frontend shows "providers are busy" on 503.
- **Challenge timing**: Initial attestation challenge sent immediately on provider registration, then every 5 minutes via ticker.
- **Model scan performance**: `scan_models()` does fast discovery without hashing. Weight hash computed on-demand only for the model being served via `compute_weight_hash()`.
- **Chat template injection**: Provider auto-injects ChatML template for models missing `chat_template` field (e.g., Qwen3.5 base models).
- **Hypervisor memory isolation**: Apple Hypervisor.framework creates Stage 2 page tables to protect inference memory from RDMA/DMA attacks. Requires `com.apple.security.hypervisor` entitlement.
- **Device auth**: RFC 8628 device code flow for linking provider machines to user accounts. Provider runs `login`, gets a code, user enters it on the web.
- **CI code signing**: GitHub Actions release workflow signs provider binary with Developer ID Application cert, notarizes with Apple, computes SHA-256 hashes after signing.

## Problem-Solving Approach

Always think from first principles. When fixing a bug or designing a feature:

1. **Identify the root cause, not the symptom.** Don't patch the immediate error — ask "why does this happen?" repeatedly until you hit the fundamental cause. A hash mismatch isn't the problem; the problem is that CI and providers see different files.

2. **Enumerate the full state space.** Before implementing, ask: "What are ALL the possible states/file types/paths/scenarios?" Don't discover edge cases one at a time through production failures. For example: if hashing a directory, list every file type that could exist (.py, .so, .dylib, .pyc, .json, dirs) and decide how each is handled BEFORE writing code.

3. **Work both top-down and bottom-up.** Top-down: what's the user-visible guarantee we're providing? Bottom-up: what does the code actually do at each step? Find where they diverge.

4. **Simulate the full lifecycle locally before shipping.** Don't assume CI → provider → runtime will work. Actually run the full flow: build the artifact, extract it, hash it, simulate imports, hash again, compare. Verify the invariant holds end-to-end.

5. **Ask "what breaks next?" after every fix.** If you exclude .pyc from hashing, what can an attacker do with .pyc? If you purge before hashing, what regenerates .pyc between purge and the next check? Each fix must not create a new hole.

6. **Pull the thread on every component.** When debugging a failure, map every component in the chain (coordinator → provider → backend → vllm-mlx). Trace the actual flow step by step — look at real logs, real source code, real API responses at each boundary. When you see a specific error (e.g. "422 Unprocessable Entity"), immediately ask "what causes that exact status code in that exact server?" and trace it to the source. Don't theorize about what MIGHT be wrong — verify what IS wrong. Example: warmup was returning 422 for months because the request was missing a required `model` field. The 422 was right there in the logs the whole time. Instead of reading it, we spent time theorizing about timing windows and false positives in health checks. The error message IS the clue — follow it.

## Common Pitfalls

- Protocol changes require updating both `provider/src/protocol.rs` (Rust) AND `coordinator/internal/protocol/messages.go` (Go). They must stay in sync.
- Attestation tests need `AuthenticatedRootEnabled: true` in test blobs or the ARV check fails and overwrites earlier error messages (the checks run sequentially, last failure wins).
- The `python` feature flag in the provider Cargo.toml links PyO3. Use `--no-default-features` when building for distribution to avoid Python linking issues.
- The coordinator uses in-memory store by default. Provider state is lost on restart. Postgres store exists but is not used in production yet.
- Binary files like `coordinator/eigeninference-coordinator` and `coordinator/eigeninference-coordinator-linux` should NOT be committed to git (15MB+ each).
- CI release workflow must compute binary SHA-256 hashes AFTER code signing, not before. Providers verify hashes of the signed binary.
- Provider bundle semantics span multiple files: `scripts/build-bundle.sh`, `scripts/install.sh`, the Swift app launcher, and `LatestProviderVersion` in `coordinator/internal/api/server.go`. Keep them in sync.
- Image generation changes span three places: coordinator consumer/provider handlers, provider proxying, and `image-bridge/`.
- Device linking changes span coordinator device auth endpoints and provider `login`/`logout` commands.
- The repo contains mixed payment language: current code implements Privy + Solana + Stripe, but some provider comments still reference Tempo/pathUSD.

## Testing New Features

Every new feature or non-trivial change must ship with tests. Don't rely on "the reviewer will catch it" or "I'll test it manually once" — write tests that a future change can run.

- **Prefer live-isolated tests over mocks.** Spin up a real instance of the dependency in the test process or a throwaway local container (test Postgres via `pgx` + a temp database, a real in-process HTTP server via `httptest.NewServer`, a real in-memory store). Do NOT mock the thing you're actually trying to exercise — mocks hide real bugs (wrong SQL, stale schema, protocol drift). The lesson from past incidents: mocked tests passed while the prod migration failed.
- **Never point tests at production.** No live coordinator, no prod DB, no real wallets, no real Privy tenants. Each test harness builds its own isolated coordinator, its own in-memory or ephemeral store, its own seed data. If a test needs credentials, they're fake fixtures, not the real ones.
- **Cover both impls when a feature spans backends.** If a `store.Store` method gets a memory impl AND a postgres impl, both need coverage (memory in the default test suite; postgres behind a build tag or a local-only integration test that uses a throwaway DB).
- **Test the real HTTP path when possible.** For new endpoints, exercise them through `httptest.NewServer(srv.Handler())` (or the equivalent) — not by calling the handler function directly. That catches routing mistakes, middleware gaps, and path-parameter bugs.
- **Frontend features need frontend tests.** When adding a page or form, add at minimum a vitest for the component's validation + state. For UI that can't be easily unit-tested, boot the dev server and walk through the flow in a browser before declaring done — and say so in the handoff.
- **Regression: every bug fix gets a test that fails without the fix.** Otherwise the bug can come back silently.

The goal is "next engineer can change this and CI tells them if they broke it," not "it worked on my machine today."

## Quality Gate

After completing each objective (task, plan phase, or discrete unit of work), spawn **both** reviewers in parallel:

1. **Codex rescue subagent** (`codex:codex-rescue`) — reviews the diff for correctness, regressions, and build/test pass
2. **Claude Code subagent** (`Agent` tool, general-purpose) — independently reviews the same diff for correctness, edge cases, and code quality

Each reviewer should:

1. Read the diff of all changes made for that objective
2. Verify correctness: does the implementation actually solve what was asked?
3. Check for regressions: broken imports, missing protocol symmetry, untested edge cases
4. Confirm builds/tests pass for affected components (run `go test`, `cargo test`, `npm run build`, etc. as appropriate)
5. Report a pass/fail verdict with specific issues if any

Only proceed to the next objective after both reviewers pass. If either flags issues, fix them before moving on.

## Git Hooks

Hooks live in `.githooks/` and are enabled via `git config core.hooksPath .githooks` (already set for this repo).

- **pre-commit**: Checks formatting on staged files only (fast).
- **pre-push**: Runs formatting + compilation + tests for changed components. Includes `cargo build --no-default-features` to match CI's release build (the `python` feature flag changes compilation).

| Component | Check | Manual fix |
|-----------|-------|------------|
| Go (coordinator/) | `gofmt -l` | `gofmt -w <file>` |
| Rust (provider/) | `cargo fmt --check` | `cd provider && cargo fmt` |
| TypeScript (console-ui/) | `npx eslint src/` | `cd console-ui && npx eslint src/ --fix` |
| Swift (app/, enclave/) | skipped | no enforced formatter |

If you clone fresh, activate the hook with:
```bash
git config core.hooksPath .githooks
```
