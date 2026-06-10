# Darkbloom

> **Public Alpha** -- Darkbloom is a decentralized private inference network for Apple Silicon. Currently in public alpha -- expect rough edges, breaking changes, and downtime.

AI compute today flows through three layers of markup — GPU manufacturers to hyperscalers to API providers to end users. Meanwhile, over 100 million Apple Silicon Macs sit idle most of each day with 64–512 GB of unified memory and up to 819 GB/s memory bandwidth, capable of running models with up to 500 billion parameters at interactive speeds. Darkbloom connects this idle capacity directly to demand. The core technical challenge is that the machine owner has root access and physical custody — they should not be able to see user prompts or model responses. We solve this by eliminating every software path through which inference data could be observed: the inference engine runs in-process (no subprocess, no local server, no IPC), debuggers are denied at the kernel level (PT_DENY_ATTACH), memory-reading APIs are blocked by Hardened Runtime, and these protections are provably immutable for the process lifetime because disabling SIP requires a reboot that terminates the process. A four-layer attestation architecture — Secure Enclave signatures, MDM-based independent verification, Apple Managed Device Attestation with Apple-signed certificate chains, and periodic challenge-response — verifies that each machine's security posture has not been tampered with. The result: the only remaining attack is physically probing memory chips soldered into the SoC package, the same residual threat model accepted by Apple's Private Cloud Compute for Siri and Apple Intelligence. The API is OpenAI-compatible. During the public alpha, operators keep 100% of revenue (0% platform fee).

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
Provider (Swift CLI, hardened process)
    |
    |  mlx-swift-lm
    v
Apple Silicon GPU (Metal)
```

Providers connect outbound over WebSocket -- no port forwarding needed. The coordinator encrypts each request with the provider's X25519 public key before forwarding it. Only the hardened provider process can decrypt it.

## Models

Models are selected from a curated catalog. The coordinator only routes requests to models it has verified.

### Text

| Model ID | Name | Architecture | Quant | Context | Max Output | Download | Min RAM | Notes |
|----------|------|--------------|-------|---------|-----------|----------|---------|-------|
| `gpt-oss-20b` | GPT-OSS 20B | 20.9B MoE, 3.6B active | fp8 | 131K | 32K | 12 GB | 24 GB | OpenAI open-weight reasoning model: configurable reasoning effort, full chain-of-thought, function calling, structured outputs. Apache 2.0. |
| `gemma-4-26b` | Gemma 4 26B | 25.2B MoE, 3.8B active | 8-bit | 131K | 32K | 28 GB | 36 GB | Google DeepMind MoE: multimodal input (text + image), configurable thinking modes, function calling. Apache 2.0. |

Supported sampling parameters: `temperature`, `top_p`, `top_k`, `frequency_penalty`, `presence_penalty`, `repetition_penalty`, `stop`, `seed`, `max_tokens`.

The table above reflects the current lineup; the live catalog is always available at `GET /v1/models/catalog` (public) or `GET /v1/models` (authed).

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
    model="gemma-4-26b",
    messages=[{"role": "user", "content": "Hello"}],
    stream=True
)
```

Also supported: the OpenAI Responses API at `/v1/responses`, legacy completions at `/v1/completions`, and the Anthropic Messages API at `/v1/messages`. Full endpoint reference: [docs/api.md](docs/api.md).

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

Zero prerequisites. The installer downloads a single signed bundle containing the
provider CLI, the Secure Enclave attestation helper, and the matching MLX
metallib. You pick a model from the catalog, link your account, and you're
serving within minutes.

### Provider CLI

```bash
darkbloom serve          # Start serving (foreground)
darkbloom start          # Background daemon
darkbloom stop           # Stop daemon
darkbloom status         # Hardware and connection info
darkbloom doctor         # Diagnose issues
darkbloom models list    # Downloaded models
darkbloom earnings       # Earnings and usage
darkbloom benchmark      # Local tok/s benchmark
darkbloom update         # Check for updates
```

### Scheduling

Providers can configure time-based availability windows. Outside scheduled hours, the provider disconnects and shuts down the backend to free GPU memory. Configure them in `~/.config/eigeninference/provider.toml`:

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

| Model | Input (per 1M tokens) | Output (per 1M tokens) |
|-------|----------------------|------------------------|
| `gpt-oss-20b` | $0.0145 | $0.07 |
| `gemma-4-26b` | $0.03 | $0.165 |

Per-token prices are set to roughly 50% of typical hosted-API list rates for comparable models. Live per-model pricing is always available at `GET /v1/pricing`. During the public alpha there is a 0% platform fee — providers keep 100% of revenue.

## Architecture

| Component | Language | Role |
|-----------|----------|------|
| Coordinator (`coordinator/`) | Go | Control plane: routing, attestation, billing, API |
| Provider (`provider-swift/`) | Swift | CLI inference agent for Apple Silicon Macs |
| Console (`console-ui/`) | Next.js 16 | Web dashboard: chat, billing, provider verification |
| Admin (`admin-ui/`) | Next.js | Admin dashboard: releases, model registry, invites |
| Landing (`landing/`) | HTML | Static landing page |

Full technical documentation lives in [docs/](docs/README.md) — see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the system architecture, [docs/api.md](docs/api.md) for the API reference, `docs/design/` for design/spec documents, and `docs/runbooks/` for operational runbooks.

## Development

Toolchain versions are pinned in [`mise.toml`](mise.toml); build/test commands are wrapped in the root [`Makefile`](Makefile) (`make` with no args lists all targets).

```bash
mise install            # one-time: install pinned toolchains
make coordinator        # Go: test + build
make provider           # Swift: build + test
make ui                 # console-ui: install + lint + test + build
make test               # all unit tests
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow.

## License

Proprietary. All rights reserved.

## Disclaimer
🚧 Darkbloom is under active development and has not been audited. Darkblom is rapidly being upgraded, features may be added, removed or otherwise improved or modified and interfaces will have breaking changes. Darkbloom should be used only for testing purposes and not in production. Darkbloom is provided "as is" and Eigen Labs, Inc. does not guarantee its functionality or provide support for its use in production. 🚧

## Security Bugs
Please report security vulnerabilities to security@eigenlabs.org. Do NOT report security bugs via Github Issues.
