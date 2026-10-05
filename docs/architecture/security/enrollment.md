# MDM enrollment

> Last updated: 2026-10-05

How a provider Mac joins Darkbloom's MDM so the coordinator can ask Apple's
management subsystem, rather than the provider binary, whether SIP and Secure
Boot are on. Enrollment is SCEP + MDM only; the historical ACME
`device-attest-01` payload was removed.

New setup on macOS 27 or later uses App Attest and does not enter this MDM flow.
The installer (`scripts/install.sh`, `configure_device_verification`) and CLI
(`provider-swift/Sources/ProviderCore/Auth/Enrollment.swift`, `EnrollmentService.enroll`)
select the setup path locally; [serving authorization](../../reference/provider-authorization.md)
still comes from the coordinator. Existing profiles remain installed until the
separate removal readiness check passes. Under the upcoming frozen legacy MDM
policy, older macOS does not qualify a new identity for legacy enrollment or
provide an unsupported-OS fallback.

## Context

The installer does not request or install a legacy profile. It defers eligible
reenrollment to `darkbloom login` with the existing account followed by
`darkbloom enroll`, whose authenticated SE-key proof is checked by the coordinator.
Existing local management is preserved, not treated as proof of eligibility
(`scripts/install.sh`, `configure_device_verification`).

The `hardware` trust level ([`attestation.md`](./attestation.md#trust-levels))
is granted only from an MDM `SecurityInfo` report. That report is produced by
`mdmclient`, signed with the device's MDM identity certificate, and delivered
through MicroMDM — none of which the provider process controls. Enrollment is
the one-time step that installs the identity certificate and the MDM payload.
The profile is generic (no serial, no UDID), read-only (`AccessRights` 1041),
and removable by the operator at any time.

## Mechanism

### Frozen legacy authorization cohort

The upcoming policy freezes a durable cohort on the first upgraded production
coordinator startup, **after revocation replay**. Membership binds the authenticated account,
Secure Enclave public key and serial of a device already successfully
MDM-verified before the freeze. It is not a list of every MicroMDM enrollment,
every saved `hardware` label, or every account that owns a provider. Subsequent
restarts reuse the frozen cohort, even when empty; new accounts, devices, keys and new
account/device associations cannot expand it. Reenrollment requires the
existing key under its frozen account. A new identity requires macOS 27 or later
and current qualified
[App Attest authorization](../../reference/provider-authorization.md); existing
qualification and runtime checks still apply, without an unsupported-OS fallback.

Durable historical evidence can conservatively omit lost or hashless historical
records. Retained hardware snapshots together with authenticated inventory may
supplement that evidence; neither unauthenticated association nor an enrollment
alone establishes membership. A grace period has **not** been chosen and no
cohort expiry is implemented. Membership is a prerequisite, not a permanent trust
grant: revocation, posture, freshness and code-identity checks remain in force.

The implementation entry points for this upcoming change are
`Policy.Initialize`, `Policy.RegistrationAllowed` and `Policy.ProviderAllowed` in
`coordinator/internal/provider/legacymdm/policy.go`, and the `FreezeLegacyMDMCohort` operation on
`LegacyMDMCohortStore` in `coordinator/store/legacy_mdm_cohort.go`.
The policy gate applies at registration identity recovery, scheduler submission,
live MDM verification, late callbacks and cached trust reuse. A saved grant or an
already outstanding command cannot authorize a nonmember.

`Policy.Initialize` requires production App Attest serving enabled with
full rollout before freezing; invalid configuration fails startup before the
freeze. The [deployment prerequisites](../../operations/coordinator-deploy.md#frozen-legacy-mdm-cutover-prerequisites)
own the required settings. New identities also require App Attest on owner
self/prefer routes; lowering the legacy trust floor cannot bypass that gate.

The [deployment classification](../../reference/configuration.md#deployment-environment)
defaults to production. Explicit development or actual opted-in memory-store
fallback skips the startup freeze; neither telemetry tags nor the App Attest
proof environment select that exception. A later production startup freezes
then-current eligible membership.

```mermaid
sequenceDiagram
    participant O as Operator (darkbloom enroll)
    participant K as Coordinator
    participant X as Caddy (/scep, /mdm/*)
    participant M as MicroMDM (127.0.0.1:9002)
    participant D as macOS (mdmclient)

    O->>O: profiles status -type enrollment<br/>(other MDM → refuse; Darkbloom profile alone is not eligibility)
    O->>K: POST /v1/enroll (linked provider Bearer token + signed SE-key proof)
    K->>K: Verify fresh proof and existing key under frozen account
    K-->>O: application/x-apple-aspen-config<br/>Darkbloom-Enroll.mobileconfig: SCEP + MDM payloads<br/>PayloadIdentifier io.darkbloom.enroll · AccessRights 1041<br/>CMS-signed when PROFILE_SIGNING_P12_* is set
    Note over O,D: If Darkbloom profile already exists, return Already enrolled without saving or reinstalling; otherwise continue below
    O->>D: open the .mobileconfig → System Settings → Profiles → operator clicks Install
    D->>X: SCEP GetCACert / PKIOperation (RSA 2048, challenge "micromdm")
    X->>M: reverse proxy
    M-->>D: device identity certificate
    D->>X: MDM CheckIn (Authenticate, TokenUpdate) → /mdm/checkin
    X->>M: reverse proxy
    Note over D,M: device now reachable through MDM push (Topic com.apple.mgmt.External.…)

    Note over K,M: later, per provider WebSocket connection (verification scheduler)
    K->>M: POST /v1/devices (lookup UDID by serial, Basic auth micromdm:{api key})
    K->>M: POST /v1/commands {SecurityInfo} (MicroMDM pushes the device)
    M->>D: APNs wake → device connects to /mdm/connect
    D->>M: SecurityInfo result (CommandUUID)
    M->>K: POST /v1/mdm/webhook<br/>X-Webhook-Token or ?token= EIGENINFERENCE_MDM_WEBHOOK_SECRET · body ≤ maxMDMWebhookBodyBytes
    K-->>K: HandleWebhook: Acknowledged + CommandUUID outstanding (outstandingCommandTTL)<br/>→ frozen cohort gate + verifyProviderViaMDM → hardware grant · DeviceInformation → MDA flag
```

This inline flow includes the upcoming authorization gates; the checked-in
`docs/assets/diagrams/enrollment-flow.mmd` and `enrollment-flow.svg` predate them.

### Copied-profile boundary

The profile remains generic and inherently copyable. Its SCEP and MDM check-in
requests go directly through the reverse proxy to MicroMDM, bypassing the
coordinator's `/v1/enroll` checks. A copied profile can therefore still enroll a
different Mac directly in MicroMDM. The restriction guarantees **coordinator MDM
authorization**, not literal prevention of direct MicroMDM enrollment. MicroMDM
presence, a valid check-in or possession of a signed profile cannot add the new
identity to the frozen cohort or authorize its legacy serving path.

### The profile

| Property | Value | Code |
|---|---|---|
| Endpoint | Upcoming `POST /v1/enroll`: linked provider Bearer token plus fresh SE-key proof and frozen-account/key membership; JSON fields and signed bytes in the [API contract](../../reference/api-contracts.md#legacy-mdm-enrollment-proof); capped at [`maxControlPlaneBodyBytes`](../../reference/api-contracts.md#limits-and-validation) | `coordinator/api/routes.go` (route), `coordinator/api/provider/trust/enroll.go` (`HandleEnroll`) |
| Response | `200`, `Content-Type: application/x-apple-aspen-config`, `Content-Disposition: attachment; filename="Darkbloom-Enroll.mobileconfig"` | `coordinator/api/provider/trust/enroll.go` (`HandleEnroll`) |
| Base URL | `EIGENINFERENCE_BASE_URL` when set; only in local/dev does it fall back to `X-Forwarded-Proto` + request `Host`, because a signed profile pointing at an attacker host would launder a malicious enrollment | `coordinator/api/server.go` (`resolveBaseURL`); `coordinator/api/server_config.go` |
| Top-level payload | `PayloadType Configuration`, `PayloadIdentifier io.darkbloom.enroll`, `PayloadDisplayName "Darkbloom Provider Enrollment"`, `PayloadOrganization Darkbloom`, fresh `PayloadUUID` per download | `coordinator/internal/provider/enrollment/enrollment_profile.go` (`Profile`) |
| Payload 1 — SCEP | `PayloadType com.apple.security.scep`, `PayloadIdentifier io.darkbloom.enroll.scep`, `PayloadUUID D01D95F9-762E-4538-A9B3-4D949D55577C`; `URL <base>/scep`, `Challenge micromdm`, RSA 2048, `Key Usage 5`, Subject `O=Darkbloom`, `CN=Darkbloom Identity` | `coordinator/internal/provider/enrollment/enrollment_profile.go` (`Profile`) |
| Payload 2 — MDM | `PayloadType com.apple.mdm`, `PayloadIdentifier io.darkbloom.enroll.mdm`, `PayloadUUID 4DF05DBF-6D20-41A4-8072-A51D327258E7`; `IdentityCertificateUUID` = SCEP UUID; `CheckInURL <base>/mdm/checkin`; `ServerURL <base>/mdm/connect`; `Topic com.apple.mgmt.External.10520cbe-9635-453d-ac4e-c79aab56f8ce`; `SignMessage true`; `CheckOutWhenRemoved true`; `ServerCapabilities [com.apple.mdm.per-user-connections, com.apple.mdm.bootstraptoken]` | `coordinator/internal/provider/enrollment/enrollment_profile.go` (`Profile`) |
| `AccessRights` | 1041 = 1 (inspect installed profiles) + 16 (query device information) + 1024 (security queries). Not requested: install/remove profiles (2), lock/passcode (4), erase (8), network queries (32), provisioning profiles (64, 128), installed apps (256), restrictions (512), settings (2048), app management (4096) | `coordinator/internal/provider/enrollment/enrollment_profile.go` (`Profile` comment) |
| Stable identifiers | PayloadIdentifiers, the two PayloadUUIDs, and the push `Topic` never change, so re-enrolling replaces the profile in place (and drops the old ACME payload on devices that still carry it) | `coordinator/internal/provider/enrollment/enrollment_profile.go` (`Profile`) |
| Removed | The ACME `device-attest-01` payload and its coordinator verification leg; `acme_verified` remains in `GET /v1/providers/attestation` as a constant `false` because shipped provider builds decode it | `coordinator/api/provider/trust/enroll.go`; `coordinator/api/provider/trust/status.go` (`HandleProviderAttestation`) |

### Profile signing

| Property | Value | Code |
|---|---|---|
| Configuration | `PROFILE_SIGNING_P12_B64` or `PROFILE_SIGNING_P12_PATH`, plus `PROFILE_SIGNING_P12_PASSWORD`; a Developer ID Application identity is expected | `coordinator/profilesign/signer.go` (`LoadFromEnv`) |
| Format | CMS `SignedData`, SHA-256 digest, signer chain added with `pkcs7.AddSignerChain`; the profile is encapsulated (not detached), so the MIME type is unchanged | `coordinator/profilesign/signer.go` (`Sign`) |
| Failure policy | No signer → `enroll.profile_unsigned`; signing error → error log + `enroll.profile_sign_error` and the **unsigned** profile is served; success → `enroll.profile_signed`. Signing is install-time UX trust only and never affects the SCEP/MDM chain | `coordinator/api/provider/trust/enroll.go` (`HandleEnroll`) |

### Operator flow

`darkbloom enroll [--coordinator URL] [--no-open]`
(`provider-swift/Sources/darkbloom/EnrollCommand.swift`) calls
`EnrollmentService.enroll` (`provider-swift/Sources/ProviderCore/Auth/Enrollment.swift`):

On macOS 27 or later, the command returns App Attest setup guidance before
profile inspection or endpoint access. Guidance asks the operator to verify
current status; neither the OS version nor this result grants authorization.
On older macOS:

1. `profiles status -type enrollment` (`checkMDMEnrollment`,
   `provider-swift/Sources/ProviderCore/Security/MDMEnrollment.swift`).
   `enrolledDarkbloom` → continue to the authenticated eligibility check;
   `enrolledOtherMDM` → `EnrollmentError.managedByOtherMDM`; `notEnrolled` or
   `checkFailed` → continue (a redundant download is idempotent).
2. For an existing frozen identity, `POST <https base>/v1/enroll` with
   `Content-Type: application/json`, the linked provider Bearer token and the
   [signed proof](../../reference/api-contracts.md#legacy-mdm-enrollment-proof).
   A non-2xx → `coordinatorReturnedHTTP`. Clients using the old unauthenticated
   request cannot download a profile under the upcoming policy.
   After success, an already installed Darkbloom profile returns "Already
   enrolled" and stops without saving the response or opening Settings. This does not
   establish current serving authorization; profile presence never bypasses
   the account/key proof or cohort check.
3. If no Darkbloom profile was detected, save to a temp
   `Darkbloom-Enroll-<uuid>.mobileconfig`; unless `--no-open`,
   `open` the file (registers it with System Settings) and then `open
   x-apple.systempreferences:com.apple.Profiles-Settings.extension`.
4. The operator clicks **Install** and authenticates. `mdmclient` performs
   SCEP against `/scep` and MDM check-in against `/mdm/checkin`; both are
   reverse-proxied by Caddy to MicroMDM on `127.0.0.1:9002`
   (`coordinator/Caddyfile`, `deploy/gcp/vm-startup.sh`).
5. `darkbloom unenroll` (`provider-swift/Sources/darkbloom/UnenrollCommand.swift`)
   opens System Settings → General → Device Management for removal; the
   coordinator has no remove-profile right.

### Coordinator ↔ MicroMDM

| Property | Value | Code |
|---|---|---|
| Client config | `EIGENINFERENCE_MDM_URL` (empty = MDM verification disabled), `EIGENINFERENCE_MDM_API_KEY`; HTTP Basic `micromdm:<api key>` | `coordinator/mdm/config.go` (`ReadConfig`); `coordinator/mdm/mdm.go` (`NewClient`) |
| Device lookup | `POST /v1/devices` filtered by serial → UDID and `EnrollmentStatus` | `coordinator/mdm/mdm.go` (`LookupDevice`) |
| Commands | `POST /v1/commands` (structured; MicroMDM sends exactly one push) for `SecurityInfo`; raw plist `POST /v1/commands/<udid>` + `GET /push/<udid>` for `DeviceInformation` with `DeviceAttestationNonce` (the raw endpoint does not auto-push) | `coordinator/mdm/mdm.go` (`SendSecurityInfoCommand`, `SendDeviceAttestationCommand`, `pushDevice`, `RequestDeviceAttestation`) |
| Allowed request types | `SecurityInfo`, `DeviceInformation` only; anything else panics in `assertReadOnlyCommand` before it is sent | `coordinator/mdm/mdm.go` (`readOnlyMDMRequestTypes`, `assertReadOnlyCommand`) |
| Outstanding commands | `CommandUUID` recorded per issued command with `outstandingCommandTTL` = 30m; consumed on the first matching response | `coordinator/mdm/mdm.go` (`trackCommand`, `consumeCommand`) |

### Webhook

MicroMDM is started with `command-webhook-url` pointing at the coordinator.

| Property | Value | Code |
|---|---|---|
| Route | `POST /v1/mdm/webhook` | `coordinator/api/routes.go` |
| Authentication | When `EIGENINFERENCE_MDM_WEBHOOK_SECRET` is set: `X-Webhook-Token: <secret>` header **or** `?token=<secret>` query (MicroMDM cannot add headers), constant-time compare; failure → `403 forbidden` before the body is read. Unset → startup warning; the CommandUUID gate alone protects the webhook | `coordinator/api/provider/trust/settings.go` (`HandleMDMWebhook`, `mdmWebhookTokenValid`); `coordinator/app/services.go` |
| Body cap | [`maxMDMWebhookBodyBytes`](../../reference/api-contracts.md#limits-and-validation) | `coordinator/api/provider/trust/settings.go` |
| Logging | `Debug` level: `body_size` and a 500-byte `body_preview` (MDM plist, never inference data) | `coordinator/api/provider/trust/settings.go` (`HandleMDMWebhook`) |
| Parsing | JSON `{topic, acknowledge_event: {status, raw_payload}}`; only `status == "Acknowledged"` with a non-empty base64 plist is processed | `coordinator/mdm/mdm.go` (`HandleWebhook`) |
| Solicited-response gate | `parseCommandUUID(plist)` must match an outstanding command; otherwise the payload is dropped — a forged SecurityInfo can never drive a grant | `coordinator/mdm/mdm.go` (`HandleWebhook`) |
| Dispatch | `SecurityInfo` → the waiting `VerifyProviderWithUDIDObserver` or the late path `ApplyLateSecurityInfo`; `DevicePropertiesAttestation` → `ApplyLateMDA` | `coordinator/mdm/mdm.go` (`SetOnLateSecurityInfo`, `SetOnMDA`); `coordinator/api/provider/` (`ApplyLateSecurityInfo`); `coordinator/internal/provider/verification/callbacks.go` (`ApplyLateMDA`) |
| Response | `200` once the body is read, even for payloads the gate drops; `400 bad request` only when the body cannot be read (for example over the cap) | `coordinator/api/provider/trust/settings.go` (`HandleMDMWebhook`) |

What the coordinator reads from `SecurityInfo`: `SystemIntegrityProtectionEnabled`,
`SecureBootLevel` (`"full"` required), `AuthenticatedRootVolumeEnabled`
(recorded only) — `coordinator/mdm/mdm.go` (`parseSecurityInfoPlist`). What
it never requests: installed apps, network information, restrictions, or
anything under the unrequested `AccessRights` bits.

## Invariants

1. The enrollment profile contains no device identity and grants only read-only rights (`AccessRights` 1041) — `coordinator/internal/provider/enrollment/enrollment_profile.go` (`Profile`).
2. Under the upcoming policy, `POST /v1/enroll` requires authenticated account/key possession and frozen membership; a caller-supplied serial cannot create membership — `coordinator/api/provider/trust/enroll.go` (`HandleEnroll`).
3. SCEP/MDM URLs in a signed profile come from `EIGENINFERENCE_BASE_URL`, not from the request `Host` — `coordinator/api/server.go` (`resolveBaseURL`).
4. Signing failures degrade to an unsigned profile with an error log and metric; they never block enrollment — `coordinator/api/provider/trust/enroll.go` (`HandleEnroll`).
5. The coordinator issues only `SecurityInfo` and `DeviceInformation` commands — `coordinator/mdm/mdm.go` (`assertReadOnlyCommand`).
6. A webhook payload is acted on only if it is `Acknowledged` and its `CommandUUID` matches a command the coordinator issued within `outstandingCommandTTL` ([Coordinator ↔ MicroMDM](#coordinator--micromdm)) — `coordinator/mdm/mdm.go` (`HandleWebhook`).
7. When a webhook secret is configured, unauthenticated webhooks are rejected before the body is read — `coordinator/api/provider/trust/settings.go` (`HandleMDMWebhook`).
8. Possession of the profile proves nothing; trust is earned by the per-connection verification described in [`attestation.md`](./attestation.md#layer-3--mdm-securityinfo-the-hardware-grant) — `coordinator/internal/provider/deviceverification/mdm_verification.go` (`VerifyProviderViaMDM`).

## Failure modes

| Failure | Effect | Code |
|---|---|---|
| Mac already managed by another MDM | On older macOS, `darkbloom enroll` refuses (`managedByOtherMDM`); macOS 27 or later returns App Attest guidance without inspecting profiles. Doctor reports "enrolled in another MDM … hardware trust unavailable on this Mac" | `provider-swift/Sources/ProviderCore/Auth/Enrollment.swift`; `provider-swift/Sources/darkbloom/DoctorCommand.swift` |
| Profile downloaded but never installed | MDM lookup returns `device-not-found`; provider stays `self_signed` and the scheduler retries | `coordinator/internal/provider/deviceverification/mdm_verification.go` (`VerifyProviderViaMDM`) |
| Enrolled but SecurityInfo never arrives (asleep, APNs delivery, Apple throttling) | `securityinfo-timeout`; retried on the MDM scheduler cadence ([attestation, Layer 3](./attestation.md#layer-3--mdm-securityinfo-the-hardware-grant)); a late webhook grants only if current identity remains allowed | `coordinator/internal/provider/verification/scheduler.go`; `coordinator/api/provider/` (`ApplyLateSecurityInfo`) |
| `EIGENINFERENCE_MDM_URL` unset | No MDM client, no scheduler; no provider can reach `hardware` | `coordinator/app/services.go` |
| Webhook secret mismatch | `403`; SecurityInfo responses are lost until MicroMDM's `command-webhook-url` token matches | `coordinator/api/provider/trust/settings.go` (`mdmWebhookTokenValid`) |
| Webhook body over `maxMDMWebhookBodyBytes` | `400 bad request`; payload ignored | `coordinator/api/provider/trust/settings.go` (`HandleMDMWebhook`) |
| Forged or replayed SecurityInfo | Dropped by the CommandUUID gate | `coordinator/mdm/mdm.go` (`HandleWebhook`) |
| Signing identity misconfigured | Unsigned profile served; macOS shows it as unverified; `enroll.profile_sign_error` | `coordinator/api/provider/trust/enroll.go` (`HandleEnroll`) |

## Code map

| Concern | File (symbol) |
|---|---|
| Profile generation and serving | `coordinator/internal/provider/enrollment/enrollment_profile.go` (`Profile`); `coordinator/api/provider/trust/enroll.go` (`HandleEnroll`) |
| Frozen eligibility and enrollment proof | `coordinator/internal/provider/legacymdm/policy.go` (`Policy.Initialize`, `Policy.RegistrationAllowed`, `Policy.ProviderAllowed`, `Policy.AuthorizeEnrollment`); `coordinator/store/legacy_mdm_cohort.go` (`LegacyMDMCohortStore`) |
| Profile signing | `coordinator/profilesign/signer.go` (`LoadFromEnv`, `Sign`) |
| Base URL pinning | `coordinator/api/server.go` (`resolveBaseURL`); `coordinator/api/server_config.go` |
| Webhook | `coordinator/api/provider/trust/settings.go` (`HandleMDMWebhook`, `mdmWebhookTokenValid`, `maxMDMWebhookBodyBytes`) |
| MicroMDM client | `coordinator/mdm/mdm.go` (`NewClient`, `LookupDevice`, `VerifyProviderWithUDIDObserver`, `RequestDeviceAttestation`, `HandleWebhook`, `assertReadOnlyCommand`, `parseSecurityInfoPlist`); `coordinator/mdm/config.go` |
| Wiring and env | `coordinator/app/services.go` |
| Reverse proxy | `coordinator/Caddyfile`; `deploy/gcp/vm-startup.sh` |
| Provider CLI | `provider-swift/Sources/darkbloom/EnrollCommand.swift`, `provider-swift/Sources/darkbloom/UnenrollCommand.swift`; `provider-swift/Sources/ProviderCore/Auth/Enrollment.swift`; `provider-swift/Sources/ProviderCore/Security/MDMEnrollment.swift` |

## Related

- [`attestation.md`](./attestation.md) — how the enrolled device's SecurityInfo becomes the `hardware` level, and the MDA flag.
- [`identity-binding.md`](./identity-binding.md) — how the MDA certificate's serial and UDID are bound to the SE key.
- [`../../provider/attestation.md`](../../provider/attestation.md) — operator how-to for enrolling and checking `darkbloom doctor`.
- [`../../operations/coordinator-deploy.md`](../../operations/coordinator-deploy.md) — deploying MicroMDM, `EIGENINFERENCE_MDM_*`, `PROFILE_SIGNING_*`.
