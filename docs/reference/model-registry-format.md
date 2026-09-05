# Model registry format

> Last updated: 2026-09-05 · commit `4d9811f7c`

Exact shapes for everything the model registry stores or accepts: the
`manifest.json` a publisher uploads to R2, the registration and admin requests,
the stored rows, alias rules, and the public catalog responses. Every table
cites the code that defines or validates the field. How the pieces fit together
is explained in [`../architecture/model-registry.md`](../architecture/model-registry.md);
the operator procedure is [`../operations/model-migration.md`](../operations/model-migration.md).

## Manifest (`manifest.json`)

Produced by `darkbloom-publish hash` (`provider-swift/Sources/darkbloom-publish/HashCommand.swift`
→ `ManifestBuilder.build` in `provider-swift/Sources/ProviderCoreFoundation/ManifestBuilder.swift`);
decoded on the coordinator as `store.ModelManifest` (`coordinator/store/interface.go`)
and validated by `validateModelManifest` (`coordinator/api/model_registry_handlers.go`).

| Field | Type | Constraint (coordinator) | Notes |
|---|---|---|---|
| `schema_version` | integer | must be `1` | `ManifestBuilder.schemaVersion = 1` |
| `model_id` | string | equals the registration `model_id` | `A-Z a-z 0-9 . _ - /`; no leading `/`; no `..` (`validRegistryIdentifier(_, true)`) |
| `version` | string | equals the registration `version` | same charset without `/` (`validRegistryIdentifier(_, false)`); e.g. `2026-05-23-r1` |
| `r2_prefix` | string | equals `modelR2Prefix(model_id, version)` | see [R2 layout](#r2-layout) |
| `aggregate_sha256` | string | 64 lowercase hex; equals the recomputed aggregate | `isLowerSHA256Hex`, `aggregateManifestFileHashes` |
| `total_size_bytes` | integer | ≥ 0; equals the sum of `files[].size_bytes` | |
| `file_count` | integer | equals `len(files)`; `files` non-empty | |
| `files` | array of `ManifestFile` | paths unique (case-insensitive) | |
| `created_at` | string (ISO 8601) | not validated | written by the builder |

### `ManifestFile`

| Field | Type | Constraint | Notes |
|---|---|---|---|
| `path` | string | relative, `/`-separated, no empty/`.`/`..` segments, no `\` | `validManifestRelativePath` |
| `size_bytes` | integer | ≥ 0; must equal the CDN `Content-Length` at registration | `verifyManifestFileHEAD` |
| `sha256` | string | 64 lowercase hex | `isLowerSHA256Hex` |
| `role` | string | closed set below | assigned by `ModelScanner.roleFor` (`provider-swift/Sources/ProviderCoreFoundation/ModelScanner.swift`); not validated by the coordinator |

`role` values: `weight` (`*.safetensors`, `*.npz`, `*.bin`), `index`
(`model.safetensors.index.json`), `tokenizer` (`tokenizer.json`,
`tokenizer_config.json`, `tokenizer.model`, `special_tokens_map.json`,
`added_tokens.json`, `vocab.json`, `merges.txt`), `config` (`config.json`,
`generation_config.json`, `quantize_config.json`), `template`
(`chat_template.jinja`, `chat_template.json`), `preprocessor`
(`preprocessor_config.json`, `processor_config.json`,
`video_preprocessor_config.json`), `other`.

### Aggregate hash

`aggregate_sha256` = hex(SHA-256(concat(raw 32-byte digest of each file, files
sorted by `path` ascending))). Implemented identically in
`aggregateManifestFileHashes` (`coordinator/api/model_registry_handlers.go`),
`ManifestBuilder.build`, and `WeightHasher.hashFilesWithRelativeKey`
(`provider-swift/Sources/ProviderCoreFoundation/WeightHasher.swift`), which the
provider runs after download. The same value is the catalog `weight_hash`.

### R2 layout

| Item | Value | Code |
|---|---|---|
| Bucket | `darkbloom-models` (`R2_BUCKET` override) | `scripts/publish-model.sh` |
| S3 endpoint for uploads | `https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com` | `scripts/publish-model.sh` |
| Object prefix | `v2/<slug>--<first 12 hex of sha256(model_id)>/<version>` | `modelR2Prefix`, `readableModelSlug` (Go); `ManifestBuilder.safeModelID` (Swift) |
| `<slug>` | `model_id` with every character outside `A-Z a-z 0-9 . _ -` (including `/`) replaced by `-`, leading/trailing `-` trimmed; `model` if empty | same |
| Objects under the prefix | every `files[].path`, plus `manifest.json` (uploaded last) | `scripts/publish-model.sh` |
| Public CDN | `https://models.darkbloom.ai` | `defaultModelRegistryCDNBaseURL` (`coordinator/api/model_registry_handlers.go`); `ModelDownloader.defaultR2CDNURL` (`provider-swift/Sources/ProviderCore/Models/ModelDownloader.swift`) |
| CDN override | coordinator `MODEL_REGISTRY_CDN_BASE_URL`; provider `DARKBLOOM_R2_CDN_URL` | `registryCDNBaseURL`; `ModelDownloader.init` |

Example: `mlx-community/gemma-4-26B-A4B-it-qat-4bit` at version `2026-05-23-r1`
→ `v2/mlx-community-gemma-4-26B-A4B-it-qat-4bit--<12hex>/2026-05-23-r1/manifest.json`.

## Registration

`POST /v1/admin/models/register` — `handleRegisterModel`
(`coordinator/api/model_registry_handlers.go`). Publishing-key auth
([below](#authentication)). Unknown JSON fields are rejected
(`DisallowUnknownFields`).

| Field | Type | Required | Validation (`validateRegisterModelRequest`) |
|---|---|---|---|
| `model_id` | string | yes | registry identifier charset, `/` allowed; must not equal an existing alias (409) |
| `version` | string | yes | registry identifier charset, no `/` |
| `display_name` | string | no | defaults to `model_id` |
| `family` | string | no | stored as given (may be empty) |
| `architecture` | string | no | stored as given |
| `quantization` | string | yes | non-empty |
| `max_context_length` | integer | yes | > 0 |
| `max_output_length` | integer | yes | > 0 |
| `min_ram_gb` | integer | yes | > 0 |
| `capabilities` | array of string | no | free-form OpenRouter-style feature names (`tools`, `reasoning`, …) |
| `required_provider_capabilities` | array of string | no | each must be `apple_m5` or `mlx_nax`, trimmed, unique (`validateRequiredProviderCapabilities`); `EigenLabs/Qwen3.8-27B-4bit` must list both |
| `description` | string | no | |
| `runtime_parameters` | object | no | merged into provider requests at dispatch |
| `metadata` | object | no | opaque; see [metadata keys](#metadata-keys) |
| `promote` | boolean | no | activate this version immediately |
| `input_price` | integer | yes | > 0, micro-USD per 1M tokens |
| `output_price` | integer | yes | > 0, micro-USD per 1M tokens |

Server-side sequence, in order; any failure before step 5 persists nothing:

1. Alias-collision guard: `GetModelAlias(model_id)` found → `409`.
2. `GET <cdn>/<r2_prefix>/manifest.json` (30 s timeout, 10 MiB limit) →
   `400 failed to fetch manifest` on any non-2xx.
3. `validateModelManifest` (table above) → `400`.
4. `HEAD` every file with 8 workers, comparing `Content-Length` to `size_bytes`
   (`verifyManifestFiles`) → `400 manifest file verification failed`.
5. `SetModelVersion` writes the entry (`status = "beta"`), version
   (`status = "ready"`, `uploaded_by` = key name), and file rows in one
   transaction.
6. `SetModelPrice("platform", model_id, input_price, output_price)`.
7. If `promote`: `PromoteModelVersion` upserts `model_active_versions`.
8. `SyncModelCatalog()`.

Response `200`:

```json
{
  "status": "registered",
  "model": { "...ModelRegistryEntry..." },
  "version": { "...ModelVersion..." },
  "files": 12,
  "input_price": 15000,
  "output_price": 70000
}
```

## Stored rows

DDL in `coordinator/store/postgres.go`; Go types in `coordinator/store/interface.go`.

### `model_registry` ↔ `ModelRegistryEntry`

| Column / JSON | Type | Default | Notes |
|---|---|---|---|
| `id` | text (PK) | | the `model_id` |
| `display_name` | text | | |
| `family`, `architecture`, `quantization` | text | `''` | |
| `max_context_length`, `max_output_length`, `min_ram_gb` | integer | `0` | |
| `capabilities` | text[] | `{}` | consumer-visible features |
| `required_provider_capabilities` | text[] | `{}` | routing gate; a migration forces `{apple_m5, mlx_nax}` onto `EigenLabs/Qwen3.8-27B-4bit` |
| `status` | text | `'beta'` | closed set: `beta`, `active`, `deprecated`, `retired` (`validModelStatus`) |
| `description` | text | `''` | |
| `runtime_parameters` | jsonb | `{}` | |
| `metadata` | jsonb | `{}` | |
| `created_at`, `updated_at` | timestamptz | `NOW()` | |

### `model_versions` ↔ `ModelVersion`

| Column / JSON | Type | Notes |
|---|---|---|
| `id` | bigserial | referenced by `model_active_versions` |
| `model_id` | text | FK → `model_registry.id`, cascade delete |
| `version` | text | unique per `model_id` |
| `r2_prefix`, `aggregate_sha256`, `total_size_bytes`, `file_count` | | copied from the manifest |
| `status` | text | `'ready'` on registration |
| `uploaded_by` | text | publishing key name, `env-bootstrap`, or `admin` |
| `uploaded_at`, `promoted_at` | timestamptz | `promoted_at` set by `PromoteModelVersion` |
| `metadata` | jsonb | the registration `metadata` |

### `model_version_files` ↔ `ModelVersionFile`

`model_version_id` (FK), `path`, `size_bytes`, `sha256`, `role` — one row per
`ManifestFile`; unique on (`model_version_id`, `path`).

### `model_active_versions`

`model_id` (PK, FK) → `model_version_id` (FK, `ON DELETE RESTRICT`),
`activated_at`. A model is **routable** when
`model_registry.status IN ('active','beta')` and the active version has
`status = 'ready'` (`activeModelRegistryQuery` in
`coordinator/store/postgres_model_registry.go`).

### Metadata keys

Keys in `model_registry.metadata` the coordinator reads
(`coordinator/api/openrouter_models.go`, `coordinator/api/model_registry_handlers.go`):

| Key | Set by | Effect |
|---|---|---|
| `hugging_face_id` | `hugging-face-id` action or registration `metadata` | `GET /v1/models` and `GET /v1/models/openrouter` emit it as `hugging_face_id`; otherwise `model_id` is used (`huggingFaceIDForModel`) |
| `openrouter_slug` | `openrouter-slug` action | OpenRouter marketplace slug in the feed |
| `deprecation_date` | `deprecation` action | `YYYY-MM-DD`; OpenRouter deprecation metadata |

## Hugging Face download artifact

`registerModelRequest.hugging_face_artifact` is an optional object stored on
`model_versions.hugging_face_artifact` (nullable JSONB) and emitted on each
public catalog model by `catalogModelFromRegistryRecord`. Its fields are
validated by `HuggingFaceArtifact.Validate` in
`coordinator/store/hugging_face_artifact.go`:

| Field | Rule |
|---|---|
| `repo_id` | `owner/repository`, at most 192 bytes; repository components use ASCII letters, digits, `_`, `-`, `.` and start with a letter, digit, or `_`; no `..` |
| `revision` | Full 40-character lowercase hexadecimal HF commit SHA; branches and tags are rejected |
| `path_prefix` | Optional directory relative to the repository root, at most 1024 bytes; same component rules; no empty or traversal components |

Example registration field (substitute the commit of your published artifact):

```json
"hugging_face_artifact": {
  "repo_id": "EigenLabs/your-model",
  "revision": "0123456789abcdef0123456789abcdef01234567",
  "path_prefix": "mlx"
}
```

The artifact is independent of `metadata.hugging_face_id`, which identifies the
upstream model for feeds. Use a public, ungated repository whose files match the
registered manifest, including any modified templates and configs. Provider
requests carry no HF credentials. Missing, gated, unavailable, or mismatched
files fall back to R2 individually. HF gets one attempt with a 30-second idle
request timeout; R2 retains the existing three-attempt policy. Every accepted
file must pass size and SHA-256 checks, then the complete snapshot must pass the
aggregate hash (`provider-swift/Sources/ProviderCore/Models/ModelDownloader+Sources.swift`,
`downloadManifestFileWithResume`). No speed comparison or automatic source race
is performed. The manifest and checksum authority remain the coordinator/R2.

Omitting the field or sending `null` on re-registration clears the source for
that version. Existing entries and older providers continue using R2. Adding or
clearing it on an existing version uses the normal registration endpoint;
production registration still requires approval.

## Admin actions

`POST /v1/admin/models/{model_id}/{action}` — `handleAdminModelRegistryAction`
(`coordinator/api/model_registry_handlers.go`). Publishing-key auth. Every
successful action calls `SyncModelCatalog()`.

| `action` | Body | Effect | Response |
|---|---|---|---|
| `promote` | `{"version": "..."}` | `PromoteModelVersion` — point `model_active_versions` at this version | `{"status":"promoted","model_id","version"}` |
| `status` | `{"status": "..."}` | `SetModelStatus`; value must be `beta`, `active`, `deprecated`, or `retired` | `{"status":"updated","model_id","model_status"}` |
| `runtime-parameters` | `{"runtime_parameters": {...}}` | **merge** keys into the existing object (partial update) | `{"status":"updated","model_id","runtime_parameters"}` |
| `capabilities` | `{"capabilities": [...]}` | **replace** wholesale; trimmed, de-duplicated, sorted (`normalizeCapabilities`) | `{"status":"updated","model_id","capabilities"}` |
| `deprecation` | `{"deprecation_date": "YYYY-MM-DD"}` or `{}` | set, or clear when empty/omitted | `{"status":"updated","model_id","deprecation_date"}` (+ `note` when cleared) |
| `openrouter-slug` | `{"slug": "..."}` or `{}` | set, or clear when empty/omitted | `{"status":"updated","model_id","openrouter_slug"}` |
| `hugging-face-id` | `{"hugging_face_id": "owner/repository"}` or `{}` | set, or clear when empty/omitted | `{"status":"updated","model_id","hugging_face_id"}` |

Unknown action → `404 model action not found`.

## Standard aliases

A standard alias is a stable public name that resolves to one `desired_build`,
with an optional still-acceptable `previous_build` during a rollout. Handlers in
`coordinator/api/model_alias_handlers.go`; stored as `ModelAlias`
(`coordinator/store/interface.go`) in `model_aliases`.

### `POST /v1/admin/models/aliases` (`handleModelAliasUpsert`)

Idempotent on `alias_id`; unknown fields rejected.

| Field | Type | Required | Notes |
|---|---|---|---|
| `alias_id` | string | yes | ≤ `maxAliasIDLength = 128`; charset `A-Z a-z 0-9 . _ -` (no `/`) |
| `display_name` | string | no | |
| `desired_build` | string | yes | a registered `model_id` |
| `previous_build` | string | no | a registered `model_id` |
| `active` | boolean | no | omitted ⇒ `true` |
| `takeover` | boolean | no | adopt an existing concrete model id as the alias name; see rules |

Rules, with the status code returned when violated:

| Rule | Code |
|---|---|
| `alias_id` and `desired_build` present and well-formed | 400 |
| `desired_build != alias_id` | 400 |
| `alias_id` does not equal a concrete `model_id` — unless `takeover=true` | 409 |
| with `takeover=true`, `previous_build == alias_id` (the absorbed concrete build) | 400 |
| without a same-named concrete model, `previous_build != alias_id` | 400 |
| `previous_build != desired_build` | 400 |
| `desired_build` (and `previous_build` if set) is a registered model | 400 |
| `alias_id` is not an existing OpenRouter-only alias | 409 |
| when `active`, no member build is pinned as a concrete source by an OpenRouter-only alias | 409 |

On success the server recomputes `retired_builds` (prior desired/previous
members no longer pointed to, oldest dropped past `maxRetiredBuilds = 16`;
`retiredBuildsAfterUpsert`), upserts the row, calls `SyncModelCatalog()` (which
fans out `desired_models`), and returns `{"status":"ok","alias": <ModelAlias>}`.

### `GET /v1/admin/models/aliases` (`handleModelAliasList`)

`{"aliases": [<ModelAlias>...]}` — standard aliases only.

### `DELETE /v1/admin/models/aliases/{aliasID}` (`handleModelAliasDelete`)

`{"status":"deleted","alias_id":"..."}`; refuses OpenRouter-only aliases (404).

### Stored `ModelAlias`

| JSON | Type | Notes |
|---|---|---|
| `alias_id` | string | primary key |
| `display_name` | string | |
| `desired_build` | string | build providers converge to |
| `previous_build` | string | omitted when empty |
| `retired_builds` | array of string | lineage; lets a provider offline through a retirement still receive `desired_models` |
| `active` | boolean | inactive aliases are not loaded into the registry |
| `openrouter_only` | boolean | marketplace clone (below) |
| `source_model`, `source_kind`, `openrouter_slug`, `hugging_face_id` | string | OpenRouter-only fields; `source_kind` ∈ `standard_alias` (default), `concrete_model` |
| `created_at`, `updated_at` | timestamp | |

### Resolution precedence

`ResolveModelConstrainedWithTraits` (`coordinator/registry/registry.go`),
called from `resolveRequestedModel` (`coordinator/api/consumer.go`):

1. Not an alias → the id is used as a concrete build.
2. Alias → `desired_build` if an eligible provider can route it; else
   `previous_build` if routable; else `desired_build` (request queues).

Responses echo the alias; billing and stats store the concrete build.

## OpenRouter-only aliases

Marketplace clones of an existing alias or concrete model with their own API
id. Handlers in `coordinator/api/openrouter_alias_handlers.go`; invariants in
`coordinator/api/openrouter_alias_invariants.go`.

| Endpoint | Handler |
|---|---|
| `GET /v1/admin/models/openrouter-aliases` | `handleOpenRouterAliasList` |
| `POST /v1/admin/models/openrouter-aliases` | `handleOpenRouterAliasUpsert` |
| `DELETE /v1/admin/models/openrouter-aliases/{aliasID}` | `handleOpenRouterAliasDelete` |

Upsert body (`openRouterAliasUpsertRequest`):

| Field | Required | Rule |
|---|---|---|
| `id` | yes | alias charset, ≤ 128; must not equal a concrete model (409) or a standard alias (409); must differ from `source_model` |
| `source_model` | yes | an active standard alias (`source_kind = standard_alias`) **or** an active concrete catalog model eligible for the text-only OpenRouter feed (`source_kind = concrete_model`); a concrete source already covered by a standard alias is rejected (409) |
| `openrouter_slug` | yes | marketplace slug |
| `hugging_face_id` | yes | repository id emitted in feeds |
| `active` | no | omitted ⇒ `true` |

The clone appears only in `GET /v1/models/openrouter` (and is retrievable via
`GET /v1/models/{id}`); it never drives provider convergence and never becomes
a build's canonical public name (`registry.AliasTarget.OpenRouterOnly`).

## Provider-facing messages

Defined in `coordinator/protocol/messages.go`; full field tables in
[`protocol-messages.md`](protocol-messages.md).

| `type` | Direction | Shape |
|---|---|---|
| `desired_models` | coordinator → provider | `{"type","models":[{"model_name","desired_build","previous_build"}]}` (`DesiredModelsMessage`); only to Swift providers ≥ `minProviderVersionForDesiredModels = "0.5.17"` (`coordinator/api/server.go`) |
| `prefetch_model_status` | provider → coordinator | `status` ∈ `started`, `downloading`, `verified`, `failed`; `bytes_done`, `bytes_total`, `error` |
| `models_update` | provider → coordinator | full `ModelInfo` (with `weight_hash`) for newly verified builds; merged only when the hash matches the catalog (`mergeProviderModels`, `coordinator/registry/registry.go`) |

## Authentication

`requirePublishingAPIKey` (`coordinator/api/model_registry_handlers.go`) guards
every `/v1/admin/models/...` endpoint on this page. Accepted, in order:

| Credential | Where | Actor recorded as |
|---|---|---|
| Publishing key | `X-Darkbloom-Publishing-Key: <key>` or `Authorization: Bearer <key>` | key `name` from `publishing_api_keys` |
| Bootstrap key | env `MODEL_REGISTRY_PUBLISHING_KEY` compared in constant time | `env-bootstrap` |
| Admin key | env `EIGENINFERENCE_ADMIN_KEY` | `admin` |

Publishing keys are stored as SHA-256 hex (`publishingSHA256Hex`) in
`publishing_api_keys` (`id`, `name`, `key_hash`, `active`, `created_at`,
`last_used_at`); a successful use stamps `last_used_at`
(`MarkPublishingAPIKeyUsed`). Missing or unknown key → `401`.

## Public catalog endpoints

Unauthenticated; used by providers and `scripts/install.sh`.

| Endpoint | Handler | Response |
|---|---|---|
| `GET /v1/models/catalog[?type=text][&include_aliases=1]` | `handleModelCatalog` (`coordinator/api/billing_handlers.go`) | `{"models":[<catalog model>...]}`; with `include_aliases`, also `"aliases"`; cached `time.Minute`; `type` other than `text` → 400 |
| `GET /v1/models/catalog/{id}` | `handleModelCatalogItem` | one catalog model, or 404 |
| `GET /v1/models/catalog/manifest/{id}` | `handleModelCatalogManifest` | the stored `ModelManifest` for the active version, or 404 |

Catalog model fields (`catalogModelFromRegistryRecord`): `id`, `s3_name`
(= `r2_prefix`), `display_name`, `model_type` (`text`), `size_gb`
(`total_size_bytes / 1e9`), `architecture`, `description`, `min_ram_gb`,
`active` (status `active`/`beta` **and** version `ready`), `weight_hash`
(= `aggregate_sha256`), `family`, `quantization`, `max_context_length`,
`max_output_length`, `capabilities`, `required_provider_capabilities`,
`runtime_parameters`, `metadata`, `status`, `created`, `version`, `r2_prefix`,
`aggregate_sha256`, `total_size_bytes`, `file_count`, optional
`hugging_face_artifact`, plus the
OpenRouter-shaped `name`, `hugging_face_id`, `input_modalities`,
`output_modalities`, `supported_features`, `supported_sampling_parameters`.

Alias entries with `include_aliases=1` (`catalogAliasesForResponse`): `id`,
`display_name`, `desired_build`, `previous_build` (if set), `retired_builds`,
`primary_build` (the desired build if it is in the catalog, else the previous
build; aliases with neither are omitted).

## Publish tooling

| Tool | Interface | Notes |
|---|---|---|
| `darkbloom-publish hash <dir> --id <model_id> --version <version> [-o manifest.json]` | `provider-swift/Sources/darkbloom-publish/HashCommand.swift` | validates id/version before hashing; writes to stdout without `-o` |
| `scripts/publish-model.sh` | interactive; env `R2_ACCOUNT_ID` (required), `R2_BUCKET` (`darkbloom-models`), `R2_ACCESS_KEY_SECRET` / `R2_SECRET_KEY_SECRET` (GCP Secret Manager names `darkbloom-r2-access-key-id`, `darkbloom-r2-secret-access-key`) | runs the hasher via `swift run -c release`, uploads files with concurrency 8, uploads `manifest.json` last; optional env `HUGGING_FACE_ARTIFACT_JSON` validates an existing public HF artifact and passes it into the printed registration command; prints a `gh workflow run register-model.yml` command; defaults `required_provider_capabilities` to `apple_m5,mlx_nax` for `EigenLabs/Qwen3.8-27B-4bit` |
| `.github/workflows/register-model.yml` | `workflow_dispatch` inputs mirroring the registration request (`capabilities_csv` and `required_provider_capabilities` are comma-separated; `runtime_parameters_json`, `metadata_json` are JSON objects; `hugging_face_artifact_json` is an artifact object or `null`; `coordinator_url` defaults to `https://api.darkbloom.dev`) | builds the payload with `jq` and POSTs with `Authorization: Bearer ${{ secrets.MODEL_REGISTRY_PUBLISHING_KEY }}` |

## Related

- [`../architecture/model-registry.md`](../architecture/model-registry.md) — why the registry is shaped this way and how routing consumes it.
- [`../operations/model-migration.md`](../operations/model-migration.md) — publishing and alias cutover runbook.
- [`api-contracts.md`](api-contracts.md) — consumer-facing `GET /v1/models`.
- [`protocol-messages.md`](protocol-messages.md) — `desired_models`, `models_update`, `prefetch_model_status` field tables.
- [`configuration.md`](configuration.md) — `MODEL_REGISTRY_CDN_BASE_URL`, `MODEL_REGISTRY_PUBLISHING_KEY`, `DARKBLOOM_R2_CDN_URL`.
