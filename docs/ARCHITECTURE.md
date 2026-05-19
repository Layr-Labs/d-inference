# Architecture

> Deep-dive into Darkbloom's system design, security model, and component interactions.

---

## Table of Contents

- [Overview](#overview)
- [System Diagram](#system-diagram)
- [Components](#components)
- [Security Architecture](#security-architecture)
- [Privacy Architecture](#privacy-architecture)
- [Inference Engine](#inference-engine)
- [Payments & Billing](#payments--billing)
- [Storage](#storage)
- [Hardware Support](#hardware-support)

---

## Overview

Darkbloom is a platform for **private, decentralized AI inference** on Apple Silicon Macs. Mac owners contribute idle GPU compute. Consumers get private inference on open-source models with hardware-backed trust guarantees from Apple's Secure Enclave and MDM-verified security posture.

Key design principles:

- **Privacy by hardware** — Prompts are encrypted end-to-end; the coordinator never sees plaintext. Provider hardening makes in-memory inspection infeasible without physical lab equipment.
- **Zero-trust providers** — Every provider must prove its security posture through multi-layer attestation before receiving traffic.
- **OpenAI compatibility** — Drop-in replacement for OpenAI APIs; no SDK changes required.

## System Diagram

```
Consumer (OpenAI SDK / Web UI / cURL)
    │
    │  HTTPS (OpenAI-compatible API)
    ▼
┌─────────────────────────────────────────────────────────┐
│  Coordinator (Go — EigenCloud TEE in prod / GCP in dev) │
│                                                         │
│  ┌──────────┐ ┌──────────┐ ┌────────────┐ ┌──────────┐ │
│  │ Routing  │ │ Billing  │ │Attestation │ │   MDM    │ │
│  │ & Queue  │ │ & Ledger │ │Verification│ │ Security │ │
│  └──────────┘ └──────────┘ └────────────┘ └──────────┘ │
└──────────────────────┬──────────────────────────────────┘
                       │
                       │  WebSocket (outbound from provider — no port forwarding)
                       ▼
┌─────────────────────────────────────────────────────────┐
│  Provider CLI (Swift `darkbloom`, hardened in-process)   │
│                                                         │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌───────────┐  │
│  │   MLX    │ │  Crypto  │ │ Security │ │  Secure   │  │
│  │Inference │ │  X25519  │ │ Hardening│ │  Enclave  │  │
│  └──────────┘ └──────────┘ └──────────┘ └───────────┘  │
└──────────────────────┬──────────────────────────────────┘
                       │
                       │  mlx-swift-lm (in-process, Metal)
                       ▼
                Apple Silicon GPU
```

> The legacy Rust provider (`provider/`) is still in production but will be retired at the Swift cutover.

---

## Components

### Coordinator (`coordinator/`)

**Language:** Go  
**Runtime:** Confidential VM (AMD SEV-SNP) — hardware-encrypted memory that even the cloud provider cannot read.

The coordinator is the control plane. Consumer requests arrive as plain text over HTTPS; the Confidential VM boundary ensures prompts are never exposed to the host. Prompt content is never logged.

**Responsibilities:**

| Capability | Details |
|-----------|---------|
| Provider management | Accepts WebSocket connections, tracks availability, health, and trust |
| Request routing | Routes to the best available provider using composite scoring |
| API surface | OpenAI-compatible HTTP API (`/v1/chat/completions`, `/v1/models`, etc.) |
| Attestation | Verifies Secure Enclave P-256 ECDSA signatures, binary hashes, SIP/SecureBoot status |
| Challenge-response | Periodically challenges providers every 5 minutes to prove key possession + security posture |
| Trust enforcement | Immediately marks providers untrusted if SIP or Secure Boot is disabled |
| Billing | API keys, usage tracking, payment ledger, Solana USDC settlement |
| Queue management | Per-model request queues (max 10, 30s timeout) when providers are busy |
| Reputation | Composite scoring: 40% job success + 30% uptime + 20% attestation + 10% response time |

**Provider Scoring Formula:**

```
score = (1 - load) × decode_tps × trust_multiplier × reputation × warm_model_bonus × health_factor
```

- `health_factor` uses live system metrics (memory pressure, CPU usage, thermal state) reported in heartbeats
- Supports up to 4 concurrent requests per provider with gradient load scoring
- In-flight requests are cancelled immediately when the consumer disconnects

### Provider CLI (`provider-swift/`)

**Language:** Swift (replaces the Rust provider at cutover)

Two binaries:

| Binary | Purpose |
|--------|---------|
| `darkbloom` | Main provider daemon — `serve`, `start`, `stop`, `status`, `doctor`, `models`, `login`, `logout`, `benchmark`, `update`, `verify` |
| `darkbloom-enclave` | Stateless Secure Enclave attestation/sign helper — `attest`, `sign`, `info`, `wallet-address` |

Inference is **in-process** via [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm). NaCl `crypto_box` (XSalsa20-Poly1305 + Curve25519) is provided by [`swift-sodium`](https://github.com/jedisct1/swift-sodium), maintaining wire-format compatibility with the Rust `crypto_box` and Go `nacl/box` implementations.

The Secure Enclave identity uses native CryptoKit — no FFI bridge.

### Provider (Legacy) (`provider/`)

**Language:** Rust + Python (PyO3)  
**Status:** In production, retired at Swift cutover.

The currently-shipping provider. Embeds the Python interpreter via PyO3 to run in-process MLX inference (`mlx-lm` / `vllm-mlx`). Same hardening posture as the Swift port. Being replaced module-for-module by `provider-swift/`.

### Consumer SDK

The **OpenAI Python SDK** serves as the consumer client. Users point its `base_url` at the coordinator and pass an `eigeninference-…` API key. Responses include Darkbloom-specific fields:

| Field | Type | Description |
|-------|------|-------------|
| `provider_attested` | `bool` | Whether the serving provider has a verified attestation |
| `provider_trust_level` | `string` | Trust level of the serving provider |

```python
from openai import OpenAI

client = OpenAI(
    base_url="https://api.darkbloom.dev/v1",
    api_key="eigeninference-..."
)

response = client.chat.completions.create(
    model="qwen3.5-27b-claude-opus-8bit",
    messages=[{"role": "user", "content": "Hello"}],
    stream=True,
)
```

---

## Security Architecture

### Threat Model Summary

The provider owns the Mac hardware but **cannot** inspect inference data:

```
Attack Vector                       Blocked By
────────────────────────────────────────────────────────────────────
Attach debugger (lldb)              PT_DENY_ATTACH + Hardened Runtime
Read process memory                 Hardened Runtime (kernel denies task_for_pid)
Sniff IPC / network                 No IPC — inference is in-process
Modify the binary                   Code signing + SIP (modified binary won't launch)
Replace with fake binary            Binary hash in attestation — coordinator verifies
Inject malicious Python package     Python path locked to signed bundle
Load kernel extension               SIP blocks unsigned kexts
Modify kernel at runtime            KIP (hardware-enforced)
Disable SIP                         Requires reboot → kills process → data gone
Read /dev/mem                       Doesn't exist on Apple Silicon
DMA attack                          IOMMU default-deny + Hypervisor.framework Stage 2
Physical memory probing             Soldered LPDDR5x into SoC die (lab-grade only)
```

> This is the same threat model as **Apple Private Cloud Compute**.

### SIP Enforcement

SIP (System Integrity Protection) is the foundation of the security model. Disabling SIP requires:

1. Reboot into Recovery Mode (kills the inference process, wipes all data from memory)
2. Run `csrutil disable`
3. Reboot back to macOS

Darkbloom checks SIP at three points:

| Check Point | Timing | Consequence |
|------------|--------|-------------|
| Process startup | Once | Refuses to serve if SIP is disabled |
| Before every inference request | Per-request | Defense-in-depth |
| Challenge-response | Every 5 minutes | Coordinator detects reboot with SIP off |

If SIP is found disabled at any point, the provider is **immediately** marked untrusted — no three-strike rule.

### Trust Levels

| Level | Name | How Achieved | Verification |
|-------|------|-------------|-------------|
| `none` | Open Mode | Provider sends no attestation | Consumer is warned |
| `self_signed` | Self-Attested | SE-signed attestation blob | Secure Enclave signature + periodic challenge-response with SIP check |
| `hardware` | Hardware-Attested | MDM enrollment + Managed Device Attestation | MDA certificate chain verified against Apple Enterprise Attestation Root CA |

### MDM Integration

Darkbloom uses Apple MDM (MicroMDM) to independently verify provider security posture:

| Capability | Details |
|-----------|---------|
| Enrollment | Profile-based (`.mobileconfig`), minimal permissions (AccessRights=1041) |
| SIP status | `SystemIntegrityProtectionEnabled` from SecurityInfo query |
| Boot security | `SecureBoot.SecureBootLevel` (full/reduced/permissive) |
| System volume | `AuthenticatedRootVolumeEnabled` (SSV integrity) |
| Disk encryption | `FDE_Enabled` (FileVault status) |
| Recovery lock | `IsRecoveryLockEnabled` |
| Push notifications | APNs for on-demand attestation queries |

Infrastructure: MicroMDM + SCEP + step-ca co-located in the coordinator container on EigenCloud (prod). Dev runs on Google Cloud with MDM disabled.

### Apple Managed Device Attestation (MDA)

After SecurityInfo verification, the coordinator requests `DevicePropertiesAttestation` via MDM. The device contacts Apple's servers, which return a DER-encoded certificate chain signed by **Apple's Enterprise Attestation Root CA**. This is the strongest verification — Apple itself vouches for the device.

```
Apple Enterprise Attestation Root CA (P-384, embedded in coordinator)
  └─ Apple Enterprise Attestation Sub CA 1
      └─ Leaf certificate (device identity)
          ├─ Serial number    (OID 1.2.840.113635.100.8.9.1)
          ├─ UDID             (OID 1.2.840.113635.100.8.9.2)
          ├─ OS version       (OID 1.2.840.113635.100.8.10.1)
          ├─ SepOS version    (OID 1.2.840.113635.100.8.10.2)
          ├─ Secure Boot      (OID 1.2.840.113635.100.8.13.2)
          └─ Freshness code   (OID 1.2.840.113635.100.8.11.1)
```

The coordinator verifies the cert chain against Apple's root CA, cross-checks the serial number against the provider's self-reported attestation, and stores the chain. Users can independently verify via `GET /v1/providers/attestation`.

### Attestation Blob

Each provider creates a signed attestation blob containing:

| Field | Description |
|-------|-------------|
| `publicKey` | Base64 P-256 public key (raw X\|\|Y, 64 bytes) |
| `chipName` | e.g., "Apple M3 Max" |
| `hardwareModel` | e.g., "Mac15,8" |
| `osVersion` | e.g., "26.3.0" |
| `secureEnclaveAvailable` | Always `true` on Apple Silicon |
| `sipEnabled` | System Integrity Protection status |
| `secureBootEnabled` | Secure Boot status |
| `encryptionPublicKey` | X25519 key bound to this identity |
| `authenticatedRootEnabled` | Authenticated Root Volume (sealed system volume) |
| `systemVolumeHash` | APFS snapshot hash (proves unmodified system volume) |
| `serialNumber` | Hardware serial number for MDM cross-reference |
| `binaryHash` | SHA-256 of the provider binary |
| `timestamp` | ISO 8601 |

Signed with the Secure Enclave P-256 key (ECDSA, DER-encoded).

### Challenge-Response Protocol

```
Every 5 minutes:

  1. Coordinator generates 32-byte random nonce + timestamp
  2. Sends attestation_challenge over WebSocket
  3. Provider signs (nonce + timestamp + public_key) with SE key
  4. Provider includes fresh sip_enabled and secure_boot_enabled status
  5. Sends attestation_response back
  6. Coordinator verifies:
     ├─ Nonce matches
     ├─ Public key matches registration
     ├─ Signature is non-empty
     ├─ sip_enabled == true   → IMMEDIATE untrust if false
     └─ secure_boot_enabled == true → IMMEDIATE untrust if false
  7. 3 consecutive verification failures → provider marked untrusted
  8. SIP or SecureBoot disabled → IMMEDIATE untrust (no 3-strike rule)
```

### User-Side Attestation Verification

Public API endpoint (no authentication required):

```bash
curl https://api.darkbloom.dev/v1/providers/attestation
```

Returns for each provider:

- Secure Enclave P-256 public key
- Hardware info (chip, model, serial, system volume hash)
- Security state (SIP, SecureBoot, ARV, SE)
- MDM verification status
- Apple MDA certificate chain (base64 DER, leaf + intermediate)
- MDA-extracted properties (serial, UDID, OS version, SepOS version)

**Independent verification steps:**

1. Download Apple's Enterprise Attestation Root CA from [apple.com/certificateauthority](https://www.apple.com/certificateauthority/)
2. Decode the `mda_cert_chain_b64` certificates from base64 to DER
3. Verify the cert chain against Apple's root CA using any x509 library
4. Check that the serial number in the Apple cert matches the provider's attestation

---

## Privacy Architecture

```
Layer                              Status    What It Means
──────────────────────────────────────────────────────────────────────
Confidential VM (coordinator)      Active    AMD SEV-SNP, hardware-encrypted memory
TLS transport (consumer)           Active    Encrypted in transit
Hardware-bound identity (SE)       Active    Provider key in Secure Enclave silicon
Signed attestation                 Active    SE signs hardware info + binary hash
Challenge-response + SIP check     Active    Ongoing security posture verification
PT_DENY_ATTACH                     Active    Kernel-level anti-debug
Hardened Runtime                   Active    Blocks external memory inspection
In-process inference               Active    No subprocess/IPC to sniff
Memory wiping                      Active    Volatile-zero after each request
Python path locking                Active    Prevents malicious package injection
Signed app bundle                  Active    Any modification breaks code signature
MDM SecurityInfo                   Active    Hardware-verified SIP/SecureBoot/SSV
SIP/SecureBoot attestation         Active    Self-reported + MDM-verified
Hardware-attested posture (MDA)    Active    Apple Enterprise Attestation Root CA signs device cert chain
User-verifiable attestation API    Active    GET /v1/providers/attestation — exposes Apple cert chain
```

---

## Inference Engine

Darkbloom runs inference **in-process** — no subprocess architecture.

| Backend | Mode | Features |
|---------|------|----------|
| **mlx-lm** | In-process (PyO3) | Primary backend, auto-installed if missing |
| **vllm-mlx** | In-process (PyO3) | Preferred when available — continuous batching, prefix caching |
| **mlx-swift-lm** | In-process (native Swift) | Swift provider backend — direct Metal access |

If the in-process engine cannot initialize, the provider refuses to start and instructs the user to install the required backend.

**Operational behavior:**

- Backend idle timeout: **1 hour** — process killed after 1 hour of no requests to free GPU memory
- Lazy reload: Backend reloaded on next request arrival (cold-start penalty of ~10–30s for model reload)
- Chat template injection: Auto-injects ChatML template for models missing `chat_template` field (e.g., Qwen3.5 base models)
- Model scan: Fast discovery at startup without hashing; weight hash computed on-demand only for the served model

---

## Payments & Billing

| Aspect | Details |
|--------|---------|
| Ledger | Internal micro-USD (1 USD = 1,000,000 micro-USD) |
| Settlement | Solana USDC (primary), Stripe (wired, not activated) |
| Platform fee | 0% — providers keep 100% |
| Minimum charge | $0.001 per request |
| Wallet derivation | BIP39 mnemonic → SLIP-0010 (m/44'/501'/0'/0') |
| Referrals | Referrers receive a share of platform fees |

---

## Storage

| Backend | Use Case | Key Feature |
|---------|----------|-------------|
| **MemoryStore** | Development | No external dependencies; bounded ring buffer |
| **PostgresStore** | Production | Atomic balance operations, persistent ledger |

**Tables:** `api_keys`, `usage`, `payments`, `balances`, `ledger_entries`, `telemetry_events`

---

## Hardware Support

Any Apple Silicon Mac (M1 or later):

| Chip | Unified Memory | Bandwidth | Recommended Models |
|------|---------------|-----------|-------------------|
| M1 | 8–16 GB | 68 GB/s | 3B–8B |
| M1 Pro / Max | 16–64 GB | 200–400 GB/s | 8B–33B |
| M2 Pro / Max | 16–96 GB | 200–400 GB/s | 8B–70B |
| M3 Pro / Max | 18–128 GB | 150–400 GB/s | 8B–122B |
| M3 Ultra | 96–256 GB | 819 GB/s | 8B–230B |
| M4 Pro / Max | 24–128 GB | 273–546 GB/s | 8B–122B |
