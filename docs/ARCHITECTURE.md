# DGInf Architecture

## Overview

DGInf is a platform for private, decentralized AI inference on Apple Silicon Macs. Mac owners provide idle compute. Consumers get private inference on open-source models with hardware-backed trust guarantees from Apple's Secure Enclave.

```
Consumer (Python SDK)
    |
    | HTTPS (TLS)
    v
Coordinator (Go, GCP Confidential VM — AMD SEV-SNP)
    |
    | WebSocket (outbound from provider, no port forwarding needed)
    v
Provider Agent (Rust CLI daemon)
    |
    | HTTP (localhost)
    v
Inference Backend (mlx-lm / vllm-mlx subprocess)
    |
    v
MLX -> Metal -> Apple Silicon GPU
```

## Components

### Provider Agent (`provider/`)

**Language:** Rust

A CLI daemon that runs on each provider Mac. Manages the inference backend, connects to the coordinator, and proxies inference requests.

- Detects Apple Silicon hardware (chip family, memory, GPU cores, bandwidth)
- Manages inference backends (mlx-lm, vllm-mlx) as subprocesses with health checking and auto-restart
- Scans HuggingFace cache for available MLX models and filters by memory
- Maintains persistent WebSocket connection to coordinator with auto-reconnect
- Proxies inference requests from coordinator to local backend (streaming SSE)
- Responds to attestation challenges to prove key possession
- Generates Secure Enclave identity and signed attestation via the enclave CLI tool

### Coordinator (`coordinator/`)

**Language:** Go

The control plane. Runs in a GCP Confidential VM (AMD SEV-SNP) — hardware-encrypted memory that even the cloud provider cannot read. Consumers send plain text over HTTPS; the Confidential VM is the trust boundary. Prompt content is never logged.

- Accepts provider WebSocket connections and tracks availability
- Exposes OpenAI-compatible HTTP API for consumers (`/v1/chat/completions`, `/v1/models`)
- Routes requests to the best available provider (round-robin, trust-aware)
- Verifies provider attestations (Secure Enclave P-256 ECDSA signatures)
- Periodically challenges providers to prove key possession (every 5 minutes)
- Manages API keys, usage tracking, payment ledger, and trust levels
- Persistent storage via PostgreSQL (in-memory fallback for development)

### Consumer SDK (`sdk/`)

**Language:** Python

OpenAI-compatible client library and CLI. Drop-in replacement for existing OpenAI code:

```python
from dginf import DGInf
client = DGInf(base_url="https://coordinator.dginf.io", api_key="dginf-...")
response = client.chat.completions.create(
    model="mlx-community/Qwen3.5-4B-MLX-4bit",
    messages=[{"role": "user", "content": "Hello"}],
    stream=True,
)
```

Includes payment commands: `dginf deposit`, `dginf balance`, `dginf usage`.

### Secure Enclave Module (`enclave/`)

**Language:** Swift

Wraps Apple CryptoKit's Secure Enclave APIs to provide hardware-bound cryptographic identity for provider nodes. This is the foundation of DGInf's trust model.

## Apple Secure Enclave Attestation

### What the Secure Enclave Is

The Secure Enclave is a dedicated hardware security subsystem on every Apple Silicon chip (M1 and later). It has its own Boot ROM, AES engine, true random number generator (TRNG), and encrypted memory — isolated from the application processor. Even if macOS is fully compromised, the Secure Enclave remains intact.

Key properties for DGInf:
- **Hardware-bound keys**: P-256 signing keys generated inside the Secure Enclave cannot be extracted, cloned, or transferred to another device. The private key never leaves the silicon.
- **Non-exportable**: The `dataRepresentation` of a Secure Enclave key is an opaque handle — it only works on the device that created it.
- **Tamper-resistant**: The Secure Enclave is physically part of the SoC die. Memory probing requires destructive desoldering of LPDDR5x chips that are soldered into the package.

### How DGInf Uses the Secure Enclave

#### Identity Key Generation

On first run (`dginf-provider init`), the provider generates a P-256 signing key inside the Secure Enclave via Apple's CryptoKit:

```swift
let privateKey = try SecureEnclave.P256.Signing.PrivateKey()
```

This key becomes the provider's permanent identity on the DGInf network. The opaque handle is saved to `~/.dginf/enclave_key.data` for persistence across reboots — but the actual private key material stays in the Secure Enclave hardware.

#### Attestation Blob

The provider creates a signed attestation blob containing:

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
| `timestamp` | ISO 8601 |

The attestation is JSON-encoded with sorted keys and signed with the Secure Enclave P-256 key (ECDSA, DER-encoded signature). This produces a `SignedAttestation` with the blob + base64 signature.

#### Registration Flow

```
Provider Boot:
  1. Secure Enclave generates/loads P-256 identity key
  2. Provider builds attestation blob with system info
  3. Secure Enclave signs the blob (P-256 ECDSA)
  4. Provider connects to coordinator via WebSocket
  5. Sends Register message with signed attestation

Coordinator Verification:
  6. Parses attestation JSON
  7. Decodes P-256 public key from base64 (64-byte raw X||Y format)
  8. Hashes the attestation blob with SHA-256
  9. Verifies the ECDSA signature against the public key
  10. Checks: SIP enabled? Secure Boot enabled? SE available?
  11. Checks: encryptionPublicKey matches Register message's public_key?
  12. If all pass -> provider marked as "self_signed" trust level
  13. If any fail -> provider accepted but marked as unattested (Open Mode)
```

#### Challenge-Response Verification

The coordinator periodically verifies that providers still hold their private key:

```
Every 5 minutes:
  1. Coordinator generates 32-byte random nonce + timestamp
  2. Sends attestation_challenge over WebSocket
  3. Provider signs (nonce + timestamp + public_key) with their key
  4. Sends attestation_response back
  5. Coordinator verifies signature against registered public key
  6. If 3 consecutive failures -> provider marked untrusted, no more jobs
```

This prevents a provider from registering once and then being compromised — ongoing key possession is verified.

### Trust Levels

| Level | Name | Meaning | How Achieved |
|-------|------|---------|-------------|
| `none` | Open Mode | No attestation. Consumer warned. | Provider sends no attestation |
| `self_signed` | Self-Attested | Attestation signed by provider's own key. Coordinator verifies signature and challenges periodically. | Provider sends SE-signed attestation |
| `hardware` | Hardware-Attested | MDA certificate chain verified against Apple Enterprise Attestation Root CA. Unforgeable. | Requires Apple Business Manager + MDM enrollment |

Consumers see the trust level in API responses:
- `X-Provider-Attested: true/false` header
- `X-Provider-Trust-Level: self_signed` header
- `attested_providers` count in `/v1/models` metadata

### Current Limitation: Self-Signed vs Hardware-Attested

Currently, the coordinator verifies that the attestation was signed by a P-256 key, but cannot prove that key lives in the Secure Enclave (vs. a software-generated P-256 key). Both produce identical signatures.

**Managed Device Attestation (MDA)** closes this gap. MDA generates a certificate chain from the Secure Enclave that roots to Apple's Enterprise Attestation Root CA:

```
Device key (Secure Enclave) -> Apple Intermediate CA -> Apple Enterprise Attestation Root CA
```

MDA also provides hardware-attested OIDs for:

| OID | Property |
|-----|----------|
| `1.2.840.113635.100.8.13.1` | SIP status (hardware-attested, not self-reported) |
| `1.2.840.113635.100.8.13.2` | Secure Boot status |
| `1.2.840.113635.100.8.13.3` | Third-party kernel extensions |

MDA requires Apple Business Manager, which requires a business entity + D-U-N-S number. The MDA certificate verification infrastructure is already built (`coordinator/internal/attestation/mda.go`) — when ABM is available, it's a matter of swapping the test root CA for Apple's real root CA.

### macOS Security Features (Built-In)

These protections exist on every Apple Silicon Mac by default:

| Feature | What it does | DGInf relevance |
|---------|-------------|----------------|
| **Secure Enclave** | Isolated security subsystem with own Boot ROM, AES, TRNG | Hardware-bound provider identity |
| **Kernel Integrity Protection (KIP)** | Hardware-enforced after kernel init — memory controller denies all writes to kernel code | Prevents runtime kernel modification |
| **Signed System Volume (SSV)** | Merkle tree hash over entire system volume, verified at boot | Detects OS tampering |
| **System Integrity Protection (SIP)** | Restricts root from modifying /System, prevents unsigned kexts | Prevents code injection |
| **IOMMU** | Per-device IOMMU for every DMA agent, default-deny | Prevents DMA-based memory extraction |
| **No /dev/mem** | Apple Silicon does not expose physical memory to userspace | Prevents direct memory reads |
| **Secure Boot** | Boot ROM -> LLB -> iBoot -> kernel, all Apple-signed | Strong boot chain |

### Privacy Architecture

```
Layer                              Status      What it means
------------------------------------------------------------
Confidential VM (coordinator)      Working     AMD SEV-SNP, hardware-encrypted memory
TLS transport (consumer)           Working     Encrypted in transit
Hardware-bound identity (SE)       Working     Provider key in Secure Enclave silicon
Signed attestation                 Working     SE signs hardware info + encryption key
Challenge-response                 Working     Ongoing key possession verification
SIP/SecureBoot attestation         Self-signed Currently software-reported
Hardware-attested posture (MDA)    Scaffolded  Needs Apple Business Manager
```

## Inference Backends

DGInf does not implement inference. It uses existing open-source backends:

| Backend | Role | Performance |
|---------|------|------------|
| **mlx-lm** | Primary | Apple's MLX library, best Metal performance, 100+ model architectures |
| **vllm-mlx** | Alternative | Continuous batching, prefix caching, 21-87% faster than llama.cpp |
| **EXO** | Future | Multi-device inference across multiple Macs via libp2p + MLX distributed |

The provider agent manages the backend as a subprocess with health checks and auto-restart.

## Payments (Tempo Blockchain)

Payments use the Tempo blockchain (Stripe's blockchain for stablecoin payments).

- **pathUSD** stablecoin at `0x20C0000000000000000000000000000000000000` (6 decimals)
- Sub-cent transaction fees (~$0.001 per transfer)
- `transferWithMemo` links payments to inference job IDs on-chain
- Internal ledger uses micro-USD (1 USD = 1,000,000), maps 1:1 to pathUSD
- Consumer deposits -> inference charges -> provider payouts (90%) + platform fee (10%)
- Testnet: Chain ID 42431, RPC `https://rpc.moderato.tempo.xyz`
- Mainnet: Chain ID 4217, RPC `https://rpc.presto.tempo.xyz`

## Storage

| Backend | Use case | Key feature |
|---------|----------|-------------|
| **MemoryStore** | Development | No external dependencies |
| **PostgresStore** | Production | Atomic balance operations, persistent ledger |

Tables: `api_keys`, `usage`, `payments`, `balances`, `ledger_entries`

Every balance change is recorded as an immutable ledger entry with type (deposit/charge/payout/platform_fee), amount, balance-after, reference, and timestamp.

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
