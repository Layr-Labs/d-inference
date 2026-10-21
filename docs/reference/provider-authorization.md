# Provider Serving Authorization

> Last updated: 2026-10-21

Provider trust status reports external serving permission, not a guarantee of
correct model output, physical uniqueness or secrecy from the executing process.
Legacy MDM/APNs and App Attest authorization are independent evidence paths.

## Provider Contract

| Evidence | Meaning and limits |
|---|---|
| Legacy verification | Secure Enclave signatures, posture, MDM/MDA and code identity retain separate meanings. App Attest does not set legacy flags. |
| App Attest | Exact qualified app identity, current connection/endpoint binding, freshness and revocation are required; shadow collection alone authorizes nothing. |
| Reported machine/resources | App measurements are not a physical uniqueness or certified RAM proof. |
| Removal readiness | Do not remove enrollment merely because a shadow exchange succeeded. Follow explicit current readiness and preserve employer/other profiles. |
| Public status | Do not publish credentials, raw Apple evidence or stable private identifiers as diagnostics. |

Provider implementation is in `provider-swift/Sources/ProviderAppAttest/` and
`provider-swift/Sources/ProviderCore/Security/`. The [App Attest wire reference](app-attest-shadow.md)
and [provider procedure](../provider/attestation.md) describe local behavior.

## External Authority

Current backend grant, expiry, revocation, renewal and qualification behavior is
maintained on the default branch in [platform authorization][platform-current].
There is no local backend policy authority. The
[immutable platform reference](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/reference/provider-authorization.md)
preserves earlier evidence, not current policy. The later
[policy revision](https://github.com/Layr-Labs/darkbloom-platform/blob/20b821646acfbf0968d1c30239cb583eeb0fa2bc/docs/reference/provider-authorization.md)
records the separation of basic serving from stricter receipt monitoring; it is
also revision-specific evidence, not a moving source of truth.

Basic serving does not require recurring receipt/risk evidence. Rewards, captured
Autopilot qualification and MDM-removal readiness retain a separate, stricter
[receipt decision][platform-receipts]. Administrative refresh cannot extend the
original proof lifetime. Refer to [current controls][platform-controls] for
cadences, freshness ceilings and recovery budgets rather than applying the old
receipt-required basic grant or 30-second basic-policy ceiling.

The release workflow calls the platform qualification/registration APIs. Current
[build qualification][platform-builds] registers complete official identity through
authenticated CI; the release key cannot use admin approval endpoints. Official
identity registration alone proves neither runtime Apple success nor serving or
removal readiness. No local backend build, deployment or fleet activation is
authorized by this reference.

Keep signed-artifact and physical security-transition qualification separate from
public Swift fixture checks. A denied, expired or unknown grant must not become
permission through a diagnostic fallback.

## New-Provider Setup

| Local OS / state | Setup behavior | Provider source |
|---|---|---|
| macOS 27 or later | Skip MDM profile download and opening Settings; link the account, start the provider and wait for App Attest serving approval | `scripts/install.sh` (`configure_device_verification`); `provider-swift/Sources/ProviderCore/Auth/Enrollment.swift` (`EnrollmentService.enroll`) |
| Older macOS | Legacy enrollment with an explicit macOS 27 upgrade option and upcoming Darkbloom MDM deactivation notice | `provider-swift/Sources/ProviderCore/Auth/ProviderOnboardingPolicy.swift` |
| Installer cannot parse OS version | Download no profile; direct the user to `darkbloom enroll`, which uses the native OS version | `scripts/install.sh` (`configure_device_verification`) |
| App Attest disabled or unqualified | New macOS 27+ setup stays pending, without silently enrolling in MDM | `provider-swift/Sources/ProviderCore/Diagnostics/ProviderAuthorizationReadiness.swift` (`summary`); `provider-swift/Sources/ProviderCore/Diagnostics/MDMTrustDiagnosis.swift` (`diagnose`) |
| Existing Darkbloom or employer profile | Leave installed; Darkbloom removal still requires separate current readiness and local user action | `provider-swift/Sources/darkbloom/UnenrollCommand+KeepServing.swift` |

The retained console setup copy in
`console-ui/src/components/provider-onboarding/content.ts` explains the same OS
choice and planned MDM deactivation. The notice sets no retirement date and does
not disable legacy serving; new console development remains platform-owned.

## Provider Diagnostics

The coordinator-to-provider `trust_status.authorization` object is mirrored in
`provider-swift/Sources/ProviderCore/Protocol/ProviderAuthorizationStatus.swift`.
Legacy `trust_level` retains its meaning. `path = app_attest` alone does not permit
profile removal: `mdm_removal_ready` requires the separate current receipt decision
and removal rollout. When removal-ready, `expires_at` is capped by that stricter
decision; otherwise it reports basic serving expiry. Backend dispatch remains
authoritative; see the [current status contract][platform-current].

`darkbloom status` and `darkbloom doctor` distinguish App Attest authorization from
legacy verification. The migration option in `darkbloom unenroll` and direct
`--keep-serving` shortcut require macOS 27 or later, matching coordinator/process
identity and an unexpired removal-ready authorization. Both the state-file write
and receipt of the coordinator decision must be at most `snapshotMaxAge = 10`
seconds old (`provider-swift/Sources/ProviderCore/Diagnostics/ProviderAuthorizationReadiness.swift`,
`currentStatus`); periodic local writes cannot refresh an old removal decision.
Migration preserves account/config/key data and identifies the exact Darkbloom
enrollment before opening System Settings. It never removes an employer profile
or the embedded signing profile. Full exit stops the service before offering
profile removal and optional cleanup. Enter/EOF cancels; noninteractive use
requires an explicit mode flag. Code:
`provider-swift/Sources/darkbloom/UnenrollCommand+KeepServing.swift` and
`provider-swift/Sources/ProviderCore/Security/DarkbloomMDMRemoval.swift`.

`darkbloom status` and `darkbloom doctor` apply the same snapshot, process,
coordinator, `online` and protocol checks, but keep displaying an App Attest
lease until its `expires_at` when its latest renewal arrived more than
`snapshotMaxAge` ago (`ProviderAuthorizationReadiness.displayedStatus`).
`none` and `legacy` decisions still require receipt within `snapshotMaxAge`.
The lease duration remains the external coordinator's decision; see the
[current status contract][platform-current].

The serving summary takes that displayed lease and the strict removal decision
separately (`ProviderAuthorizationReadiness.summary`). Status and both doctor
paths derive them from the same daemon snapshot and observation time. Positive
removal advice requires the matching fresh decision and `mdm_removal_ready`.
A late but unexpired serving lease remains visible while the summary asks for
fresh removal readiness and retains existing profiles. `unenroll` still checks
readiness before and after profile inspection.

## Related

- [Identity binding](../architecture/security/identity-binding.md)
- [Privacy and cache storage](../architecture/security/encryption.md)
- [Release qualification](../operations/provider-release.md)
- [Endpoint resumption candidate](protocol-messages.md#app-attest-endpoint-resumption-candidate)

[platform-current]: https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/reference/provider-authorization.md
[platform-controls]: https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/reference/provider-authorization.md#controls
[platform-receipts]: https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/reference/provider-authorization.md#receipt-monitoring-and-stricter-readiness
[platform-builds]: https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/reference/provider-authorization.md#durable-build-qualification
