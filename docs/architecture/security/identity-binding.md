# Identity binding

This document explains how the coordinator knows which provider it is talking to, and why the provider is the only party that can decrypt inference requests. Four separate primitives play distinct roles; conflating them is the most common source of confusion.

## Roles

| Primitive | Role | Why it matters |
|---|---|---|
| **APNs device token** | Remote code identity | Only the genuine, Apple-provisioned Darkbloom binary can receive a push for `io.darkbloom.provider`. |
| **In-memory X25519 key `K`** | Decryption | Prompts are encrypted to `K`. It lives only in the hardened process's protected memory, so only genuine code can decrypt. |
| **Secure Enclave P-256 key** | Signing / attestation | Signs the registration blob and challenge responses. Bound to the hardware and (for the persistent key) to the team's keychain access group. |
| **Apple MDA certificate** | Hardware trust | Apple-signed proof of genuine hardware + SIP-on + Secure-Boot-Full. |

The provider is the decryption endpoint. The coordinator routes ciphertext to it; no other node can open it.

## Binding diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│ Provider Mac (Apple Silicon, SIP on, Secure Boot Full)              │
│                                                                     │
│  Secure Enclave P-256 key  ───────────┐                             │
│  (persistent, keychain-backed)        │ signs                       │
│                                       ▼                             │
│  Attestation blob {SE pubkey, K, SIP, ...}                         │
│                                       │                             │
│                                       │ binds K to SE identity      │
│                                       ▼                             │
│  In-memory X25519 key K  ◄────────────┘  (decrypts inference)       │
│       ▲                                                             │
│       │ encrypted prompts arrive here                               │
│       │                                                             │
│  APNs device token T  ──► receives E_K(nonce) push                  │
│       ▲                                                             │
│       │ only genuine binary can receive this push                   │
│       │                                                             │
└───────┼─────────────────────────────────────────────────────────────┘
        │
        │ WebSocket (outbound from provider, pinned TLS)
        │
┌───────┼─────────────────────────────────────────────────────────────┐
│       │                                                             │
│  Coordinator CVM                                                    │
│       │                                                             │
│       │ MDA cert from Apple ──► verifies hardware + SIP             │
│       │                                                             │
│       │ matches MDA serial to attestation serial                    │
│       │                                                             │
└───────┼─────────────────────────────────────────────────────────────┘
        │
        │ HTTPS / optional NaCl Box
        ▼
  Consumer
```

## How each binding is established

### 1. SE identity ↔ hardware (MDA)

At registration the provider sends an SE-signed attestation blob containing the SE public key, `K`, serial number, and security state. The coordinator later requests Apple MDA via MicroMDM and supplies a `DeviceAttestationNonce` equal to `SHA256(SE public key)`. Apple embeds that hash in the signed MDA certificate as the `FreshnessCode` OID. The coordinator checks that the returned freshness code matches the hash of the SE public key it already accepted. This cryptographically binds the SE key to genuine Apple hardware.

Code:

- MDA nonce binding: `coordinator/api/provider.go:2350-2361`
- Freshness verification: `coordinator/api/provider.go:2426-2429`

### 2. SE identity ↔ X25519 key `K`

The attestation blob includes `encryptionPublicKey = K`. The coordinator requires the `public_key` field in the `register` message to equal the attestation's `encryptionPublicKey`. A mismatch marks the provider untrusted. This binds the decryption key to the SE identity.

Code:

- Key binding check: `coordinator/api/provider.go:2130-2157`
- Attestation blob field: `provider-swift/Sources/ProviderCore/Security/AttestationBuilder.swift:27-58`

### 3. APNs device token ↔ `K`

The provider's `register` message carries both `public_key` (`K`) and `apns_device_token` (`T`). The coordinator stores them as a 1:1 pair on the `registry.Provider` struct. When it sends the APNs code-identity challenge, it encrypts the nonce to the `K` registered alongside that `T`. The provider proves it holds `K` by decrypting the push and echoing the nonce back over the WebSocket.

Code:

- Registration fields: `coordinator/protocol/messages.go:156-160`
- Challenge dispatch: `coordinator/api/provider.go:554-617`
- Response verification: `coordinator/api/provider.go:596-607`

### 4. Continuous binding per request

Every inference request is encrypted to `K` with a fresh coordinator ephemeral key. Each response chunk is encrypted back to that ephemeral key. Because `K` only exists in the genuine hardened process, every request and response re-proves code identity continuously, not just at registration.

Code:

- Provider decrypt/encrypt: `provider-swift/Sources/ProviderCore/ProviderLoop.swift:959-1178`
- Coordinator encrypt: `coordinator/api/consumer.go:448-510`
- Key implementation: `provider-swift/Sources/ProviderCore/Crypto/NodeKeyPair.swift`

## What APNs does and does not prove

APNs proves that the WebSocket peer is the genuine, team-signed, Apple-provisioned Darkbloom binary, on a SIP-attested device, controlling `K`.

APNs does **not** prove the exact release `cdhash`. It binds App ID / Team ID, not binary version. Version/downgrade control is intended to come from reproducible builds + a public transparency log of blessed cdhashes. Once APNs has established that the binary is genuine, its self-reported `binaryHash` becomes trustworthy enough to match against that log.

## Why ACME SE P-384 is not the signing/decryption endpoint

The enrollment profile includes an ACME `device-attest-01` payload that generates a P-384 key in the Secure Enclave. That key is attested by Apple and bound to the device, but on macOS it lands in the data-protection keychain inside a restricted system access group. Third-party processes—including the Darkbloom provider—cannot use it for application-level signing or decryption. Apple system services (Wi-Fi EAP-TLS, built-in VPN, MDM, Safari mTLS) are the only consumers.

Therefore:

- The provider's operational signing key is a separate **SE P-256** key created by CryptoKit / the Security framework and protected by the team's keychain access group.
- The provider's operational decryption key is the **in-memory X25519 `K`**, not SE-backed.
- The ACME P-384 cert is retained for future transport-layer use but is not the active application-trust anchor today.

See `enrollment.md` for the full ACME limitation discussion.

## Why the provider must remain the decryption endpoint

The coordinator could in principle decrypt every prompt and re-encrypt to a provider-held key, but it already does exactly that: it decrypts the consumer-sealed body in CVM memory, then re-encrypts to `K`. The provider must be the final decryption endpoint because:

- Inference runs on the provider's GPU; the plaintext must exist there to be tokenized and fed into the model.
- No practical cryptographic scheme (MPC, FHE) can hide the prompt from the inference process at interactive latency and cost.
- The security claim is not "the provider is blind"; it is "only the attested, genuine provider binary can read the prompt."

This is why `K` confidentiality rests on SIP + Hardened Runtime + no `get-task-allow`: together they make the process memory unreadable even by root. The MDA check is load-bearing because it is the only non-circular proof that SIP is on.

## Failure modes

| Failure | Effect |
|---|---|
| Provider has no APNs device token | Cannot become `CodeAttested`; fail-closed once enforcement begins. |
| APNs push dropped or delayed | Provider stays un-attested until a later reconnect or retry; no private traffic routed. |
| SIP disabled (requires reboot) | Reboot drops the WebSocket; re-registration re-runs MDA + APNs and fails. |
| `K` mismatch with attestation | Registration rejected or provider marked untrusted. |
| MDA serial mismatch | Provider marked untrusted (impersonation attempt). |
| SE signature invalid | Challenge/registration rejected; provider untrusted. |

## Canonical code paths

| Concern | Path |
|---|---|
| SE attestation blob | `provider-swift/Sources/ProviderCore/Security/AttestationBuilder.swift` |
| Persistent SE P-256 key | `provider-swift/Sources/ProviderCore/Security/PersistentEnclaveKey.swift` |
| In-memory X25519 `K` | `provider-swift/Sources/ProviderCore/Crypto/NodeKeyPair.swift` |
| APNs challenge sender | `coordinator/apns/attestor.go` |
| APNs challenge dispatch | `coordinator/api/provider.go:487-617` |
| MDA verification | `coordinator/attestation/mda.go` |
| Routing gate | `coordinator/registry/registry.go:305-342` |
| Protocol fields | `coordinator/protocol/messages.go` |
