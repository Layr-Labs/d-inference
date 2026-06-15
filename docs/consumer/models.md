# Models

How Darkbloom exposes models to consumers and how to interpret the catalog.

## Model Catalog Is Dynamic

Darkbloom does not hardcode a consumer-facing model list. Models are registered in the coordinator's DB-backed registry via `POST /v1/admin/models/register`, published to R2, and discovered by providers on heartbeat. The authoritative consumer catalog is always:

```bash
GET /v1/models
```

The provider-facing catalog is at:

```bash
GET /v1/models/catalog
```

Registry handlers: [`coordinator/api/model_registry_handlers.go`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/model_registry_handlers.go). Model alias resolution: [`coordinator/api/model_alias_handlers.go`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/model_alias_handlers.go).

## Public Aliases and Concrete Builds

A public alias such as `gemma-4-26b` can resolve to different concrete builds over time (for example, `mlx-community/gemma-4-26b-a4b-it-fp8` today and a quantized 4-bit build tomorrow). Consumers call only the alias. The coordinator resolves the alias to a concrete build for routing and billing, then echoes the public alias back in the response so consumers never see the underlying build ID ([`coordinator/api/consumer.go:1350-1357`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/consumer.go#L1350-L1357)).

`/v1/models` hides concrete build IDs and shows only public aliases ([`coordinator/api/model_alias_handlers_test.go:956-962`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/model_alias_handlers_test.go#L956-L962)).

## Listing Models

**GET** `/v1/models` returns an OpenRouter-compatible model list with a Darkbloom `metadata` block:

```json
{
  "object": "list",
  "data": [
    {
      "id": "gemma-4-26b",
      "object": "model",
      "created": 1699999999,
      "owned_by": "darkbloom",
      "name": "Gemma 4 26B",
      "quantization": "int8",
      "context_length": 8192,
      "max_output_length": 4096,
      "pricing": {
        "prompt": "0.00000003",
        "completion": "0.000000165",
        "image": "0",
        "request": "0",
        "input_cache_read": "0"
      },
      "supported_sampling_parameters": [
        "temperature", "top_p", "top_k",
        "frequency_penalty", "presence_penalty", "repetition_penalty",
        "stop", "seed", "max_tokens"
      ],
      "supported_features": ["tools", "json_mode", "structured_outputs", "logprobs"],
      "metadata": {
        "model_type": "text",
        "provider_count": 12,
        "attested_providers": 10,
        "trust_level": "attested",
        "routable_providers": 8,
        "warm_providers": 5,
        "can_accept": true
      }
    }
  ]
}
```

Types: [`coordinator/api/types/types.go:106-171`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/types/types.go#L106-L171).

### Metadata Fields

| Field | Meaning |
|---|---|
| `model_type` | `text`, `embedding`, etc. |
| `provider_count` | Providers advertising this model |
| `attested_providers` | Providers that passed attestation |
| `trust_level` | Aggregate trust level (e.g., `attested`, `self_signed`) |
| `routable_providers` | Providers currently eligible to receive requests |
| `warm_providers` | Providers with the model already loaded |
| `can_accept` | Whether the fleet can accept a request right now |

## Capabilities

Capabilities are stored in the registry and translated into the OpenRouter feature vocabulary:

| Registry capability | OpenRouter feature |
|---|---|
| `tools`, `tool_use`, `function_calling` | `tools` |
| `json`, `json_mode`, `json_schema` | `json_mode` / `structured_outputs` |
| `logprobs` | `logprobs` |
| `reasoning`, `thinking` | `reasoning` |
| `vision`, `image`, `multimodal` | Adds `image` to input modalities |

Feature mapping: [`coordinator/api/openrouter_models.go:104-147`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/openrouter_models.go#L104-L147). Modality derivation: [`coordinator/api/openrouter_models.go:68-102`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/openrouter_models.go#L68-L102).

## Model Selection Guide

Because the catalog is dynamic, treat these as examples based on registry capabilities rather than guarantees:

| Use Case | What to Look For |
|---|---|
| General chat assistant | Text model with high `warm_providers` |
| Code generation | Model advertising `reasoning` or `tools` |
| Structured data extraction / JSON mode | `json_mode` or `structured_outputs` in `supported_features` |
| Multimodal (image + text) | `image` in `input_modalities` |
| Cost-sensitive high volume | Lower `pricing.prompt` and `pricing.completion` |
| Long context | High `context_length` |

## Pricing

Model prices come from the platform price table. `GET /v1/pricing` returns the current values and the fallback rates that apply when a model has no platform price. See [billing.md](billing.md).

## Hardware Requirements

Memory and chip requirements are a provider-side concern. The provider CLI reserves the model weight footprint plus a small one-request headroom (`ModelLoadAdmission.defaultLoadHeadroomGb = 2.0` GB, [`provider-swift/Sources/ProviderCore/Inference/ModelLoadAdmission.swift`](../../provider-swift/Sources/ProviderCore/Inference/ModelLoadAdmission.swift)) when loading a model. A ~28 GB weights model therefore needs roughly `28 + 2 + provider.memory_reserve_gb` of usable RAM. Model weights are cached under `~/.cache/huggingface/hub` ([`provider-swift/Sources/ProviderCoreFoundation/ModelScanner.swift`](../../provider-swift/Sources/ProviderCoreFoundation/ModelScanner.swift)). Consumers do not need to manage this; the coordinator's capacity check rejects requests that no provider can fit.

## Deprecation

A model can be staged for deprecation via registry metadata. Deprecated models are removed from `GET /v1/models` but continue to serve existing requests until the deprecation date. Providers auto-evict after a grace period. The deprecation date is read from `metadata.deprecation_date` ([`coordinator/api/openrouter_models.go:284-291`](https://github.com/eigeninference/d-inference/blob/master/coordinator/api/openrouter_models.go#L284-L291)).
