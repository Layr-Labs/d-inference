# Darkbloom Architecture

## Overview

Darkbloom is a decentralized private inference network for Apple Silicon Macs. Mac owners provide idle compute; consumers get OpenAI-compatible inference on open-weight models with hardware-backed privacy guarantees. The coordinator handles routing, auth, billing, attestation, and capacity management. Providers run inference locally and in-process via MLX-Swift. Requests are end-to-end encrypted — the operator of a provider machine cannot read prompts or responses.

```
Consumer (OpenAI SDK / Anthropic SDK / Web UI / curl)
    |
    |  HTTPS (OpenAI-compatible API, api.darkbloom.dev)
    v
Coordinator (Go, EigenCloud TEE in prod / GCP VM in dev)
    |
    |  WebSocket (outbound from provider — no port forwarding)
    v
Provider CLI (`darkbloom`, hardened Swift process)
    |
    |  mlx-swift-lm (in-process, no subprocess/IPC)
    v
Apple Silicon GPU (Metal)
```

## Components

### Coordinator (`coordinator/`)

**Language:** Go. **Prod:** EigenCloud TEE app `d-inference` at `api.darkbloom.dev`. **Dev:** GCP VM at `api.dev.darkbloom.xyz` (see [runbooks/dev-environment.md](runbooks/dev-environment.md)).

The control plane. Top-level packages (not `internal/`):

| Package | Responsibility |
|---------|----------------|
| `api/` | HTTP + WebSocket handlers: consumer endpoints, provider relay, billing, device auth, enrollment, releases, stats |
| `attestation/` | Secure Enclave + Apple MDA verification |
| `apns/` | APNs-triggered code attestation |
| `auth/` | Privy JWT verification + user provisioning |
| `billing/` | Stripe, Solana USDC deposits, referrals |
| `e2e/` | X25519 (NaCl box) request-encryption helpers |
| `mdm/` | MicroMDM client + webhook handling |
| `payments/` | Internal micro-USD ledger + pricing tables |
| `protocol/` | WebSocket message types shared with the provider |
| `ratelimit/` | Consumer / financial-endpoint rate limiting |
| `registry/` | Provider registry, request queueing, routing, reputation, token-budget admission |
| `store/` | Persistence (in-memory or Postgres) |
| `telemetry/` | Datadog DogStatsD metrics |

Responsibilities:

- Accepts provider WebSocket connections (`GET /ws/provider`) and tracks availability, capacity, and health via heartbeats
- Exposes the consumer HTTP API: `POST /v1/chat/completions`, `/v1/completions`, `/v1/responses`, `/v1/messages` (Anthropic), `GET /v1/models`, plus billing/pricing/stats endpoints (full list in [api.md](api.md))
- Routes requests using token-budget admission with engine-reported capacity (see [Routing](#routing--capacity))
- Verifies provider attestations (Secure Enclave P-256 ECDSA signatures), challenges providers every 5 minutes, and immediately untrusts any provider whose SIP or Secure Boot is found disabled
- Verifies the provider binary hash against blessed release versions
- Manages API keys, usage tracking, the payment ledger, trust levels, invites, and referrals
- Encrypts each request with the target provider's X25519 public key before forwarding (sealed transport)
- Per-model request queues when all providers are busy; early 429 with `Retry-After` when the fleet is at capacity

### Provider (`provider-swift/`)

**Language:** Swift. Two binaries:

- `darkbloom` — the provider daemon. Subcommands: `serve`, `start`, `stop`, `status`, `doctor`, `models`, `login`, `logout`, `benchmark`, `earnings`, `update`, `verify`.
- `darkbloom-enclave` — stateless Secure Enclave attestation/sign helper (`attest`, `sign`, `info`, `wallet-address`).

Inference is **in-process** via [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm) (forked under `libs/mlx-swift-lm`). There is no subprocess, no local inference server, and no embedded Python interpreter — so there is no IPC or server surface to observe. NaCl `crypto_box` (XSalsa20-Poly1305 + Curve25519) comes from `swift-sodium`, wire-compatible with Go `nacl/box`. The Secure Enclave identity is native CryptoKit.

Key provider-side mechanics:

- **Continuous batching**: all concurrent requests are merged into one batched forward pass per step (MLX-Swift `BatchedEngine`). Near-linear throughput scaling (B=4/B=1 ≈ 3.8x on Qwen, ≈ 2.9x on Gemma MoE). Temperature=0 uses a vectorized greedy fast path.
- **Model slots**: a provider can hold multiple loaded models simultaneously (default max 3). Slot states: `running`, `idle` (loaded, no requests), `crashed`, `reloading`, `idle_shutdown`.
- **KV budget**: memory gating for the KV cache to prevent OOM; loading a model requires ~3x its estimated memory in headroom.
- **Encrypted SSD prefix cache** (optional): KV-cache checkpoints persisted to SSD under a Secure-Enclave-wrapped KEK (see [design/ssd-kv-cache-design.md](design/ssd-kv-cache-design.md)).
- **Idle GPU timeout**: model state released after 1 hour without requests; lazily reloaded on the next request. The coordinator can also push `load_model` to pre-warm.
- **Scheduling windows**: time-based availability configured in `~/.config/eigeninference/provider.toml`; outside scheduled hours the provider disconnects and frees GPU memory.
- **Request cancellation**: in-flight requests are tracked by `request_id`; on consumer or coordinator disconnect, generation stops promptly.
- **Declarative model reconcile**: the coordinator publishes `desired_models`; the provider self-reconciles (downloads, hot-swaps) with zero downtime (see [runbooks/model-migration-runbook.md](runbooks/model-migration-runbook.md)).

### Console UI (`console-ui/`)

Next.js 16 / React 19 web app: chat (with image upload for vision models), billing, models, stats, provider management, API key console, earnings, device linking. Auth via Privy. Talks to the coordinator through proxy API routes.

### Admin UI (`admin-ui/`)

Next.js admin dashboard for release management, model registry actions, invite codes, and log reports (admin OTP auth).

### Landing (`landing/`)

Static marketing site with a provider earnings calculator.

## Request Lifecycle

1. Consumer sends an OpenAI-style request over HTTPS with an API key (`eigeninference-…`) or Privy JWT.
2. Coordinator authenticates, rate-limits (ITPM/OTPM token-per-minute limits), and parses the request.
3. Routing selects a provider with capacity for the model (token-budget admission). If none: enqueue (per-model queue, limit 10) or return 429/503.
4. Coordinator encrypts the request body with the provider's X25519 public key (NaCl box) — sealed transport.
5. The provider decrypts inside the hardened process, runs batched MLX inference, and streams encrypted tokens back over the WebSocket.
6. Coordinator relays SSE chunks to the consumer, decomposing per-request latency into the `X-Timing` header (parse, reserve, route, queue, encrypt, dispatch, provider).
7. Usage is metered and billed to the consumer's micro-USD balance; the provider's payout is credited to the ledger.

Responses include Darkbloom-specific fields `provider_attested` (bool) and `provider_trust_level` (string). Reasoning models emit `<think>`-wrapped reasoning segments which are surfaced as `reasoning_content`.

## Routing & Capacity

- **Token-budget admission**: providers report real token-budget usage in heartbeats — active tokens, max potential tokens, and EWMA decode TPS. The coordinator admits requests against engine-reported capacity, falling back to fleet-median TPS when a provider hasn't reported.
- **Speculative TTFT dispatch**: a backup provider is dispatched at 50% of the TTFT deadline; the first token wins and the loser is cancelled.
- **Provider scoring**: `decode_tps × trust_multiplier × reputation × warm_model_bonus × health_factor`. Health factor uses live system metrics from heartbeats (memory pressure, CPU, thermal state).
- **Reputation**: 40% job success + 30% uptime + 20% attestation + 10% response time.
- **Queueing**: per-model queues (max 10) drain as providers become idle; queued requests time out rather than waiting indefinitely. The coordinator returns early 429 with `Retry-After` for OpenRouter compatibility when the fleet is saturated.
- **Self-route**: consumers can pin requests to provider machines their own account owns — free, never falls back to public providers (see [design/self-route.md](design/self-route.md)). **Direct mode** removes the relay entirely on LAN/localhost (see [design/direct-mode.md](design/direct-mode.md)).
- **Capacity introspection**: `GET /v1/models/capacity` exposes per-model routable/warm/cold provider counts, aggregate TPS, queue depth, estimated TTFT, and remaining token budget.

### Coordinator State Model

Provider state lives in several overlapping fields with different precedence:

- `BackendCapacity.Slots` is **authoritative** for the scheduler when present. It derives slot state, loaded models, token budgets, and observed TPS.
- `WarmModels` (heartbeat-updated) is only a fallback for legacy providers without `BackendCapacity`.
- `CurrentModel` follows heartbeat `active_model`; nil means no model loaded.
- `pendingModelLoads` only affects swap planning, not admission.

## Security Architecture

### Why Providers Can't Read Prompts

The provider owns the Mac, but cannot inspect inference data:

```
Attack                          Blocked by
─────────────────────────────────────────────────
Attach debugger (lldb)          PT_DENY_ATTACH + Hardened Runtime
Read process memory             Hardened Runtime (kernel denies task_for_pid)
Sniff IPC/network               No IPC — inference is in-process
Modify the binary               Code signing + SIP (modified binary won't launch)
Replace with fake binary        Binary hash in attestation — coordinator verifies
Load kernel extension           SIP blocks unsigned kexts
Modify kernel at runtime        KIP (hardware-enforced)
Disable SIP                     Requires reboot → kills process → data gone
Read /dev/mem                   Doesn't exist on Apple Silicon
DMA / RDMA attack               IOMMU default-deny + Hypervisor.framework Stage 2 page tables
Physical memory probing         Soldered LPDDR5x in SoC package (lab-grade only)
```

This is the residual threat model accepted by Apple Private Cloud Compute.

### SIP Cannot Be Disabled at Runtime

Disabling SIP requires rebooting into Recovery Mode, which terminates the inference process and wipes its memory. SIP is checked:

- At process startup (refuses to serve if disabled)
- Before every inference request
- In every 5-minute challenge-response (coordinator detects a reboot with SIP off)

If SIP is found disabled at any point, the provider is immediately marked untrusted and receives no more jobs.

### Trust Levels

| Level | Name | Meaning | How Achieved |
|-------|------|---------|--------------|
| `none` | Open Mode | No attestation. Consumer warned. | Provider sends no attestation |
| `self_signed` | Self-Attested | SE-signed attestation + periodic challenge-response with SIP check | Provider sends SE-signed attestation |
| `hardware` | Hardware-Attested | MDM SecurityInfo cross-check + MDA certificate chain verified against Apple Enterprise Root CA | MDM enrollment + Managed Device Attestation |

Production requires `MIN_TRUST=hardware`.

### Attestation Layers

1. **Secure Enclave signature** — persistent P-256 key in the SE (keychain access-group bound) signs the attestation blob.
2. **MDM SecurityInfo** — MicroMDM independently queries SIP, Secure Boot level, Authenticated Root Volume (SSV), FileVault, and Recovery Lock via Apple's MDM protocol (enrollment profile, AccessRights=1041; APNs push for on-demand queries).
3. **Apple Managed Device Attestation (MDA)** — the device obtains a DER cert chain signed by Apple's Enterprise Attestation Root CA carrying serial, UDID, OS/SepOS version, and Secure Boot level as OIDs. The coordinator verifies the chain against Apple's embedded root and cross-checks the serial against the self-reported attestation.
4. **Challenge-response** — every 5 minutes the coordinator sends a 32-byte nonce; the provider signs `nonce + timestamp + public_key` and includes fresh SIP/Secure Boot status. SIP/Secure Boot disabled → immediate untrust; 3 consecutive failures → untrust.

MDM infrastructure (MicroMDM + SCEP + step-ca) is co-located in the coordinator container. ACME `device-attest-01` client certs are also supported (see [design/acme-mda-apple-root-signed.md](design/acme-mda-apple-root-signed.md)); APNs-triggered code attestation is described in [design/apns-code-attestation-design.md](design/apns-code-attestation-design.md).

### Attestation Blob

Signed with the Secure Enclave P-256 key (ECDSA, DER-encoded):

| Field | Description |
|-------|-------------|
| `publicKey` | Base64 P-256 public key (raw X\|\|Y, 64 bytes) |
| `chipName` | e.g., "Apple M3 Max" |
| `hardwareModel` | e.g., "Mac15,8" |
| `osVersion` | e.g., "26.3.0" |
| `secureEnclaveAvailable` | Always true on Apple Silicon |
| `sipEnabled` | System Integrity Protection status |
| `secureBootEnabled` | Secure Boot status |
| `encryptionPublicKey` | X25519 key bound to this identity |
| `authenticatedRootEnabled` | Authenticated Root Volume (sealed system volume) |
| `systemVolumeHash` | APFS snapshot hash (proves unmodified system volume) |
| `serialNumber` | Hardware serial for MDM cross-reference |
| `binaryHash` | SHA-256 of the signed provider binary |
| `timestamp` | ISO 8601 |

### User-Verifiable Attestation

`GET /v1/providers/attestation` (public, no auth) returns per provider: the SE public key, hardware info, security state, MDM verification status, the base64-DER MDA certificate chain, and MDA-extracted properties. Anyone can:

1. Download Apple's Enterprise Attestation Root CA from [apple.com/certificateauthority](https://www.apple.com/certificateauthority/)
2. Decode `mda_cert_chain_b64` and verify the chain with any x509 library
3. Check the certificate serial matches the provider's self-reported attestation

### End-to-End Encryption

Each request is encrypted with the target provider's X25519 public key using NaCl box (XSalsa20-Poly1305 + Curve25519). The X25519 key is bound to the provider's SE identity in the attestation blob. Decryption happens only inside the hardened provider process; the coordinator forwards ciphertext. Response tokens are encrypted on the return path the same way.

## Models & Registry

The model catalog is **DB-backed in the coordinator** and points to manifests in Cloudflare R2 under `https://models.darkbloom.ai`. Nothing is hardcoded in the provider or UI.

- `GET /v1/models/catalog` (public) lists active models with architecture, quantization, context limits, min RAM, per-file + aggregate SHA-256, and supported sampling parameters.
- Providers download the files listed in the manifest and verify per-file and aggregate SHA-256 before serving.
- Public model names are **aliases** with a desired-build pointer, enabling zero-downtime quant migrations invisible to consumers ([runbooks/model-migration-runbook.md](runbooks/model-migration-runbook.md)).
- Publishing uses `scripts/publish-model.sh` + the `register-model.yml` workflow + `POST /v1/admin/models/register`.
- The provider auto-injects a ChatML template for models that ship without `chat_template`.

Current production catalog (live at `GET /v1/models/catalog`):

| Model | Architecture | Quant | Context | Max output | Min RAM |
|-------|--------------|-------|---------|-----------|---------|
| `gpt-oss-20b` | 20.9B MoE (3.6B active) | fp8 | 131,072 | 32,768 | 24 GB |
| `gemma-4-26b` | 25.2B MoE (3.8B active) | 8-bit | 131,072 | 32,768 | 36 GB |

## Payments & Billing

- Internal double-entry **micro-USD ledger** (1,000,000 micro-USD = $1.00) with atomic balance operations.
- Per-model token pricing set in `coordinator/payments/pricing.go`; live at `GET /v1/pricing`.
- **Platform fee: 0% during the public alpha** (`DefaultPlatformFeePercent = 0`) — providers keep 100% of revenue. Per-account fee overrides exist.
- Deposits: Stripe (card) and Solana USDC (on-chain verification; coordinator wallet derived from a BIP39 mnemonic via SLIP-0010, `m/44'/501'/0'/0'`).
- Payouts: Stripe Connect (onboard, withdraw, webhook-driven status).
- Referrals: referrers earn a share of platform fees (15% currently).
- Invite codes gate alpha access.

## Storage

| Backend | Use case | Notes |
|---------|----------|-------|
| MemoryStore | Development / default | Provider state lost on restart |
| PostgresStore | Production | AWS RDS (prod), Cloud SQL (dev); atomic balances, persistent ledger, model registry |

## Auth

- **Privy JWTs** — console users (account management, key creation, device approval).
- **API keys** (`eigeninference-…`) — programmatic consumers; per-key ITPM/OTPM rate limits, rotation, and scoping via `/v1/keys`.
- **Device-code flow (RFC 8628)** — links provider machines to user accounts: provider runs `darkbloom login`, gets a code, user approves on the web.
- **Admin** — OTP-based admin auth + scoped admin endpoints; a scoped release key lets GitHub Actions register releases.

## Observability

- **Datadog DogStatsD** metrics: attestation, routing, billing, fleet version, provider capacity.
- **X-Timing header**: per-request latency decomposition (parse, reserve, route, queue, encrypt, dispatch, provider).
- **Telemetry events** (`POST /v1/telemetry/events`): wire types mirrored in `coordinator/protocol/telemetry.go`, `provider-swift/Sources/ProviderCore/Telemetry/`, and `console-ui/src/lib/telemetry-types.ts`. The field allowlist in `coordinator/api/telemetry_handlers.go` is the privacy backstop — prompt/completion content is never accepted.
- **Provider log reports**: `darkbloom doctor` can upload sanitized log bundles (`POST /v1/provider/log-report`).

## Release Pipeline

CI (`.github/workflows/release-swift.yml`, triggered by `vX.Y.Z-swift[.N]` tags) builds the Swift CLI, signs with a Developer ID Application cert, notarizes with Apple, computes SHA-256 hashes **after** signing, and uploads the bundle to R2, then registers it with the coordinator via `POST /v1/releases`. Providers install/update via `install.sh` (served from the coordinator), which verifies the bundle hash and code signature. The version gate (`LatestProviderVersion` in `coordinator/api/server.go`) drives update prompts.

## Hardware Support

Any Apple Silicon Mac (M1 or later), macOS 14+:

| Chip | Memory | Bandwidth | Best Models |
|------|--------|-----------|-------------|
| M1 | 8-16 GB | 68 GB/s | 3B-8B |
| M1 Pro/Max | 16-64 GB | 200-400 GB/s | 8B-33B |
| M2 Pro/Max | 16-96 GB | 200-400 GB/s | 8B-70B |
| M3 Pro/Max | 18-128 GB | 150-400 GB/s | 8B-122B |
| M3 Ultra | 96-256 GB | 819 GB/s | 8B-230B |
| M4 Pro/Max | 24-128 GB | 273-546 GB/s | 8B-122B |
| M5 Max | up to 128 GB | high-bandwidth | 8B-122B |
