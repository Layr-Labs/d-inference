# Provider Enrollment

> Last updated: 2026-10-09

This page explains the provider's enrollment boundary. Backend profile generation,
Apple verification, MicroMDM and webhook operation live in the
[platform enrollment guide](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/security/enrollment.md).

## Context

Legacy MDM enrollment and qualified App Attest authorization are independent.
New-provider eligibility and legacy recovery depend on current external policy;
installing a profile is not itself proof of serving permission. Never enroll or
remove an unrelated employer-management profile as a troubleshooting shortcut.

## Mechanism

### Frozen legacy authorization cohort

The platform owns the legacy cohort and validates a linked account, key and
device evidence. The provider must not synthesize membership or interpret an
old profile as a new authorization. App Attest-only providers do not acquire
legacy flags merely by completing their separate exchange.

### Copied-profile boundary

A copied configuration profile does not establish the recipient's verified
identity. The provider uses current account/key evidence for its enrollment
request; the external verifier decides eligibility. Keep profile handling
separate from its resulting trust status.

### The profile

`provider-swift/Sources/ProviderCore/Security/MDMEnrollment.swift` owns provider
interaction with the downloaded enrollment profile. Preserve expected-host
validation and explicit user approval; do not accept arbitrary caller URLs or
quietly install a profile into a different management context.

### Profile signing

The external service signs the profile. Signing and transport validation do not
prove that every installed profile is eligible for legacy serving. Backend CMS
signing keys and service configuration do not belong in this repository.

### Operator flow

Follow [provider attestation](../../provider/attestation.md) for supported
enrollment and verification steps. The CLI obtains the appropriate evidence,
the user approves the native operation, and the platform reports the result.
Do not bypass a failed proof or overwrite credentials to force a successful state.

For qualified removal, `provider-swift/Sources/ProviderCore/Security/DarkbloomMDMRemoval.swift`
and `ProfileInventoryAuthorization.swift` preserve the native authorization
boundary and distinguish Darkbloom profiles from other management. Removal
readiness is not implied by a successful shadow exchange.

## Invariants

- Preserve expected-host checks and current signed account/key proof.
- Treat denied, unavailable and incomplete verification as distinct from success.
- Never infer eligibility from possession of the generic profile.
- Keep employer/other enrollment untouched; do not use background actions to
  circumvent required native authorization.

## Failure modes

An unsupported device, failed authorization, unavailable Apple service or
ineligible cohort can leave the provider connected but not routable. Use the
actual platform verdict and [troubleshooting guide](../../provider/troubleshooting.md).
Do not deploy or reconfigure a backend from this checkout to conceal a failure.

## Code map

| Responsibility | Source |
|---|---|
| Enrollment interaction | `provider-swift/Sources/ProviderCore/Security/MDMEnrollment.swift` |
| Profile inventory authorization | `provider-swift/Sources/ProviderCore/Security/ProfileInventoryAuthorization.swift` |
| Scoped removal | `provider-swift/Sources/ProviderCore/Security/DarkbloomMDMRemoval.swift` |
| Serving policy | [Platform authorization](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/reference/provider-authorization.md) |

## Related

- [Attestation](attestation.md)
- [Provider trust](provider-trust.md)
- [App Attest protocol](../../reference/app-attest-shadow.md)
