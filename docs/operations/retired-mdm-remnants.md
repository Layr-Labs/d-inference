# Remove the retired MDM profile helpers

> Last updated: 2026-11-18

Darkbloom verifies Macs with App Attest only; Darkbloom MDM is gone. The
provider keeps a few helpers so operators can remove the inert old profile.
This page lists each one and when to delete it. The platform's mirror for
coordinator items is
[`docs/operations/retired-mdm-remnants.md`](https://github.com/Layr-Labs/darkbloom-platform/blob/dev/docs/operations/retired-mdm-remnants.md)
in darkbloom-platform (on its `dev` branch once the platform sweep merges).

## When to use

Use it when you prepare a provider release, to check whether a kept item can
now be deleted.

| Kept item | Why | Remove when |
|---|---|---|
| Profile notice: one line in `start`, `status`, the installer, and the `darkbloom mdm profile` row of `doctor` (`provider-swift/Sources/ProviderCore/Diagnostics/RetiredMDMProfile.swift`, `RetiredMDMProfile`; `scripts/install.sh`, `retired_darkbloom_profile_installed`) | Many Macs still carry the old "Darkbloom Provider Enrollment" profile | Rule N = 8, below |
| `darkbloom unenroll`, choice 2 and `--keep-serving` (`provider-swift/Sources/darkbloom/UnenrollCommand+KeepServing.swift`, `Unenroll`) | Names the old profile and opens System Settings so the user can remove it | Rule N = 8; choice 1 (full exit) stays |
| Profile detection (`provider-swift/Sources/ProviderCore/Security/MDMEnrollment.swift`, `checkMDMEnrollment`, `parseMDMEnrollmentStatus`) and the unprivileged-read check (`scripts/test-provider-profiles-unprivileged.py`) | The two rows above need it | With the two rows above |
| Hidden `darkbloom enroll` (`provider-swift/Sources/darkbloom/EnrollCommand.swift`, `Enroll`) | Older scripts still call it; it prints App Attest setup and downloads nothing | With the two rows above |
| Coordinator compat fields `mdm_verified` / `mda_verified` in `GET /v1/providers/attestation` (documented in [attestation troubleshooting](../provider/attestation.md#troubleshooting)) | This provider does not decode them (`ProviderAttestation` in `provider-swift/Sources/darkbloom/Diagnostics/DoctorAttestationIdentity.swift`), but CLIs before 0.10.14 decode them as required booleans | Platform side: when the minimum provider version is at least 0.10.14 |

**Rule N = 8.** Remove these items once 8 provider releases after 0.10.14 have
shipped (0.10.22 or later; about 3–4 weeks at 2–3 releases a week) **and** the
coordinator's minimum provider version is at least the release that drops
them. Remove them earlier if the owner confirms that no Mac still carries the
profile.

## Steps

1. Confirm the rule: the latest published version is 0.10.22 or later, and the
   platform's `EIGENINFERENCE_MIN_PROVIDER_VERSION` will be at least the release
   that drops the items.
2. Delete the rows above, their tests and the doc text that names them; delete
   this page and its index links.
3. Add a `changelog.d/` fragment: the provider no longer mentions the old profile.

## Verification

`git grep -n -i mdm -- provider-swift scripts docs/provider docs/architecture docs/reference`
finds no match for these helpers. Expected leftovers on other timelines: the
coordinator's always-false `mdm_verified`/`mda_verified` keys (in
`docs/provider/attestation.md` and `docs/reference/provider-authorization.md`;
they go when the platform drops them) and the platform field names cited in
`docs/architecture/security/provider-trust.md` and `identity-binding.md` (they go
with the platform's MDM drop migrations).

## Rollback

Revert the removal commit; the helpers read the profile state only and change
nothing on the Mac.

## Related

- [Attestation: remove the retired Darkbloom profile](../provider/attestation.md#remove-the-retired-darkbloom-profile)
- [Old Darkbloom MDM profile cleanup](../architecture/security/enrollment.md)
- [Release a provider version](provider-release.md)
