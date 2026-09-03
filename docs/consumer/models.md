# Models reference

> Last updated: 2026-09-03 · commit `5d400cf75`

The model catalog is database-driven: model builds, their capabilities and prices live in the coordinator's registry and price tables, and public names are aliases maintained by operators (`coordinator/api/model_alias_handlers.go`, [`../architecture/model-registry.md`](../architecture/model-registry.md)). There is no static list to reproduce here; `GET /v1/models` is the list. This page is the reference for that response, for how the `model` you send is resolved, and for the capability fields the API exposes.

## `GET /v1/models`

Handler `handleListModels` (`coordinator/api/models_endpoints.go`). Requires a bearer credential (`requireAuth`).

```bash
curl -s https://api.darkbloom.dev/v1/models -H "Authorization: Bearer $DARKBLOOM_API_KEY"
```

Response `ModelListResponse` (`coordinator/api/types/types.go`):

```json
{
  "object": "list",
  "data": [ ModelEntry, … ]
}
```

What is listed (`listModelEntries`, `aliasModelEntries`):

- Every **active public alias** that has a desired build in the catalog, under the alias id. The concrete builds an alias points at (desired, previous, retired) are hidden.
- Every **catalog build not covered by an alias**, under its build id.
- `?include_builds=1` adds the hidden builds (operations/debugging).
- OpenRouter-only aliases are excluded; they appear only in `GET /v1/models/openrouter` (`handleListModelsOpenRouter`, `coordinator/api/openrouter_endpoint.go`).
- With `X-Darkbloom-Route: self`, or on a key created with `self_route_only`, the list is instead the account's own machines' models, filtered by the key's `allowed_models` (`selfRouteModelEntries`, `filterEntriesByKeyAllowList`). See [`../provider/self-route.md`](../provider/self-route.md).

### `ModelEntry` fields

| Field | Type | Meaning | Source |
|---|---|---|---|
| `id` | string | The name to send as `model`: an alias id, or a build id for un-aliased builds | `aliasModelEntries` (`coordinator/api/models_endpoints.go`), `modelEntryForConcrete` (`coordinator/api/concrete_model_entries.go`) |
| `object` | string | Always `"model"` | |
| `created` | int | Registry entry creation time (Unix seconds); 0 when no registry record | `openRouterModelFieldsFor` (`coordinator/api/openrouter_models.go`) |
| `owned_by` | string | Always `"eigeninference"` | |
| `name` | string | Display name | alias display name, else catalog display name |
| `hugging_face_id` | string | Upstream weights identifier, when known | `huggingFaceIDForModel` |
| `description` | string | From the registry entry | |
| `input_modalities` | string[] | `["text"]` plus `"image"`, `"audio"`, `"video"` when the build's capabilities include them; embedding models report `["text"]` → `["embedding"]` | `deriveModalities` (`coordinator/api/openrouter_models.go`) |
| `output_modalities` | string[] | `["text"]` (or `["embedding"]`) | `deriveModalities` |
| `quantization` | string | Quantization of a concrete build; empty on alias entries because an alias spans quants | `mapQuantizationToOpenRouter` |
| `context_length` | int | Maximum prompt+completion context of the primary build | registry `MaxContextLength` |
| `max_output_length` | int | Maximum completion length; `max_tokens` above it is clamped at request time (`ensureMaxTokensBound`, `coordinator/api/consumer.go`) | registry `MaxOutputLength` |
| `pricing` | object | `prompt`, `completion`, `image`, `request`, `input_cache_read` — USD per unit as decimal strings, from the platform price table | `buildModelPricing`, `resolvePlatformPricing`; see [`../reference/pricing-model.md`](../reference/pricing-model.md) |
| `supported_sampling_parameters` | string[] | `temperature`, `top_p`, `top_k`, `frequency_penalty`, `presence_penalty`, `repetition_penalty`, `stop`, `seed`, `max_tokens` | `defaultSamplingParameters` |
| `supported_features` | string[] | Feature vocabulary derived from registry capabilities: `tools`, `json_mode`, `structured_outputs`, `logprobs`, `web_search`, `reasoning`; omitted when none | `supportedFeaturesFromCapabilities` |
| `deprecation_date` | string | Optional, from registry metadata | `deprecationDateFromMetadata` |
| `metadata` | object | Darkbloom-specific block, below | |

### `metadata` (`ModelMetadata`)

| Field | Meaning |
|---|---|
| `model_type` | Registry model type (e.g. text generation vs embedding) |
| `quantization` | Build quantization; empty on alias entries |
| `provider_count` | Providers currently advertising the build (concrete entries only) |
| `attested_providers` | How many of them passed attestation (concrete entries only) |
| `trust_level` | Aggregate trust level across providers (concrete entries only) |
| `attestation` | `{secure_enclave, sip_enabled, secure_boot}` when hardware attestation facts are known (concrete entries only) |
| `display_name` | Same as `name` |
| `routable_providers` | Providers eligible to receive this model right now |
| `warm_providers` | Providers with the model loaded |
| `can_accept` | Whether at least one provider can accept a request now; alias entries aggregate across the alias's routable builds |

`routable_providers`, `warm_providers` and `can_accept` come from the live registry snapshot (`registry.ModelCapacitySnapshot`), so they change between calls; `GET /v1/models/capacity` (`handleModelsCapacity`, `coordinator/api/capacity.go`) exposes the same numbers unauthenticated with a 2 s cache.

## `GET /v1/models/{id}`

Handler `handleGetModel`. Returns one `ModelEntry` for a listed id, a hidden build id, or an alias; 404 `model_not_found` with `param: "model"` otherwise. Self-route requests retrieve from the owned-model view so list and retrieve always agree.

## How `model` is resolved on inference

`resolveRequestedModel` (`coordinator/api/consumer.go`) calls `registry.ResolveModelConstrainedWithTraits` with the request's constraints (self-route policy, media/tool traits):

1. **Alias.** The alias is mapped to its desired build; if every desired-build provider is saturated or too slow and the previous build can serve, the request goes to the previous build instead (`maybeFallbackAlias`). The forwarded body carries the build id; every response, stream chunk and usage record echoes the alias you sent (`publicModel`).
2. **Alias with no routable build** → 503 `model_unavailable`, message `model "<id>" has no available build right now`, `param: "model"`, **no** `Retry-After`.
3. **Build id.** Passed through unchanged.
4. **Unknown id.** Passes resolution, then fails the catalog check after the balance reservation is taken and released: 404 `model_not_found`, message `model "<id>" is not available — see /v1/models for supported models`, `param: "model"`. Self-route requests skip this check because their catalog is the machine's own model set.

### `model_not_allowed`

A key created with `allowed_models` can only use those ids. Any other `model` fails in the prelude with 403 `model_not_allowed` (`keyModelAllowed`, `coordinator/api/apikey_handlers.go`) before resolution, so the allow-list should name the same ids `GET /v1/models` returns.

## Capability flags as the API exposes them

| Capability | Where to read it | What the API enforces |
|---|---|---|
| Vision | `"image"` in `input_modalities` | Image parts on a model without it → 400; a vision model with no vision-capable provider online → 503 `model_unavailable` (`visionToolsFailFast`, `coordinator/api/inference_preprocess.go`) |
| Tools | `"tools"` in `supported_features` | Tool definitions are normalised and validated for every model (`NormalizeToolSchemas`, `coordinator/api/toolschema.go`; `validateToolConstraintPolicy`, `coordinator/api/tool_constraints.go`); uncompilable schemas → 422; only providers at or above the `tools` version floor (`capabilityVersionFloors`, `coordinator/registry/request_traits.go`) are eligible, and an inference-enforced `tool_choice` (`required` / named) cannot be combined with image content (400) |
| JSON / structured output | `"json_mode"`, `"structured_outputs"` in `supported_features` | `response_format` is forwarded to the provider without coordinator validation; whether it is honoured depends on the build's capabilities |
| Reasoning | `"reasoning"` in `supported_features` | `reasoning` / `reasoning_effort` are applied per model policy (`applyResolvedModelReasoningPolicy`, `coordinator/api/reasoning_request_policy.go`); reasoning tokens are reported in `usage.completion_tokens_details.reasoning_tokens` |
| Context | `context_length`, `max_output_length` | `max_tokens` clamped to `max_output_length`; prompts no provider can accept → 413 `payload_too_large` (`runInferenceAdmission`, `coordinator/api/inference_admission.go`) |
| Availability | `metadata.can_accept`, `routable_providers`, `warm_providers` | Zero routable providers at dispatch → 503 `model_unavailable` |

## Related

- Route table, headers, full error catalogue: [`../reference/api-contracts.md`](../reference/api-contracts.md)
- Aliases, builds and the registry lifecycle: [`../architecture/model-registry.md`](../architecture/model-registry.md)
- Prices: [`../reference/pricing-model.md`](../reference/pricing-model.md)
- Making your first call: [`quickstart.md`](quickstart.md)
