<p align="center">
  <strong>Darkbloom</strong><br>
  <em>Decentralized Private Inference on Apple Silicon</em>
</p>

<p align="center">
  <a href="https://github.com/Layr-Labs/d-inference/actions/workflows/ci.yml"><img src="https://github.com/Layr-Labs/d-inference/actions/workflows/ci.yml/badge.svg?branch=master" alt="CI"></a>
  <a href="https://github.com/Layr-Labs/d-inference/blob/master/LICENSE"><img src="https://img.shields.io/badge/license-proprietary-blue" alt="License"></a>
  <a href="https://github.com/Layr-Labs/d-inference/releases"><img src="https://img.shields.io/github/v/release/Layr-Labs/d-inference?display_name=tag&sort=semver" alt="Latest Release"></a>
  <a href="https://api.darkbloom.dev/health"><img src="https://img.shields.io/badge/coordinator-live-brightgreen" alt="Coordinator Status"></a>
</p>

<p align="center">
  <a href="#quick-start">Quick Start</a> &middot;
  <a href="#architecture">Architecture</a> &middot;
  <a href="#api-reference">API Reference</a> &middot;
  <a href="#become-a-provider">Become a Provider</a> &middot;
  <a href="#security">Security</a> &middot;
  <a href="#development">Development</a> &middot;
  <a href="#contributing">Contributing</a>
</p>

---

AI compute today flows through three layers of markup — GPU manufacturers to hyperscalers to API providers to end users. Meanwhile, **over 100 million Apple Silicon Macs** sit idle most of each day with 64–512 GB of unified memory and up to 819 GB/s memory bandwidth, capable of running models with up to 500 billion parameters at interactive speeds.

**Darkbloom** connects this idle capacity directly to demand. The API is **OpenAI-compatible**. Providers keep **95% of revenue**. Consumer prompts are **never visible** to providers — enforced by hardware, not policy.

> **Status:** Active development. Breaking changes may occur between releases. See the [changelog](https://github.com/Layr-Labs/d-inference/releases) for details.

## Table of Contents

- [Quick Start](#quick-start)
- [Architecture](#architecture)
- [Supported Models](#supported-models)
- [API Reference](#api-reference)
- [Become a Provider](#become-a-provider)
- [Security](#security)
- [Pricing](#pricing)
- [Project Structure](#project-structure)
- [Development](#development)
- [Deployment](#deployment)
- [Contributing](#contributing)
- [License](#license)
- [Security Bugs](#security-bugs)

## Quick Start

### Use the API

Darkbloom exposes an **OpenAI-compatible API**. Point any OpenAI SDK at the coordinator and start making requests:

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://api.darkbloom.dev/v1",
    api_key="eigeninference-..."
)

response = client.chat.completions.create(
    model="qwen3.5-27b-claude-opus-8bit",
    messages=[{"role": "user", "content": "Hello"}],
    stream=True
)
for chunk in response:
    print(chunk.choices[0].delta.content or "", end="")
```

**cURL:**

```bash
curl https://api.darkbloom.dev/v1/chat/completions \
  -H "Authorization: Bearer eigeninference-..." \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.5-27b-claude-opus-8bit",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": true
  }'
```

The **Anthropic Messages API** is also supported at `/v1/messages`.

### Supported Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/chat/completions` | `POST` | Chat completions (streaming & non-streaming) |
| `/v1/completions` | `POST` | Text completions |
| `/v1/messages` | `POST` | Anthropic Messages API |
| `/v1/audio/transcriptions` | `POST` | Speech-to-text transcription |
| `/v1/images/generations` | `POST` | Image generation |
| `/v1/models` | `GET` | List available models |

## Architecture

```
Consumer (OpenAI SDK / Web UI / cURL)
    │
    │  HTTPS — OpenAI-compatible API
    ▼
Coordinator (Go, Confidential VM)
    │
    │  WebSocket (outbound from provider — no port forwarding)
    ▼
Provider (Swift CLI, hardened process)
    │
    │  mlx-swift-lm (in-process)
    ▼
Apple Silicon GPU (Metal)
```

| Component | Language | Role |
|-----------|----------|------|
| **Coordinator** | Go | Control plane — routing, attestation verification, billing, OpenAI-compatible API |
| **Provider CLI** | Swift | Hardened inference agent on Apple Silicon Macs |
| **Console** | Next.js 16 / React 19 | Web dashboard — chat, billing, provider verification, model catalog |
| **Enclave Helper** | Swift | Secure Enclave attestation and signing utilities |
| **Image Bridge** | Python (FastAPI) | Image generation bridge (Draw Things gRPC backend) |

Providers connect **outbound** over WebSocket — no port forwarding, no firewall configuration. The coordinator encrypts each request with the provider's **X25519 public key** before forwarding. Only the hardened provider process can decrypt it.

For the full architecture deep-dive, see [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Supported Models

### Text

| Model | Architecture | Size | Min RAM | Notes |
|-------|-------------|------|---------|-------|
| Gemma 4 26B 8-bit | 26B MoE, 4B active | 28 GB | 36 GB | Google's latest MoE, fast multimodal |
| Qwen3.5 27B Claude Opus 8-bit | 27B dense | 27 GB | 36 GB | Frontier-quality reasoning, Claude Opus distilled |
| Trinity Mini 8-bit | 27B Adaptive MoE | 26 GB | 48 GB | Fast agentic inference |
| Qwen3.5 122B MoE 8-bit | 122B MoE, 10B active | 122 GB | 128 GB | Best quality reasoning |
| MiniMax M2.5 8-bit | 239B MoE, 11B active | 243 GB | 256 GB | SOTA coding, ~100 tok/s |

### Hardware Compatibility

| Chip | Unified Memory | Bandwidth | Recommended Models |
|------|---------------|-----------|-------------------|
| M1 | 8–16 GB | 68 GB/s | 3B–8B |
| M1 Pro / Max | 16–64 GB | 200–400 GB/s | 8B–33B |
| M2 Pro / Max | 16–96 GB | 200–400 GB/s | 8B–70B |
| M3 Pro / Max | 18–128 GB | 150–400 GB/s | 8B–122B |
| M3 Ultra | 96–256 GB | 819 GB/s | 8B–230B |
| M4 Pro / Max | 24–128 GB | 273–546 GB/s | 8B–122B |

## API Reference

### Authentication

All API requests require an API key passed via the `Authorization` header:

```
Authorization: Bearer eigeninference-<your-key>
```

### Response Extensions

Darkbloom adds the following fields to standard OpenAI-compatible responses:

| Field | Type | Description |
|-------|------|-------------|
| `provider_attested` | `bool` | Whether the provider has a verified attestation |
| `provider_trust_level` | `string` | Trust level: `self_signed`, `hardware`, or `none` |

### Error Handling

| Status | Meaning |
|--------|---------|
| `401` | Invalid or missing API key |
| `429` | Rate limit exceeded |
| `503` | All providers busy — request queued (120s timeout) |

## Become a Provider

Earn by serving inference on your idle Mac.

### Requirements

| Requirement | Minimum |
|-------------|---------|
| Hardware | Apple Silicon Mac (M1 or later) |
| OS | macOS 14 (Sonoma) or later |
| Memory | 16 GB+ unified memory recommended |
| Network | Outbound HTTPS/WSS (no port forwarding needed) |

### Install

```bash
curl -fsSL https://api.darkbloom.dev/install.sh | bash
```

Zero prerequisites. The installer downloads a single **signed and notarized** bundle containing the provider CLI, the Secure Enclave attestation helper, and the matching MLX metallib. Pick a model from the catalog, link your account, and start serving within minutes.

### Provider CLI Reference

```
darkbloom serve          # Start serving inference (foreground)
darkbloom start          # Start as a background daemon (launchd)
darkbloom stop           # Stop the background daemon
darkbloom status         # Show hardware info and connection state
darkbloom doctor         # Diagnose configuration and security issues
darkbloom models list    # List downloaded models
darkbloom earnings       # View earnings and usage statistics
darkbloom benchmark      # Run a local tok/s benchmark
darkbloom update         # Check for and install updates
darkbloom login          # Link provider to your account (device code flow)
darkbloom logout         # Unlink provider from your account
```

### Scheduling

Configure time-based availability windows in `~/.config/eigeninference/provider.toml`:

```toml
[schedule]
enabled = true

[[schedule.windows]]
days = ["mon", "tue", "wed", "thu", "fri"]
start = "22:00"
end = "08:00"
```

Outside scheduled hours, the provider disconnects and shuts down the backend to free GPU memory. The backend is lazy-reloaded when the next request arrives during active hours.

## Security

Darkbloom prevents anyone — **including the provider operator** — from reading consumer prompts.

### Defense in Depth

| Layer | Protection |
|-------|-----------|
| **E2E Encryption** | Requests encrypted with provider's X25519 key before forwarding; only the hardened provider decrypts |
| **Hardened Runtime + SIP** | Blocks debugger attachment (`PT_DENY_ATTACH`), memory reads (`task_for_pid` denied), and code injection |
| **In-Process Inference** | No subprocess, no IPC, no local server — nothing to sniff |
| **Secure Enclave Attestation** | Hardware-bound P-256 identity; signed attestation blobs verified by the coordinator |
| **Binary Hash Verification** | Coordinator verifies the provider runs a known-good signed binary |
| **Challenge-Response** | SIP and Secure Boot status re-verified every 5 minutes |
| **MDM SecurityInfo** | Apple MDM independently verifies hardware integrity (SIP, Secure Boot, FileVault) |
| **MDA Certificate Chain** | Apple Enterprise Attestation Root CA signs the device certificate chain |
| **RDMA/DMA Protection** | Hypervisor.framework Stage 2 page tables isolate inference memory |

> This is the same residual threat model accepted by **Apple Private Cloud Compute** for Siri and Apple Intelligence: the only remaining attack vector is physically probing memory chips soldered into the SoC package.

### Trust Levels

| Level | Name | Verification |
|-------|------|-------------|
| `none` | Open Mode | No attestation; consumer is warned |
| `self_signed` | Self-Attested | Secure Enclave signature + periodic challenge-response with SIP check |
| `hardware` | Hardware-Attested | MDA certificate chain verified against Apple Enterprise Attestation Root CA |

### Public Attestation API

Attestation data is **publicly verifiable** — no authentication required:

```bash
curl https://api.darkbloom.dev/v1/providers/attestation
```

Returns each provider's Secure Enclave public key, hardware info, security state, MDM verification status, and the full Apple MDA certificate chain. Verify independently using any standard x509 library against [Apple's Enterprise Attestation Root CA](https://www.apple.com/certificateauthority/).

For the full threat model, see [`docs/threat-model.yaml`](docs/threat-model.yaml).

## Pricing

| Type | Input | Output |
|------|-------|--------|
| Gemma 4 26B | $0.065 / 1M tokens | $0.20 / 1M tokens |
| Qwen3.5 27B | $0.10 / 1M tokens | $0.78 / 1M tokens |
| Qwen3.5 122B | $0.13 / 1M tokens | $1.04 / 1M tokens |
| MiniMax M2.5 | $0.06 / 1M tokens | $0.50 / 1M tokens |

**0% platform fee. Providers keep 100% of revenue.**

Payments settled via **Solana USDC** on-chain.

## Project Structure

```
coordinator/              Go control plane
├── cmd/coordinator/      Main service entrypoint
├── api/                  HTTP + WebSocket handlers
├── attestation/          Secure Enclave + MDA verification
├── auth/                 Privy JWT integration
├── billing/              Stripe, Solana USDC, referrals
├── e2e/                  X25519 request-encryption helpers
├── mdm/                  MicroMDM client + webhook handling
├── payments/             Internal ledger + pricing
├── protocol/             WebSocket message types (shared with provider)
├── registry/             Provider registry, scoring, routing, reputation
└── store/                In-memory or Postgres persistence

provider-swift/           Swift provider CLI (replacing Rust provider)
├── Sources/ProviderCore/ Shared library (protocol, hardware, crypto, inference)
├── Sources/darkbloom/    CLI executable (serve, start, stop, doctor, etc.)
└── Tests/                Unit tests

provider/                 Rust provider agent (legacy, in production)
├── src/                  CLI, coordinator client, proxying, security, crypto
└── Cargo.toml            Default "python" feature enables PyO3 inference

console-ui/               Next.js 16 / React 19 web dashboard
├── src/app/              Pages: chat, billing, images, models, stats, settings
├── src/components/       UI components, providers, trust badges
├── src/lib/              API client, Zustand store
└── src/hooks/            Auth, toast notifications

enclave/                  Swift Secure Enclave helper + FFI bridge
image-bridge/             Python FastAPI image generation service
scripts/                  Build, signing, install, and deploy helpers
docs/                     Architecture, deploy runbooks, threat model
landing/                  Static landing page
.github/workflows/        CI and release automation
```

## Development

### Prerequisites

| Tool | Version | Required For |
|------|---------|-------------|
| Go | 1.22+ | Coordinator |
| Rust (stable) | Latest | Legacy provider |
| Swift | 5.9+ (Xcode 15+) | Swift provider, enclave, macOS app |
| Node.js | 20+ | Console UI |
| Python | 3.11+ | Image bridge, crypto interop tests |

> **Note:** Full provider/app development requires **macOS on Apple Silicon (M1+)**. The coordinator and console UI can be developed on any platform.

### Build & Test

```bash
# Coordinator (Go)
cd coordinator && go test ./... && go build ./cmd/coordinator

# Swift provider (CLI replacement)
cd provider-swift && swift test && swift build -c release

# Legacy Rust provider
cd provider && PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 cargo test

# Console UI (Next.js 16)
cd console-ui && npm install && npm run build && npm test

# Image bridge (Python)
cd image-bridge && python3 -m venv .venv && source .venv/bin/activate \
  && pip install -r requirements.txt pytest httpx && PYTHONPATH=. pytest

# Cross-language crypto interop
python3 -m pytest tests/test_crypto_interop.py
```

### Code Formatting

The repository uses a pre-commit hook (`.githooks/pre-commit`) that checks staged files:

| Component | Formatter | Check Command | Fix Command |
|-----------|-----------|--------------|-------------|
| Go (`coordinator/`) | `gofmt` | `gofmt -l .` | `gofmt -w <file>` |
| Rust (`provider/`) | `cargo fmt` | `cargo fmt --check` | `cargo fmt` |
| TypeScript (`console-ui/`) | ESLint | `npx eslint src/` | `npx eslint src/ --fix` |
| Swift | — | No enforced formatter | Match surrounding style |
| Python | PEP 8 | — | Manual |

### First-Time Setup

```bash
git clone https://github.com/Layr-Labs/d-inference.git
cd d-inference
git config core.hooksPath .githooks   # Enable pre-commit + pre-push checks
```

## Deployment

### Coordinator

The production coordinator runs on **EigenCloud** (TEE) at `api.darkbloom.dev`. A separate dev environment runs on Google Cloud at `api.dev.darkbloom.xyz`.

| Environment | Host | Database | Console UI |
|-------------|------|----------|-----------|
| **Production** | EigenCloud app `d-inference` | AWS RDS PostgreSQL | EigenCloud |
| **Development** | GCE VM `d-inference-dev` | Cloud SQL Postgres 16 | Vercel |

For detailed deployment procedures, see:
- [`docs/dev-environment.md`](docs/dev-environment.md) — Dev environment runbook

### Provider Bundle

CI (`.github/workflows/release-swift.yml`) builds, signs, notarizes, and uploads the Swift CLI bundle to Cloudflare R2. Providers fetch updates via `install.sh` served by the coordinator.

## Contributing

We welcome contributions! Please read [`CONTRIBUTING.md`](CONTRIBUTING.md) for:

- How to file bugs and propose features
- Development setup and workflow
- Code style and testing requirements
- Protocol change guidelines

**Roadmap:** [GitHub Projects Board](https://github.com/orgs/Layr-Labs/projects/25)

## License

Proprietary. All rights reserved. See [`LICENSE`](LICENSE) for details.

## Security Bugs

**Do NOT report security vulnerabilities via GitHub Issues.**

Please report security vulnerabilities to **security@eigenlabs.org** or use [GitHub Security Advisories](https://github.com/Layr-Labs/d-inference/security/advisories/new).

---

<p align="center">
  <sub>Built by <a href="https://www.eigenlayer.xyz">Eigen Labs</a></sub>
</p>
