# App Attest specification and draft review

> Last updated: 2026-09-14 · commit `2f39698d2`

Review of Apple's current documentation and the App Attest draft in PR #995.
These are findings observed on this date; the documentation's publication or
change dates are not established. The [retirement proposal](../design/app-attest-retirement.md)
defines follow-up work.

## Current draft gaps

| Finding at the reviewed commit | Consequence |
|---|---|
| `coordinator/appattest/authenticator.go` accepts only CBOR integers for the validation category | Rejects the four-byte representation in Apple's published example. This review adds strict integer/four-byte decoding and regression tests. |
| `coordinator/appattest/verify.go` parses but discards receipts | No independent receipt verification, persistence, or fraud renewal. Existing key rows cannot retroactively supply those receipts. |
| `coordinator/api/app_attest_shadow_observation.go` compares version/category to registration | A cryptographic pass is not an approved-release decision. No complete prospective authorization verdict exists. |
| `AppAttestShadowClient.respond` marks the key attested before server acceptance; a later unknown-key request clears it | Lost proofs or server persistence failures can force rotation. Enrollment needs acknowledgement and reconciliation. |
| `handleAppAttestShadow` scopes local storage by coordinator URL; server ownership also depends on the legacy SE identity | Account changes and eventual legacy removal require an explicit credential/account migration. |
| Local Apple retries have fixed delays; callback completion is not bounded | Aggregate enrollment budgeting and recovery from a stalled operation remain incomplete. |

## Apple's published byte example

Decoded the first `attestationObject` in the
[validation guide](https://developer.apple.com/documentation/devicecheck/attestation-object-validation-guide),
parsed its certificate and authenticator data, and checked the certificate
chain against the pinned Apple root at the leaf's issuance period.
The decoded sample is 5,906 bytes; SHA-256 is
`e4ca508153f6619a29d0887eb0ffe19540b9f15c5a6aeccdac26c49affd5f61a`.

- `apple_validation_category_01` is a four-byte CBOR byte string,
  `01 00 00 00`, interpreted as little-endian category 1. Bundle version is
  the string `1`. The example is not a Developer ID Mac acceptance fixture.
- The computed public-key hash and credential ID agree with each other but
  differ from the guide's printed expected hash.
- The certificate nonce agrees with hashing authenticator data plus the raw
  example challenge; it does not agree with hashing authenticator data plus
  SHA-256 of that challenge as instructed by the validation algorithm.
- The sample leaf is valid April 20–23, 2026, and its access-policy blob differs
  from the required Mac policy. It is not accepted as a current Mac proof.

Only the category representation informs the parser correction. Nonce,
certificate-time, environment, root, and exact Mac-policy checks remain strict.
The guide is useful for structural compatibility, not a substitute for a
physical Mac fixture. The main validation page also uses different extension
names in its attestation and assertion instructions; resolve actual Mac
assertion fields from signed evidence before adding aliases.

## Validation boundary

The new tests first failed on byte-encoded categories and revealed that CBOR
null was decoded as numeric zero. The correction checks the CBOR major type,
rejects malformed values and null, preserves unknown category values for
policy evaluation, and verifies a signed byte-category assertion while rejecting
its tampered counterpart. Existing certificate round trips now include the
byte representation, with test roots restricted to tests.

Live Developer ID/macOS 27 enrollment, receipt validation, security-transition
behavior, and final signed-artifact compatibility remain untested. This review
does not change APNs/MDM enforcement or deploy any component.
