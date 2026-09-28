# Publish new weights for an existing model

> Last updated: 2026-09-28 · commit `b788194f0`

Use this runbook to change an existing model's weights while keeping its model
ID, pricing and aliases. The [revision architecture](../architecture/model-revisions.md)
explains staging, draining, retained hashes and failure recovery.

## When to use

Use a new revision for replacement weights, tokenizer/config updates or an
embedded MTP checkpoint under an existing model ID. For a new model ID or a
quantization exposed as a separate build, use [model migration](model-migration.md).
Overwriting an already published R2 revision is rejected.

## Prerequisites

- The model already has an active registry entry. Qualify the new checkpoint's
  engine compatibility, memory, output and MTP behavior separately; an upload
  succeeding is not a model-quality verdict.
- Deploy the coordinator support and release the provider support once. Macs
  must advertise `model_revisions_v1` for automatic same-ID updates.
- Configure AWS CLI credentials for the R2 bucket and
  `MODEL_REGISTRY_PUBLISHING_KEY` for the selected coordinator. The command takes
  the R2 endpoint explicitly or through `R2_ENDPOINT`.
- Use a complete, stable local checkpoint directory; do not modify its files
  during hashing/upload. Keep old R2 revisions and provider snapshots for rollback.
- Exercise this flow on dev first. Production publication, promotion or
  retirement requires approval for that specific operation.

## Steps

1. Read the existing catalog entry and save its version and hash before selecting
   replacement bytes. The [Nemotron Lightning rollout](cache-routing-rollout.md#widen-the-plan-gate-and-add-nemotron-lightning-and-bonsai-2)
   uses the catalog ID `nvidia-nemotron-3.5-lightning`; confirm that ID and its
   active entry on the selected coordinator. A Hugging Face repository name is
   a download source and does not replace the catalog ID.

   ```bash
   REVISION_COORDINATOR=https://api.dev.darkbloom.xyz
   REVISION_MODEL_ID=nvidia-nemotron-3.5-lightning
   curl --fail --silent --show-error \
     "${REVISION_COORDINATOR}/v1/models/catalog/${REVISION_MODEL_ID}" \
     --output /tmp/nemotron-catalog-before.json
   python3 -m json.tool /tmp/nemotron-catalog-before.json
   ```

   Retain the returned `version`, `aggregate_sha256`, `r2_prefix` and any
   `hugging_face_artifact` for verification and rollback. Choose and qualify the
   exact replacement checkpoint independently; the commands below leave its
   local path and optional pinned HF source explicit.

2. Preview the publication. This hashes locally and makes no remote changes:

   ```bash
   python3 scripts/publish-model-revision.py publish /path/to/qualified-checkpoint "$REVISION_MODEL_ID" \
     --coordinator "$REVISION_COORDINATOR" \
     --endpoint https://ACCOUNT.r2.cloudflarestorage.com \
     --version candidate-YYYYMMDD-r1 --dry-run
   ```

3. Run the same command without `--dry-run` to reserve the R2 prefix, upload
   files and the final manifest, then invoke the authenticated
   `publish-revision` registry action. Omit `--version` to generate a unique
   timestamp/UUID version. Retry with the same version and identical files to
   resume an interrupted publication.

   To use a different HF source for this revision, add these flags to both the
   preview and publication commands:

   ```bash
   --hf-repo-id EigenLabs/model-revision-v2 \
   --hf-revision <full-lowercase-40-character-commit-SHA> \
   --hf-path-prefix mlx/q4
   ```

   The path prefix is optional. The pinned HF repo must contain this revision's
   exact manifest files and bytes. Providers try that HF source first, verify
   checksums, and fall back to R2 if it is unavailable or incorrect. Every
   new version can specify a different repo, commit and subdirectory. Omitting
   the HF flags for a new version makes it R2-only; a source is never inherited
   from another version. Retrying an existing version preserves its stored
   source, including R2-only, even if the flags are omitted or changed. Use
   [normal registration](model-migration.md#2-register-the-build-in-the-coordinator-catalog)
   for an intentional mirror edit on an existing version.

   The action preserves model metadata, upstream `hugging_face_id` and pricing,
   and records the initial authenticated publisher in `uploaded_by`. Identical
   retries keep the original `uploaded_by` and `uploaded_at`, and the stored
   download source. The coordinator
   checks the R2 manifest and file sizes before promotion; providers check file
   and aggregate SHA-256 hashes for either source. If publication returns 503
   after promotion, retry with the same version and HF flags until the live
   catalog refresh and desired-state delivery succeed. A provider send failure
   can return 503 even after the durable promotion and live catalog have changed;
   do not treat that response as a rollback.

4. Let eligible providers download while serving their existing revisions.
   Providers then stagger their model-scoped drains, switch snapshots and
   announce the new hash through `models_update`. No per-model binary release,
   alias edit or manual fleet download command is needed after support is installed.

5. If this model participates in cache routing, qualify and derive the new
   `(model_id, model_aggregate_sha256, prompt_contract_id)` tuple using the
   [cache-routing rollout](cache-routing-rollout.md#widen-the-plan-gate-and-add-nemotron-lightning-and-bonsai-2).
   Append it to `EIGENINFERENCE_CACHE_ROUTING_ALLOWED_ARTIFACTS` through that
   runbook's separately approved deployment step. Keep tuples for retained
   approved revisions during convergence and rollback. Promotion does not update
   the allowlist, and a changed weight hash needs a new tuple even when its
   tokenizer and prompt contract remain identical.

## Verification

- Read `GET /v1/models/catalog/{model_id}` and
  `GET /v1/models/catalog/manifest/{model_id}`. Confirm `version`, `r2_prefix`
  and `aggregate_sha256` match the published manifest and that the catalog ID,
  pricing and aliases remain the intended ones.
- Check provider logs for `model revision:` and the exact model/version.
  `outcome=installed` follows activation and advertisement; download progress
  alone does not prove a loaded replacement. Check heartbeat slot state and
  signed model hashes for resident-model verification.
- Compare connected providers' advertised hashes with the desired hash,
  separating old approved revisions, updated advertisements, loaded slots,
  offline providers and providers lacking revision support.
- Exercise inference before/during/after the switch, including accepted streams,
  a failed download, cancellation, a newer promotion and rollback. There is no
  guaranteed zero-gap rollout for a model with only one available provider.
- The fixture suites cover filesystem publication, cold activation, cancellation,
  drain ownership and coordinator/store behavior. A real large-checkpoint swap
  and fleet availability remain separate pilot qualification gates.

## Rollback

Use the existing authenticated `POST /v1/admin/models/{model_id}/promote` with
`{"version":"previous-version"}`. Providers receive its hash as desired state
and use the retained snapshot when available. Previously approved, non-retired
revisions remain acceptable during that convergence. Rollback does not restore
model metadata changes made separately through other admin actions. If promotion
returns 503 with `Retry-After: 5`, its storage change may already be committed;
retry the same previous version until the live catalog refresh and desired-state
delivery succeed.

Retirement is a separate, explicit operation after checking fleet adoption:
`POST /v1/admin/models/{model_id}/retire-revision` with `{"version":"old-version"}`.
The active version cannot be retired. Re-registering a retired version does
not reactivate it; publish a new version to approve its bytes again.
Retirement revokes the old hash for routing
and challenge validation, including returning offline providers; do not use it
as automatic storage cleanup. It does not delete R2 or provider files.
If retirement returns 503 after its storage write, retry the same operation;
revocation is not complete until the live routing policy refresh succeeds.

## Related

- [Coordinator deployment](coordinator-deploy.md)
- [Provider release](provider-release.md)
- [Model revision design](../architecture/model-revisions.md)
- [Cache-routing rollout](cache-routing-rollout.md)
