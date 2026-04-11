# Darkbloom

> **Research project** -- Darkbloom is an experimental prototype exploring decentralized private inference on Apple Silicon. Expect rough edges, breaking changes, and downtime.

Private AI inference on a decentralized network of hardware-verified Apple Silicon Macs. Your prompts are encrypted end-to-end -- nobody sees your data, not even us.

## How It Works

```
Consumer (SDK / Web UI / curl)
    |
    |  HTTPS, OpenAI-compatible API
    v
Coordinator (Go, EigenCloud TEE)
    |
    |  WebSocket (outbound from provider)
    v
Provider (Rust, hardened process)
    |
    |  vllm-mlx / Draw Things / Cohere STT
    v
Apple Silicon GPU (Metal)
```

Providers connect outbound over WebSocket -- no port forwarding needed. The coordinator never sees plaintext prompts; requests are encrypted with the provider's X25519 public key before leaving the consumer.

## Models

Models are selected from a curated catalog. The coordinator only routes requests to models it has verified.

### Text

| Model | Architecture | Size | Min RAM | Notes |
|-------|-------------|------|---------|-------|
| Qwen3.5 27B Claude Opus 8-bit | 27B dense | 27 GB | 36 GB | Frontier-quality reasoning, Claude Opus distilled |
| Trinity Mini 8-bit | 27B Adaptive MoE | 26 GB | 48 GB | Fast agentic inference |
| Qwen3.5 122B MoE 8-bit | 122B MoE, 10B active | 122 GB | 128 GB | Best quality reasoning |
| MiniMax M2.5 8-bit | 239B MoE, 11B active | 243 GB | 256 GB | SOTA coding, ~100 tok/s |

### Image

| Model | Architecture | Size | Min RAM |
|-------|-------------|------|---------|
| FLUX.2 Klein 4B | 4B diffusion | 8.1 GB | 16 GB |
| FLUX.2 Klein 9B | 9B diffusion | 13 GB | 24 GB |

Image generation uses Draw Things with Metal FlashAttention. Adaptive batching sizes batches based on available system memory.

### Speech-to-Text

| Model | Architecture | Size | Min RAM |
|-------|-------------|------|---------|
| Cohere Transcribe 03-2026 | 2B conformer | 4.2 GB | 8 GB |

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

# Image generation
image = client.images.generate(
    model="flux_2_klein_4b_q8p.ckpt",
    prompt="A cat astronaut on Mars"
)

# Audio transcription
transcript = client.audio.transcriptions.create(
    model="CohereLabs/cohere-transcribe-03-2026",
    file=open("audio.mp3", "rb")
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

Zero prerequisites. The installer bundles the provider binary, Python 3.12 runtime, vllm-mlx, ffmpeg, and Secure Enclave tooling. You pick a model from the catalog, link your account, and you're serving within minutes.

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
| E2E encryption | Prompts encrypted with provider's X25519 key; coordinator never sees plaintext |
| Hardened Runtime + SIP | Blocks debugger attachment, memory reads, code injection |
| Secure Enclave attestation | Hardware-bound P-256 identity, signed attestation blobs |
| Binary hash verification | Coordinator verifies the provider runs a blessed binary |
| Challenge-response | SIP/SecureBoot re-verified every 5 minutes |
| MDM SecurityInfo | Apple MDM cross-checks hardware integrity (SIP, Secure Boot, FileVault) |
| MDA certificate chain | Optional Apple Enterprise Attestation Root CA verification |
| RDMA detection | Refuses to serve if Thunderbolt 5 DMA is enabled |

Attestation data is publicly verifiable at `GET /v1/providers/attestation`.

### Trust Levels

| Level | Name | Verification |
|-------|------|-------------|
| `self_signed` | Self-Attested | Secure Enclave signature + periodic challenge-response |
| `hardware` | Hardware-Attested | MDA certificate chain from Apple Enterprise Attestation Root CA |

## Pricing

| Type | Rate |
|------|------|
| Text (Qwen3.5 27B) | $0.10 / 1M input, $0.78 / 1M output |
| Text (Qwen3.5 122B) | $0.13 / 1M input, $1.04 / 1M output |
| Text (MiniMax M2.5) | $0.06 / 1M input, $0.50 / 1M output |
| Image (FLUX.2 Klein 4B) | $0.0015 / image |
| Audio (Cohere Transcribe) | $0.001 / minute |

5% platform fee. Providers keep 95%.

## Architecture

| Component | Language | Role |
|-----------|----------|------|
| Coordinator (`coordinator/`) | Go | Control plane: routing, attestation, billing, API |
| Provider (`provider/`) | Rust | Inference agent: security, attestation, WebSocket client |
| Console (`console-ui/`) | Next.js 15 | Web dashboard: chat, billing, provider verification |
| macOS App (`app/EigenInference/`) | Swift | Menu bar app: status, scheduling, earnings |
| Secure Enclave (`enclave/`) | Swift | Hardware-bound P-256 identity |
| Image Bridge (`image-bridge/`) | Python | Draw Things gRPC integration for FLUX models |
| Landing (`landing/`) | HTML | Static landing page |

## Development

```bash
# Coordinator
cd coordinator && go test ./...

# Provider (set PYO3_USE_ABI3_FORWARD_COMPATIBILITY=1 on Python 3.14+)
cd provider && cargo test

# macOS App
cd app/EigenInference && swift build -c release

# Console UI
cd console-ui && npm install && npm run dev

# Image Bridge tests
cd image-bridge && python3 -m pytest tests/
```

## License

Proprietary. All rights reserved.
