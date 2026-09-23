# Roll out App Attest recovery with MDM coexistence

> Last updated: 2026-09-23 · commit `cb9418cad`

Use this runbook for App Attest reliability upgrades on a fleet that may already
serve without MDM. [Provider authorization](../reference/provider-authorization.md)
owns the serving controls; the [protocol reference](../reference/app-attest-shadow.md)
owns exchange bounds and recovery. Source tests, signed-artifact qualification,
deployment and observed provider recovery are separate results.

## When to use

Deploy a reviewed App Attest parser, recovery or observability change and publish
its provider release. For the first activation of MDM-free serving, follow
[MDM-optional rollout](mdm-optional-rollout.md). The original 0.9.3 incident is a
[historical report](../reports/2026-09-14-app-attest-release-disconnects.md), not
instructions to reset an already enabled fleet to a shadow-only cohort.

## Prerequisites

- Review and merge the candidate; pass coordinator/protocol race checks,
  provider recovery tests, release integrity and packaged runtime smoke.
- Obtain operator approval for the specific coordinator deployment,
  configuration changes and provider release. Preserve the approved cohort,
  serving/removal settings, receipt credentials, existing build approvals and
  independently valid legacy path unless that operation explicitly changes them.
- Retain an immutable rollback image that understands App Attest-only serving,
  durable qualification and revocation. An old legacy-only coordinator cannot
  safely serve as a compatible rollback after providers remove MDM.
- Qualify the exact signed artifact following [build qualification](app-attest-build-qualification.md).
  Include real Apple enrollment/assertions, process/coordinator restart, account
  change, SIP/Full Security transitions and supported older-macOS behavior.
  Local unsigned tests do not complete those checks.
- Check the affected cohort through enrollment, a fresh verified assertion,
  durable evidence and current authorization on the same connection. Repeat
  across a coordinator restart and a bounded archive/identity lookup failure;
  an `eligible` observation alone is insufficient. Qualify the exact signed
  artifact with its full 32-byte CodeDirectory hash. A 20-byte Apple-signed
  CandidateCDHash is usable only when it uniquely binds to that durable
  qualification and passes the other current serving checks.

## Steps

1. Record the current release, coordinator image, configuration and trust controls.
   Deploy the reviewed coordinator with the approved drain procedure in
   [coordinator deployment](coordinator-deploy.md). Verify readiness and successful
   inference on existing provider versions before advancing their release.
2. Verify receipt renewal, appended receipt versions and evidence completeness.
   Keep receipt credentials independent of APNs. Initial `ATTEST` receipts and
   renewed risk receipts have different roles; an initial receipt without a
   risk metric cannot establish serving readiness.
3. Deploy the console separately when presentation changes are included. Check
   source-snapshot counts against the public stats response. A historical label
   or expired browser snapshot is not the current dispatch decision.
4. Build, sign and stage the new provider through [provider release](provider-release.md).
   Qualify and approve its exact bytes, then publish them. Retain older approved
   builds during adoption; a version bump or notarization alone grants no trust.
5. Observe enrollment and assertion outcomes separately by provider version and
   macOS cohort. Distinguish verification, receipt readiness, current App Attest-only /
   dual / legacy authorization, and distinct successfully completed requests.
   Generic native errors do not identify their underlying Apple cause. Compare
   the bounded domain/code diagnostics on upgraded clients before assigning one.
6. Confirm recovery in the affected cohort before claiming an incident resolved.
   Do not infer a verified provider-to-person mapping from a hardware screenshot
   alone. Canonical Darkbloom identities do not prove immutable physical devices.

## Verification

| Gate | Evidence required |
|---|---|
| Enrollment | Failed/interrupted attempts recover under generation budgets; service-unavailable retry preserves its key; cached proofs survive lost replies; expired original transactions reject the proof and retry later without weakening binding checks |
| Assertions | Fresh endpoint-bound signatures and increasing counters; generic errors do not rotate accepted keys; rejected/timed-out work cannot create a grant |
| Receipt/readiness | Valid current receipt and risk metric, healthy renewal, complete accepted-proof blobs; missing/unavailable data remains unknown |
| Mac/build policy | Exact Apple Mac ACL, launch category, Apple-signed type-2 measurement, active release and full-hash durable qualification; test ambiguous/revoked 20-byte candidates, reduced-security and altered-app negatives |
| Identity/revocation | Stable same-account identity after verified reconnect; cross-account/claimed-key negatives; revocation and expiry enforced at every dispatch path |
| Serving | Real completed requests from upgraded App Attest-only, dual and legacy providers; disconnects and failures compared with preceding cohorts |
| Presentation | Public stats explicitly describe their source snapshot; owner controls and MDM-removal readiness remain current and bounded |

For a credential revocation, use the approved administrative
[revocation endpoint](../reference/provider-authorization.md#admin-revocation).
It fences both paths for that credential's current presenters. Build withdrawal
has different semantics; follow the [qualification rollback](app-attest-build-qualification.md#rollback).
Never delete evidence or reset counters to make a provider appear healthy.

## Rollback

Prefer the approved compatible coordinator/provider rollback for a regression.
Disabling `EIGENINFERENCE_APP_ATTEST_SHADOW` alone does **not** stop exchanges or
serving when `EIGENINFERENCE_APP_ATTEST_SERVING` remains enabled: the serving path
also needs fresh proofs. Disabling MDM-removal readiness alone prevents further
removal guidance and does not remove existing serving permission.

If the operator explicitly approves stopping all new App Attest exchanges,
both shadow and serving controls must be disabled through the configuration and
deployment procedure. This also removes the App Attest serving path; providers
without independently valid legacy authorization lose public-serving eligibility.
Inventory, durable evidence and receipt maintenance remain separate. Retain
aliases, counters, qualifications, revocations and all original receipt failures.
Code: `coordinator/appattest/service/session.go` (`startAppAttestShadow`) and
`coordinator/appattest/service/config.go` (`ConfigFromEnvironment`).

## Related

- [Current protocol, storage and recovery](../reference/app-attest-shadow.md)
- [Serving and administrative contracts](../reference/provider-authorization.md)
- [Provider release sequence](provider-release.md)
- [2026-09-22 recovery investigation](../reports/2026-09-22-app-attest-recovery.md)
