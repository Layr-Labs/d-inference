# Model Registry

The model registry is the coordinator-managed catalog of servable models. It stores model metadata, versioned manifests, and file fingerprints. Providers download approved models from an R2 CDN; the coordinator never fronts model bytes. Consumer-facing model names are aliases that resolve to concrete builds, allowing zero-downtime quant swaps and rollouts.

Canonical code:

* Coordinator registry store: `coordinator/store/postgres_model_registry.go`
* Store interface: `coordinator/store/interface.go:254-280`
* Alias handlers: `coordinator/api/model_alias_handlers.go`
* Alias resolution: `coordinator/registry/registry.go:1206-1295`
* Provider catalog client: `provider-swift/Sources/ProviderCore/Models/ModelCatalog.swift`
* Publish tooling: `provider-swift/Sources/darkbloom-publish/`

## Registry schema

The Postgres store uses four tables for the catalog (`coordinator/store/postgres_model_registry.go:16-303`):

| Table | Purpose |
|---|---|
| `model_registry` | Canonical model metadata: id, display name, family, architecture, quantization, context/output lengths, min RAM, capabilities, status, runtime parameters, metadata |
| `model_versions` | Uploaded version of a model: version string, R2 prefix, aggregate SHA-256, total size, file count, status, uploader |
| `model_version_files` | Per-version file list: path, size, SHA-256, role |
| `model_active_versions` | Which version is currently active for each model |

Only models whose `status` is `active` or `beta` and whose active version has `status = 'ready'` are returned by `ListActiveModelRegistry` (`postgres_model_registry.go:155-207`).

## Supported model shape

The in-memory shape used by routing and listing is `SupportedModel` (`coordinator/store/interface.go:814-833`):

```go
type SupportedModel struct {
    ID           string  // e.g. "mlx-community/Qwen3.5-9B-MLX-4bit"
    S3Name       string  // CDN key for legacy downloads
    DisplayName  string  // Human-readable
    ModelType    string  // "text", "embedding", "tts"
    SizeGB       float64 // Disk/memory footprint
    Architecture string
    Description  string
    MinRAMGB     int     // Minimum system RAM
    Active       bool
    WeightHash   string  // Expected SHA-256 of weight files
}
```

`SupportedModel` is derived from the canonical registry records; it is no longer a standalone persisted catalog (`store/interface.go:816-818`).

## Model aliases

Public model names are **aliases** that resolve to a single desired concrete build. Aliases live in the `model_aliases` table and are managed via `POST /v1/admin/models/aliases` (`coordinator/api/model_alias_handlers.go:38-149`).

Each alias has:

| Field | Meaning |
|---|---|
| `alias_id` | Public name, e.g. `gemma-4-26b` |
| `desired_build` | Concrete build the fleet should converge to |
| `previous_build` | Still-acceptable build during a staggered rollout |
| `retired_builds` | Lineage of former members, kept so offline providers rejoining recognize the alias |

Alias resolution is performed by `ResolveModel` and `ResolveModelConstrained` (`coordinator/registry/registry.go:1206-1295`):

1. If the requested id is not an alias, return it unchanged.
2. If it is an alias, prefer the `DesiredBuild` when at least one provider can route it.
3. Otherwise fall back to `PreviousBuild` if routable.
4. If neither is routable, return `DesiredBuild` so the request queues against a real build instead of black-holing.

`ResolveModelConstrained` additionally respects serial allowlists, self-route-only, and prefer-owner constraints so an alias never resolves to a build that the allowed providers cannot serve.

### Rollouts and takeovers

A rollout is just setting `desired_build` to a new registered build. A revert sets it back. The `takeover` flag supports the special case where a public alias adopts the name of an existing concrete model (`model_alias_handlers.go:22-31`, `71-103`).

After an alias change, `SyncModelCatalog` refreshes the in-memory catalog and `fanOutDesiredModels` pushes the new desired state to every connected Swift provider (`model_alias_handlers.go:139-145`, `246-270`).

## Manifests and CDN

Model bytes are stored in R2 and served from `https://models.darkbloom.ai` (`provider-swift/Sources/ProviderCore/Models/ModelCatalog.swift:573`). The coordinator exposes two catalog endpoints:

* `GET /v1/models/catalog` — active `CatalogModel` list.
* `GET /v1/models/catalog/manifest/{modelID}` — active manifest for a model (`ModelManifest` in `store/interface.go:912-931`).

A manifest contains:

```go
type ModelManifest struct {
    SchemaVersion   int
    ModelID         string
    Version         string
    R2Prefix        string
    AggregateSHA256 string
    TotalSizeBytes  int64
    FileCount       int
    Files           []ManifestFile
}
```

Each `ManifestFile` records path, size, and SHA-256. The aggregate hash is verified after download; a mismatch clears staging so a corrected manifest re-downloads cleanly (`ModelCatalog.swift:751-755`).

## Provider download and prefetch

The provider catalog client fetches the active catalog and downloads models into the standard HuggingFace cache layout at `~/.cache/huggingface/hub/models--{org}--{name}/snapshots/local/` (`ModelCatalog.swift:13`, `ModelCatalog.swift:597-608`).

Two paths exist:

* **Foreground `download`** — used by `darkbloom models download`. Concurrent 4-way download, progress rendering, same staging/resume contract.
* **Background `prefetch`** — used by the prefetch coordinator. Sequential download, resumes from a stable staging directory keyed by `r2Prefix`, verifies per-file SHA-256 and aggregate hash (`ModelCatalog.swift:650-763`).

Both paths verify each file's size and SHA-256 before promoting it from staging. Capacity checks account for already-staged or partially downloaded bytes so a resume is not rejected for room equal to the full model size (`ModelCatalog.swift:713-724`, `ModelCatalog.swift:947-957`).

## Desired models push

The coordinator tells Swift providers declaratively which builds are desired for each public alias via `DesiredModelsMessage` (`coordinator/protocol/messages.go:381-393`). The provider reconciles:

1. Background-prefetch any missing desired build.
2. Once verified on disk, hard-swap and emit `models_update` (`protocol/messages.go:395-406`).

`DesiredModelsForProvider` (`coordinator/registry/registry.go:2277-2333`) builds conservative entries: a provider only receives desired models for aliases where it already advertises a member (desired, previous, or retired build). Empty entry sets are also sent — they mark in-flight prefetches as stale when an alias is deleted or repointed (`model_alias_handlers.go:232-236`).

## Weight hash verification

When a provider downloads or prefetches a build, it computes a SHA-256 fingerprint of the weight files. The coordinator verifies this `WeightHash` against the catalog before merging the model into the provider's advertised inventory (`coordinator/registry/registry.go:1595-1622`, `1660-1678`). A mismatched or missing hash prevents the build from becoming routable for that provider.

Weight hashing is on-demand for the served model only; model scan at startup uses fast discovery without hashing (`docs/AGENTS.md` Common Pitfalls).

## Publishing API keys

Model manifests are published using hashed publishing API keys (`coordinator/store/postgres_model_registry.go:234-290`). `PUT /v1/admin/models` and alias endpoints require a valid publishing key. Keys are stored hashed and stamped with `last_used_at` on use.
