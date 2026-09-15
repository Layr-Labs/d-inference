# App Attest protocol 2, inventory, and archive validation

> Last updated: 2026-09-14 · commit `b7d0735e4`

The draft coexistence implementation passed real Apple attestation, assertion,
and independent initial-receipt verification on one M5 Max running macOS 27.0
build `26A428`. After restarting both the signed debug provider and isolated
coordinator, PostgreSQL retained one machine identity, one credential, and the
complete evidence history. This is not a final notarized-release qualification.

## Setup and boundaries

- Separate Developer ID signed debug app and user LaunchAgent; same authorized
  CDhash-opt-in provisioning profile as the earlier physical validation.
- Separate test authentication token/account and configuration; production login,
  installed provider, MDM enrollment, security settings, and production services
  were not changed.
- Isolated coordinator connected to a disposable local PostgreSQL 16 database,
  reachable from the Mac through a loopback SSH tunnel.
- Protocol 2 with account scope and locally generated OS/build/version/chip/hash
  claims. The test used the full provider executable and real WebSocket path.
- Startup model preload was disabled. No real inference workload was submitted
  on the physical Mac in this run.

The signed executable SHA-256 was
`14b4f40d6f5ecbc20c0abbe3082c8c51b54a73f073dc6fb0b595ee462c5de1b1`.
The [sanitized result](evidence/2026-09-14-app-attest-inventory/validation.json)
contains sizes, counts, and timings without serials, credential IDs, raw receipts,
or full certificates. Complete test evidence remains in a private local database
archive, outside the repository.

## Observed results

| Check | Result |
|---|---|
| Account-scoped enrollment | One real Apple attestation verified; complete 5,822-byte CBOR retained. |
| Independent receipt verification | The 3,972-byte initial `ATTEST` receipt verified against Apple Root CA G3, including its app/key/client-hash bindings. |
| Receipt re-verification | The archived receipt verified at its original capture time; changing the expected client hash produced `receipt_client_hash`. |
| Assertions | Two real 140-byte assertions verified and were retained in full. |
| Coordinator and provider restart | One machine, two connection sessions, one key; counter advanced from 1 to 2 without another attestation. |
| OS adoption | Both session records retained `27.0.0` and `26A428`. |
| Identity assurance | `key_bound`, correctly distinct from hardware-verified physical identity. The isolated coordinator did not perform MDM/MDA verification. |
| Build policy | Missing Apple version/category data stayed missing; prospective build measurement remained unqualified/unknown. |
| Timing | Server-observed attestation ~850 ms; assertions ~39 ms and ~57 ms. One machine/sample only. |
| Legacy trust | Shadow success did not grant APNs code identity or MDA verification. |

## Automated verification

- Full coordinator suite passed locally (`go test ./coordinator/...`).
- Focused race checks cover App Attest cryptography, receipt roots/bindings,
  protocol transcripts, machine identity input validation, archive failure,
  encrypted inference coexistence, and original enrollment-context recovery.
- Disposable PostgreSQL race tests cover concurrent identity creation, reconnects,
  key rotation/alias merge, original account/session attribution, duplicate
  completion, replay races, atomic rollback, receipt versions/leases, and backfill
  protection of live sessions.
- Swift checks cover entitlements, both transcript versions, registration encoder
  symmetry, account isolation, lost enrollment response/restart recovery, callback
  deadlines and duplicate callbacks, and existing client registration/APNs fields.
- Admin integration queries against PostgreSQL cover distinct machine/session
  counts, unknown/disabled cohorts, latest versus previously observed macOS 27,
  assertion history, and complete record lookup. Admin lint and production build
  passed; unavailable sections remain independently rendered.
- Existing App Attest/profile and provider signing-validation tests passed.

## Remaining release qualifications

The final notarized bundle, installer/updater and legacy APNs/MDM regression matrix,
real inference on the final artifact, additional macOS/hardware cohorts, reboot and
security-transition negatives, and a live Apple fraud-receipt renewal round trip
remain separate checks. The receipt renewal implementation is available but needs
dedicated server credentials; no production secret was configured in this task.
DeviceCheck's separate device-token/two-bit service remains deferred.

APNs/MDM retirement and any App Attest enforcement require a future change based
on these observations. This draft was not deployed to production.
