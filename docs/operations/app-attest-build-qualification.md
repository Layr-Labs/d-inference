# Qualify and publish a signed App Attest build

> Last updated: 2026-10-11

Use this runbook to approve an exact signed provider artifact before users can update to it. Approval persists across coordinator restarts and refreshes without a hotswap. The [authorization reference](../reference/provider-authorization.md) owns serving controls and freshness deadlines.

## When to use

Every production provider publication, including a retry after missing qualification. A CI build or notarization success alone does not qualify App Attest serving.

## Linked automation status

The linked workflow uses dispatch across the public-provider/internal-platform
boundary. **The linked PRs
are not production-ready without provisioning and qualifying the real hardware
service and receipt issuer.** This change does not establish a successful
hardware run, a deployed qualification endpoint, credentials, runner registration
or GitHub settings. Missing infrastructure must fail, never skip a required gate.
The coordinator implementation and independent qualification tools belong to
`Layr-Labs/darkbloom-platform`, not the retained backend copy in this repository.

The linked flow is:

1. Retain and stage the final signed bundle and payload/provenance from the exact
   signing run/attempt, without advancing latest.
2. Run both signed-artifact static lanes on macOS 27 and macOS 26 using
   `scripts/provider-release-qualification.py`. Retain each candidate-bound report,
   evidence digest and producing workflow attempt.
3. Dispatch and poll the internal platform's `provider-release-qualification.yml`
   at the configured protected tag and expected commit. Platform preflight checks
   its own signed platform tag/source and the exact provider signed tag, source
   and producing run. Its isolated hardware runner
   runs the exact candidate against a preprovisioned local coordinator fixture,
   requiring actual App Attest, encrypted inference, idle restart/reconnect and
   post-restart inference observations.
4. Require the independent HTTPS hardware service to execute actual tamper/replay
   and security-transition tests. Its trusted issuer signs a fresh nonce,
   candidate identity, qualification run/attempt, policy, validity interval and
   evidence digests. Unavailable hardware/service or missing receipts fail the job;
   candidate-generated pass flags are not evidence.
5. In a separate Linux job, the platform finalizer validates the exact retained
   artifacts, all seven gates and original report producer attempts. Only this
   job receives the qualification Ed25519 private key and scoped release key.
   It runs no candidate binary or candidate-selected script and submits the
   signed envelope to `POST /v1/releases/qualify`; no admin key is used.
6. Only successful qualification allows the existing provider publication job
   to register the release and update R2/GitHub publication.

The exact mandatory names are `signed_bundle`, `app_attest`,
`encrypted_inference`, `lifecycle`, `tamper_replay`, `security_transitions`, and
`older_macos`. Every check needs passed evidence; there are no skips, waivers or
alternate check sets. Static macOS compatibility and notarization do not prove
Apple enrollment or physical security transitions.

One-time setup requires an independently controlled dedicated hardware runner,
preprovisioned trusted fixture/model/Apple inputs, an actual hardware-test service
and trusted hardware-issuer keys, plus separate finalizer key custody and the
coordinator's optional public-key/policy configuration. Candidate/build/signing
jobs never receive the qualification private key. Follow the
[platform setup and receipt contract](https://github.com/Layr-Labs/darkbloom-platform/blob/master/docs/operations/app-attest-build-qualification.md),
including the distinction between nonce-bound hardware receipts and the final
coordinator envelope. Validate the protected platform dispatch tag and expected
commit before activation; placeholder or mismatched pins are rejected. The source
is not a completed infrastructure rollout.

`d-inference` is public and `darkbloom-platform` is internal, so a direct reusable
workflow call is not supported. Provider CI uses
`PLATFORM_QUALIFICATION_DISPATCH_TOKEN`, a fine-grained platform Actions
read/write token, plus `PLATFORM_QUALIFICATION_REF` (`qualification/v1`, a protected short tag name,
not `refs/tags/...` or a raw SHA) and
`PLATFORM_QUALIFICATION_SHA` (expected commit), to dispatch and poll. Internal
source is never copied into this public repository. The platform workflow uses
its own token to check out internal source and a separate
`PROVIDER_ACTIONS_READ_TOKEN` with only `d-inference` Actions read to download
public provider artifacts. Neither cross-repository token grants coordinator
admin or signing authority.

Platform preflight accepts signed annotated `qualification/vN` tags (`N >= 1`)
pointing at its exact `GITHUB_SHA`; the verified source commit must be an
ancestor of platform `master`. The workflow checks out its own `github.sha`.
An approved operator must establish the protected tag and configure
`PLATFORM_QUALIFICATION_SHA` to the expected merge/tag commit. No tag or GitHub
setting is created by this source change.

`scripts/provider_release_qualification/dispatch.py` sends a fresh random
32-hex `request_id` and compact JSON `request` to the platform dispatch endpoint,
then finds `Provider qualification <request_id>`. It checks the observed run's
repository, workflow path, `workflow_dispatch` event, expected commit and start
time, and requires one unambiguous correlation before accepting success. Polling
is bounded to 55 minutes with 15-second intervals; timeout, ambiguity, failure or
identity mismatch leaves publication blocked. Dispatch runs under the provider's
existing protected `prod` / `dev` environment; no protection setting is changed.

The dispatched workflow executes in `darkbloom-platform`. An approved operator
must provision the following environments in that platform repository:
`provider-qualification-hardware-dev` / `provider-qualification-hardware-prod`
to protect the dedicated trusted runner and supply its matching
`RELEASE_QUALIFICATION_POLICY` variable, and
`provider-qualification-finalizer-dev` / `provider-qualification-finalizer-prod`
with only `QUALIFICATION_SIGNING_SEED` (base64 raw 32-byte Ed25519 seed) and
`RELEASE_KEY` secrets plus `COORDINATOR_URL` and `RELEASE_QUALIFICATION_POLICY`
variables. Do not pass provider secrets to the dispatched workflow or expose the
seed to candidate/build/hardware jobs. Deploying the coordinator public-key and
policy configuration is a separate approved operation. The independent hardware
service is not provisioned here; its absence deliberately blocks qualification.

Provision the protected root-owned output parent
`/private/var/db/darkbloom-qualification/runs/` on the hardware runner. Reports
and evidence go into `<run>-<attempt>` beneath it, not `RUNNER_TEMP` or another
candidate-writable ancestor. This separates authoritative results from the
temporary candidate download.

The `lifecycle` report currently covers idle stop/restart, reconnect and
post-restart inference, not continuing authorization renewal, in-flight drain
or cancellation. Those scenarios need separate qualification. The finalizer
also rejects stale or wrong-policy hardware reports; reissuing a fresh final
envelope cannot extend their validity.

Set repository variables `DEV_RELEASE_QUALIFICATION_POLICY` and
`PROD_RELEASE_QUALIFICATION_POLICY` for the static lanes to the corresponding
finalizer/coordinator policy IDs; missing values fail rather than selecting a
fallback policy. The static lanes run on macOS 26 and 27 only. A checked 14.0
deployment target is not proof of runtime qualification on macOS 14.

Authenticated static artifact downloads and candidate checking are separate
steps. The checker runs without the download token; bounded candidate smoke
execution uses `nobody` under a root-controlled default-deny supervisor. The
static sandbox/Metal path has not been run in this change, and its source or
offline tests are not evidence of successful execution on macOS.

Existing global `prod` approvals remain. Release-only automation requires a
separately approved operator change to release-specific environments and their
protection rules; this source change does not remove global reviewers.

## Prerequisites

- Human authorization for release operations. Manual build approval requires an administrator credential; the linked automatic path instead requires the independently configured platform qualification authority. The CI release key alone and admin-owned inference/provider credentials cannot approve builds.
- Deploy the coordinator implementing `coordinator/api/releases/app_attest_publication.go` and the additive `app_attest_build_qualifications` table before using the updated publication workflow. All serving coordinators and rollback images must understand durable qualification and revocation.
- Complete the signed-artifact, actual Apple proof, hardware-security transition, supported older-macOS, and inference checks in [MDM-optional rollout](mdm-optional-rollout.md#prerequisites). Record actual test evidence; a hash mapping is not evidence that those tests ran.
- Preserve existing qualified env pairs during the initial transition. They remain a compatibility fallback for existing builds without a durable row, only while the qualification store is readable and fresh. They cannot approve a new gated publication and never override a durable revocation.

## Steps

1. Start the source-matching tagged [provider release](provider-release.md). Compilation and SDK checks remain parallel. The signing job notarizes and smokes the final app, then retains the exact bytes and metadata in a GitHub artifact for 30 days. A separate Linux `stage-release` job downloads that retained artifact and uploads it under `releases/v<VERSION>/artifacts/<BUNDLE_SHA256>/darkbloom-bundle-macos-arm64.tar.gz`. If downloading or uploading fails, rerun the failed staging job to reuse the same signed bytes; do not rerun successful signing. It does not advance latest aliases, register a release, or create a GitHub Release.
2. Download the `provider-publication-<SOURCE_SHA>-<SIGNING_ATTEMPT>` artifact named in the signing job outputs. Review `release-payload.json`, `qualification-request.json`, and the final signed bundle. Confirm the source commit, CI run, binary/bundle/metallib hashes and full CodeDirectory SHA-256. Use `CandidateCDHashFull sha256` from the final executable, not the truncated `CDHash`, and compare it with the current verified Apple assertion measurement.
3. Wait for **Stage retained signed artifact in R2** to succeed, then complete qualification against these exact bytes. In the linked automatic flow, both static lanes and platform hardware/finalizer jobs must succeed; they submit the signed receipt without an admin token. Manual approval remains available as an explicit separate operation: put the test report/reference and operator confirmation in the template's `evidence` field and submit it using an administrator credential:

   ```bash
   curl --fail-with-body --request POST "$COORDINATOR_URL/v1/admin/app-attest/builds" \
     --header "Authorization: Bearer $DARKBLOOM_ADMIN_TOKEN" \
     --header 'Content-Type: application/json' \
     --data-binary @qualification-request.json
   ```

   A 200 response confirms durable approval and local policy readiness. This does not publish the release or turn on serving/removal. A 503 after persistence is retryable with the same body; a conflicting identity returns 409. To import a previously published build, construct the same body from its original signed release and original source/run provenance; keep its existing URL.

   Retries preserve the original candidate artifact ID/digest and signing
   run/attempt, plus each successful report's own producing run/attempt. Do not
   guess the current attempt, select the newest similarly named artifact, or
   rebuild/re-sign to recover a downstream failure. Expired reports require
   actual tests again and fresh finalization, never timestamp editing. A signed
   receipt cannot revive a permanently revoked build.
4. Approve the environment-protected **Publish qualified signed release** job. If it already stopped with `app_attest_qualification_required`, use **Re-run failed jobs**. Do not rerun successful signing: a new signature timestamp changes the artifact identity and requires a new approval. Publication downloads the retained artifact from the same run, verifies its source/run/version/origin/digest, calls `POST /v1/releases`, checks `/v1/releases/latest`, then updates R2 latest aliases and creates the GitHub Release. An older staged version never overwrites a newer latest alias. Partial publication retries resume a draft left by creation/upload/publish failure: upload missing bytes, repair only an incomplete `starter` placeholder, verify the exact downloaded hash, then publish. Completed mismatched assets are never overwritten. The retained changelog preserves the tag annotation as data.
5. Check the registered release, current serving grants and completed requests by version. Adding approval does not fabricate a new Apple assertion: a never-authorized connection still needs its normal fresh proof/identity flow. Retained qualified proofs can renew on the next five-second authorizer pass while their original assertion deadline remains valid. Keep prior approved versions active during adoption.

## Verification

- `GET /v1/admin/app-attest/builds` lists exact identities, operator attribution, approval time, evidence and any permanent revocation record.
- Missing approval, altered binary/code/bundle/metallib, source/run mismatch or revoked approval must leave the previous latest release unchanged. The registration transaction locks the qualification row; a concurrent revocation cannot be bypassed by an earlier in-memory check.
- Active catalog membership and the qualified runtime must agree. Polling refreshes other coordinators; unchanged policies do not churn generations. Cached latest-download and version responses also check current qualification and catalog readiness. Unknown/stale readiness returns 503 rather than advertising an unauthorized build.
- Verify App Attest-only and legacy providers separately. This workflow does not enable MDM removal, change rewards, configure Stripe, change model/cache policy, or grant trust from CI metadata.

## Rollback

To withdraw only App Attest qualification, submit `{"binary_hash":"<SHA256>","reason":"<operator reason>"}` to `POST /v1/admin/app-attest/builds/revoke` with admin authentication. The accepting coordinator fences stale grants before returning; other coordinators stop extending affected leases within the 30-second qualification freshness ceiling, including during a database outage. Every dispatch path retains its final lease check. Already delivered work cannot be recalled. Complete independent legacy verification remains usable; use the existing admin release-deactivation operation when the artifact itself must be withdrawn from both paths.

Revocation is permanent for a binary hash, including across restarts and stale env settings. Do not delete the row or roll back to a coordinator that ignores it. Preserve the original approval evidence. Publish a separately reviewed signed build to recover from a withdrawn build; use an already approved older release for an operational rollback. A missing approval is resolved by qualification, not by disabling serving gates or silently re-enrolling machines.

## Related

- [Provider release pipeline](provider-release.md)
- [Provider authorization and admin contracts](../reference/provider-authorization.md)
- [Storage model](../architecture/storage.md)
- [Coordinator deploy and rollback](coordinator-deploy.md)
