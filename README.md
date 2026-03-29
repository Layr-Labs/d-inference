# DGInf — Decentralized Private Inference

A platform for private, decentralized AI inference on Apple Silicon Macs. Mac owners rent out idle compute. Consumers get private inference on open-source models with hardware-backed trust from Apple's Secure Enclave.

**Privacy claim:** Nobody in the chain can see your prompts — not the coordinator (runs in a hardware-encrypted Confidential VM), not the provider (SIP + Hardened Runtime + in-process inference prevent memory inspection), and not DGInf as a company.

## How It Works

```
Consumer (Python SDK / CLI)
    │
    │  HTTPS + OpenAI-compatible API
    ▼
Coordinator (Go, GCP Confidential VM — AMD SEV-SNP)
    │
    │  WebSocket (outbound from provider, no port forwarding needed)
    ▼
Provider Agent (Rust, hardened process)
    │
    │  In-process Python (PyO3) — no subprocess, no IPC
    ▼
MLX inference engine → Metal → Apple Silicon GPU
```

## Quick Start

### Consumer

```bash
pip install dginf

# One-shot inference
dginf configure --url https://coordinator.dginf.io --api-key dginf-...
dginf ask "Explain quantum computing"

# Or use the Python SDK (OpenAI-compatible drop-in)
from dginf import DGInf
client = DGInf()
response = client.chat.completions.create(
    model="mlx-community/Qwen2.5-7B-Instruct-4bit",
    messages=[{"role": "user", "content": "Hello"}],
    stream=True,
)
```

### Provider

```bash
# Install (downloads provider binary, enclave helper, and Python/MLX runtime)
curl -fsSL https://inference-test.openinnovation.dev/install.sh | bash

# Start serving
dginf-provider serve --model mlx-community/Qwen3.5-9B-MLX-4bit

# Or use the background daemon
dginf-provider start

# Check for updates
dginf-provider update

# Diagnostics
dginf-provider doctor
dginf-provider status
```

The provider agent:
1. Detects your Apple Silicon hardware
2. Generates a Secure Enclave identity key (P-256 ECDSA)
3. Enrolls in MDM for hardware-verified security posture
4. Verifies RDMA is disabled (Thunderbolt 5 remote memory access protection)
5. Loads the model via vllm-mlx with continuous batching
6. Connects to the coordinator and starts accepting jobs

## Architecture

| Component | Language | What It Does |
|-----------|----------|-------------|
| **Coordinator** (`coordinator/`) | Go | Control plane: routing, attestation verification, payments, stats API |
| **Provider Agent** (`provider/`) | Rust | Inference agent: security hardening, attestation, WebSocket client, self-update |
| **Web Frontend** (`web/`) | Next.js | Verification panel, stats dashboard, chat interface |
| **macOS App** (`app/DGInf/`) | Swift/SwiftUI | Menu bar app with idle detection, earnings dashboard |
| **Secure Enclave** (`enclave/`) | Swift | Hardware-bound P-256 identity, signed attestation blobs |
| **Scripts** (`scripts/`) | Bash | Hardened Runtime signing, app bundling, installer |

## Security Model

DGInf prevents providers from reading consumer prompts through multiple layers:

| Protection | What It Blocks |
|---|---|
| **PT_DENY_ATTACH** | Debugger attachment (lldb, dtrace, Instruments) |
| **Hardened Runtime** | External process memory reads (task_for_pid, mach_vm_read) |
| **SIP enforcement** | Kernel-level enforcement of the above; cannot be disabled without reboot |
| **In-process inference** | No subprocess or IPC channel to sniff — all inference inside hardened process |
| **Python path locking** | Only loads from signed app bundle, not system packages (prevents malicious vllm-mlx) |
| **Signed app bundle** | Any file modification breaks code signature; SIP refuses to run modified bundle |
| **Binary hash attestation** | Coordinator verifies provider runs the expected blessed binary version |
| **SIP re-verification** | Checked at startup, before every request, and in every 5-min challenge-response |
| **RDMA detection** | Detects Thunderbolt 5 RDMA via `rdma_ctl status`; refuses to serve if enabled (bypasses all software protections) |
| **Memory wiping** | Volatile-zeros prompt/response buffers after each request |
| **MDM SecurityInfo** | Hardware-verified SIP, Secure Boot, and system integrity via Apple MDM |
| **E2E encryption** | Consumer requests encrypted with provider's X25519 public key (NaCl box); coordinator never sees plaintext prompts |

**Remaining attack surface:** Physical memory probing on soldered LPDDR5x — same threat model as Apple Private Cloud Compute.

### Trust Levels

| Level | Name | How Achieved |
|-------|------|-------------|
| `none` | Open Mode | No attestation |
| `self_signed` | Self-Attested | Secure Enclave P-256 signature verified + periodic challenge-response |
| `hardware` | Hardware-Attested | MDA certificate chain from Apple Enterprise Attestation Root CA (via MDM) |

## MDM Infrastructure

DGInf uses Apple MDM (MicroMDM) to query provider security posture:

- **Enrollment:** Provider installs a `.mobileconfig` profile (one click, minimal permissions)
- **Access Rights:** Query device info + security info only (AccessRights=1041). No erase, lock, or app management.
- **SecurityInfo query returns:** SIP status, Secure Boot level, Authenticated Root Volume, FileVault status
- **Push notifications:** APNs for on-demand attestation queries

Infrastructure: MicroMDM + SCEP + step-ca (ACME with device-attest-01) on AWS.

## Inference

| Backend | Status | Use |
|---------|--------|-----|
| **vllm-mlx** | Primary | Continuous batching + prefix caching, launched as subprocess |
| **cohere-transcribe** | STT | Speech-to-text via custom stt_server.py |

Models are downloaded from the DGInf S3 CDN (`s3://dginf-models/`, no auth required) or HuggingFace as fallback.

## Payments

- Internal micro-USD ledger (1 USD = 1,000,000 micro-USD)
- $0.50 per 1M output tokens, 10% platform fee
- Consumer deposits via Stripe (MVP) or Tempo blockchain settlement
- Provider payouts: 90% of inference charges

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

# Web frontend (Next.js)
cd web && npm run dev

# Deploy coordinator
cd coordinator && GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -o dginf-coordinator-linux ./cmd/coordinator
```

## Hardware Support

Any Apple Silicon Mac (M1 or later):

| Chip | Memory | Bandwidth | Best Models |
|------|--------|-----------|-------------|
| M1 | 8-16 GB | 68 GB/s | 3B-8B |
| M1 Pro/Max | 16-64 GB | 200-400 GB/s | 8B-33B |
| M2 Pro/Max | 16-96 GB | 200-400 GB/s | 8B-70B |
| M3 Pro/Max | 18-128 GB | 150-400 GB/s | 8B-122B |
| M3 Ultra | 96-256 GB | 819 GB/s | 8B-230B |
| M4 Pro/Max | 24-128 GB | 273-546 GB/s | 8B-122B |
| M4 Ultra | 256-512 GB | 819 GB/s | 8B-400B+ |

## License

Proprietary. All rights reserved.
