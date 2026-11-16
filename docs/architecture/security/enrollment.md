# Old Darkbloom MDM profile cleanup

> Last updated: 2026-11-16

Darkbloom verifies Macs with App Attest only and runs no MDM. The provider has
no MDM enrollment, no MDM trust path and no MDM removal decision. Macs enrolled
before the removal may still carry the old "Darkbloom Provider Enrollment"
profile; it does nothing. This page is the provider's boundary for helping an
operator delete it. The steps for operators are in
[provider attestation](../../provider/attestation.md#remove-the-retired-darkbloom-profile).

## Mechanism

- **Detection, unprivileged.** `checkMDMEnrollment` in
  `provider-swift/Sources/ProviderCore/Security/MDMEnrollment.swift` runs
  `/usr/bin/profiles status -type enrollment` and classifies the reported MDM
  server. A profile counts as this install's only when the server is https and its
  host is this build environment's coordinator host or another
  `*.darkbloom.dev` / `*.darkbloom.ai` host. The other build environment's host,
  the retired `api.dev.darkbloom.xyz` and every other host (an employer's MDM) are
  foreign. A configured coordinator URL never adds a host.
- **Notice.** `RetiredMDMProfile`
  (`provider-swift/Sources/ProviderCore/Diagnostics/RetiredMDMProfile.swift`) gives
  `start`, `status` and `doctor` one informational line while this install's profile
  is installed, and nothing otherwise.
- **Removal guidance.** `darkbloom unenroll` choice 2 (`--keep-serving`) names the
  profile by its display name and the server that `profiles status` reported, says
  to remove nothing if no profile has exactly that name, and opens System Settings at
  the installed profiles (`RetiredMDMProfile.openSystemSettings`). The user removes
  the profile there; macOS lets only the user remove it.

## Invariants

- No privileges: the provider never runs `profiles` through `sudo` and runs no
  `profiles` command but the status read (`scripts/test-provider-profiles-unprivileged.py`).
- No profile is downloaded, installed or removed by any provider code.
- An employer's profile or another install's profile is never offered for removal;
  an unreadable enrollment state opens nothing.
- The cleanup grants and withholds nothing: serving is the coordinator's App Attest
  decision.

## Code map

| Responsibility | Source |
|---|---|
| Enrollment state, unprivileged | `provider-swift/Sources/ProviderCore/Security/MDMEnrollment.swift` (`checkMDMEnrollment`, `parseMDMEnrollmentStatus`) |
| Notice, doctor row, System Settings link | `provider-swift/Sources/ProviderCore/Diagnostics/RetiredMDMProfile.swift` |
| `unenroll` choice 2 | `provider-swift/Sources/darkbloom/UnenrollCommand+KeepServing.swift` (`guideRetiredProfileRemoval`) |

The MDM enrollment boundary this page used to describe is in the history at
[`63a82b502c`](https://github.com/Layr-Labs/d-inference/blob/63a82b502c/docs/architecture/security/enrollment.md).

## Related

- [Attestation](attestation.md)
- [Provider trust](provider-trust.md)
- [App Attest protocol](../../reference/app-attest-shadow.md)
