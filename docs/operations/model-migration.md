# Migrate a public model to a new build

> Last updated: 2026-09-05 · commit `4d9811f7c`

Runbook for moving a public model name (an **alias**, e.g. `gemma-4-26b`) from
one concrete build to another with no downtime and without consumers ever
seeing the quantization. The whole migration is one field: set the alias's
`desired_build`; the coordinator pushes `desired_models` to eligible providers,
each provider prefetches the build in the background and hard-swaps, and
routing prefers the desired build while still accepting the previous one.
Rollback is the same write pointed the other way.

**Run the entire flow on the dev coordinator first** (`https://api.dev.darkbloom.xyz`,
[dev-environment.md](dev-environment.md)) with one or two throwaway providers.
Production alias writes are production mutations and need explicit human
approval for the specific operation.

## When to use

- Cutting a served model over to a new quantization or re-published weights
  (e.g. 8-bit → QAT 4-bit).
- Introducing a public alias in front of a raw HuggingFace build id.
- Reverting such a cutover.

Not for: registering a brand-new model (that is just steps 1–2 plus
`promote`), or changing prices/status of an existing build
(`POST /v1/admin/models/<id>/status`, `…/promote`, `…/runtime-parameters` in
`coordinator/api/model_registry_handlers.go`, `handleAdminModelRegistryAction`).

## Prerequisites

- **Auth.** A publishing key: `MODEL_REGISTRY_PUBLISHING_KEY` (env bootstrap),
  `EIGENINFERENCE_ADMIN_KEY`, or an active row in `publishing_api_keys`
  (`requirePublishingAPIKey`, header `X-Darkbloom-Publishing-Key` or
  `Authorization: Bearer`). The same key authorizes `/v1/admin/models/register`,
  `/v1/admin/models/aliases`, and the per-model actions.
- **Providers that understand `desired_models`.** `fanOutDesiredModels` in
  `coordinator/api/model_alias_handlers.go` only pushes to providers passing
  `providerSupportsDesiredModels(backend, version)`, i.e. version ≥
  `minProviderVersionForDesiredModels = "0.5.17"` (`coordinator/api/server.go`).
  Older providers keep serving whatever they advertise and are never migrated.
- **Coordinator with the retired-resident-build challenge alibi.** After a
  hard-swap the old build is still resident on the provider and may be reported
  as `active_model_hash` at the next challenge; the coordinator accepts any
  catalog-validated hash from `model_hashes` (regression test
  `TestChallengeRetiredResidentBuildHashDoesNotUntrust`,
  `coordinator/api/model_hash_race_test.go`). Do **not** deprecate the old
  registry record while any provider may still hold it resident (see "Retire").
- **Canary the new build on one production-version provider** via its raw build
  id before flipping: prefetch, hash-verify, GPU-load, and serve chat, tool
  calls, and vision if applicable. Disk verification proves bytes, not
  loadability; the hard-swap advertises the build **before** its first load, so
  an unloadable build turns the fleet into 500s until you revert (the
  `load-failure cool-down started` path in `coordinator/api/provider.go` lets
  alias resolution fall back to `previous_build`, but treat it as a backstop).
- **For a takeover migration, pre-position the rollback build first** (step 6).
- R2 access for publishing: `R2_ACCOUNT_ID`, `GCP_PROJECT`, and the Secret
  Manager secrets `darkbloom-r2-access-key-id` / `darkbloom-r2-secret-access-key`
  read by [`scripts/publish-model.sh`](../../scripts/publish-model.sh); bucket
  `darkbloom-models`, served at `https://models.darkbloom.ai`.

### Mechanics in one paragraph

An alias row (`model_aliases`, `store.ModelAlias`) has `desired_build`, an
optional `previous_build`, and an accumulated `retired_builds` lineage
(`retiredBuildsAfterUpsert`). `Registry.DesiredModelsForProvider` builds the
`desired_models` message for a provider that currently advertises any member of
the alias; the provider (`ProviderLoop+Prefetch.swift`) downloads and
hash-verifies the desired build with no GPU load, then sends an authoritative
`models_update` advertising the new build and dropping the old one; the
coordinator logs `provider now advertises build (models_update)` and
`models_update hard-swap: dropping retired build` (`coordinator/registry/registry.go`).
`Registry.ResolveModel` maps the alias to the desired build, falls back to
`previous_build` until the desired one is routable, and otherwise queues
against the desired build — capacity never black-holes. There are no weights,
ramps, or migration controllers.

## Steps

### 1. Publish the new build to R2

```bash
R2_ACCOUNT_ID=<cloudflare account id> GCP_PROJECT=<gcp project> scripts/publish-model.sh
#   Model directory: <local path with config.json, tokenizer, *.safetensors>
#   Model id (for example mlx-community/foo): mlx-community/gemma-4-26B-A4B-it-qat-4bit
#   Version (no slashes): 2026-09-03-r1
#   Required provider capabilities (comma-separated, optional):
```

To prefer an existing public HF mirror, set `HUGGING_FACE_ARTIFACT_JSON` before
running the script. Supply `repo_id`, a full commit `revision`, and optionally
`path_prefix`; see the [artifact field contract](../reference/model-registry-format.md#hugging-face-download-artifact).
The script carries it into the printed `hugging_face_artifact_json` workflow
input. It does not upload HF files. Check the HF files against the manifest
before registering; mismatched files will use the R2 fallback. For an existing
version, re-run registration with the artifact field (or `null` to clear it)
under the same production approval boundary.

The script runs `darkbloom-publish hash` (`provider-swift/Sources/darkbloom-publish/HashCommand.swift`)
to write `manifest.json` (per-file and aggregate SHA-256, `r2_prefix` derived
from id + version), uploads every file plus the manifest to
`s3://darkbloom-models/<r2_prefix>/` with concurrency 8, and prints the exact
`gh workflow run register-model.yml …` command for step 2. Manifest fields:
[`../reference/model-registry-format.md`](../reference/model-registry-format.md).

### 2. Register the build in the coordinator catalog

Either run the printed `gh workflow run register-model.yml` command (workflow
[`.github/workflows/register-model.yml`](../../.github/workflows/register-model.yml),
uses the GitHub secret `MODEL_REGISTRY_PUBLISHING_KEY`; inputs `model_id`,
`version`, `display_name`, `family`, `architecture`, `quantization`,
`capabilities_csv`, `required_provider_capabilities`, `max_context_length`,
`max_output_length`, `min_ram_gb`, `description`, `runtime_parameters_json`,
`metadata_json`, `input_price`, `output_price`, `promote`, `coordinator_url`)
or call the endpoint directly:

```bash
curl -fsS -X POST "$COORD/v1/admin/models/register" \
  -H "Authorization: Bearer $PUBLISHING_KEY" -H 'Content-Type: application/json' \
  -d '{
    "model_id": "mlx-community/gemma-4-26B-A4B-it-qat-4bit",
    "version": "2026-09-03-r1",
    "display_name": "Gemma 4 26B (QAT 4-bit)",
    "family": "gemma-4",
    "quantization": "4bit",
    "max_context_length": 131072,
    "max_output_length": 8192,
    "min_ram_gb": 22,
    "capabilities": ["chat","tools","reasoning","vision"],
    "input_price": 30000,
    "output_price": 165000,
    "promote": true
  }'
```

`handleRegisterModel` fetches `manifest.json` from the CDN, verifies every
listed file exists with the declared size and hash, and stores the version;
`promote: true` makes it the active version. Prices are micro-USD per 1M tokens
and required. Confirm both old and new builds are visible:

```bash
curl -fsS "$COORD/v1/models?include_builds=1" -H "Authorization: Bearer $API_KEY" | jq '.data[].id'
```

### 3. Choose the alias shape

- **Fresh alias** — the public name differs from every concrete model id
  (e.g. `gemma-4-26b` in front of `mlx-community/…-fp8`). Create it pointing at
  the **current** build first (no behaviour change), then flip in step 4.
- **Takeover** — the public name **is** the old concrete id (consumers already
  request `gemma-4-26b` directly). Validation rejects `desired_build ==
  alias_id`, so there is no "create pointing at current" pre-step: steps 3 and 4
  collapse into the single `takeover: true` upsert in step 4, and **you must
  pre-position a rollback build first (step 6)** because a takeover alias can
  never be flipped back to its own name.

Fresh-alias creation:

```bash
curl -fsS -X POST "$COORD/v1/admin/models/aliases" \
  -H "Authorization: Bearer $PUBLISHING_KEY" -H 'Content-Type: application/json' \
  -d '{"alias_id":"gemma-4-26b","display_name":"Gemma 4 26B","desired_build":"mlx-community/gemma-4-26b-a4b-it-fp8"}'
```

`GET /v1/models` now lists `gemma-4-26b` and hides raw builds (pass
`?include_builds=1` to see them, `coordinator/api/models_endpoints.go`).
Requests that still send the raw id keep working.

`aliasUpsertRequest` fields (`coordinator/api/model_alias_handlers.go`;
unknown fields rejected): `alias_id` (letters, digits, `.`, `_`, `-`; ≤128),
`display_name`, `desired_build` (required, must be a registered build ≠
`alias_id`), `previous_build`, `active` (default `true`), `takeover`.

### 4. Flip `desired_build`

Fresh alias — keep the old build as `previous_build` so not-yet-swapped
providers keep serving:

```bash
curl -fsS -X POST "$COORD/v1/admin/models/aliases" \
  -H "Authorization: Bearer $PUBLISHING_KEY" -H 'Content-Type: application/json' \
  -d '{"alias_id":"gemma-4-26b","display_name":"Gemma 4 26B",
       "desired_build":"mlx-community/gemma-4-26B-A4B-it-qat-4bit",
       "previous_build":"mlx-community/gemma-4-26b-a4b-it-fp8"}'
```

Takeover — `previous_build` **must** equal `alias_id`, `desired_build` must be
a distinct registered build, and every later upsert of this alias must keep
`takeover: true` while the absorbed registry record is live:

```bash
curl -fsS -X POST "$COORD/v1/admin/models/aliases" \
  -H "Authorization: Bearer $PUBLISHING_KEY" -H 'Content-Type: application/json' \
  -d '{"alias_id":"gemma-4-26b","display_name":"Gemma 4 26B","takeover":true,
       "previous_build":"gemma-4-26b","desired_build":"gemma-4-26b-qat-4bit"}'
```

The upsert is idempotent on `alias_id`, re-syncs the registry, and calls
`fanOutDesiredModels`, which pushes `desired_models` to every eligible provider
advertising a member of the alias; new or reconnecting providers get the push
right after `register`. Download stagger across the fleet is the only
rate-limiting there is.

### 5. Monitor

```bash
watch -n 10 'curl -fsS "$COORD/v1/models?include_builds=1" -H "Authorization: Bearer $API_KEY" \
  | jq ".data[] | select(.id | test(\"gemma-4-26b\"))"'
```

Use `include_builds=1` counts, not `/v1/models/capacity` (keyed by concrete
build ids; the public row decays as convergence completes). Coordinator log
lines to watch: `provider now advertises build (models_update)`,
`models_update hard-swap: dropping retired build`, `load-failure cool-down
started`, and the deroute signature `provider active model hash matches no
advertised model` (should not be sustained). Prefetch progress is **provider-
side** only: the coordinator ignores `prefetch_model_status` frames
(`coordinator/api/provider.go`, `TypePrefetchModelStatus`); look at the
provider's log for `Scheduling desired-build prefetch retry`.

Failed downloads retry with bounded backoff — `desiredPrefetchRetryDelays` in
`provider-swift/Sources/ProviderCore/ProviderLoop.swift` is `30s, 60s, 120s,
300s, 600s` — resuming from bytes already staged; after the fifth failure the
provider logs `giving up until the next desired_models push` and stays on its
current build. **Manual unstick:** re-POST the identical step-4 body; the
fan-out resets every provider's retry budget.

### 6. (Takeover only, before step 4) Pre-position the rollback build

[`scripts/preposition-rollback-build.sh`](../../scripts/preposition-rollback-build.sh)
server-side-copies the absorbed version's R2 objects to a new id's prefix,
rewrites `model_id`/`r2_prefix` in the manifest, and registers + promotes the
new id. Registry fields are explicit arguments — copy them from the absorbed
build's registry row, including capabilities (they drive `/v1/models`
features and the OpenRouter feed if this id ever becomes primary):

```bash
R2_ACCOUNT_ID=… GCP_PROJECT=… scripts/preposition-rollback-build.sh \
  gemma-4-26b 2026-05-30-r1 gemma-4-26b-8bit "$COORD" "$PUBLISHING_KEY" \
  8bit 36 131072 16384 30000 165000 chat
#  <src-model-id> <src-version> <new-model-id> <coordinator> <key> <quant> <min-ram-gb> <max-ctx> <max-out> <in-µ$/Mtok> <out-µ$/Mtok> [caps-csv]
```

## Verification

| Check | Expected |
|---|---|
| `GET /v1/models` | alias listed; raw builds hidden |
| `GET /v1/models?include_builds=1` | desired-build routable count rises, previous-build count falls to 0 |
| Coordinator logs | one `provider now advertises build (models_update)` + `hard-swap: dropping retired build` per provider; no sustained `active model hash matches no advertised model` |
| Provider logs | prefetch verified, no `giving up until the next desired_models push` |
| Consumer traffic | no 5xx surge; TTFT stable; tool calls and vision work on the new build |
| Challenges | no providers untrusted after their next 5-minute challenge |

## Rollback

There is no rollback endpoint; a revert is the same upsert pointed back.

**Fresh alias:**

```bash
curl -fsS -X POST "$COORD/v1/admin/models/aliases" \
  -H "Authorization: Bearer $PUBLISHING_KEY" -H 'Content-Type: application/json' \
  -d '{"alias_id":"gemma-4-26b","display_name":"Gemma 4 26B",
       "desired_build":"mlx-community/gemma-4-26b-a4b-it-fp8",
       "previous_build":"mlx-community/gemma-4-26B-A4B-it-qat-4bit"}'
```

Providers still holding the old build serve it immediately; the new build stays
acceptable until they re-converge.

**Takeover alias:** `desired_build` cannot return to `alias_id`; flip to the
pre-positioned rollback id instead:

```bash
curl -fsS -X POST "$COORD/v1/admin/models/aliases" \
  -H "Authorization: Bearer $PUBLISHING_KEY" -H 'Content-Type: application/json' \
  -d '{"alias_id":"gemma-4-26b","display_name":"Gemma 4 26B","takeover":true,
       "previous_build":"gemma-4-26b","desired_build":"gemma-4-26b-8bit"}'
```

Providers that never swapped serve the absorbed id at once; already-swapped
providers must fetch the rollback id (staging is keyed by R2 prefix, so expect a
re-download even though the bytes are identical). Without a pre-positioned
build the only exit is `DELETE /v1/admin/models/aliases/{aliasID}`, which
strands swapped providers on a build the public name no longer reaches.

## Retire the old build

Only after `include_builds=1` shows zero providers on the previous build.
Re-POST the alias **without** `previous_build`; the rotated-out build lands in
`retired_builds`, so a machine that was offline is still converged when it
returns (membership matches desired, previous, or retired). The old build
unloads from GPU via the normal idle timeout; nothing clears `previous_build`
automatically.

```bash
curl -fsS -X POST "$COORD/v1/admin/models/aliases" \
  -H "Authorization: Bearer $PUBLISHING_KEY" -H 'Content-Type: application/json' \
  -d '{"alias_id":"gemma-4-26b","display_name":"Gemma 4 26B","desired_build":"mlx-community/gemma-4-26B-A4B-it-qat-4bit"}'
```

**Takeover aliases retire in a different order.** The upsert above is rejected
while the absorbed record is live (without `takeover` the id collision 409s;
with it, `previous_build` must equal `alias_id`):

1. Wait for convergence **plus the residency drain** (retired GPU slots unload
   up to an hour after the box's last old-build inference). Deprecating earlier
   removes the absorbed record's catalog hash and voids the challenge alibi.
2. `POST /v1/admin/models/gemma-4-26b/status` with `{"status":"deprecated"}`
   (valid statuses: `beta`, `active`, `deprecated`, `retired`).
3. Re-upsert the alias without `takeover` and without `previous_build`.

## Related

- [`../reference/model-registry-format.md`](../reference/model-registry-format.md) — manifest, registration, alias, and R2 layout reference.
- [`../architecture/model-registry.md`](../architecture/model-registry.md) — how the registry, catalog, and provider download fit together.
- [dev-environment.md](dev-environment.md) — where to rehearse.
- [release-policy-rollout.md](release-policy-rollout.md) — the other routing gate that can deroute providers during a rollout.
