# DGInf — Decentralized Private Inference

A platform for private, decentralized AI inference on Apple Silicon Macs. Mac owners rent out idle GPU compute. Consumers get private inference on open-source models with hardware-backed trust from Apple's Secure Enclave.

**Privacy claim:** Nobody in the chain can see your prompts — not the coordinator, not the provider (SIP + Hardened Runtime + in-process inference prevent memory inspection), and not DGInf as a company.

## How It Works

```
Consumer (Web UI / Python SDK)
    │
    │  HTTPS + OpenAI-compatible API
    ▼
Coordinator (Go)
    │
    │  WebSocket (outbound from provider, no port forwarding needed)
    ▼
Provider Agent (Rust, hardened process)
    │
    │  In-process Python (PyO3) — no subprocess, no IPC
    ▼
MLX inference engine → Metal → Apple Silicon GPU
```

## Become a Provider

Earn money by serving AI inference on your idle Mac.

### Requirements

- Any Apple Silicon Mac (M1 or later)
- macOS 13 (Ventura) or later
- 8 GB+ unified memory (16 GB+ recommended)

### Install

```bash
curl -fsSL https://inference-test.openinnovation.dev/install.sh | bash
```

That's it. The installer will:
1. Download the provider binary, Python/MLX runtime, and ffmpeg (zero prerequisites)
2. Set up Secure Enclave identity and enrollment profile
3. Download the best model for your hardware (auto-selected by RAM)
4. Start the provider in the background

Your Mac is serving inference within minutes.

**Models by memory** (auto-selected during install):

| Memory | Model | Parameters |
|--------|-------|------------|
| 8 GB | `mlx-community/Qwen2.5-0.5B-Instruct-4bit` | 0.5B |
| 16 GB | `mlx-community/Qwen3.5-9B-MLX-4bit` | 9B |
| 32 GB | `mlx-community/Qwen3.5-14B-Instruct-4bit` | 14B |
| 64 GB+ | `mlx-community/Qwen3.5-32B-Instruct-4bit` | 32B |

### Provider CLI Reference

```bash
dginf-provider init          # Detect hardware, create config
dginf-provider serve         # Start serving (foreground)
dginf-provider start         # Start serving (background daemon)
dginf-provider stop          # Stop the background daemon
dginf-provider status        # Show hardware and connection status
dginf-provider doctor        # Diagnose issues (SIP, Enclave, MDM, connectivity)
dginf-provider models list   # List downloaded models
dginf-provider models download  # Download a model
dginf-provider earnings      # Show earnings and usage history
dginf-provider wallet        # Show or create provider wallet (macOS Keychain)
dginf-provider benchmark     # Run standardized benchmarks
dginf-provider logs -w       # Stream logs in real-time
dginf-provider update        # Check for and install updates
dginf-provider enroll        # Enroll in MDM (without serving)
dginf-provider unenroll      # Remove MDM enrollment
```

### What Happens When You Serve

1. Your Apple Silicon hardware is detected (chip, memory, GPU cores, bandwidth)
2. A Secure Enclave identity key is generated (P-256 ECDSA, non-extractable from hardware)
3. SIP, Secure Boot, and RDMA status are verified
4. The model is loaded via vllm-mlx with continuous batching
5. A WebSocket connection is opened to the coordinator (outbound — no port forwarding needed)
6. Periodic challenge-response attestation runs every 5 minutes (fresh SIP/SecureBoot checks)
7. Inference requests arrive from the coordinator and are processed locally on your GPU
8. After 10 minutes of no requests, the model is unloaded to free GPU memory (auto-reloads on next request)

### macOS Menu Bar App

A native SwiftUI menu bar app is also available as an alternative to the CLI:

- Status indicator (green = online, yellow = paused, gray = offline)
- Real-time tokens/second display
- Idle detection (pauses when you're using your Mac)
- Earnings dashboard and wallet
- Auto-start at login via Launch Agent
- Diagnostics, benchmarks, and log viewer

Build from source:
```bash
cd app/DGInf && swift build -c release
```

## Consumer API

The coordinator exposes an OpenAI-compatible API.

```bash
# Create an API key
curl -X POST https://inference-test.openinnovation.dev/v1/auth/keys

# Chat completion
curl https://inference-test.openinnovation.dev/v1/chat/completions \
  -H "Authorization: Bearer dginf-..." \
  -H "Content-Type: application/json" \
  -d '{
    "model": "mlx-community/Qwen3.5-9B-MLX-4bit",
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": true
  }'

# List available models
curl https://inference-test.openinnovation.dev/v1/models \
  -H "Authorization: Bearer dginf-..."

# Audio transcription
curl https://inference-test.openinnovation.dev/v1/audio/transcriptions \
  -H "Authorization: Bearer dginf-..." \
  -F file=@audio.mp3
```

### Web Interface

A web chat interface is available at the coordinator URL with model browsing, provider verification, billing, and network stats.

## Architecture

| Component | Language | What It Does |
|-----------|----------|-------------|
| **Coordinator** (`coordinator/`) | Go | Control plane: request routing, attestation verification, scoring, payments, OpenAI-compatible API |
| **Provider Agent** (`provider/`) | Rust | Inference agent: hardware detection, security hardening, attestation, WebSocket client, in-process MLX inference |
| **Web Frontend** (`web/`) | Next.js 15 / React 19 | Chat interface, model browser, provider verification, billing dashboard |
| **macOS App** (`app/DGInf/`) | Swift / SwiftUI | Menu bar app: status, earnings, idle detection, diagnostics |
| **Secure Enclave** (`enclave/`) | Swift | Hardware-bound P-256 identity, signed attestation blobs |
| **Scripts** (`scripts/`) | Bash | Installer, Hardened Runtime code signing, app bundling, DMG distribution |

## Security Model

DGInf prevents anyone — including providers — from reading consumer prompts through multiple defense layers:

| Protection | What It Blocks |
|---|---|
| **PT_DENY_ATTACH** | Debugger attachment (lldb, dtrace, Instruments) |
| **Hardened Runtime** | External process memory reads (task_for_pid, mach_vm_read) |
| **SIP enforcement** | Kernel-level enforcement of the above; cannot be disabled without reboot |
| **In-process inference** | No subprocess or IPC channel to sniff — all inference inside hardened process |
| **Python path locking** | Only loads from signed app bundle, not system packages |
| **Signed app bundle** | Any file modification breaks code signature; SIP refuses to run modified bundle |
| **Binary hash attestation** | Coordinator verifies provider runs the expected blessed binary version |
| **SIP re-verification** | Checked at startup, before every request, and in every 5-min challenge-response |
| **RDMA detection** | Detects Thunderbolt 5 RDMA; refuses to serve if enabled (bypasses software protections) |
| **Hypervisor memory isolation** | Stage 2 page tables protect inference memory if RDMA is present |
| **Memory wiping** | Volatile-zeros prompt/response buffers after each request |
| **MDM SecurityInfo** | Hardware-verified SIP, Secure Boot, and system integrity via Apple MDM |
| **E2E encryption** | Consumer requests encrypted with provider's X25519 public key (NaCl box); coordinator never sees plaintext |

**Remaining attack surface:** Physical memory probing on soldered LPDDR5x — same threat model as Apple Private Cloud Compute.

### Trust Levels

| Level | Name | How Achieved |
|-------|------|-------------|
| `none` | Open Mode | No attestation |
| `self_signed` | Self-Attested | Secure Enclave P-256 signature verified + periodic challenge-response with SIP/SecureBoot checks |
| `hardware` | Hardware-Attested | MDA certificate chain from Apple Enterprise Attestation Root CA (via MDM) |

### Attestation Chain

```
Secure Enclave P-256 key (non-extractable from hardware)
    ↓ Signs attestation blob (hardware info + SIP + binary hash)
Coordinator verifies ECDSA signature
    ↓ Cross-checks via MDM SecurityInfo query
MDM returns: SIP status, Secure Boot level, FileVault, Authenticated Root Volume
    ↓ Optional: Apple Device Attestation (MDA)
Apple Enterprise Attestation Root CA certificate chain
    ↓ Public verification endpoint
GET /v1/providers/attestation — anyone can independently verify the chain
```

## Provider Scoring

Providers are ranked by a composite score:

```
score = (1 - load) × decode_tps × trust_multiplier × reputation × warm_model_bonus × health_factor
```

- **decode_tps** — measured throughput during inference
- **trust_multiplier** — higher for hardware-attested providers
- **reputation** — 40% job success + 30% uptime + 20% attestation + 10% response time
- **warm_model_bonus** — preference for providers with the model already loaded
- **health_factor** — live system metrics (memory pressure, CPU usage, thermal state) from heartbeats

## Payments

- Internal micro-USD ledger (1 USD = 1,000,000 micro-USD)
- $0.50 per 1M output tokens, 10% platform fee
- Provider payouts: 90% of inference charges
- Provider wallet: secp256k1 key stored in macOS Keychain

## Hardware Support

Any Apple Silicon Mac (M1 or later):

| Chip | Memory | Bandwidth | Best Models |
|------|--------|-----------|-------------|
| M1 | 8–16 GB | 68 GB/s | 0.5B–8B |
| M1 Pro/Max | 16–64 GB | 200–400 GB/s | 8B–33B |
| M2 Pro/Max | 16–96 GB | 200–400 GB/s | 8B–70B |
| M3 Pro/Max | 18–128 GB | 150–400 GB/s | 8B–122B |
| M3 Ultra | 96–256 GB | 819 GB/s | 8B–230B |
| M4 Pro/Max | 24–128 GB | 273–546 GB/s | 8B–122B |
| M4 Ultra | 256–512 GB | 819 GB/s | 8B–400B+ |

## Development

```bash
# Coordinator (Go)
cd coordinator && go build ./... && go test ./...

# Provider (Rust) — requires PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 on Python 3.14+
cd provider && cargo build --release && cargo test

# Provider without Python feature (for distribution bundles)
cd provider && cargo build --release --no-default-features

# Enclave helper (Swift)
cd enclave && swift build -c release

# macOS App (Swift)
cd app/DGInf && swift build -c release && swift test

# Web frontend (Next.js)
cd web && npm install && npm run dev
```

## License

Proprietary. All rights reserved.
