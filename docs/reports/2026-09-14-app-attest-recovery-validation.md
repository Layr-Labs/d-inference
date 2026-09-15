# App Attest 0.9.4 recovery qualification

> Last updated: 2026-09-14 · commit `b725a72a8`

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
| Swift tests | 17 App Attest XCTest cases and 23 CLI/updater tests passed |
| Atomic installer | Existing cases and rejection of a missing callback marker passed |
| Admin UI | PostgreSQL cohort/current-connection/expiry/revocation cases, lint and production build passed |
| Final optimized callback smoke | Completion, cancellation and expiry paths passed alongside Gemma and Metal markers |
| Negative control | Replacing only the safe callback-timer sleep with the old generic overload made the revised deterministic smoke abort with SIGABRT and `freed pointer was not the last allocation`; fixed source was restored and rebuilt |
| Locally Developer ID signed 0.9.4 app | Real Apple enrollment and assertions 1–3 verified; restart reused the key and verified counters 4–6 without another enrollment |
| Apple risk receipt endpoint | HTTP 200; fresh `RECEIPT` signature, app/key, dates and risk metric verified; Apple provided next-refresh and expiration timestamps |

The full-client tests used an isolated loopback coordinator, synthetic auth,
separate local state and no consumer inference. Each provider remained alive
until the harness deliberately sent SIGTERM. Those resulting socket EOFs are
not application crashes. Test credentials/proof bytes/receipts remain in private
local artifacts and are not committed here.

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

The observed macOS 27 assertions had valid signatures/counters but omitted
Apple bundle-version and validation-category extensions. The prospective policy
therefore reports missing metadata as unknown. Neither an app-reported build
nor enrollment metadata substitutes for a current Apple assertion field.

Physical SIP/Full Security transitions, altered-resource/re-sign negatives,
final notarization and multi-machine/older-OS release qualification remain
separate gates. The future enforcement/removal release also needs current
revocation/catalog evaluation at every dispatch and an explicit older-OS and
accounting policy. A stable credential identity is not a certified count of
physical Macs. See the [rollout runbook](../operations/app-attest-rollout.md).
