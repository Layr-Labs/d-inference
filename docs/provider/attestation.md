# Reaching and keeping `hardware` trust

> Last updated: 2026-09-06 · commit `14f809d65`

How to take a provider Mac from `self_signed` to `hardware` trust and keep it
there, so the coordinator routes public inference to it. For operators; the
mechanism — what each layer proves, the grant and loss conditions, the routing
gate, and the code map — is in
[`../architecture/security/attestation.md`](../architecture/security/attestation.md)
and is not restated here.

## Prerequisites

- A supported Apple silicon Mac with SIP on and Secure Boot at **Full
  Security**, running the provider ([`installation.md`](./installation.md),
  [`hardware-requirements.md`](./hardware-requirements.md)). Both settings are
  changed only in Recovery; the coordinator checks them independently of your
  self-report ([Layer 3](../architecture/security/attestation.md#layer-3--mdm-securityinfo-the-hardware-grant)).
- The Mac must not be enrolled in another MDM. `darkbloom enroll` refuses
  (`managedByOtherMDM`) and `darkbloom doctor` reports "enrolled in another
  MDM … hardware trust unavailable on this Mac"
  ([`../architecture/security/enrollment.md#failure-modes`](../architecture/security/enrollment.md#failure-modes)).
- A real console user logged in (Aqua session), automatic login enabled,
  auto-logout on idle disabled, and sleep prevented. APNs registration, which
  the code-identity flag depends on, only works inside a logged-in GUI session;
  `darkbloom doctor` reports these as `console session`, `automatic login`,
  `auto-logout on idle` and `sleep prevention`
  ([`troubleshooting.md#doctor-checks`](./troubleshooting.md#doctor-checks)).
- A healthy `darkbloom start`. Registration with a valid Secure-Enclave-signed
  blob grants `self_signed` at once ([Layer 1](../architecture/security/attestation.md#layer-1--secure-enclave-registration-blob));
  `hardware` is only ever granted on top of that.

## Steps

### 1. Enrol the Mac

```bash
darkbloom enroll
```

The command downloads the enrolment profile from `POST /v1/enroll`, saves it as
`Darkbloom-Enroll-<uuid>.mobileconfig`, registers it with System Settings and
opens the Profiles pane (`EnrollCommand.swift`; options in
[`cli-reference.md`](./cli-reference.md#darkbloom-enroll--darkbloom-unenroll)).
The download accepts at most 1 MiB and rejects interrupted, oversized, empty,
or incorrectly typed responses before saving or opening a profile.
"Already enrolled" means the Darkbloom profile is present and you can skip to
step 3. What the profile contains and the read-only `AccessRights` it requests
are in [`../architecture/security/enrollment.md#the-profile`](../architecture/security/enrollment.md#the-profile).

### 2. Approve the profile

In **System Settings → General → Device Management**, select *Darkbloom
Provider Enrollment*, click **Install**, and authenticate. `mdmclient` then
performs SCEP and the MDM check-in against the coordinator's MicroMDM
([operator flow](../architecture/security/enrollment.md#operator-flow)). If the
profile is shown as unverified, the coordinator served it unsigned; installing
it is still safe because signing is install-time UX only
([profile signing](../architecture/security/enrollment.md#profile-signing)).

### 3. Confirm your posture

The coordinator grants `hardware` when Apple's MDM subsystem on your Mac
reports SIP enabled and `SecureBootLevel` `full`, in agreement with your
attestation blob. Check both before waiting on the coordinator:

```bash
csrutil status            # System Integrity Protection status: enabled.
csrutil authenticated-root status
```

For Secure Boot, open **Startup Security Utility** in Recovery and confirm
**Full Security**. Fixing either setting requires a reboot into Recovery, which
also restarts the provider.

### 4. Wait for the verification, or re-check

Nothing more is needed from you: the coordinator's verification scheduler picks
up the enrolled device, sends a `SecurityInfo` command, and grants on the first
report that agrees with your blob. A transient outcome (device not found yet,
not enrolled, report timed out) leaves your level unchanged and is retried on
the scheduler's backoff; only a received report that **contradicts** your blob
demotes you ([Layer 3](../architecture/security/attestation.md#layer-3--mdm-securityinfo-the-hardware-grant),
[failure modes](../architecture/security/attestation.md#failure-modes)).

To re-check after fixing something, restart the provider so it re-registers:

```bash
darkbloom restart
darkbloom status
```

### Keeping the level

- **Stay online and awake.** Trust is per connection: a reconnect caps a
  stored `hardware` back to `self_signed`, and the coordinator restores it
  from durable device evidence on your first passing challenge only within the
  trust-reuse bounds; otherwise a fresh `SecurityInfo` round-trip runs
  (trust reuse in [Layer 3](../architecture/security/attestation.md#layer-3--mdm-securityinfo-the-hardware-grant)).
  Missing the periodic challenge deroutes you; the cadence, timeouts and strike
  counts are in [Layer 2](../architecture/security/attestation.md#layer-2--periodic-challenge).
- **Keep the console session.** `code_attested` is earned through an APNs push
  that only a logged-in Aqua session can receive; once the operator enables
  enforcement, un-attested providers receive no private text
  ([Flag — APNs code identity](../architecture/security/attestation.md#flag--apns-code-identity)).
- **Keep the same identity.** The Secure Enclave signing key is persistent in
  the keychain, so your SE public key survives restarts and is the identity the
  trust-reuse and code-identity caches are keyed on
  ([`../architecture/security/identity-binding.md`](../architecture/security/identity-binding.md)).
  If the keychain path fails — for example a binary without the
  `keychain-access-groups` entitlement — `ProviderLoop.swift` falls back to an
  ephemeral key with a warning, you appear as a brand-new identity, and you
  re-earn every flag from scratch.
- **Run a released build.** Binary, metallib and model-hash drift against
  registration untrusts you; `darkbloom update` returns you to a build in the
  release record ([`cli-reference.md`](./cli-reference.md#darkbloom-update)).

## Verify

`darkbloom status` prints the last `trust_status` the coordinator sent as
`Trust: <level> / <status>` (`StatusCommand.swift`). What you want to see:

| `Trust:` line | Meaning |
|---|---|
| `hardware / online` with reason `MDM verification passed` or `MDM verification passed (late SecurityInfo)` | A fresh `SecurityInfo` grant on this connection |
| `hardware / online` with a trust-reuse reason (`same_binary`, `continuity`, `approved_release_transition`, `continuity_release_transition`) | Restored from durable device evidence after a reconnect |
| `self_signed / online`, reason `SE attestation verified, awaiting MDM verification` | Enrolment not complete or the report has not arrived yet — see Troubleshooting |
| any level `/ untrusted` with a failure reason | The coordinator stopped routing to you — see Troubleshooting |

The reason strings are listed in
[trust status messages](../architecture/security/attestation.md#trust-status-messages-to-providers).

`darkbloom doctor` shows the local side: MDM enrolment, SIP, the console-session
checks above, and (with `--support`) the coordinator URL and MDM state
([`troubleshooting.md#doctor-checks`](./troubleshooting.md#doctor-checks)).

Anyone can read your public verdict — `trust_level`, `mdm_verified`,
`mda_verified` and the verified posture fields, never your serial, UDID, APNs
token or `code_attested` — from `GET /v1/providers/attestation`; the fields are
explained in [`../consumer/verification.md#public-attestation-endpoint`](../consumer/verification.md#public-attestation-endpoint).

What `hardware` does not prove: it says nothing about *which* binary holds your
key (that is `code_attested`) or *which* Apple device (that is `mda_verified`;
Apple issues a fresh attestation only about once per device per week, so the
flag can lag the level — [Flag — Apple Managed Device Attestation](../architecture/security/attestation.md#flag--apple-managed-device-attestation)).
Neither flag changes the level. Single-node inference is the supported security
boundary: multi-node RDMA over Thunderbolt bypasses the in-process memory
protections and is not trusted. The process defences behind the privacy
capabilities the routing gate requires, and their known limits, are recorded in
[`../threat-model.yaml`](../threat-model.yaml) and summarised in
[`../architecture/components/provider.md#process-boundaries`](../architecture/components/provider.md#process-boundaries);
what the provider can and cannot see is in
[`../architecture/security/encryption.md#what-each-party-can-observe`](../architecture/security/encryption.md#what-each-party-can-observe).

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `trust_level: self_signed` persists | MDM verification not completed | `darkbloom enroll`, install the profile, approve MDM in System Settings → Device Management; the scheduler retries on its own |
| `mdm_verified: false` | Not enrolled, or `SecurityInfo` timed out | Confirm enrolment; wait for the next retry on the [scheduler backoff](../architecture/security/attestation.md#layer-3--mdm-securityinfo-the-hardware-grant) |
| `mda_verified: false` while `hardware` | Apple has not issued a fresh attestation yet or the chain did not bind your SE key | Wait; informational only, routing is unaffected |
| `trust_status` reason `posture-mismatch` / status `untrusted` | MDM says SIP or Secure Boot differs from your blob | Fix the posture in Recovery (`csrutil enable`, Full Security), reboot, restart the provider |
| `code_attested` never passes | No Aqua session / no APNs token / pushes throttled | Log in at the console, enable automatic login, disable auto-logout; check `darkbloom doctor`; a reconnect soon after a proof uses the resume path instead of a push ([Flag — APNs code identity](../architecture/security/attestation.md#flag--apns-code-identity)) |
| Derouted after missed challenges | Sleep or network blip | Recovers on the next passing challenge; prevent sleep |
| Binary hash drift warning | Running a build not in the coordinator's release record | `darkbloom update` |
| `darkbloom enroll` says the Mac is managed by another MDM | Another MDM profile is installed | Remove it (System Settings → General → Device Management) or use another Mac; `hardware` is unavailable while it is present |
| Every flag lost after an update or reinstall | The Secure Enclave key fell back to ephemeral (warning in `darkbloom logs`) | Reinstall a signed release build so the `keychain-access-groups` entitlement is present |

For local diagnostics use `darkbloom doctor` and `darkbloom logs --last 1h`.
Provider logs are never uploaded automatically; `darkbloom report` uploads a
unified-log excerpt to `POST /v1/provider/log-report` only when you run it
(`--dry-run` prints it first; [`cli-reference.md`](./cli-reference.md#darkbloom-report)).

## Related

- [`../architecture/security/attestation.md`](../architecture/security/attestation.md) — trust levels, the three layers, both flags, the routing gate, invariants, and code map.
- [`../architecture/security/enrollment.md`](../architecture/security/enrollment.md) — the MDM profile, operator flow, and webhook.
- [`../architecture/security/identity-binding.md`](../architecture/security/identity-binding.md) — how the SE key, `K`, the APNs token, and your account are bound.
- [`../architecture/security/encryption.md`](../architecture/security/encryption.md) — the three NaCl Box hops and the privacy statement.
- [`../consumer/verification.md`](../consumer/verification.md) — how consumers read your verdict.
- [`troubleshooting.md`](./troubleshooting.md) — doctor checks and symptom → fix rows.
- [`../design/apns-code-attestation.md`](../design/apns-code-attestation.md) — design record for code identity.
