# Provider Serving Authorization

> Last updated: 2026-11-18

Provider trust status reports external serving permission, not a guarantee of
correct model output, physical uniqueness or secrecy from the executing process.
App Attest is the only verification path.

## Provider Contract

| Evidence | Meaning and limits |
|---|---|
| Legacy fields | `trust_level` and Secure Enclave signatures keep their meaning; public `mdm_verified` / `mda_verified` are retired, always false, and kept only for older CLIs ([remove when](../operations/retired-mdm-remnants.md)). App Attest does not set legacy flags. |
| App Attest | Exact qualified app identity, current connection/endpoint binding, freshness and revocation are required; shadow collection alone authorizes nothing. |
| Reported machine/resources | App measurements are not a physical uniqueness or certified RAM proof. |
| Old Darkbloom profile | Does nothing; the operator may remove it at any time without a coordinator decision. Preserve employer/other profiles. |
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

Basic serving does not require recurring receipt/risk evidence. Rewards and
captured Autopilot qualification retain a separate, stricter
[receipt decision][platform-receipts]. Administrative refresh cannot extend the
original proof lifetime. Refer to [current controls][platform-controls] for
cadences, freshness ceilings and recovery budgets rather than applying the old
receipt-required basic grant or 30-second basic-policy ceiling.

The release workflow calls the platform qualification/registration APIs. Current
[build qualification][platform-builds] registers complete official identity through
authenticated CI; the release key cannot use admin approval endpoints. Official
identity registration alone proves neither runtime Apple success nor serving
readiness. No local backend build, deployment or fleet activation is
authorized by this reference.

Keep signed-artifact and physical security-transition qualification separate from
public Swift fixture checks. A denied, expired or unknown grant must not become
permission through a diagnostic fallback.

## New-Provider Setup

| Local OS / state | Setup behavior | Provider source |
|---|---|---|
| macOS 27 or later | No profile; link the account, start the provider and wait for App Attest serving approval | `scripts/install.sh` (`configure_device_verification`); `provider-swift/Sources/darkbloom/EnrollCommand.swift` (`Enroll.guidance`) |
| Older macOS | Cannot serve; update to macOS 27 or later (`ProviderOnboardingPolicy.upgradeGuidance`). No profile is downloaded | `provider-swift/Sources/ProviderCore/Auth/ProviderOnboardingPolicy.swift`; `scripts/install.sh` (`configure_device_verification`) |
| Installer cannot parse OS version | Download no profile; print the login/start/status steps | `scripts/install.sh` (`configure_device_verification`) |
| App Attest disabled or unqualified | New macOS 27+ setup stays pending; there is no fallback | `provider-swift/Sources/ProviderCore/Diagnostics/ProviderAuthorizationReadiness.swift` (`summary`) |
| Existing Darkbloom profile | Does nothing; the installer and `start`/`status`/`doctor` print one removal hint, and `darkbloom unenroll` choice 2 guides removal by the user | `provider-swift/Sources/ProviderCore/Diagnostics/RetiredMDMProfile.swift`; `provider-swift/Sources/darkbloom/UnenrollCommand+KeepServing.swift` |
| Employer profile | Never offered for removal; unrelated to serving | `provider-swift/Sources/ProviderCore/Security/MDMEnrollment.swift` (`parseMDMEnrollmentStatus`) |

## Provider Diagnostics

The coordinator-to-provider `trust_status.authorization` object is mirrored in
`provider-swift/Sources/ProviderCore/Protocol/ProviderAuthorizationStatus.swift`.
Legacy `trust_level` retains its meaning. `expires_at` reports the basic serving
expiry. Unknown keys are ignored. Backend dispatch remains
authoritative; see the [current status contract][platform-current].

`darkbloom status` and `darkbloom doctor` describe only the App Attest decision; a
`legacy` path reads as retired (`provider-swift/Sources/ProviderCore/Diagnostics/ProviderAuthorizationReadiness.swift`,
`summary`). Removing the old Darkbloom profile reads no authorization: `darkbloom
unenroll` choice 2 (`--keep-serving`) works on any macOS, needs no privileges,
names the profile "Darkbloom Provider Enrollment" with the server from
`profiles status -type enrollment`, and opens System Settings, where the user
removes it. It keeps account/config/key data and never removes an employer
profile or the embedded signing profile. Full exit stops the service before
offering profile removal and optional cleanup. Enter/EOF cancels; noninteractive
use requires an explicit mode flag. Code:
`provider-swift/Sources/darkbloom/UnenrollCommand+KeepServing.swift`
(`guideRetiredProfileRemoval`) and
`provider-swift/Sources/ProviderCore/Diagnostics/RetiredMDMProfile.swift`.

`darkbloom status` and `darkbloom doctor` apply the same snapshot, process,
coordinator, `online` and protocol checks, but keep displaying an App Attest
lease until its `expires_at` when its latest renewal arrived more than
`snapshotMaxAge` ago (`ProviderAuthorizationReadiness.displayedStatus`).
`none` and `legacy` decisions still require receipt within `snapshotMaxAge`.
The lease duration remains the external coordinator's decision; see the
[current status contract][platform-current].

When neither shows a decision, an older `none` or `legacy` report stays visible
as dated history, so a denial can't vanish 10 seconds after it arrived and leave
a denied Mac looking healthy (`ProviderAuthorizationReadiness.lastReportedStatus`,
`lastReportedSummary`; `DaemonState.lastReportedProviderAuthorization`). Every
check above still applies except the receipt's age: the state-file write within
`snapshotMaxAge`, the process and coordinator identity, `online`, protocol `1`,
and a receipt after the process started and at most 2 seconds ahead. An older
`app_attest` report, or a path it doesn't know, is never history.

| Command | Line | Level |
|---|---|---|
| `darkbloom status` | `Last reported authorization: received <age> ago; not a fresh dispatch grant. <summary>` before the trust line | — |
| `darkbloom doctor` | `last reported authorization`, in its coordinator checks (after the health check) and in the diagnosis's trust section, as `serving authorization` appears in both | INFO for `legacy`, WARN for `none` |
| `darkbloom verify` | `last reported authorization`, after the coordinator health check | INFO for `legacy`, WARN for `none` |

History is display only: it is never a dispatch grant, changes no enrollment and doesn't touch the coordinator's own
per-request authorization. It never stands in for the public proofs: the trust
level and the public attestation lookup still run after it, and `darkbloom
verify` still fails on any warning or failure (an INFO line fails nothing).
Code: `provider-swift/Sources/darkbloom/StatusCommand.swift`,
`provider-swift/Sources/darkbloom/Diagnostics/DoctorRunner.swift`,
`provider-swift/Sources/darkbloom/DoctorCommand.swift` (`buildCoordinatorDoctorChecks`)
and `provider-swift/Sources/darkbloom/VerifyCommand.swift`.

The serving summary takes that displayed lease
(`ProviderAuthorizationReadiness.summary`). Status and both doctor paths derive
it from the same daemon snapshot and observation time.

## Related

- [Identity binding](../architecture/security/identity-binding.md)
- [Privacy and cache storage](../architecture/security/encryption.md)
- [Release qualification](../operations/provider-release.md)
- [Endpoint resumption candidate](protocol-messages.md#app-attest-endpoint-resumption-candidate)

[platform-current]: https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/reference/provider-authorization.md
[platform-controls]: https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/reference/provider-authorization.md#controls
[platform-receipts]: https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/reference/provider-authorization.md#receipt-monitoring-and-stricter-readiness
[platform-builds]: https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/reference/provider-authorization.md#durable-build-qualification
