# Qualify and publish a signed App Attest build

> Last updated: 2026-09-20 · commit `3b1b6a476`

Use this runbook to approve an exact signed provider artifact before users can update to it. Approval persists across coordinator restarts and refreshes without a hotswap. The [authorization reference](../reference/provider-authorization.md) owns serving controls and freshness deadlines.

## When to use

Every production provider publication, including a retry after missing qualification. A CI build or notarization success alone does not qualify App Attest serving.

## Prerequisites

- Human authorization for the release and build qualification; administrator access to the coordinator through a verified Privy session (including `scripts/admin.sh login`) or admin key. The CI release key and admin-owned inference/provider credentials cannot approve builds.
- Deploy the coordinator implementing `coordinator/api/app_attest_publication.go` and the additive `app_attest_build_qualifications` table before using the updated publication workflow. All serving coordinators and rollback images must understand durable qualification and revocation.
- Complete the signed-artifact, actual Apple proof, hardware-security transition, supported older-macOS, and inference checks in [MDM-optional rollout](mdm-optional-rollout.md#prerequisites). Record actual test evidence; a hash mapping is not evidence that those tests ran.
- Preserve existing qualified env pairs during the initial transition. They remain a compatibility fallback for existing builds without a durable row, only while the qualification store is readable and fresh. They cannot approve a new gated publication and never override a durable revocation.

## Steps

1. Start the source-matching tagged [provider release](provider-release.md). Compilation and SDK checks remain parallel. The signing job notarizes and smokes the final app, then retains the exact bytes and metadata in a GitHub artifact for 30 days. A separate Linux `stage-release` job downloads that retained artifact and uploads it under `releases/v<VERSION>/artifacts/<BUNDLE_SHA256>/darkbloom-bundle-macos-arm64.tar.gz`. If downloading or uploading fails, rerun the failed staging job to reuse the same signed bytes; do not rerun successful signing. It does not advance latest aliases, register a release, or create a GitHub Release.
2. Download the `provider-publication-<SOURCE_SHA>-<SIGNING_ATTEMPT>` artifact named in the signing job outputs. Review `release-payload.json`, `qualification-request.json`, and the final signed bundle. Confirm the source commit, CI run, binary/bundle/metallib hashes and full CodeDirectory SHA-256. Use `CandidateCDHashFull sha256` from the final executable, not the truncated `CDHash`, and compare it with the current verified Apple assertion measurement.
3. Wait for **Stage retained signed artifact in R2** to succeed, then complete qualification against these exact bytes. Put the test report/reference and operator confirmation in the template's `evidence` field. Submit the template using an administrator credential:

   ```bash
   curl --fail-with-body --request POST "$COORDINATOR_URL/v1/admin/app-attest/builds" \
     --header "Authorization: Bearer $DARKBLOOM_ADMIN_TOKEN" \
     --header 'Content-Type: application/json' \
     --data-binary @qualification-request.json
   ```

   A 200 response confirms durable approval and local policy readiness. This does not publish the release or turn on serving/removal. A 503 after persistence is retryable with the same body; a conflicting identity returns 409. To import a previously published build, construct the same body from its original signed release and original source/run provenance; keep its existing URL.
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
