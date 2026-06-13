# Provider Attestation

Darkbloom verifies every provider before routing private inference traffic to
it. This page describes the trust levels, the attestation chain, and what you
need to do to reach the highest trust level.

## Trust levels

The coordinator stores a `TrustLevel` for each provider
(`coordinator/registry/registry.go:51-58`):

| Level | Name | Meaning |
|-------|------|---------|
| `none` | No attestation | Provider registered without an attestation. Not routed for private text. |
| `self_signed` | Self-attested | A valid Secure-Enclave-signed attestation was verified. |
| `hardware` | Hardware-attested | Self-signed attestation plus MDM/ACME/MDA cross-check against Apple. |

The default minimum trust level for public routing is `hardware`
(`coordinator/registry/registry.go:773`). Self-route relaxes the trust floor for
the owner's own machine only, but it does **not** bypass the code-identity gate
once that gate is enforced.

## What the coordinator verifies before routing

Private-text routing has a single chokepoint:
`providerSupportsPrivateTextLocked` in `coordinator/registry/registry.go:305-342`.
A provider must satisfy all of the following:

1. Has a non-empty X25519 public key bound at registration.
2. Uses the Swift backend (`mlx-swift`).
3. Advertises encrypted response chunks.
4. Passed runtime manifest checking.
5. Has coordinator-verified SIP from a recent challenge (`ChallengeVerifiedSIP`).
6. Passed APNs code-identity attestation when enforcement is active (`CodeAttested`).
7. Reports the required privacy capabilities:
   - `text_backend_inprocess = true`
   - `text_proxy_disabled = true`
   - `anti_debug_enabled = true`
   - `core_dumps_disabled = true`
   - `env_scrubbed = true`

The privacy capability values are reported in the `register` message and are
defined in `coordinator/protocol/messages.go:169-180`.

## Registration attestation

When a provider connects, it sends a `register` WebSocket message containing a
signed attestation blob. The blob is built in
`provider-swift/Sources/ProviderCore/Security/AttestationBuilder.swift` and
signed by a per-launch P-256 key held in the Apple Secure Enclave
(`provider-swift/Sources/ProviderCore/Security/SecureEnclaveIdentity.swift`).

The blob contains:

| Field | Purpose |
|-------|---------|
| `chipName` | e.g. "Apple M4 Max" |
| `hardwareModel` | Machine model identifier, e.g. "Mac16,1" |
| `serialNumber` | Used for MDM/MDA cross-reference |
| `osVersion` | macOS version string |
| `sipEnabled` | System Integrity Protection state |
| `secureBootEnabled` | Secure Boot state |
| `authenticatedRootEnabled` | Authenticated root volume state |
| `rdmaDisabled` | RDMA safety signal |
| `hypervisorActive` | Hypervisor state (reported only) |
| `secureEnclaveAvailable` | Confirms SE presence |
| `binaryHash` | SHA-256 of the provider binary |
| `systemVolumeHash` | Signed system-volume snapshot hash |
| `publicKey` | SE P-256 public key |
| `encryptionPublicKey` | X25519 public key used for per-request NaCl Box |

The coordinator verifies the ECDSA signature over the exact attestation JSON
bytes in `coordinator/attestation/attestation.go:128` and checks that the
encryption public key in the blob matches the key supplied in the `register`
message (`coordinator/api/provider.go:2130-2156`).

## Periodic challenge-response

After registration, the coordinator sends an `attestation_challenge` message
every `DefaultChallengeInterval` (5 minutes,
`coordinator/api/provider.go:50-51`). The provider signs `nonce + timestamp`
with its SE key and returns the signature plus a fresh status signature
(`provider-swift/Sources/ProviderCore/Security/AttestationBuilder.swift:264-327`).

The coordinator verifies:

- Signature against the SE public key bound at registration.
- That SIP is still enabled (sets `ChallengeVerifiedSIP`).
- Runtime hash / template hash matches if a runtime manifest is configured.
- Provider version is still above the minimum.

A provider is only routable while its last successful challenge is within
`challengeFreshnessMaxAge` (6 minutes,
`coordinator/registry/scheduler.go:37`). Three consecutive failures mark the
provider `untrusted` (`coordinator/registry/registry.go:62-64`), and six
consecutive timeouts force a WebSocket reconnect
(`coordinator/api/provider.go:69`).

## Upgrading from `self_signed` to `hardware`

A provider starts at `self_signed` after SE attestation verifies. It can be
promoted to `hardware` through one of these independent paths:

1. **MDM verification** — `verifyProviderViaMDM`
   (`coordinator/api/provider.go:2268-2340`). The coordinator queries its
   MicroMDM server for the device's serial number and checks that MDM-reported
   SIP/Secure Boot match the provider's self-report. If they match, trust is
   upgraded to `hardware` and Apple Device Attestation (MDA) is requested.

2. **ACME device-attest-01** — `applyACMETrust`
   (`coordinator/api/provider.go:693-737`). A provider that presents an Apple
   device-attest-01 client certificate proves possession of the same SE key the
   attestation claims. The coordinator verifies the cert chain and upgrades to
   `hardware`.

3. **Apple MDA** — `verifyAppleDeviceAttestation`
   (`coordinator/api/provider.go:2342-2466`). After MDM succeeds, the
   coordinator asks Apple to sign a device attestation certificate. The
   coordinator verifies the chain to the Apple Enterprise Attestation Root CA
   and checks that the MDA serial matches the provider's serial. The MDA cert
   may also bind the SE public key via the `FreshnessCode` OID.

The `hardware` verdict means the coordinator has an independent, Apple-signed
proof that the provider is running on genuine Apple hardware with the claimed
security posture.

## APNs code-identity attestation (v0.6.0+)

The strongest production gate is APNs code-identity attestation. It proves that
the running binary is the genuine, Apple-team-provisioned Darkbloom provider.

### How it works

1. The provider registers with an APNs device token obtained by
   `registerForRemoteNotifications()` in a logged-in macOS GUI session
   (`provider-swift/Sources/darkbloom/ProviderAppKitHost.swift:61`).
2. The coordinator generates a random nonce, encrypts it to the provider's
   X25519 public key using the same NaCl Box path used for inference bodies,
   and pushes it to the provider via APNs
   (`coordinator/apns/attestor.go:172-227`).
3. The provider receives the push, decrypts the nonce with its X25519 key, and
   signs the nonce with its SE P-256 key
   (`provider-swift/Sources/ProviderCore/ProviderLoop.swift:3116-3156`).
4. The provider returns the decrypted nonce and signature in a
   `code_attestation_response` WebSocket message
   (`coordinator/protocol/messages.go:39-42`).
5. The coordinator verifies nonce equality and the SE signature against the key
   bound at registration (`coordinator/api/provider.go:596-604`).
6. On success the connection is marked `CodeAttested`
   (`coordinator/registry/registry.go:299`).

Only the genuine hardened process can both receive the APNs push (Apple's
enforcement) and decrypt the nonce (only the process holds the X25519 private
key `K`). The SE signature binds that proof to the registration identity.

### Requirements for code-identity attestation

APNs registration only works when the provider process runs in a real macOS
Aqua (GUI) session. Headless or login-window boxes cannot obtain a device token
and therefore cannot attest. `AttestationReadiness`
(`provider-swift/Sources/ProviderCore/Diagnostics/AttestationReadiness.swift`)
evaluates the local state and reports:

| Check | Why it matters |
|-------|----------------|
| Real console user logged in | `registerForRemoteNotifications()` requires an Aqua session. |
| Automatic login enabled | The session self-recovers after reboot. |
| Auto-logout-after-idle disabled | Logging out kills the GUI launchd agent and APNs registration. |
| Sleep prevention | Deep idle sleep delays reconnect/attestation. |

You can inspect the readiness verdict with `darkbloom doctor`.

### Enforcement

Code-identity attestation is rolled out with a grace deadline:

- `codeAttestationConfigured` — true once the coordinator has APNs credentials.
- `codeAttestationDeadline` — the instant after which un-attested providers are
  fail-closed and removed from private-text routing
  (`coordinator/registry/registry.go:666-684`).

Before the deadline, the coordinator challenges providers and measures coverage
but still routes un-attested ones. After the deadline, un-attested providers
(including headless or pre-0.6.0 nodes) are derouted. Operators monitor coverage
via `/v1/stats` (`coordinator/registry/registry.go:3585-3600`).

The throttle (`coordinator/api/code_attest_throttle.go`) keeps APNs pushes
within Apple's background budget: one challenge per connection, bounded retries,
a 20-minute per-device push cooldown, and a 30-minute reuse window for the same
SE key + version.

## Public attestation endpoint

Anyone can inspect provider attestations:

```bash
# All providers
curl https://api.darkbloom.dev/v1/providers/attestation

# Specific provider
curl https://api.darkbloom.dev/v1/providers/<provider_id>/attestation
```

The response is built by `handleProviderAttestation`
(`coordinator/api/provider.go:2471-2580`) and includes:

| Field | Meaning |
|-------|---------|
| `trust_level` | `none`, `self_signed`, or `hardware` |
| `status` | `online`, `offline`, `untrusted`, etc. |
| `mdm_verified` | `true` for `hardware` trust via MDM |
| `acme_verified` | `true` if ACME device-attest-01 verified |
| `mda_verified` | `true` if Apple MDA chain verified |
| `mda_cert_chain_b64` | Base64 DER certificates for independent verification |
| `sip_enabled`, `secure_boot_enabled`, `authenticated_root_enabled` | Latest verified posture |
| `se_public_key` | SE P-256 public key |

The response also includes Apple root CA URLs and instructions for verifying the
MDA chain independently.

## Troubleshooting attestation

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `trust_level: self_signed` | MDM/ACME not completed | Run `darkbloom enroll` and install the profile; or check ACME cert provisioning |
| `mdm_verified: false` | Device not enrolled or MDM check timed out | Confirm enrollment in System Settings → Device Management |
| `mda_verified: false` | MDA command failed or freshness expired | Wait for next MDM/MDA retry; re-enroll if persistent |
| Code-attest never passes | No Aqua session / no APNs token | Log in at the console, enable automatic login, disable auto-logout |
| `ChallengeVerifiedSIP: false` | SIP disabled or challenge failing | Re-enable SIP in Recovery; check `darkbloom doctor` |
| Binary hash drift warning | Running a build not in the coordinator's release record | Run `darkbloom update` |

For detailed failure logs, run `darkbloom report` or inspect unified logs with
`darkbloom logs --last 1h`.
