# Roll out App Attest recovery and qualify MDM retirement

> Last updated: 2026-09-16 · commit `ccd969470`

Use this runbook to qualify provider 0.9.4 alongside authoritative APNs/MDM.
The [protocol reference](../reference/app-attest-shadow.md) owns configuration,
policy conditions and timing. A ready PR is distinct from a qualified release
artifact, a deployed coordinator, and a successful fleet rollout.

## When to use

Resume App Attest after the 0.9.3 callback-timer incident, repair archived
receipt scheduling, and collect evidence for a later MDM/APNs retirement.
Keep the current production pause until the replacement artifact and cohort
have been explicitly approved.

## Prerequisites

- Review and merge the candidate. Pass coordinator race/PostgreSQL contracts,
  provider callback/client/updater tests, installer acceptance, admin queries,
  and the full optimized packaged runtime smoke.
- Build the qualification candidate with the macOS 27 SDK. Qualify the final notarized bundle on physical macOS 27 with real Apple
  enrollment, repeated assertions, process/coordinator restart, sleep/reboot,
  account change and key loss. Confirm install/update and ordinary APNs/MDM
  serving on supported older macOS. Local Developer ID signing is not final
  notarized-release qualification.
- Obtain specific human approval for each production deploy, configuration,
  secret change, provider release and traffic change. See
  [coordinator deployment](coordinator-deploy.md).
- Mount a dedicated DeviceCheck-authorized ES256 server key and supply its
  identifier for App Attest receipt renewal. Do not replace APNs credentials.
  Merely enabling DeviceCheck in Apple’s portal does not configure the worker.

## Steps

1. Deploy the reviewed coordinator and additive migrations through the existing
   approved drain/hotswap procedure. Keep `EIGENINFERENCE_APP_ATTEST_SHADOW=false`
   and `EIGENINFERENCE_APP_ATTEST_ROLLOUT_PERCENT=0`. Machine inventory and
   interrupted-evidence/receipt-job maintenance continue while paused.
2. Configure the receipt key path and identifier through the approved secret
   procedure. Verify successful Apple HTTP responses, fresh `RECEIPT` validation,
   new appended receipt versions, due-job drainage and no missing blob records.
   A `renewal_required` record is a historical input, not a fresh risk receipt.
3. Publish the approved provider 0.9.4 artifact. Verify its registered release,
   final hashes and installer/updater smoke. Older 0.9.3 providers must continue
   ordinary serving and must receive no App Attest operations.
4. Enable shadow with a one-percent stable account cohort. Leave qualified build hashes
   empty until the exact artifact completes the Mac security tests below.
   Increase the percentage only after comparing disconnects, serving success,
   Apple/storage timeouts, retries, dropped submissions and evidence completeness
   against the excluded cohort on the same OS/version/time window.
5. Record the exact signed binary hashes for builds that pass Mac launch/build
   identity and security-transition qualification. Only then populate
   `EIGENINFERENCE_APP_ATTEST_QUALIFIED_BUILD_HASHES` and the corresponding
   `EIGENINFERENCE_APP_ATTEST_QUALIFIED_CODE_HASHES` pairs. Obtain the full
   SHA-256 CodeDirectory digest from the same final executable using
   `codesign -d --verbose=4`; use `CandidateCDHashFull sha256`, not the truncated
   `CDHash`. Confirm Apple returns exactly that measurement. This cannot make missing
   Apple assertion metadata, absent receipts, revoked keys or old clients pass.
6. Review the private `/app-attest` readiness view by provider version. Include
   all recent identities; distinguish online, offline, excluded, unsupported,
   unevaluated, unknown, ineligible and expired observations. Do not substitute
   event counts for a unique-machine denominator.

## Verification

| Gate before the later retirement release | Evidence required |
|---|---|
| Runtime reliability | Final artifact smoke, real Apple exchanges, no callback-related process aborts, no serving regression in matched cohorts |
| Recovery | Interrupted enrollment, delayed receipt delivery, Apple timeout/late callback, DB failure, reconnect and concurrent-counter negatives |
| Evidence completeness | No missing accepted-proof/receipt blobs; pending/interrupted/storage-error and dropped counts explicitly reconciled or explained; renewal jobs not overdue |
| Mac policy | Existing-key assertions fail after SIP or Full Security is reduced and rebooted; fresh enrollment under reduced posture also fails |
| App/build identity | Current Apple launch category and exact CodeDirectory measurement, wrong-team/re-sign/unapproved-build/altered-resource negatives, correct catalog and qualified binary/code-hash pair; protocol 3 hardware claims match registration |
| Identity continuity | Same account/credential and fresh endpoint proof retain identity without MDM; account transfer/claimed key cannot inherit it; balances and historical accounting remain unchanged |
| Revocation and dispatch | The later enforcement change must call the shared policy at every dispatch/reseal path, using current revocation and catalog state; expiry/reconnect cannot reuse an old verdict |
| Supported fleet and rewards | Explicit policy for Macs without App Attest; explicit resolution of any reward rule requiring one certified physical Mac or certified RAM |

Do not mark retirement ready from aggregate cryptographic successes alone.
Current Mac assertions that omit required Apple metadata remain unknown; do
not substitute app-reported fields. App Attest does not supply a permanent
physical machine identifier. These platform/product conditions require evidence
or a deliberate eligibility/accounting decision, not a code toggle.

For a credential revocation, use `RevokeAppAttestKey` in
`coordinator/store/postgres/app_attest_readiness.go` through an approved administrative
operation. It requires the owning account, retains the reason/time, and cannot
silently revoke another account’s key. This release records the prospective
result; APNs/MDM continues to decide serving.

## Rollback

Set `EIGENINFERENCE_APP_ATTEST_SHADOW=false` through the approved configuration
and drain procedure. Keep the durable archive, aliases, counters and revocations.
Receipt renewal can continue independently when its credentials are configured.
Never restart a pre-pause container whose environment re-enables 0.9.3 clients.
Do not delete or rewrite old receipt failures to make readiness appear healthy.

## Related

- [Current protocol, storage and policy](../reference/app-attest-shadow.md)
- [Retirement design](../design/app-attest-retirement.md)
- [Provider release](provider-release.md)
- [0.9.3 disconnect investigation](../reports/2026-09-14-app-attest-release-disconnects.md)
