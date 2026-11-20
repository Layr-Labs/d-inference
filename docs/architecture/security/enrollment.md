# Old Darkbloom profile cleanup

> Last updated: 2026-11-18

Darkbloom verifies Macs with App Attest only. Some Macs still carry the old
"Darkbloom Provider Enrollment" profile; it does nothing. This page is the
provider's boundary for helping an operator delete it. The steps for operators
are in
[provider attestation](../../provider/attestation.md#remove-the-retired-darkbloom-profile);
[the retired-profile helpers note](../../operations/retired-mdm-remnants.md) says
when this code is removed.

## Mechanism

- **Detection, unprivileged.** `checkMDMEnrollment` in
  `provider-swift/Sources/ProviderCore/Security/MDMEnrollment.swift` runs
  `/usr/bin/profiles status -type enrollment` and classifies the reported
  server. A profile counts as this install's only when the server is https and its
  host is this build environment's coordinator host or another
  `*.darkbloom.dev` / `*.darkbloom.ai` host. The other build environment's host,
  the retired `api.dev.darkbloom.xyz` and every other host (an employer's profile) are
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
  `profiles` command but the status read (regression check:
  `scripts/test-provider-profiles-unprivileged.py`).
- A server line holding a control or format character (an escape sequence, a
  carriage return, a bidi override) is never ours and is shown escaped, so it
  cannot rewrite the line that names the profile.
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

## Related

- [Attestation](attestation.md)
- [Provider trust](provider-trust.md)
- [App Attest protocol](../../reference/app-attest-shadow.md)
