# Provider attestation and security model

> Last updated: 2026-09-03 · commit `5d400cf75`

What the coordinator verifies about your Mac and your provider process before it
routes private inference to you, what each verdict means, how to reach the
`hardware` level, and what the process itself defends against. This page is
written for operators; the architecture pages it links to hold the full
mechanics and code map.

## Trust levels

The coordinator keeps a `TrustLevel` per provider connection
(`coordinator/registry/registry.go`, `TrustLevel`):

| Level | Meaning | How you get there |
|---|---|---|
| `none` | No verified attestation. Connected, but never routed public traffic. | Default for a new connection, or a registration without an attestation blob. |
| `self_signed` | Your Secure Enclave signed a valid attestation blob and you are passing the periodic challenge. | Automatic on a healthy `darkbloom start`. |
| `hardware` | Apple's MDM subsystem on your Mac independently confirmed SIP and full Secure Boot, agreeing with your blob. | Enrol with `darkbloom enroll`; the coordinator does the rest. |

Two flags travel with the level and never change it:

| Flag | Meaning |
|---|---|
| `mda_verified` | Apple Managed Device Attestation proved which Apple device holds your SE key. Informational; requires `hardware` first. |
| `code_attested` | The running process proved it is the genuine Darkbloom binary via an APNs code-identity challenge. Required for private-text routing once enforcement is switched on. |

Public traffic only reaches machines at or above the coordinator's trust floor,
which is `hardware` unless the operator lowers it (`EIGENINFERENCE_MIN_TRUST`;
the gate-by-gate rule is in
[Routing gate](../architecture/security/attestation.md#routing-gate)). Routing
your own requests to your own machine (self-route) relaxes only the trust floor
and the private-only rule; every privacy gate below still applies, including
code identity once it is enforced.

`darkbloom status` prints the last `trust_status` message the coordinator sent
(`Trust: <level> / <status>`); the reasons are `"SE attestation verified,
awaiting MDM verification"`, `"MDM verification passed"`, `"MDM verification
passed (late SecurityInfo)"`, a trust-reuse decision such as `same_binary` or
`continuity`, or the failure reason with status `untrusted`.

## What the coordinator checks before routing to you

Private-text routing has one chokepoint, `providerSupportsPrivateTextLocked`
(`coordinator/registry/registry.go`), evaluated inside
`providerLivenessGateReasonLocked`
(`coordinator/registry/routing_eligibility.go`). You must satisfy all of:

1. A non-empty X25519 public key bound at registration (`register.public_key`,
   equal to the SE-signed blob's `encryptionPublicKey`).
2. Backend `mlx-swift`.
3. `encrypted_response_chunks: true` in the `register` message.
4. Runtime manifest checked (`RuntimeManifestChecked`).
5. Coordinator-verified SIP from a recent signed challenge
   (`ChallengeVerifiedSIP`), not your self-report.
6. Current application evidence when a release policy is enforced.
7. `code_attested` once code-identity enforcement is active (below).
8. `PrivacyCapabilities` all true: `text_backend_inprocess`,
   `text_proxy_disabled`, `anti_debug_enabled`, `core_dumps_disabled`,
   `env_scrubbed`. (`python_runtime_locked` and `dangerous_modules_blocked`
   are wire-compatibility fields and are not consulted.)

On top of that, the liveness gate requires status not `offline` / `untrusted`,
`RuntimeVerified`, the trust floor, and a challenge verified within the last
16 minutes (`challengeFreshnessMaxAge`, `coordinator/registry/scheduler.go`).
The ordered gate table is in
[`../architecture/security/attestation.md`](../architecture/security/attestation.md#routing-gate).

## Registration attestation

On connect the provider sends a `register` message carrying an attestation blob
built by `provider-swift/Sources/ProviderCore/Security/AttestationBuilder.swift`
and signed by a P-256 key in the Secure Enclave.

The key is **persistent**: `PersistentEnclaveKey.loadOrCreateVerified`
(`provider-swift/Sources/ProviderCore/Security/PersistentEnclaveKey.swift`)
keeps it in the keychain under access group `SLDQ2GJ6TL.io.darkbloom.provider`
with label `io.darkbloom.provider.attestation-signing.v2`, so your SE public key
is the same across restarts and is the identity the coordinator's trust-reuse
and code-identity caches are keyed on. Only if the keychain path fails (for
example a binary without the `keychain-access-groups` entitlement) does
`ProviderLoop.swift` fall back to an ephemeral key with a warning — you then
appear as a brand-new identity and re-earn every flag from scratch.

Signed fields (`coordinator/attestation/attestation.go`, `AttestationBlob`):

| Field | Purpose |
|---|---|
| `chipName`, `hardwareModel`, `osVersion`, `chipFamily`? | Hardware class shown on the public endpoint |
| `serialNumber` | MDM lookup and MDA cross-reference; never published |
| `sipEnabled`, `secureBootEnabled`, `authenticatedRootEnabled`, `rdmaDisabled` | Self-reported posture. `secureBootEnabled` is a historical proxy: `checkSecureBootEnabled` delegates to `checkAuthenticatedRootEnabled` (`provider-swift/Sources/ProviderCore/Security/SecurityHardening.swift`); the coordinator's real Secure Boot signal is MDM `SecurityInfo.SecureBootLevel` |
| `secureEnclaveAvailable` | Must be true |
| `binaryHash`, `metallibHash`?, `systemVolumeHash`?, `runtimeCapabilities`? | Drift telemetry and runtime claims; `binaryHash` derouts only under an explicit binary-hash policy |
| `publicKey` | SE P-256 public key (base64) |
| `encryptionPublicKey` | Your X25519 key `K`; must equal `register.public_key` |
| `timestamp` | RFC 3339; must be within ±2 minutes of coordinator time (`RegistrationAttestationMaxAge`) for providers ≥ 0.8.15 |

The coordinator (`verifyProviderAttestation`, `coordinator/api/provider.go`)
verifies the ECDSA signature over the exact blob bytes, requires
`secureEnclaveAvailable`, `sipEnabled`, and `secureBootEnabled` to be true,
checks the timestamp, and checks the key binding. Success grants `self_signed`
immediately.

> **Legacy field:** older builds also signed a `hypervisorActive` /
> `hypervisor_active` field. Hypervisor isolation was never implemented and the
> field is retired from every trust decision, but the coordinator still decodes
> it when a provider sends it so those older signed payloads keep verifying.

## Periodic challenge-response

After registration the coordinator sends `attestation_challenge` every
`DefaultChallengeInterval` = 5 minutes and expects a reply within
`ChallengeResponseTimeout` = 30 seconds (`coordinator/api/provider.go`). The
provider signs `nonce + timestamp` with the SE key and adds a `status_signature`
over the canonical status JSON (`AttestationBuilder.swift`).

The coordinator (`verifyChallengeResponse`) checks both signatures against the
SE key from registration, requires `sip_enabled` to be present and true (sets
`ChallengeVerifiedSIP`), untrusts on `secure_boot_enabled == false`, compares
binary / metallib / model hashes with registration, and enforces the minimum
provider version.

| Outcome | Effect |
|---|---|
| Pass | `LastChallengeVerified = now`; you stay routable for up to 16 minutes |
| No reply in 30 s | Transient failure; 3 in a row → derouted (`MarkUntrustedTransient`), recovered by the next passing challenge; 6 consecutive timeouts → the coordinator closes the WebSocket so you re-register cleanly |
| Bad nonce / signature, SIP or Secure Boot off, hash drift | Hard failure; SIP/Secure Boot off and drift untrust immediately, otherwise 3 in a row → `untrusted` (`MaxFailedChallenges`, `coordinator/registry/registry.go`) |

## Reaching `hardware`

`hardware` is granted **only** by an MDM `SecurityInfo` cross-check
(`verifyProviderViaMDM`, `coordinator/api/provider.go`): the coordinator looks
up your Mac by serial in MicroMDM, sends a `SecurityInfo` command, waits up to
90 seconds for the webhook, and grants when `SystemIntegrityProtectionEnabled`
is true, `SecureBootLevel` is `full`, and both agree with your blob.
Authenticated Root Volume is recorded but not compared.

- Enrol with `darkbloom enroll` (profile from `POST /v1/enroll`; SCEP + MDM,
  read-only `AccessRights`; see
  [`../architecture/security/enrollment.md`](../architecture/security/enrollment.md)).
- Attempts are owned by a store-backed scheduler; transient outcomes
  (`device-not-found`, `found-not-enrolled`, `securityinfo-timeout`, `error`)
  leave your level unchanged and retry after 2–4 min, then 6–12 min, then every
  15–30 min. A late `SecurityInfo` for the same command still grants.
- Only a received `SecurityInfo` that **contradicts** your blob
  (`posture-mismatch`) demotes you, and that untrust is terminal for the
  connection.
- On reconnect a stored `hardware` level is capped to `self_signed`
  (`RestoreProviderState`, `coordinator/registry/persistence.go`). Trust reuse
  (`coordinator/api/trust_reuse.go`) re-grants it after your first passing
  challenge if the last live MDM proof is under 5 minutes old
  (`EIGENINFERENCE_TRUST_REUSE_WINDOW`) or the coordinator measured your
  offline gap at ≤ 90 seconds (`EIGENINFERENCE_TRUST_REUSE_RECONNECT_GAP`,
  clamped to at most 120 s). Otherwise a fresh `SecurityInfo` round-trip runs.

**Apple Managed Device Attestation** runs after the grant
(`verifyAppleDeviceAttestation`): the coordinator requests a
`DeviceInformation` / `DeviceAttestation` with nonce `SHA-256(SE public key)`,
verifies the chain to the Apple Enterprise Attestation Root CA, and attaches
`mda_verified` only while you hold `hardware` and the leaf binds your SE key
(`FreshnessCode`) or your serial. Apple issues a fresh attestation roughly once
per device per 7 days, so a cached chain is re-verified and re-bound on
reconnect. MDA never grants or blocks routing.

(An ACME `device-attest-01` leg once existed as a second path; it was never
wired end-to-end and was removed on 2026-07-03.)

## APNs code-identity attestation

Only a process signed by the Darkbloom team, carrying App ID
`io.darkbloom.provider` and the `aps-environment` entitlement
(`provider-swift/entitlements.plist`), can receive a push for the coordinator's
topic. The coordinator uses that to prove which binary holds your key `K`.
Design record: [`../design/apns-code-attestation.md`](../design/apns-code-attestation.md).

### How it works

1. The provider registers with the APNs device token obtained by
   `registerForRemoteNotifications()` in a logged-in macOS GUI session
   (`provider-swift/Sources/darkbloom/ProviderAppKitHost.swift`,
   `provider-swift/Sources/ProviderCore/Apns/APNsBridge.swift`).
2. After your first signed challenge, `codeAttestLoop`
   (`coordinator/api/provider_codeattest.go`) picks a path:
   - **Resume**: a durable proof for the same SE key, version, APNs token, and
     `K` younger than `reuseWindow` = 30 minutes authorises a
     `code_attestation_resume_challenge` over the WebSocket — no push; reply
     within `resumeTimeout` = 30 s.
   - **Push**: otherwise the coordinator seals a 32-byte nonce to `K` with the
     same NaCl Box used for inference bodies and sends it via APNs
     (`coordinator/apns/attestor.go`); the nonce is accepted for
     `challengeValidity` = 300 s.
3. The provider decrypts the nonce with `K`, signs it with the SE key, and
   replies `code_attestation_response{nonce, signature}`
   (`provider-swift/Sources/ProviderCore/ProviderLoop.swift`).
4. `handleCodeAttestationResponse` requires the nonce recorded for **this** SE
   key + APNs token + `K` and verifies the signature against the registration
   SE key; `GrantProcessCodeAttested` sets `code_attested` and the proof is
   persisted for later resumes.

Throttle (`coordinator/api/code_attest_throttle.go`): at most one push per
device per `backgroundPushCooldown` = 20 minutes (background mode) or
`alertPushCooldown` = 75 seconds (alert mode); `maxAttempts` = 3 per loop with
a 15–30 s retry delay; the per-device push budget can be reset by a token
rotation at most once per `budgetClearCooldown` = 20 minutes. After three
unanswered pushes the loop stops until you reconnect; `code_attested` stays
false and nothing else changes.

### Requirements

APNs registration works only in a real Aqua (GUI) session; headless or
login-window Macs cannot obtain a token. `AttestationReadiness`
(`provider-swift/Sources/ProviderCore/Diagnostics/AttestationReadiness.swift`)
reports through `darkbloom doctor`:

| Check | Why it matters |
|---|---|
| Real console user logged in | `registerForRemoteNotifications()` requires an Aqua session |
| Automatic login enabled | The session self-recovers after reboot |
| Auto-logout-after-idle disabled | Logging out kills the GUI launchd agent and the APNs registration |
| Sleep prevention | Deep idle sleep delays reconnect and attestation |

### Enforcement

Code identity is mandatory only when the coordinator has APNs credentials
**and** `APNS_ENFORCE_AFTER` (RFC 3339) has passed
(`codeAttestationEnforcedLocked`, `coordinator/registry/registry.go`). Before
that the coordinator challenges and measures coverage but still routes
un-attested providers. After it, providers without `code_attested` — headless
or pre-0.6.0 nodes included — fail gate 7 above and receive no private text.
This is not a trust-level change and not an `untrusted` status.

## Security model of the provider process

The provider is a hardened macOS process. Its guarantees come from Apple
platform features plus Darkbloom runtime checks
(`provider-swift/Sources/ProviderCore/Security/`):

| Attack | Blocked by |
|---|---|
| Attach a debugger | `ptrace(PT_DENY_ATTACH)` at startup — failure is fatal, no override (`AntiDebug.swift`, `denyDebuggerAttachment`) — plus Hardened Runtime; `checkDebuggerAttached` re-checks `P_TRACED` |
| Read process memory | Hardened Runtime (kernel denies `task_for_pid`) |
| Recover secrets from a crash | Core dumps disabled with `setrlimit(RLIMIT_CORE, 0)` (`disableCoreDumps`) |
| Inject code via the loader or malloc debugging | 13 environment variables scrubbed at startup (`DYLD_INSERT_LIBRARIES`, `DYLD_LIBRARY_PATH`, `DYLD_FRAMEWORK_PATH`, `LD_PRELOAD`, `MallocStackLogging*`, `MallocScribble`, `MallocGuardEdges`, `MallocLogFile`, `MallocErrorAbort`, `NSZombieEnabled`, `OBJC_DEBUG_POOL_ALLOCATION`, `CFNETWORK_DIAGNOSTICS`) (`EnvironmentScrubber.swift`) |
| Sniff IPC or a local network hop | None exists — inference runs in-process (`text_backend_inprocess`, `text_proxy_disabled`) |
| Modify the binary | Code signing + SIP; `checkHardenedRuntimeEnabled` / `verifyBundleSignature` run `codesign` on the executable and bundle |
| Replace it with a fake binary | APNs code-identity attestation (above) |
| Inject a malicious Python package | No embedded Python interpreter |
| Load an unsigned kernel extension, patch the kernel | SIP; KIP (hardware-enforced) |
| Disable SIP at runtime | Requires a reboot into Recovery, which kills the process and wipes memory |
| DMA attack | IOMMU default-deny |

### What the provider can see

The provider is the decryption endpoint: the prompt and the completion are
plaintext inside the provider process, because in-process inference at native
speed requires it. The coordinator handles plaintext only in memory for the life
of one request (parsed for routing, cache affinity, and billing) and never logs
or stores it; the consumer → coordinator hop is TLS plus optional NaCl Box
sealing, and the coordinator → provider and provider → coordinator hops are
mandatory NaCl Box. The full per-party table is in
[`../architecture/security/encryption.md`](../architecture/security/encryption.md#what-each-party-can-observe);
code identity bounds *which* binary may act as the decryption endpoint.

### SIP and Secure Boot

SIP cannot be disabled without rebooting into Recovery, which kills the
inference process and wipes memory. The provider self-checks SIP at startup
(`csrutil status`) and reports it in every signed challenge; the coordinator
trusts only its own verification of that signed status (`ChallengeVerifiedSIP`)
and gets Secure Boot from MDM `SecurityInfo.SecureBootLevel`, not from the
provider's local check, which is an Authenticated-Root proxy.

### Honest limits

- A compromised binary signed by a stolen team key could inspect prompts.
  Mitigation: reproducible builds plus a public transparency log of blessed
  cdhashes, and least-access controls on signing identities.
- APNs code identity binds App ID and Team ID, not an exact `cdhash`, and needs
  a GUI session; a dropped push is an availability event, not a confidentiality
  breach.
- RDMA over Thunderbolt (multi-node inference) bypasses in-process memory
  protections. Single-node inference is the supported security boundary today.
- An operator with root can always boot a modified OS offline; the challenge
  and MDM gates catch it when the machine reconnects.
- Same-team binaries with the `keychain-access-groups` entitlement can load the
  persistent SE key; third-party code cannot.

## Public attestation endpoint

Anyone can inspect privacy-redacted trust status:

```bash
curl https://api.darkbloom.dev/v1/providers/attestation
```

`GET /v1/providers/attestation` (no auth; `handleProviderAttestation`,
`coordinator/api/provider.go`) returns `{providers: [...]}` with, per provider:

| Field | Meaning |
|---|---|
| `provider_id` | Opaque connection ID |
| `chip_name`, `hardware_model`, `memory_gb`, `gpu_cores`, `models[]` | Hardware class and served models |
| `trust_level` | `none`, `self_signed`, or `hardware` |
| `status` | `online`, `offline`, `untrusted`, … |
| `secure_enclave`, `sip_enabled`, `secure_boot_enabled`, `authenticated_root_enabled`, `system_volume_hash`? | Latest verified posture |
| `se_public_key` | Your SE P-256 public key |
| `mdm_verified` | `true` exactly when the live connection holds `hardware` |
| `acme_verified` | Deprecated, always `false` (kept on the wire for shipped decoders) |
| `mda_verified`, `mda_os_version`?, `mda_sepos_version`? | Apple MDA result, surfaced only while the connection holds `hardware` |

Not exposed: serial number, UDID, APNs token, the MDA certificate chain (its
leaf embeds serial and UDID), and `code_attested`. Consumers read the same
verdict per response from the `X-Provider-*` headers — see
[`../consumer/verification.md`](../consumer/verification.md).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `trust_level: self_signed` persists | MDM verification not completed | `darkbloom enroll`, install the profile, approve MDM in System Settings → Device Management; the scheduler retries on its own |
| `mdm_verified: false` | Not enrolled, or `SecurityInfo` timed out | Confirm enrollment; wait for the next retry (2–4 min, then 6–12 min, then 15–30 min) |
| `mda_verified: false` while `hardware` | Apple has not issued a fresh attestation yet (about one per 7 days) or the chain did not bind your SE key | Wait; informational only, routing is unaffected |
| `trust_status` reason `posture-mismatch` / status `untrusted` | MDM says SIP or Secure Boot differs from your blob | Fix the posture in Recovery (`csrutil enable`, full Secure Boot), reboot, restart the provider |
| `code_attested` never passes | No Aqua session / no APNs token / pushes throttled | Log in at the console, enable automatic login, disable auto-logout; check `darkbloom doctor`; a reconnect within 30 minutes of a proof uses the resume path |
| Derouted after 3 missed challenges | Sleep or network blip | Recovers on the next passing challenge; prevent sleep |
| Binary hash drift warning | Running a build not in the coordinator's release record | `darkbloom update` |

For local diagnostics use `darkbloom doctor` and `darkbloom logs --last 1h`.
Provider logs are never uploaded automatically; `darkbloom report` uploads a
unified-log excerpt to `POST /v1/provider/log-report` only when you run it
(`--dry-run` prints it first).

## Related

- [`../architecture/security/attestation.md`](../architecture/security/attestation.md) — full mechanism, invariants, and code map.
- [`../architecture/security/enrollment.md`](../architecture/security/enrollment.md) — the MDM profile and webhook.
- [`../architecture/security/identity-binding.md`](../architecture/security/identity-binding.md) — how the SE key, `K`, the APNs token, and your account are bound.
- [`../architecture/security/encryption.md`](../architecture/security/encryption.md) — the three NaCl Box hops and the privacy statement.
- [`../design/apns-code-attestation.md`](../design/apns-code-attestation.md) — design record for code identity.
