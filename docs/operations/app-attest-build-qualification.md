# Qualify and publish a signed App Attest build

> Last updated: 2026-09-24 · commit `b6f9574ed`

Use this runbook to approve an exact signed provider artifact before users can update to it. Approval persists across coordinator restarts and refreshes without a hotswap. The [authorization reference](../reference/provider-authorization.md) owns serving controls and freshness deadlines.

## When to use

Every production provider publication, including a retry after missing qualification. CI signing alone does not qualify App Attest serving.

## Prerequisites

- Human authorization for the release and build qualification; administrator access to the coordinator through a verified Privy session (including `scripts/admin.sh login`) or admin-session key. The CI release key cannot approve builds.
- Deploy the coordinator implementing `coordinator/api/app_attest_publication.go` and the `app_attest_build_qualifications` table. All serving coordinators and rollback images must understand durable qualification and revocation.
- Complete the signed-artifact, actual Apple proof, hardware-security transition, supported older-macOS, and inference checks in [MDM-optional rollout](mdm-optional-rollout.md#prerequisites). Record actual test evidence; a hash mapping is not evidence that those tests ran.

## Steps

1. Start the source-matching tagged [provider release](provider-release.md). Build and qualification jobs run in parallel on CI. After signing succeeds, the independent `stage-release` job (Linux) downloads the retained signed artifact, verifies its digest, and uploads to `releases/v<VERSION>/artifacts/<BUNDLE_SHA256>/darkbloom-bundle-macos-arm64.tar.gz`. Do not rerun successful signing; a new signature timestamp changes the artifact identity and requires new approval.

2. After R2 staging succeeds, the workflow runs independent qualification validators on the retained bytes. Two jobs run in parallel:
   - `validate-macos-27` (xcode-27 runner)
   - `validate-older-macos` (blacksmith-12vcpu-macos-latest runner)

   Each runs the qualification validator:

   ```bash
   python3 scripts/provider-release-qualify.py --directory <dir> \
     --lane macos-27 --level static,smoke,live --output qualification-result-macos-27.json
   ```

   Replace `macos-27` with `older-macos` for the older-macOS lane. Static and smoke checks run on both lanes. Live checks (`app-attest`, `inference`, `graceful-drain`, `accounting`) require `DARKBLOOM_QUALIFY_LIVE=1` plus `DARKBLOOM_QUALIFY_COORDINATOR`, `DARKBLOOM_QUALIFY_PROVIDER_ID`, and `DARKBLOOM_QUALIFY_API_KEY` (enrolled provider credentials only). CI also runs static and smoke checks and uploads `provider-qualification-<lane>-<source_sha>-<run_attempt>` artifacts.

3. After staging and validation jobs complete, download the `provider-publication-<SOURCE_SHA>-<SIGNING_ATTEMPT>` artifact from the signing job. Review `release-payload.json`, `qualification-request.json`, and the signed bundle. Confirm source commit, CI run, binary/bundle/metallib hashes and full CodeDirectory SHA-256. Use `codesign -d --verbose=4` to extract `CandidateCDHashFull sha256` from the final executable, not the truncated `CDHash`.

4. Run the evidence aggregation script to record qualification results and operator attribution:

   ```bash
   python3 scripts/provider-release-publication.py evidence \
     --directory <dir> \
     --result qualification-result-macos-27.json \
     --result qualification-result-older-macos.json \
     --operator '<your name>' \
     --exception macos-27:live='prod integration not available' \
     --exception older-macos:live='prod integration not available'
   ```

   Only failed checks cannot be excepted; exceptions render as `EXCEPTION ... NOT RUN` in the evidence string. The tool generates `qualification-evidence.json` alongside an updated `qualification-request.json`.

5. Approve the build using admin credentials:

   ```bash
   curl --fail-with-body --request POST "$COORDINATOR_URL/v1/admin/app-attest/builds" \
     --header "Authorization: Bearer $DARKBLOOM_ADMIN_TOKEN" \
     --header 'Content-Type: application/json' \
     --data-binary @qualification-request.json
   ```

   A 200 response confirms durable approval and local policy readiness. A 503 after persistence is retryable with the same body; a conflicting identity returns 409. To import a previously published build, reconstruct the body from its original signed release and source/run provenance; keep its existing URL.

6. Approve the environment-protected **Publish qualified signed release** job. If it stopped with `app_attest_qualification_required`, use **Re-run failed jobs**. The publish job downloads the retained artifact, verifies its digest, checks approval via `POST /v1/releases/qualification`, polls the coordinator for up to `QUALIFICATION_WAIT_MINUTES` (default 60) until approved, then calls `POST /v1/releases`, updates R2 latest aliases, and creates the GitHub Release. An older staged version never overwrites a newer latest alias. Partial publication retries resume from an incomplete draft; completed mismatched assets are never overwritten.

7. The new `verify-release` job runs after publication to validate `/v1/releases/latest`, both latest aliases, and the GitHub release asset (prod only).

## Verification

- `GET /v1/admin/app-attest/builds` lists exact identities, operator attribution, approval time, evidence and any permanent revocation record.
- Missing approval, altered binary/code/bundle/metallib, source/run mismatch or revoked approval must leave the previous latest release unchanged. The registration transaction locks the qualification row; a concurrent revocation cannot be bypassed by an earlier in-memory check.
- Active catalog membership and the qualified runtime must agree. Cached latest-download and version responses also check current qualification and catalog readiness. Unknown/stale readiness returns 503 rather than advertising an unauthorized build.
- After publication completes, `verify-release` validates `/v1/releases/latest`, both `releases/latest/` aliases, and (on prod) the GitHub release asset against the registered hashes. This workflow does not enable MDM removal, change rewards, configure Stripe, change model/cache policy, or grant trust from CI metadata.

## Rollback

To withdraw only App Attest qualification, submit `{"binary_hash":"<SHA256>","reason":"<operator reason>"}` to `POST /v1/admin/app-attest/builds/revoke` with admin-session authentication. The accepting coordinator fences stale grants before returning; other coordinators stop extending affected leases within the 30-second qualification freshness ceiling. Already delivered work cannot be recalled. Revocation is permanent for a binary hash, including across restarts. Preserve the original approval evidence. Publish a separately reviewed signed build to recover from a withdrawn build; use an already approved older release for an operational rollback.

## Related

- [Provider release pipeline](provider-release.md)
- [Provider authorization and admin contracts](../reference/provider-authorization.md)
- [Storage model](../architecture/storage.md)
- [Coordinator deploy and rollback](coordinator-deploy.md)
