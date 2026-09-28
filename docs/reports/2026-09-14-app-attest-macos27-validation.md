# Physical macOS 27 App Attest validation

> Last updated: 2026-09-14 · commit `cc4847115`

Physical Mac validation of the App Attest shadow draft, including corrections
discovered with Apple-generated proofs and the real provider registration path.
This is development validation, not a published provider release or a completed
[retirement qualification](../design/app-attest-retirement.md).

## Environment and artifacts

- Physical MacBook Pro, Apple M5 Max, 128 GB, macOS 27.0 build `26A428`.
  Hardware inventory is an OS report, distinct from Apple-signed evidence.
- SIP reports enabled. A user GUI session is active. No security setting,
  enrollment profile, installed provider bundle, or production service was changed.
- Developer ID Application signing uses team `SLDQ2GJ6TL` and signing identifier
  `io.darkbloom.provider`, with Hardened Runtime and the newly downloaded profile.
  The profile grants the CDhash opt-in without an environment entitlement.
- A separate validation app compiles the actual `ProviderAppAttest` sources.
  A separate full Darkbloom debug bundle uses the provider packaging helper,
  rebuilt binaries, resource bundles, and the installed release's metallib.
  Both pass static signature checks; neither is a notarized release candidate.
- Test coordinators bind only to loopback and are reached through SSH forwarding.
  The full provider uses a separate config, no production auth token, disabled
  auto-update/restart, and disabled startup model preload. No consumer workload
  or production routing is exercised.

## Observed results

| Check | Result |
|---|---|
| API eligibility in a full app launched through LaunchServices | `isSupported = true`; the real client reaches Apple's service. |
| Initial key attestation | Accepted by the production-root verifier, including identity, nonce, environment, credential key, and exact Mac access policy. The profile without an environment entitlement produces a production attestation on this host. |
| Assertion verification | Passes after the corrections below. OpenSSL independently verifies ES256 over the computed nonce as a message. |
| Fresh app launches | The same validation key is reused through LaunchServices and a user LaunchAgent; observed accepted counters advance from 2 through 5. |
| Replay and modified client data | Rejected against the Apple-generated assertion. The regression fixture also rejects a different relying-party identity. |
| Direct executable launch over SSH | API support remains true, but the existing Keychain record cannot be read in this launch context; the client reports `keychain_error`. This does not establish behavior before user login or on all SSH setups. |
| Full provider WebSocket exchange | Pass after the registration correction: negotiated protocol 1, verified attestation, encrypted challenge decrypted by the provider, verified assertion, and persisted counter 1. Legacy trust remains `self_signed`; APNs code-attested and MDA-verified flags remain false in the isolated coordinator. |
| Full provider and coordinator process restart | Pass: the saved credential is reused without new attestation, a fresh encrypted challenge is verified, and the counter advances to 2. The harness persists credentials to a private JSON file; this is not a production PostgreSQL restart test. |
| App metadata extensions | The captured attestation has 164 authenticator bytes; the assertion has 37. Both carry flag `0x40` and no extension data. No documented bundle-version or validation-category extension is present. |

The validation app's initial Apple attestation call took about 1.26 seconds;
successful assertion calls took 12–24 milliseconds in this small sample.
These are client-call timings from one host, not fleet latency percentiles.
The full provider's coordinator-observed attestation exchange took about
891 milliseconds and its first assertion exchange about 25 milliseconds,
after the initial randomized delay.
After the full provider/coordinator restart, the assertion exchange took about
34 milliseconds. [Sanitized observations](evidence/2026-09-14-app-attest-macos27/observations.json)
retain stage outcomes, timings, and legacy-state comparisons without raw proofs,
receipts, tokens, serials, provider identifiers, or public endpoint keys.

The signed full-provider executable's SHA-256 is
`f4a009e9078f1fb2322ccf956ede7ce001cca1ce1dd9a290e563f27b9a86fa23`.
Its source is the stamped commit plus this change's raw-registration codec
correction. Its bundle version remains `0.9.2`; this is a separate debug
validation artifact, not the published binary with that version.

## Corrections discovered by live testing

| Problem | Correction and regression evidence |
|---|---|
| Go treated the assertion nonce as the final ECDSA digest | Hash the nonce for ES256 message verification. The certificate nonce calculation remains unchanged. A real Mac assertion fails before the fix and passes afterward; an incorrectly constructed single-hash signature is rejected. |
| The assertion parser rejected the Mac's retained AT flag | Permit the observed flag on the simplified assertion header. Continue rejecting undeclared trailing credential bytes and malformed extensions. |
| Swift dropped negotiation for registrations carrying raw legacy attestation JSON | Mirror `app_attest_protocol` into `encodeRegisterPreservingRawAttestation`. A regression using the actual registration codec first fails on both encoding and decoding, then passes while preserving the original signed JSON bytes. |

The fixed public assertion vector is in
`coordinator/appattest/testdata/macos27_assertion.json`. It contains public
verification material and a client-data digest, with no receipt or private key.
It tests assertion compatibility; certificate-chain acceptance was checked
separately at capture. Original raw evidence remains outside the repository
in private validation storage.

Code: `coordinator/appattest/verify.go` (`Verifier.Assertion`),
`coordinator/appattest/authenticator.go` (`authData`),
`provider-swift/Sources/ProviderCore/Protocol/ProtocolCodec.swift`
(`encodeRegisterPreservingRawAttestation`).

## Remaining acceptance and design work

The absence of version/category extensions is a real policy constraint on this
tested Mac build. Continue recording `metadata_missing`; do not turn a successful
signature into an approved-build decision. A follow-up can evaluate binding
the app's internally derived build identity into the assertion transcript,
with that assurance distinguished from independent Apple-supplied metadata.
There is no such policy change in this correction.

Still required: a release-configuration, signed and notarized candidate;
encrypted inference workload acceptance; APNs/MDA regression with the updated
release artifact on supported OS cohorts; interrupted enrollment, account
changes, and receipt lifecycle qualification; app updates and OS reboot; and
reuse of an old key after deliberately changing SIP or Full Security on an
explicitly designated test setup. No security-reduction test was performed.

Keep APNs and MDM authoritative. See the
[current shadow reference](../reference/app-attest-shadow.md) and
[earlier specification audit](2026-09-14-app-attest-spec-review.md).
