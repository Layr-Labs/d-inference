# App Attest 0.9.4 recovery qualification

> Last updated: 2026-09-14 · commit `a99ce680a`

The 0.9.4 candidate adds guarded shadow activation, recovery, receipt renewal
and prospective authorization. Local tests and real Apple exchanges validate
those components. Production remains paused; the candidate is not a published
or notarized release and this report does not certify MDM retirement.

## Observed checks

| Check | Result |
|---|---|
| Full coordinator unit suite | Passed |
| App Attest/API/store/authorization race tests | Passed, including a disposable local PostgreSQL instance |
| PostgreSQL recovery | Old receipt failures remain unchanged; historical recovery is queued once; interrupted verification cannot advance counters |
| Identity and revocation | Fresh credential association retains identity without legacy proof; other accounts cannot inherit it; revocation is durable and idempotent |
| Swift tests | 19 App Attest XCTest cases, 18 coordinator-client cases and 23 CLI/updater cases passed |
| Atomic installer | Existing cases and rejection of a missing callback marker passed |
| Admin UI | PostgreSQL cohort/current-connection/expiry/revocation cases, including immediate revocation reasons and deduplicated machine counts, lint and production build passed |
| Final optimized callback smoke | Completion, cancellation and expiry paths passed alongside Gemma and Metal markers |
| Negative control | Replacing only the safe callback-timer sleep with the old generic overload made the revised deterministic smoke abort with SIGABRT and `freed pointer was not the last allocation`; fixed source was restored and rebuilt |
| Locally Developer ID signed 0.9.4 app | Real Apple enrollment and assertions 1–3 verified; restart reused the key and verified counters 4–6 without another enrollment |
| Actual Go coordinator + PostgreSQL + signed protocol 3 provider | Across restarts and the hardware-substitution negative: one machine, five sessions, one credential, assertion counter 5, six proof blobs and two receipt blobs; provider remained alive. The final provider bound both hardware and its existing verification key |
| Hardware substitution through a local WebSocket proxy | Changing only registration RAM produced `hardware_claims_mismatch` and an ineligible prospective verdict; the cryptographic assertion remained valid and the provider stayed alive |
| SDK 27 full provider + actual coordinator/PostgreSQL | All optimized smoke markers passed. The existing credential advanced counters 6–7 across an SDK upgrade/reconnect. An exact lab-qualified binary/code-hash mapping produced `eligible`; an intentionally wrong code hash produced only `apple_code_measurement_mismatch`. Both providers remained alive. Qualification/catalog inputs were synthetic local test approvals, not production qualification. |
| Apple risk receipt endpoint | HTTP 200; fresh `RECEIPT` signature, app/key, dates and risk metric verified; Apple provided next-refresh and expiration timestamps |

Both the challenge harness and actual Go coordinator tests used isolated loopback endpoints, synthetic auth,
separate local state and no consumer inference. Each provider remained alive
until the harness deliberately sent SIGTERM. Those resulting socket EOFs are
not application crashes. Test credentials/proof bytes/receipts remain in private
local artifacts and are not committed here.

Protocol 3 has an independent Go/Swift transcript vector and regression coverage
for version 2 cached-enrollment recovery, memory/verification-key substitution and bounds. Protocol 3 also binds the existing attestation public key, preserving the link to model/runtime signatures after MDM retirement. The
base-reward memory-cap table moved unchanged into the hardware package.

Review regressions cover a single enrollment snapshot shared by archive and
verification, retryable enrollment-store failures, account-stable cohort selection
through provisional identity changes, and live-session preference after a delayed
terminal capture, signed OS status after readiness failure/revocation, and explicit stale/expired-policy blockers.

## Renewal format correction

A real Apple renewal initially failed the old verifier's `receipt_client_hash`
check. The signed renewed receipt's field 4 contained UTF-8 replacement bytes,
not the original 32-byte enrollment hash. Apple's published receipt verification
steps authenticate the app, attested key, signature chain and creation time;
they do not require a renewed risk receipt to repeat the enrollment challenge.

The verifier keeps exact challenge binding for initial `ATTEST` receipts.
Renewed `RECEIPT` objects require the expected app/key, valid Apple signature,
fresh creation, unexpired lifetime and valid risk fields. Initial and renewed
types cannot substitute for one another in the worker. No lossy byte sequence
is treated as a nonce. Tests cover wrong app/key, stale risk receipts and the
separate historical-input validator. A subsequent real Apple response passed
this validation. See [Apple's receipt contract](https://developer.apple.com/documentation/devicecheck/assessing-fraud-risk).

## Qualification limits

The original full provider, built with SDK 26.5, produced valid macOS 27 signatures/counters but no Apple extensions. A subsequent controlled Objective-C probe used the same full app Info.plist, Developer ID, profile and entitlements with SDK 26.5 versus SDK 27.0 (Command Line Tools 27 beta 6, clang 21.0.0). Both completed real Apple enrollment and assertion verification. SDK 26.5 returned 37-byte authenticator data without extensions; SDK 27.0 returned 153 bytes with Developer ID category 6, code-hash type 2 and a 32-byte digest matching the signed executable's full CodeDirectory SHA-256. Neither returned a bundle-version field.

The server now records these signed code measurements and the prospective policy requires an exact qualified binary/code-hash mapping plus the active catalog. A matching current code measurement can identify the release when the Mac omits bundle version. Missing/unsupported measurements and absent qualification remain unknown. These wire details are empirically verified; public documentation for the two code-hash extension names was not found. They still require final-artifact and supported-OS qualification. No client-reported field or enrollment metadata substitutes for a current Apple assertion measurement.

The full SDK 27 provider test finished on 2026-09-15. Its compile commands selected SDK 27, but CLT 27 beta 6 initially linked SDK 14 metadata. A minimal Swift control reproduced this independently of the build engine. Supplying the same SDK through `SDKROOT` corrected the link metadata; the full provider was relinked from its SDK 27 objects, signed, checked for SDK 27 and tested. The release workflow now supplies that environment and checks the final linked SDK. No global toolchain selection was changed.

Physical SIP/Full Security transitions, altered-resource/re-sign negatives,
final notarization and multi-machine/older-OS release qualification remain
separate gates. The future enforcement/removal release also needs current
revocation/catalog evaluation at every dispatch and an explicit older-OS and
accounting policy. A stable credential identity is not a certified count of
physical Macs. See the [rollout runbook](../operations/app-attest-rollout.md).
