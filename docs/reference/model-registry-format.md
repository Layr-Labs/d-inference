# Model Registry Format

This document describes the model manifest format, the registration flow, and the alias system. Canonical code: manifest builder in [`provider-swift/Sources/ProviderCoreFoundation/Manifest.swift`](../../provider-swift/Sources/ProviderCoreFoundation/Manifest.swift), registry handlers in [`coordinator/api/model_registry_handlers.go`](../../coordinator/api/model_registry_handlers.go), aliases in [`coordinator/api/model_alias_handlers.go`](../../coordinator/api/model_alias_handlers.go), storage types in [`coordinator/store/interface.go`](../../coordinator/store/interface.go), and the publish script in [`scripts/publish-model.sh`](../../scripts/publish-model.sh).

## Manifest JSON schema

A manifest is produced by `darkbloom-publish hash` and uploaded to R2 as `manifest.json`.

| Field | Type | Description |
|---|---|---|
| `schema_version` | integer | Currently `1` |
| `model_id` | string | HuggingFace-style id, e.g. `mlx-community/gemma-4-26B-A4B-it-qat-4bit` |
| `version` | string | Build tag, e.g. `2026-05-23-r1`; no slashes |
| `r2_prefix` | string | R2 object prefix computed from model slug and hash |
| `aggregate_sha256` | string | Lowercase hex SHA-256 of sorted per-file hashes |
| `total_size_bytes` | integer | Sum of all file sizes |
| `file_count` | integer | Length of `files` |
| `files` | array | [`ManifestFile`](#manifestfile) entries |
| `created_at` | string | ISO 8601 timestamp |

### `ManifestFile`

| Field | Type | Description |
|---|---|---|
| `path` | string | Relative path using `/` separators |
| `size_bytes` | integer | File size |
| `sha256` | string | Lowercase hex SHA-256 of file contents |
| `role` | string | `weight`, `tokenizer`, `config`, `template`, `preprocessor`, `index`, `other` |

### Aggregate hash computation

1. Sort files by `path` ascending.
2. Decode each file's SHA-256 digest to bytes.
3. Concatenate the decoded digests in sorted order into a single SHA-256 hash.
4. Hex-encode the result.

Implemented in [`aggregateManifestFileHashes`](../../coordinator/api/model_registry_handlers.go) and in the Swift [`ManifestBuilder`](../../provider-swift/Sources/ProviderCoreFoundation/ManifestBuilder.swift).

### R2 prefix format

```
v2/<readable-slug>--<first-12-hex-of-sha256(model_id)>/<version>
```

`<readable-slug>` is derived from `model_id` by replacing unsafe characters with `-` and trimming. See [`modelR2Prefix`](../../coordinator/api/model_registry_handlers.go) and [`readableModelSlug`](../../coordinator/api/model_registry_handlers.go).

## Publish flow

1. **Hash locally** with `darkbloom-publish hash <dir> --id <model_id> --version <version> -o manifest.json`.
2. **Upload files** to the R2 prefix computed from the manifest (concurrency 8 in [`publish-model.sh`](../../scripts/publish-model.sh)).
3. **Upload `manifest.json` last** so the registry registration never sees a partial build.
4. **Register** via `POST /v1/admin/models/register` with the publishing API key (or admin key / bootstrap key).

The publish script performs steps 1–3 and prints a sample `gh workflow run register-model.yml` invocation for step 4.

## Registration request

`POST /v1/admin/models/register`

| Field | Type | Required | Notes |
|---|---|---|---|
| `model_id` | string | yes | Must not collide with an existing public alias |
| `version` | string | yes | Matches manifest |
| `display_name` | string | no | Defaults to `model_id` |
| `family` | string | yes | |
| `architecture` | string | yes | |
| `quantization` | string | yes | |
| `max_context_length` | integer | yes | > 0 |
| `max_output_length` | integer | yes | > 0 |
| `min_ram_gb` | integer | yes | > 0 |
| `capabilities` | array | no | Capability strings |
| `description` | string | no | |
| `runtime_parameters` | object | no | Merged into provider request at dispatch |
| `metadata` | object | no | Opaque metadata (deprecation date, OpenRouter slug, etc.) |
| `promote` | bool | no | Immediately activate this version |
| `input_price` | integer | yes | micro-USD per 1M tokens, > 0 |
| `output_price` | integer | yes | micro-USD per 1M tokens, > 0 |

On registration the coordinator:

1. Fetches `https://models.darkbloom.ai/<r2_prefix>/manifest.json` (or `MODEL_REGISTRY_CDN_BASE_URL` override).
2. Validates schema version, id/version/r2_prefix match, hash format, file count, and aggregate hash.
3. HEAD-verifies every file in the manifest.
4. Saves the registry entry + version + file list transactionally.
5. Sets platform pricing.
6. Optionally promotes the version.

See [`handleRegisterModel`](../../coordinator/api/model_registry_handlers.go) and [`validateModelManifest`](../../coordinator/api/model_registry_handlers.go).

## Registry entry schema

Stored as `ModelRegistryEntry` + `ModelVersion` + `ModelVersionFile` rows.

| Field | Type | Notes |
|---|---|---|
| `id` | string | Same as `model_id` |
| `display_name` | string | |
| `family` | string | |
| `architecture` | string | |
| `quantization` | string | |
| `max_context_length` | integer | |
| `max_output_length` | integer | |
| `min_ram_gb` | integer | |
| `capabilities` | array | |
| `status` | string | `beta`, `active`, `deprecated`, `retired` |
| `description` | string | |
| `runtime_parameters` | object | |
| `metadata` | object | |

Active versions are selected by `model_active_versions.model_version_id`. A model is routable when `model_registry.status IN ('active','beta')` AND `model_versions.status = 'ready'`.

## Model aliases

Aliases provide stable consumer-facing names (e.g. `gemma-4-26b`) that resolve to concrete builds.

`POST /v1/admin/models/aliases`

| Field | Type | Required | Notes |
|---|---|---|---|
| `alias_id` | string | yes | Public name; max 128 chars, safe charset only |
| `display_name` | string | no | |
| `desired_build` | string | yes | Concrete registered build id |
| `previous_build` | string | no | Fallback build during rollout |
| `active` | bool | no | Defaults to `true` |
| `takeover` | bool | no | Adopt an existing concrete model id as fallback |

Rules:

- `alias_id` must not collide with a concrete model id unless `takeover=true`.
- `desired_build` and `previous_build` must each be registered models.
- `desired_build` can never equal `alias_id`.
- `previous_build` must differ from `desired_build`.
- Rollouts are performed by updating `desired_build`; reverts by changing it back.

The coordinator pushes the updated `desired_models` message to connected Swift providers that advertise a member of the alias. See [`fanOutDesiredModels`](../../coordinator/api/model_alias_handlers.go).

### Alias resolution precedence

At request time, [`resolveRequestedModel`](../../coordinator/api/consumer.go) resolves a consumer-provided model name:

1. If it is a public alias, map to `desired_build` (or `previous_build` if desired is saturated and previous has capacity).
2. Otherwise treat it as a raw concrete build id.

The concrete build id is what is used for routing, billing, and serving; the public alias is echoed back to the consumer.

## Admin model actions

`POST /v1/admin/models/{model_id}/{action}`

| Action | Body | Effect |
|---|---|---|
| `promote` | `{ "version": "..." }` | Activate a version |
| `status` | `{ "status": "..." }` | Set `beta`/`active`/`deprecated`/`retired` |
| `runtime-parameters` | `{ "runtime_parameters": {...} }` | Merge runtime params |
| `capabilities` | `{ "capabilities": [...] }` | Replace capabilities wholesale |
| `deprecation` | `{ "deprecation_date": "YYYY-MM-DD" }` | Set/clear deprecation metadata |
| `openrouter-slug` | `{ "slug": "..." }` | Set/clear OpenRouter marketplace slug |

## Authentication for registry operations

Registry and alias endpoints accept one of:

- `X-Darkbloom-Publishing-Key` header
- `Authorization: Bearer <key>`
- `MODEL_REGISTRY_PUBLISHING_KEY` bootstrap environment variable
- `EIGENINFERENCE_ADMIN_KEY`

Publishing keys are stored hashed (SHA-256) in the `publishing_api_keys` table. See [`requirePublishingAPIKey`](../../coordinator/api/model_registry_handlers.go).

## Public catalog endpoints

| Endpoint | Description |
|---|---|
| `GET /v1/models/catalog` | Active models (cached 60 s) |
| `GET /v1/models/catalog/{id}` | Single catalog entry |
| `GET /v1/models/catalog/manifest/{id}` | Stored manifest |

The catalog derives OpenRouter-shaped fields from registry entries, including quantization mapping, modalities, features, and pricing. See [`openrouter_models.go`](../../coordinator/api/openrouter_models.go).
