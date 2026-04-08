# EigenInference - Decentralized GPU Inference

Decentralized inference network for Apple Silicon Macs. Providers offer GPU compute, consumers send OpenAI-compatible requests, the coordinator matches them.

## Project Structure

```
coordinator/          Go — central matchmaking server (runs on AWS)
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

app/EigenInference/   Swift — macOS menu bar app (SwiftUI)
├── Sources/EigenInference/
│   ├── EigenInferenceApp.swift    App entry, menu bar setup
│   ├── StatusViewModel.swift      Core state management
│   ├── ProviderManager.swift      Provider subprocess lifecycle
│   ├── CLIRunner.swift            Launches eigeninference-provider
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
├── Tests/EigenInferenceTests/

enclave/              Swift — Secure Enclave attestation CLI helper
├── Sources/
│   ├── EigenInferenceEnclave/     Library (P-256 key gen, attestation blob, FFI bridge for Rust)
│   └── EigenInferenceEnclaveCLI/  CLI tool (attest, sign, derive-e2e-key, info, wallet-address)
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

## SSH

Use persistent SSH control sockets to avoid rate limits when running multiple commands against the same host:

```bash
# First connection opens the socket (add to first SSH/SCP call):
ssh -o ControlMaster=auto -o ControlPath=/tmp/ssh-%r@%h -o ControlPersist=600 -i ~/.ssh/eigeninference-infra ubuntu@34.197.17.112 "..."

# Subsequent calls reuse it automatically (same ControlPath):
ssh -o ControlPath=/tmp/ssh-%r@%h ubuntu@34.197.17.112 "..."
scp -o ControlPath=/tmp/ssh-%r@%h file ubuntu@34.197.17.112:/path
```

Always use control sockets when running multiple SSH/SCP commands to the same host in a session.

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

## Formatting

A pre-commit hook in `.githooks/pre-commit` checks formatting on staged files only. It is enabled via `git config core.hooksPath .githooks` (already set for this repo).

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
