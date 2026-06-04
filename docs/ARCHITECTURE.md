# EigenInference Architecture

## Overview

EigenInference is a platform for private, decentralized AI inference on Apple Silicon Macs. Mac owners provide idle compute. Consumers get private inference on open-source models with hardware-backed trust guarantees from Apple's Secure Enclave and MDM-verified security posture.

```
Consumer (OpenAI SDK / Web UI / curl)
    |
    | HTTPS (OpenAI-compatible API)
    v
Coordinator (Go, runs on EigenCloud TEE in prod / GCP VM in dev)
    |
    | WebSocket (outbound from provider, no port forwarding needed)
    v
Provider CLI (Swift `darkbloom`, hardened in-process)
    |
    | mlx-swift-lm
    v
Apple Silicon GPU (Metal)
```

## Components

### Coordinator (`coordinator/`)

**Language:** Go

The control plane. Runs in a GCP Confidential VM (AMD SEV-SNP) — hardware-encrypted memory that even the cloud provider cannot read. Consumers send plain text over HTTPS; the Confidential VM is the trust boundary. Prompt content is never logged.

- Accepts provider WebSocket connections and tracks availability
- Exposes OpenAI-compatible HTTP API for consumers (`/v1/chat/completions`, `/v1/models`)
- Routes requests to the best available provider using scoring: `(1-load) * decode_tps * trust_multiplier * reputation * warm_model_bonus * health_factor`
- Health factor uses live system metrics (memory pressure, CPU usage, thermal state) from heartbeats
- Supports up to 4 concurrent requests per provider (gradient load scoring)
- Cancels in-flight requests when consumer disconnects or coordinator drops
- Verifies provider attestations (Secure Enclave P-256 ECDSA signatures)
- Periodically challenges providers to prove key possession + fresh SIP/SecureBoot status (every 5 minutes)
- Immediately marks provider untrusted if SIP or Secure Boot found disabled in challenge response
- Verifies binary hash in attestation against known blessed versions
- Manages API keys, usage tracking, payment ledger, and trust levels
- Per-model request queues (max 10, 30s timeout) for when providers are busy
- Reputation scoring: 40% job success + 30% uptime + 20% attestation + 10% response time
- Persistent storage via PostgreSQL (in-memory fallback for development)

### Consumer SDK

The OpenAI Python SDK is the consumer client; users point its base URL at the
coordinator and pass a `eigeninference-…` API key. Coordinator response
includes EigenInference-specific fields `provider_attested` (bool) and
`provider_trust_level` (string).

```python
from openai import OpenAI
client = OpenAI(base_url="https://api.darkbloom.dev/v1", api_key="eigeninference-...")
response = client.chat.completions.create(
    model="mlx-community/Qwen2.5-7B-Instruct-4bit",
    messages=[{"role": "user", "content": "Hello"}],
    stream=True,
)
```

### Provider Agent (`provider-swift/`)

**Language:** Swift

CLI provider agent. Two binaries:
- `darkbloom`: the main provider daemon. Subcommands `serve`, `start`, `stop`,
  `status`, `doctor`, `models`, `login`, `logout`, `benchmark`, `update`, `verify`.
- `darkbloom-enclave`: stateless Secure Enclave attestation/sign helper (legacy name `eigeninference-enclave` ships as a symlink for backward compatibility)
  used by `install.sh`. Subcommands `attest`, `sign`, `info`, `wallet-address`.

Inference is in-process via [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm)
(forked under `libs/mlx-swift-lm`). NaCl `crypto_box` (XSalsa20-Poly1305 + Curve25519)
is provided by [`swift-sodium`](https://github.com/jedisct1/swift-sodium) so the
wire format remains compatible with the Rust `crypto_box` and Go `nacl/box`
implementations.

The Secure Enclave identity is native CryptoKit — no FFI bridge.

## Security Architecture

### Why Providers Can't Read Prompts

The provider owns the Mac hardware, but cannot inspect inference data because:

```
Attack                          Blocked by
─────────────────────────────────────────────────
Attach debugger (lldb)          PT_DENY_ATTACH + Hardened Runtime
Read process memory             Hardened Runtime (kernel denies task_for_pid)
Sniff IPC/network               No IPC — inference is in-process
Modify the binary               Code signing + SIP (modified binary won't launch)
Replace with fake binary        Binary hash in attestation — coordinator verifies
Inject malicious Python pkg     Python path locked to signed bundle
Load kernel extension           SIP blocks unsigned kexts
Modify kernel at runtime        KIP (hardware-enforced)
Disable SIP                     Requires reboot → kills process → data gone
Read /dev/mem                   Doesn't exist on Apple Silicon
DMA attack                      IOMMU default-deny
Physical memory probing         Soldered LPDDR5x into SoC die (lab-grade only)
```

This is the same threat model as Apple Private Cloud Compute.

### SIP Cannot Be Disabled at Runtime

SIP (System Integrity Protection) is the foundation of the security model. To disable SIP, the provider must:
1. Reboot into Recovery Mode (kills the inference process, wipes all data from memory)
2. Run `csrutil disable`
3. Reboot back to macOS

EigenInference checks SIP:
- At process startup (refuses to serve if disabled)
- Before every inference request (defense-in-depth)
- In every 5-minute challenge-response (coordinator detects if provider rebooted with SIP off)

If SIP is found disabled at any point, the provider is immediately marked untrusted and receives no more jobs.

### Trust Levels

| Level | Name | Meaning | How Achieved |
|-------|------|---------|-------------|
| `none` | Open Mode | No attestation. Consumer warned. | Provider sends no attestation |
| `self_signed` | Self-Attested | SE-signed attestation + periodic challenge-response with SIP check | Provider sends SE-signed attestation |
| `hardware` | Hardware-Attested | MDA certificate chain verified against Apple Enterprise Root CA | MDM enrollment + Managed Device Attestation |

### MDM Integration

EigenInference uses Apple MDM (MicroMDM) to independently verify provider security posture:

- **Enrollment:** Profile-based (`.mobileconfig`), minimal permissions (AccessRights=1041)
- **SecurityInfo query returns:**
  - `SystemIntegrityProtectionEnabled`: SIP status
  - `SecureBoot.SecureBootLevel`: Boot security level (full/reduced/permissive)
  - `AuthenticatedRootVolumeEnabled`: System volume integrity (SSV)
  - `FDE_Enabled`: FileVault disk encryption
  - `IsRecoveryLockEnabled`: Recovery Mode lock status
- **Push notifications:** APNs for on-demand attestation queries
- **Infrastructure:** MicroMDM + SCEP + step-ca co-located in the coordinator container on EigenCloud (prod). Dev runs on Google Cloud with MDM disabled.

### Apple Device Attestation (MDA)

After SecurityInfo verification, the coordinator requests `DevicePropertiesAttestation` via MDM. The device contacts Apple's servers, which return a DER-encoded certificate chain signed by Apple's Enterprise Attestation Root CA. This is the strongest verification — Apple itself vouches for the device.

```
Verification chain:
  Apple Enterprise Attestation Root CA (P-384, embedded in coordinator)
    └─ Apple Enterprise Attestation Sub CA 1
        └─ Leaf cert (device identity)
            ├─ Serial number (OID 1.2.840.113635.100.8.9.1)
            ├─ UDID (OID 1.2.840.113635.100.8.9.2)
            ├─ OS version (OID 1.2.840.113635.100.8.10.1)
            ├─ SepOS version (OID 1.2.840.113635.100.8.10.2)
            ├─ Secure Boot level (OID 1.2.840.113635.100.8.13.2)
            └─ Freshness code (OID 1.2.840.113635.100.8.11.1)
```

The coordinator verifies the cert chain against Apple's root CA, cross-checks the serial number against the provider's self-reported attestation, and stores the cert chain. Users can independently verify via `GET /v1/providers/attestation`, which exposes the base64-encoded DER certificates. Any standard x509 library can verify these against Apple's public Enterprise Attestation Root CA.

### User Attestation Verification

Public API endpoint (no auth required): `GET /v1/providers/attestation`

Returns for each provider:
- Secure Enclave P-256 public key
- Hardware info (chip, model, serial, system volume hash)
- Security state (SIP, SecureBoot, ARV, SE)
- MDM verification status
- **Apple MDA certificate chain** (base64 DER, leaf + intermediate)
- MDA-extracted properties (serial, UDID, OS version, SepOS version)

Users can verify by:
1. Downloading Apple's Enterprise Attestation Root CA from [apple.com/certificateauthority](https://www.apple.com/certificateauthority/)
2. Decoding the `mda_cert_chain_b64` certificates from base64 to DER
3. Verifying the cert chain against Apple's root CA using any x509 library
4. Checking that the serial number in the Apple cert matches the provider's attestation

### Attestation Blob

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
  3. Provider signs (nonce + timestamp + public_key) with their key
  4. Provider includes fresh sip_enabled and secure_boot_enabled status
  5. Sends attestation_response back
  6. Coordinator verifies:
     - Nonce matches
     - Public key matches registration
     - Signature is non-empty
     - sip_enabled == true (IMMEDIATE untrust if false)
     - secure_boot_enabled == true (IMMEDIATE untrust if false)
  7. If 3 consecutive failures → provider marked untrusted
  8. If SIP or SecureBoot disabled → IMMEDIATE untrust (no 3-strike rule)
```

## Privacy Architecture

```
Layer                              Status      What it means
─────────────────────────────────────────────────────────────────
Confidential VM (coordinator)      Working     AMD SEV-SNP, hardware-encrypted memory
TLS transport (consumer)           Working     Encrypted in transit
Hardware-bound identity (SE)       Working     Provider key in Secure Enclave silicon
Signed attestation                 Working     SE signs hardware info + binary hash
Challenge-response + SIP check     Working     Ongoing security posture verification
PT_DENY_ATTACH                     Working     Kernel-level anti-debug
Hardened Runtime                   Working     Blocks external memory inspection
In-process inference               Working     No subprocess/IPC to sniff
Memory wiping                      Working     Volatile-zero after each request
Python path locking                Working     Prevents malicious package injection
Signed app bundle                  Working     Any modification breaks code signature
MDM SecurityInfo                   Working     Hardware-verified SIP/SecureBoot/SSV
SIP/SecureBoot attestation         Working     Self-reported + MDM-verified
Hardware-attested posture (MDA)    Working     Apple Enterprise Attestation Root CA signs device cert chain
User-verifiable attestation API    Working     GET /v1/providers/attestation — exposes Apple cert chain
```

## Inference

EigenInference runs inference **in-process** — no subprocess architecture. The
provider links the MLX inference engine directly via [`mlx-swift-lm`](https://github.com/ml-explore/mlx-swift-lm);
there is no embedded Python interpreter and no local inference server.

| Backend | Mode | Features |
|---------|------|----------|
| **mlx-swift-lm** | In-process (Swift) | MLX-Swift continuous batching with prefix caching |

There is no subprocess fallback. The inference engine is compiled into the
`darkbloom` binary, so there is no IPC or local server surface to observe.

## Payments

- Internal micro-USD ledger (1 USD = 1,000,000 micro-USD)
- Pricing: $0.50 per 1M output tokens, $0.001 minimum per request
- Platform fee: 10%, provider payout: 90%
- Settlement: Stripe (wired, not activated) or Solana USDC (primary)

## Storage

| Backend | Use case | Key feature |
|---------|----------|-------------|
| **MemoryStore** | Development | No external dependencies |
| **PostgresStore** | Production | Atomic balance operations, persistent ledger |

Tables: `api_keys`, `usage`, `payments`, `balances`, `ledger_entries`

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
