# Provider attestation

Attestation binds a provider machine to an Apple Secure Enclave identity, checks its security posture, and—since v0.6.0—proves that the running binary is the genuine, Apple-provisioned Darkbloom build. The coordinator uses attestation state to decide whether a provider may receive private inference traffic.

## Trust levels

| Level | Name | Meaning | Canonical code |
|---|---|---|---|
| `none` | Open Mode | No attestation provided; consumer is warned. | `coordinator/registry/registry.go:305-342` |
| `self_signed` | Self-attested | SE-signed blob + periodic WebSocket challenge-response with fresh SIP check. | `coordinator/attestation/attestation.go:119-231` |
| `hardware` | Hardware-attested | MDM-enrolled + Apple Device Attestation (MDA) certificate chain verified against Apple's Enterprise Root CA. | `coordinator/attestation/mda.go:98-186`, `coordinator/api/provider.go:2268-2339` |

The single routing chokepoint is `providerSupportsPrivateTextLocked` in `coordinator/registry/registry.go:305-342`.

## Secure Enclave attestation blob

At registration the provider sends a JSON blob signed by a P-256 key held in the Apple Secure Enclave. The private key never leaves the silicon.

| Field | Description |
|---|---|
| `publicKey` | P-256 public key (raw `X\|\|Y`, 64 bytes) |
| `chipName` | e.g. `Apple M3 Max` |
| `hardwareModel` | e.g. `Mac15,8` |
| `osVersion` | macOS version |
| `secureEnclaveAvailable` | Always true on Apple Silicon |
| `sipEnabled` | System Integrity Protection status (self-reported at registration) |
| `secureBootEnabled` | Secure Boot status |
| `encryptionPublicKey` | X25519 key `K` bound to this identity for inference encryption |
| `authenticatedRootEnabled` | Authenticated Root Volume (SSV) |
| `systemVolumeHash` | APFS snapshot hash |
| `serialNumber` | Hardware serial number |
| `binaryHash` | SHA-256 of the provider binary |
| `rdmaDisabled` | Whether RDMA is disabled |
| `timestamp` | ISO 8601 |

The coordinator verifies the ECDSA signature against the embedded public key and enforces minimum security requirements: Secure Enclave available, SIP enabled, Secure Boot enabled. Code:

- Provider builder: `provider-swift/Sources/ProviderCore/Security/AttestationBuilder.swift:27-211`
- Coordinator verification: `coordinator/attestation/attestation.go:119-231`
- Registration handler: `coordinator/api/provider.go:2074-2218`

### X25519 key binding

The coordinator binds the WebSocket X25519 key `K` to the SE identity by requiring the attestation's `encryptionPublicKey` to match the `public_key` in the `register` message. A mismatch marks the provider untrusted. See `coordinator/api/provider.go:2130-2157`.

### `binaryHash` is no longer a standalone trust signal

`binaryHash` is self-reported by the running binary. Against a malicious provider it proves nothing, because the measurer is the adversary. Starting in v0.6.0 it is demoted to drift telemetry and transparency-log matching; the active code-identity proof is APNs-based attestation. The hash is still included in the SE-signed status canonical so that a blessed-build policy can be re-enabled as a rollback/emergency gate. Code:

- Demotion logic: `coordinator/api/provider.go:2159-2193`
- Design rationale: [`architecture/decisions/apns-code-attestation.md`](../decisions/apns-code-attestation.md) §Context, §Decision.

## Periodic challenge-response (liveness / posture)

Every ~5 minutes the coordinator sends an `attestation_challenge` over the WebSocket. The provider signs a canonical status payload and returns fresh runtime security state:

```
canonical = {
  nonce,
  timestamp,
  sip_enabled,
  secure_boot_enabled,
  rdma_disabled,
  hypervisor_active,
  binary_hash,
  active_model_hash,
  python_hash,
  runtime_hash,
  template_hashes,
  model_hashes
}
```

The coordinator verifies:

- Nonce matches.
- Signature is valid against the registered SE public key.
- `sip_enabled == true` (immediate untrust if false).
- `secure_boot_enabled == true` (immediate untrust if false).

Three consecutive failures also mark the provider untrusted; SIP/SecureBoot failure is immediate. Code:

- Challenge sender: `coordinator/api/provider.go:830-899`
- Response verification: `coordinator/api/provider.go:1300-1436`
- Status canonical builder: `coordinator/attestation/attestation.go:330-430`

## APNs code-identity attestation (v0.6.0)

Device attestation proves genuine Apple hardware and SIP-on posture, but it does **not** prove which binary is running. APNs code-identity attestation closes that gap.

Only a genuine, Apple-signed, team-provisioned Darkbloom binary can receive a push for the App ID topic `io.darkbloom.provider`. The coordinator pushes an encrypted challenge `E_K(nonce)` to the provider's APNs device token. The provider decrypts it with its in-memory X25519 key `K` and returns the decrypted nonce plus a Secure Enclave signature over the same WebSocket. This binds the anonymous WebSocket session to genuine code holding `K`.

The three orthogonal pillars:

1. **Code identity ← APNs.** Only our App-ID-provisioned binary can receive the push. Apple's `aps-environment` entitlement is authorized by an Apple-signed provisioning profile bound to our Team ID + App ID.
2. **Locked environment ← MDA/MDM.** Apple-signed proof of genuine hardware + SIP-on + Secure-Boot-Full; this makes pillar 1 and the SE access-group trustworthy.
3. **Continuous binding ← in-memory X25519 key `K`.** Each request is encrypted to `K`, so only genuine code can decrypt every prompt. `K` lives only in the hardened process's protected memory, not in the keychain.

### Per-connection flow

1. Provider launches, creates/loads SE key + X25519 `K`, calls `registerForRemoteNotifications()` to obtain device token `T`, opens a pinned-TLS WebSocket, and sends `{X25519 pubkey K, device token T}` signed by the SE key.
2. Coordinator binds `T ↔ K`, verifies MDA/ACME/SIP, and sends an APNs background push to `T` carrying `E_K(nonce)`. The nonce is single-use, short-TTL, and must be answered on the same WebSocket that registered `K`+`T`.
3. Provider receives the push (only genuine code can), decrypts `nonce` with `K`, and returns `nonce` + `Sign_SE(nonce)` over the WebSocket.
4. Coordinator verifies and marks the connection `CodeAttested`; private inference traffic may now route to it.

Re-attestation happens on reconnect, not by polling, because SIP cannot be disabled without a reboot which drops the connection.

Code:

- APNs sender / JWT / HTTP2: `coordinator/apns/attestor.go`
- Push challenge dispatch and verification: `coordinator/api/provider.go:487-617`
- Routing gate: `coordinator/registry/registry.go:305-342`
- Provider APNs delegate + decrypt: `provider-swift/Sources/ProviderCore/ProviderLoop.swift`
- AppKit rehost for `.accessory` run loop: `provider-swift/Sources/darkbloom/main.swift` and `ProviderAppKitHost.swift`
- Protocol fields: `coordinator/protocol/messages.go:39-42`, `156-160`, `462-480`

### Rollout and fail-closed behavior

Code attestation is configured and enforced separately:

- `SetCodeAttestationConfigured` wires the APNs attestor and starts issuing challenges.
- `SetCodeAttestationDeadline` is the instant the gate becomes mandatory.
- Until the deadline, un-attested providers keep routing (grace/observe mode).
- After the deadline, `providerSupportsPrivateTextLocked` returns false for any provider whose `CodeAttested` flag is false.

`CodeAttested` is in-memory and per-connection; a reconnect forces re-attestation. Code:

- Policy knobs: `coordinator/registry/registry.go:437-490`
- Gate implementation: `coordinator/registry/registry.go:311-328`

### Limits and honest residuals

- Background push delivery is best-effort and device-budget-throttled. The coordinator is built dual-mode (`background` vs `alert`) so the choice is a config flag, not a rearchitecture.
- APNs requires a logged-in GUI Aqua session. Headless/login-screen Macs fail closed.
- APNs binds App ID / Team ID, not exact `cdhash`. Exact version pinning is intended to be layered via reproducible builds + a public transparency log of blessed cdhashes.
- Root of trust = Apple's silicon/attestation + our control of our Apple signing identity.
- A determined attacker on their own hardware could manually enable private-data logging, harvest a genuine device token, and race the `T ↔ K` registration. This is the same "patient insider on own hardware" residual that exists for any local-attestation scheme.
- A dropped push is an availability event, not a confidentiality breach.

## MDM / MDA hardware trust

The coordinator uses MicroMDM to push a `.mobileconfig` enrollment profile and to query `SecurityInfo`. It then requests `DevicePropertiesAttestation` from Apple, receiving a DER certificate chain signed by Apple's Enterprise Attestation Root CA. The chain carries:

- Serial number (`1.2.840.113635.100.8.9.1`)
- UDID (`...9.2`)
- OS version (`...10.1`)
- SepOS version (`...10.2`)
- Secure Boot level (`...13.2`)
- Freshness code (`...11.1`)

The coordinator verifies the chain against the embedded Apple root CA, cross-checks the serial number against the provider's self-reported attestation, and stores the chain. A serial mismatch marks the provider untrusted. Code:

- MDM client / webhook: `coordinator/mdm/mdm.go`
- MDA verification: `coordinator/attestation/mda.go`
- Provider registration flow: `coordinator/api/provider.go:2254-2429`

See `enrollment.md` for the enrollment profile design and the current limitations of the ACME path.

## Public verification API

`GET /v1/providers/attestation` (no auth required) returns, per provider:

- Secure Enclave P-256 public key,
- hardware info (chip, model, serial, system volume hash),
- security state (SIP, SecureBoot, ARV, SE),
- MDM verification status,
- Apple MDA certificate chain (base64 DER, leaf + intermediate),
- MDA-extracted properties (serial, UDID, OS version, SepOS version).

Users can independently verify the MDA chain against Apple's public Enterprise Attestation Root CA.
