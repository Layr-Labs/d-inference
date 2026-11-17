# Publish new weights for an existing model

> Last updated: 2026-11-10

Use this runbook to change an existing model's weights while keeping its model
ID, pricing and aliases. The [revision architecture](../architecture/model-revisions.md)
explains staging, draining, retained hashes and failure recovery.

## When to use

Use a new revision for replacement weights, tokenizer/config updates or an
embedded MTP checkpoint under an existing model ID. For a new model ID or a
quantization exposed as a separate build, use [model migration](model-migration.md).
Overwriting an already published R2 revision is rejected.

### Choose the operation first

| State | Operation | Credentials |
|---|---|---|
| New model ID with a valid, already published canonical manifest | Register the build using [model migration](model-migration.md#2-register-the-build-in-the-coordinator-catalog) | Coordinator publishing key |
| Existing model ID with a valid, already published new revision | Set `publish_revision_only=true` and `promote=true` in **Register Model** | Coordinator publishing key |
| Missing files, changed bytes, wrong manifest inventory or noncanonical prefix | Publish a new immutable revision, then register or promote it | Model-bucket upload credentials plus coordinator publishing key |

A public download URL proves read access, not bucket write permission. Conversely,
an R2 write failure does not prevent registering a valid existing upload. Check
the model ID, version, canonical prefix and complete serving inventory before
choosing a path. Keep optional assistant checkpoints outside the base inventory
unless the runtime explicitly supports their combined layout.

The coordinator validates the canonical manifest and file sizes; providers verify
the file hashes. A backup manifest at another prefix cannot be submitted as an
arbitrary manifest URL through the standard registration API. Publish a new
canonical revision when its identity or inventory differs; do not make direct
database edits part of the routine workflow.

## Prerequisites

- The model already has an active registry entry. Qualify the new checkpoint's
  engine compatibility, memory, output and MTP behavior separately; an upload
  succeeding is not a model-quality verdict.
- Confirm the external platform already supports the revision API and Macs
  advertise `model_revisions_v1` for automatic same-ID updates. Backend
  deployment is owned by the platform and is not part of this runbook.
- Configure `MODEL_REGISTRY_PUBLISHING_KEY` for the selected coordinator.
- For uploads only, configure AWS CLI credentials for the **model bucket** and
  its matching account endpoint. The command takes the endpoint explicitly or
  through `R2_ENDPOINT`. Release-artifact credentials and the account selected
  in a browser are not evidence of access to `darkbloom-models`.
- For uploads from local files, use a complete, stable checkpoint directory and
  do not modify it during hashing/upload. Keep old R2 revisions and provider
  snapshots for rollback. An already published revision needs no local checkpoint.
- Exercise this flow on dev first. Production publication, promotion or
  retirement requires approval for that specific operation.

### Check upload access before moving bytes

Confirm the endpoint, bucket and credential source with the bucket owner. Keep
credentials out of terminal output, reports and commits. The endpoint is the
account URL, without a bucket path appended. With credentials already configured,
check one known object in the actual model bucket:

```bash
aws s3api head-object --bucket darkbloom-models \
  --key "$KNOWN_MODEL_MANIFEST_KEY" --endpoint-url "$R2_ENDPOINT" \
  --query '{bytes:ContentLength,etag:ETag}'
```

`AccessDenied` or HTTP 403 is an access/configuration failure, not evidence that
the model is missing. Stop and correct that tuple instead of trying unrelated
accounts or assuming release CI credentials have model-bucket access. This read
check does not prove write permission; the normal conditional revision reservation
is the first authorized write. A timeout leaves the outcome uncertain: inspect
the destination and any running publisher before resuming the same reserved
version with identical bytes.

## Steps

1. Read the existing catalog entry and save its version and hash before selecting
   replacement bytes. The [Nemotron Lightning rollout](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/cache-routing-rollout.md#widen-the-plan-gate-and-add-nemotron-lightning-and-bonsai-2)
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

2. If an upload is needed, preview it. This hashes locally and makes no remote
   changes. For an already published revision, use the workflow mode in step 3:

   ```bash
   python3 scripts/publish-model-revision.py publish /path/to/qualified-checkpoint "$REVISION_MODEL_ID" \
     --coordinator "$REVISION_COORDINATOR" \
     --endpoint https://ACCOUNT.r2.cloudflarestorage.com \
     --version candidate-YYYYMMDD-r1 --dry-run
   ```

3. To upload, run the same command without `--dry-run` to reserve the R2 prefix, upload
   files and the final manifest, then invoke the authenticated
   `publish-revision` registry action. Omit `--version` to generate a unique
   timestamp/UUID version. Retry with the same version and identical files to
   resume an interrupted publication.

   If the revision is already uploaded, the **Register Model** GitHub workflow
   accepts `publish_revision_only=true` with `promote=true`. It invokes `publish-revision` with the
   version and optional pinned HF artifact, preserving model metadata and prices.
   It uses only `MODEL_REGISTRY_PUBLISHING_KEY`; it does not need R2 credentials
   or a local GCP login. Registration-only inputs are optional at dispatch and
   ignored in this mode; normal registration validates them before sending.
   Revision-only publication always promotes; leaving `promote=false` fails
   before any HTTP request. Use normal registration for a staged-only build.
   Keep `publish_revision_only=false` for normal registration.

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
   catalog and alias refresh and desired-state delivery succeed. An alias read or provider send failure
   can return 503 even after the durable promotion and live catalog have changed;
   do not treat that response as a rollback. An alias refresh failure retains the
   last loaded alias map and does not fan out desired state from that stale map.

4. Let eligible providers download while serving their existing revisions.
   Providers then stagger their model-scoped drains, switch snapshots and
   announce the new hash through `models_update`. No per-model binary release,
   alias edit or manual fleet download command is needed after support is installed.

5. If this model participates in cache routing, qualify and derive the new
   `(model_id, model_aggregate_sha256, prompt_contract_id)` tuple using the
   [cache-routing rollout](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/cache-routing-rollout.md#widen-the-plan-gate-and-add-nemotron-lightning-and-bonsai-2).
   Append it to `EIGENINFERENCE_CACHE_ROUTING_ALLOWED_ARTIFACTS` through that
   runbook's separately approved deployment step. Keep tuples for retained
   approved revisions during convergence and rollback. Promotion does not update
   the allowlist, and a changed weight hash needs a new tuple even when its
   tokenizer and prompt contract remain identical. Until it is appended the
   model has no cache routing: `artifact_allowlist.stale_models` in
   `GET /v1/cache/status` counts it and the coordinator log names the exact
   tuple ([stale entries](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/cache-routing-rollout.md#stale-entries-after-a-model-revision)).

## Re-quantize and upload from CI

The **Model Requant Upload** workflow (`.github/workflows/model-requant-upload.yml`)
uploads a re-quantized revision of an existing model with the repository's R2
credentials, without anyone handling them. It rebuilds the revision on the runner
with `scripts/models/requant.py`. That script re-quantizes the language-model
linears from the pinned bf16 source and copies every other byte of the current
revision: vision tower, MTP head, norms and tokenizer files. The workflow then
compares the result byte for byte with the canonical manifest of the candidate
that was built and qualified locally. It never registers or promotes.

Dispatch it from `master` only:

```bash
gh workflow run model-requant-upload.yml --ref master -f mode=check \
  -f model_id=… -f version=… -f recipe=… -f template_url=… -f source_url=… \
  -f manifest_json="$(cat manifest.json)" [-f keys=legacy|prod]
```

A run on any other ref stops at its first step, so the bytes are always checked
by the reviewed code. Run one dispatch at a time: a third dispatch while one runs
replaces the pending second (GitHub's concurrency rule).

It runs two jobs:
- **`preflight`** holds no secret. It runs the ref guard, validates the inputs,
  installs the hash-pinned tools and runs the quantizer's selftest.
- **`requant-upload`** runs in the **`prod` environment**, with three modes.
  - **Approval:** every run waits for Gajesh2007's approval of the `prod`
    environment, after `preflight` passes. He is its required reviewer, and
    admins can't bypass it. No step with a key starts before the approval.
    This workflow adds no other gate.
  - **Branch policy:** the environment's deployment policy allows `master`,
    `v*` branches and `v*` tags. The workflow's ref guard narrows that to
    `master`, but only in the copy of the workflow it runs.
  - **Keys:** only a job in that environment can see its `PROD_R2_*`
    secrets. The gate protects only secrets created in `prod`. The
    repository's `R2_*` stay readable by any workflow a writer pushes.
  - **Environment settings, for the repository owner:**
    - Drop the `v*` branch rule from `prod`'s deployment policy; nothing uses
      it.
    - Create any future `PROD_R2_*` inside `prod`, not as repository secrets.
    - Never add `R2_*` to `prod`. Same-named environment secrets would
      silently replace the repository's `R2_*` that `keys=legacy` uses.

Two R2 key sets are tested:
- **`legacy`**: the repository's `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY` and
  `R2_ENDPOINT`. `release-provider.yml` falls back to these when `PROD_R2_*` is
  empty, and the 0.10.11 production release used them for every key.
- **`prod`**: `PROD_R2_ACCESS_KEY_ID`, `PROD_R2_SECRET_ACCESS_KEY` and
  `PROD_R2_ENDPOINT`. They were absent from the `prod` environment on
  2026-11-10.

`upload` uses the set named by the `keys` input (default `legacy`).

1. **Locally.**
   - Install the tools the workflow installs, by hash. numpy 2.5.4 needs
     Python 3.12 or later:
     `pip install --require-hashes --only-binary :all: -r scripts/models/requirements-requant-upload.txt`.
   - Run `python3 scripts/models/requant.py selftest`. It takes about a second
     and must print `selftest ok`.
   - Build the candidate with the same script and recipe, with no
     `--shard-gb` or `--base-group`. Nothing may write into the folder
     afterwards.
   - Qualify it: load, quality and speed.
   - Hash it with `darkbloom-publish hash … --id <model> --version <new version>`,
     and hash it again after qualification to confirm nothing changed. The
     resulting `manifest.json` is the workflow's `manifest_json` input, and its
     aggregate is the new cache-routing tuple's.
2. **Dispatch in mode `check`** (the default) and approve it. It runs the
   selftest on the runner, then tests both key sets with a read-only
   `head-object` of the template's `manifest.json` in `darkbloom-models`.
   - **What it prints:** only one verdict per set, for example
     `keys legacy (R2_*): pass` or `keys prod (PROD_R2_*): absent`:
     - `pass` or `fail`;
     - `absent` when every part of the set is empty. That is not a failure of
       the run;
     - `fail (incomplete)` when only some parts are empty.

     An absent or incomplete set runs nothing.
   - **When it fails:** if no set passes, or, in `upload` mode, if the `keys`
     set did not pass.
   - **Why:** release-bucket credentials are not necessarily model-bucket
     credentials.
3. **Dispatch in mode `build`** for the first model. It rebuilds and verifies
   with no write. The output depends only on the template revision, the pinned
   source, the recipe and numpy, so a difference in any file stops the run. Once
   one model has matched, `upload` alone is enough for the next ones: it rebuilds
   and verifies before any write.
4. **Dispatch in mode `upload`** with `confirm_version` set to the version and
   `keys` set to a set that passed `check`. The upload step holds only that
   set. It refuses unless that set passed this run's check and no part of it is
   empty. It makes the conditional reservation (`publish-model-revision.py`'s
   rule, so an existing revision with other bytes is refused), uploads the
   files, then the manifest last. Each object is public at `models.darkbloom.ai` once it lands,
   but nothing selects the revision until it is registered.
5. **Promote separately**, on its own approval: **Register Model** with
   `publish_revision_only=true` and `promote=true`.

Inputs are validated before any credential is in scope:
- the template must be `https://models.darkbloom.ai/v2/<slug>--<12 hex>/<version>`,
  a revision of the same model ID;
- the source must be pinned to a 40-character Hugging Face commit;
- the recipe must be `g32`, `mixed46`, `router8` or `router8+mixed46`;
- the version must be one path component that does not start with `.`;
- the manifest must be one that Register and every provider read, and its ID,
  version and canonical `r2_prefix` must match. The manifest checks are:
  - schema 1 and integer counts;
  - `created_at` in `darkbloom-publish hash`'s form (`YYYY-MM-DDTHH:MM:SSZ`). Register
    accepts a manifest without it, but providers cannot decode one;
  - `file_count`, the total and the aggregate recomputed from the file digests;
  - unique paths (ignoring case), with no hidden, empty, `.` or `..` parts;
  - each file's role is the one `darkbloom-publish` assigns.

**If the selftest or `build` ever reports a difference, do not loosen the check**,
change the recorded digests to pass, or upload the runner's bytes as the tested
ones. The fallback moves the locally qualified bytes instead:
1. Stage them at a pinned Hugging Face commit.
2. Download them in CI.
3. Verify them against the same manifest.
4. Reserve and upload them.

The registry already records a revision's `hugging_face_artifact`.

Tests: `python3 -m unittest discover -s scripts/models -p 'test_*.py'`
([model publication workflow checks](../developer/test.md#model-publication-workflow-checks)).

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

- [Coordinator deployment](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/coordinator-deploy.md)
- [Provider release](provider-release.md)
- [Model revision design](../architecture/model-revisions.md)
- [Bonsai 9B publication incident](../reports/2026-10-15-bonsai9b-publication.md)
- [Cache-routing rollout](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/operations/cache-routing-rollout.md)
