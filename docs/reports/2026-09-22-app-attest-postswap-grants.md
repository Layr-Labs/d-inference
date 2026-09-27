# App Attest authorization after the 0.9.9 coordinator swap

> Last updated: 2026-09-22 · commit `cb9418cad`

This report separates verified Apple proof, complete archival, account and
machine binding, and a live permission to serve. It uses bounded read-only
production observations after the 2026-09-22 coordinator swap. Counts are
connection sessions, not necessarily distinct physical Macs. Private proof
bytes, account identifiers and credential IDs are excluded.

## Observed outcome

The coordinator became ready on `cb9418cad` at 21:43:18 PDT and continued
serving inference. Immediately before the swap, 342 of 1,134 public connections
had App Attest authorization. At 22:00:41 PDT, 236 of 1,153 had it; 912 had
either App Attest or legacy authorization. The older browser snapshot bug
cannot explain this: the lower count came from the coordinator's current
verification response. The signed provider release remained 0.9.8.

| Distinct observation | What it establishes |
|---|---|
| Four Macs previously rejected at enrollment reached assertion after the parser repair | Their signed assertions carry flags `0x40`, a complete 116-byte Apple extension map, Developer ID category 6 and type-2 32-byte CodeDirectory SHA-256. `Verifier.Assertion` checked the signature over all authenticator bytes, then the old assertion-only ED check rejected them as `authenticator_trailing_data`. Acceptance must stay limited to that measured, fully signed shape. |
| One enrollment returned `code_directory_measurement` | It carried a type-2 **20-byte** Apple-signed hash. Apple [TN3126](https://developer.apple.com/documentation/technotes/tn3126-inside-code-signing-hashes) defines `CandidateCDHash sha256` as the 20-byte truncation of `CandidateCDHashFull sha256`. A protected comparison found this proof matches the prefix of exactly **one** active, unrevoked, fully qualified signed release's full 32-byte measurement, with matching published binary and version. The older parser rejected this shape before that comparison. |
| 55 connections' latest policy was `evidence_archive_gap` | Those sessions also had 110 successfully verified, durably recorded assertions after the swap. The session's cumulative dropped-proof count could keep `ArchiveComplete` false throughout the connection, even for a later complete proof. A later sample found 54 such sessions whose first recorded drop was during `prepare/attempted`, before their successful assertions; the exact refused frame was not durably captured. |
| 79 sessions had eligible prospective policy but no current App Attest grant | 68 retained valid legacy serving authorization; 11 had neither method. A prospective policy observation is not permission to serve. A later read-only sample established the startup backfill race below for its then-current 75 pending sessions. |
| 162 identities reported assertion `apple_error` after cutover | 161 had the same outcome in the prior 24 hours. Released 0.9.8 clients omit Apple's native error code, so the initiating Apple failure cannot be reconstructed from these events. |

At 05:20 UTC, **75 of 75** currently eligible but ungranted sessions had an
inventory row with `source=historical_registration` and
`disconnect_reason=observed_disconnect`, while their corresponding
`provider_sessions` rows remained open with a heartbeat in the preceding
minute. All **246** then-current eligible and granted sessions had open
`live_registration` inventory rows. The backfill in
`coordinator/store/machine_inventory_backfill.go`
(`BackfillMachineInventory`) had selected provider rows before their bounded
live inventory write completed. It inserted a historical disconnected row;
later live captures could not supersede that confirmed tombstone.
`coordinator/store/postgres_machine_continuity.go`
(`ResolveMachineContinuity`) correctly requires an open machine session, so
the grant was refused. Repair must skip open or freshly connected provider
sessions during backfill and reopen only a matching historical tombstone for
the exact authenticated account and still-live provider after a fresh proof.
Genuine provider-session closures remain closed. The separate 20-byte signed
measurement path can grant only when its type-2 bytes uniquely match the
20-byte `CandidateCDHash` of the **same** exact durable qualified signed
artifact. Full 32-byte qualification of that artifact, active catalog and
version, category 6, revocation and all other checks remain mandatory; an
app-reported hash or an environment-only bootstrap cannot substitute.
This carries a 160-bit code identity measurement for that Apple wire form;
the full 256-bit Apple wire form remains preferred. A 20-byte prefix alone
without the independent artifact qualification is insufficient.

## Authorization invariant

The current signed assertion must verify against the accepted, account-scoped
key and fresh connection transcript. Its complete proof and decision must be
durable before advancing the counter. A bounded storage/queue refusal remains
in the inventory audit; it cannot count as a good proof. A later independent,
fully recorded and verified assertion can reestablish authorization after
all current receipt, revocation, qualified-build, machine, runtime and expiry
checks pass. These later checks are required at dispatch and cannot be inferred
from a historical `eligible` event.

## Source repair and remaining release validation

The follow-up source change accepts the bounded signed assertion formats,
checks Apple's 20-byte prefix against a unique current durable full-hash
qualification, prevents the backfill race, repairs only a proven live
historical tombstone and lets an independently archived new assertion recover
after an earlier gap. A temporarily unavailable catalog or ambiguous shortened
hash withholds App Attest permission without classifying the signed code as
tampered and hard-denying independently valid MDM/APNs authorization. An
unsigned challenge-field mismatch is likewise archived but not treated as
confirmed cryptographic tampering. Regression tests cover tamper, replay, wrong challenge,
ambiguous/revoked build prefixes, drop/grant ordering and strict identity
continuity with disposable PostgreSQL and memory storage. These source tests
do not prove the deployed coordinator or a packaged provider has recovered.

The exact signed 0.9.9 provider artifact still needs its own Apple
enrollment/assertion and SIP/Full Security qualification before publication.
After the separately approved deployment, compare fresh proofs with current
grants and completed inference for the affected cohort. Historical generic
Apple errors remain a separate diagnosis until the released client supplies
native error codes.

Related sources: `coordinator/appattest/authenticator.go` (`authData`),
`coordinator/appattest/verify.go` (`Assertion`),
`coordinator/appattest/service/storage.go` (`acquireStorage`),
`coordinator/appattest/service/policy.go` (`observeBuildPolicy`),
`coordinator/appattest/service/authorization_identity.go`
(`updateServingAuthorization`) and
`coordinator/registry/app_attest_authorization.go`
(`GrantAppAttestServingAuthorization`).
