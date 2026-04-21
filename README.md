# Darkbloom

> **Research project** -- Darkbloom is an experimental prototype exploring decentralized private inference on Apple Silicon. Expect rough edges, breaking changes, and downtime.

AI compute today flows through three layers of markup — GPU manufacturers to hyperscalers to API providers to end users. Meanwhile, over 100 million Apple Silicon Macs sit idle most of each day with 64–512 GB of unified memory and up to 819 GB/s memory bandwidth, capable of running models with up to 500 billion parameters at interactive speeds. Darkbloom connects this idle capacity directly to demand. The core technical challenge is that the machine owner has root access and physical custody — they should not be able to see user prompts or model responses. We solve this by eliminating every software path through which inference data could be observed: the inference engine runs in-process (no subprocess, no local server, no IPC), debuggers are denied at the kernel level (PT_DENY_ATTACH), memory-reading APIs are blocked by Hardened Runtime, and these protections are provably immutable for the process lifetime because disabling SIP requires a reboot that terminates the process. A four-layer attestation architecture — Secure Enclave signatures, MDM-based independent verification, Apple Managed Device Attestation with Apple-signed certificate chains, and periodic challenge-response — verifies that each machine's security posture has not been tampered with. The result: the only remaining attack is physically probing memory chips soldered into the SoC package, the same residual threat model accepted by Apple's Private Cloud Compute for Siri and Apple Intelligence. The API is OpenAI-compatible. Operators keep 95% of revenue.

## How It Works

```
Consumer (SDK / Web UI / curl)
    |
    |  HTTPS, OpenAI-compatible API
    v
Coordinator (Go, Confidential VM)
    |
    |  WebSocket (outbound from provider)
    v
Provider (Rust, hardened process)
    |
    |  vllm-mlx
    v
Apple Silicon GPU (Metal)
```

Providers connect outbound over WebSocket -- no port forwarding needed. The coordinator encrypts each request with the provider's X25519 public key before forwarding it. Only the hardened provider process can decrypt it.

## Models

Models are selected from a curated catalog. The coordinator only routes requests to models it has verified.

### Text

| Model | Architecture | Size | Min RAM | Notes |
|-------|-------------|------|---------|-------|
| Gemma 4 26B 8-bit | 26B MoE, 4B active | 28 GB | 36 GB | Google's latest MoE, fast multimodal |
| Qwen3.5 27B Claude Opus 8-bit | 27B dense | 27 GB | 36 GB | Frontier-quality reasoning, Claude Opus distilled |
| Trinity Mini 8-bit | 27B Adaptive MoE | 26 GB | 48 GB | Fast agentic inference |
| Qwen3.5 122B MoE 8-bit | 122B MoE, 10B active | 122 GB | 128 GB | Best quality reasoning |
| MiniMax M2.5 8-bit | 239B MoE, 11B active | 243 GB | 256 GB | SOTA coding, ~100 tok/s |

## Use the API

OpenAI-compatible. Works with any OpenAI SDK by changing the base URL.

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://api.darkbloom.dev/v1",
    api_key="eigeninference-..."
)

# Chat completion
response = client.chat.completions.create(
    model="qwen3.5-27b-claude-opus-8bit",
    messages=[{"role": "user", "content": "Hello"}],
    stream=True
)
```

The Anthropic Messages API is also supported at `/v1/messages`.

## Become a Provider

Earn by serving inference on your idle Mac.

### Requirements

- Apple Silicon Mac (M1 or later)
- macOS 14 (Sonoma) or later
- 16 GB+ unified memory recommended

### Install

```bash
curl -fsSL https://api.darkbloom.dev/install.sh | bash
```

Zero prerequisites. The installer bundles the provider binary, Python 3.12 runtime, vllm-mlx, and Secure Enclave tooling. You pick a model from the catalog, link your account, and you're serving within minutes.

### Provider CLI

```bash
darkbloom serve          # Start serving (foreground)
darkbloom start          # Background daemon
darkbloom stop           # Stop daemon
darkbloom status         # Hardware and connection info
darkbloom doctor         # Diagnose issues
darkbloom models list    # Downloaded models
darkbloom earnings       # Earnings and usage
darkbloom update         # Check for updates
```

### macOS Menu Bar App

A native SwiftUI app is also available:

- One-click start/stop
- Real-time throughput display
- Idle detection (pauses when you're using your Mac)
- Provider scheduling (set hours your Mac serves, GPU memory freed between windows)
- Earnings dashboard
- Auto-start at login

### Scheduling

Providers can configure time-based availability windows. Outside scheduled hours, the provider disconnects and shuts down the backend to free GPU memory. Configured in the app's Settings or directly in `~/.config/eigeninference/provider.toml`:

```toml
[schedule]
enabled = true

[[schedule.windows]]
days = ["mon", "tue", "wed", "thu", "fri"]
start = "22:00"
end = "08:00"
```

## Security

Darkbloom prevents anyone -- including providers -- from reading consumer prompts.

| Layer | What It Does |
|-------|-------------|
| E2E encryption | Coordinator encrypts requests with provider's X25519 key before forwarding; only the hardened provider process decrypts |
| Hardened Runtime + SIP | Blocks debugger attachment, memory reads, code injection |
| Secure Enclave attestation | Hardware-bound P-256 identity, signed attestation blobs |
| Binary hash verification | Coordinator verifies the provider runs a blessed binary |
| Challenge-response | SIP/SecureBoot re-verified every 5 minutes |
| MDM SecurityInfo | Apple MDM cross-checks hardware integrity (SIP, Secure Boot, FileVault) |
| MDA certificate chain | Optional Apple Enterprise Attestation Root CA verification |
| RDMA detection | Enables hypervisor and runs inside it |

Attestation data is publicly verifiable at `GET /v1/providers/attestation`.

### Trust Levels

| Level | Name | Verification |
|-------|------|-------------|
| `self_signed` | Self-Attested | Secure Enclave signature + periodic challenge-response |
| `hardware` | Hardware-Attested | MDA certificate chain from Apple Enterprise Attestation Root CA |

## Pricing

| Type | Rate |
|------|------|
| Text (Gemma 4 26B) | $0.065 / 1M input, $0.20 / 1M output |
| Text (Qwen3.5 27B) | $0.10 / 1M input, $0.78 / 1M output |
| Text (Qwen3.5 122B) | $0.13 / 1M input, $1.04 / 1M output |
| Text (MiniMax M2.5) | $0.06 / 1M input, $0.50 / 1M output |

0% platform fee. Providers keep 100%.

## Architecture

| Component | Language | Role |
|-----------|----------|------|
| Coordinator (`coordinator/`) | Go | Control plane: routing, attestation, billing, API |
| Provider (`provider/`) | Rust | Inference agent: security, attestation, WebSocket client |
| Console (`console-ui/`) | Next.js 16 | Web dashboard: chat, billing, provider verification |
| macOS App (`app/Darkbloom/`) | Swift | Menu bar app: status, scheduling, earnings |
| Secure Enclave (`enclave/`) | Swift | Hardware-bound P-256 identity |
| Landing (`landing/`) | HTML | Static landing page |

## Development

```bash
# Coordinator
cd coordinator && go test ./...

# Provider (set PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 on Python 3.14+)
cd provider && cargo test

# macOS App
cd app/Darkbloom && swift build -c release

# Console UI
cd console-ui && npm install && npm run dev
```

## License

Proprietary. All rights reserved.

## Disclaimer
🚧 Darkbloom is under active development and has not been audited. Darkblom is rapidly being upgraded, features may be added, removed or otherwise improved or modified and interfaces will have breaking changes. Darkbloom should be used only for testing purposes and not in production. Darkbloom is provided "as is" and Eigen Labs, Inc. does not guarantee its functionality or provide support for its use in production. 🚧

## Security Bugs
Please report security vulnerabilities to security@eigenlabs.org. Do NOT report security bugs via Github Issues.
