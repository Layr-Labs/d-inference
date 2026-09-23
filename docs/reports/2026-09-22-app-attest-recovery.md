# App Attest enrollment recovery and network snapshot investigation

> Last updated: 2026-09-22 · commit `08d78d49d`

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

## 0.9.9 follow-up audit

The follow-up checked Apple's enrollment, assertion, error and macOS policy
contracts against the key lifecycle, callback adapter, stored enrollment context,
receipt worker, authorization evaluator, dispatch gates and rollout docs.

| Additional finding | Reproduction and change |
|---|---|
| Service-unavailable recovery changed the original hash after a reconnect | Apple's [serverUnavailable contract](https://developer.apple.com/documentation/devicecheck/dcerror-swift.struct/code/serverunavailable) requires the same key and hash. The immediate loop complied, but the next coordinator attempt changed its session/challenge/endpoint transcript. A restart/protocol-upgrade test failed on the old code. `ShadowEnrollmentAttempt` now persists the original enrollment inputs and returns their original server context; subsequent serving assertions use fresh current-process inputs. |
| Cancellation during known-safe backoff retired the key | The PR review identified a marker still armed after Apple's server-unavailable reply. A reproduced cancellation then cleared a fresh key and hit its one-hour generation cooldown. The marker is now cleared durably before backoff and armed separately before each Apple call. The cancellation/restart test preserves the key and original hash. |
| Expired original enrollment could stop recovery permanently | The server's 24-hour clock starts before the Apple call, while older clients cached its successful reply afterward. A regression reproduces the expiry as a terminal `enrollment_context` result. Matching expired transactions now reject the proof as `enrollment_expired` and retry later, so the client can retire its expired cache. Binding mismatches are tested separately and remain terminal. |
| Rollout docs described obsolete shadow-only behavior | The shared evaluator already feeds the enabled serving path. Turning shadow off alone does not stop exchanges when serving remains enabled. The current runbook preserves existing serving settings during upgrades and explains the availability impact of explicitly disabling both paths. |

The version constants and release runbook now prepare **0.9.9**, without publishing
it or changing the active release. A bounded read-only production inspection at
20:30 America/Los_Angeles found no archived `enrollment_context`,
`enrollment_storage_error`, `counter_replay` or `certificate_chain` outcomes in
the preceding 24 hours. The expiry correction is a reproduced code defect, not
an attribution for the current Slack reports.

The audit retains the security boundaries: no accepted-key rotation on generic
assertion errors; no support inferred from OS version alone; no authorization
from a cached enrollment proof, diagnostic field or network snapshot; no change
to revocation, receipt expiry or exact signed-build qualification. A permanently
unanswered Apple callback still holds its operation slot; repeated live calls
are not allowed to accumulate. Apple's native cause in the historical assertion
case remains unavailable because the old client discarded it. New diagnostic
codes and actual post-upgrade proofs are needed before calling that case resolved.

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
