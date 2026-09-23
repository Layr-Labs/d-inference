# App Attest enrollment recovery and network snapshot investigation

> Last updated: 2026-09-22 · commit `011ccd3d1`

This investigation covers provider 0.9.8 and coordinator source `011ccd3d1`.
The repairs described here are a proposed patch, not a production deployment
or proof that every affected Mac has recovered. Customer identities, private
certificates, receipts and raw proof bodies are excluded.

## Reproduced failures

| Failure | Evidence | Repair and limit |
|---|---|---|
| Public App Attest count falls to zero | A source snapshot contained 1,139 connections, 336 App Attest, 846 legacy and 270 dual-path verdicts. Every serialized App Attest lease had 29 seconds remaining. At snapshot +40 seconds, the old UI reported zero App Attest and only 846 verified connections, matching the reported screen. | Network stats, filters and proof details now describe the source snapshot and retain its visible age. Live owner controls and coordinator dispatch still enforce current expiry. |
| Valid Apple attestation rejected as `authenticator_trailing_data` | Six rejected production proofs contained a valid 116-byte CDhash extension map with flags `0x40`; two accepted controls used `0xc0`. All passed the embedded Apple chain, exact Mac ACL and nonce checks before the framing rejection. | The parser accepts this bounded, complete attestation-only extension shape. Private replay accepts all six rejected proofs and both controls. Unflagged assertion tails and malformed extensions remain rejected. |
| Initial enrollment retries an unusable key indefinitely | One screenshot-matched machine reused the same unaccepted key through seven operation timeouts and 22 generic Apple errors across reconnects. The underlying native error was discarded by the released client. | Failed or interrupted enrollment retires the key under the existing persisted one-hour cooldown and shared generation budget. The initiating Apple failure cannot be reconstructed from the old coarse error. |

Apple's [enrollment guidance](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)
permits retrying the same key after `serverUnavailable`; other attestation
errors require a new key. The patch records an attempt marker before calling
Apple, preserves a successfully saved enrollment proof across lost responses,
and does not rotate accepted credentials for generic assertion errors.

## Distinct reporter cases

Account-scoped inspection at approximately 20:03–20:05 America/Los_Angeles
found an enrolled-key assertion failure as well. That credential previously
produced 116 verified assertions, then returned 123 `apple_error` results since
September 16. Its last success and first failure both reported provider 0.9.4
and macOS build `26A428`; this failure predates 0.9.8. Its current connection
had legacy authorization and completed 21 distinct successful route requests
in the preceding 15 minutes. **The enrollment repair is not a demonstrated
fix for this assertion failure.**

Another reporting account had two currently App Attest-authorized Macs and a
third whose availability check reported `unsupported`, using legacy authorization.
All three had successful routes in that same 15-minute inspection. An OS version
report alone does not establish Apple API support or serving authorization.

The supplied email for the group-DM reporter had no provider tokens or machine
sessions. A machine matching the screenshot's hardware/model/activity was found
under another login; that association remains tentative, not a confirmed account
match.

New optional diagnostics preserve a closed domain bucket, signed numeric error
code and one bounded underlying-error pair. Native descriptions, arbitrary
domain strings and `userInfo` are excluded. These are untrusted diagnostic data,
never authorization evidence. Old generic errors cannot reveal their native cause.

## UI check

The production-built local console was checked against public stats. It displayed
343 App Attest connections when the source snapshot was 32 seconds old, retaining
the stale indicator. The captured frame below is another observation; fleet counts
may differ. Synthetic regression coverage pins the original 1,139-connection
failure at +40 seconds and verifies that live expiry still works.

![Local console showing verification at the source snapshot](images/2026-09-22-app-attest-snapshot.png)

## Validation and rollout boundary

The full coordinator suite, focused App Attest/protocol race tests, 29 focused
Swift App Attest tests, 803 console tests, console lint/build and docs checks
passed during preparation. The focused Swift harness compiles the actual module
and tests without the inference dependency graph; it is not signed-app
qualification. The full provider suite and final CI results belong to the PR's
validation record.

Deploying the coordinator can accept the authenticated framing variant on existing
clients. The console deployment fixes snapshot presentation. Enrollment recovery
and native diagnostics require a new signed provider release and adoption. No
database migration, trust bypass, forced provider restart or automatic production
mitigation was performed. The rollout monitor remains paused at the operator's request.

Follow-up runtime checks must distinguish fresh enrollment success, subsequent
verified assertions, current serving authorization and successful inference.
Passing parser tests or preserving a historical snapshot does not establish
those outcomes for a particular affected Mac.
