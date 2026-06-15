# Reference

Dry reference material for Darkbloom's public interfaces, wire protocols, schemas, and operational formats.

## API and protocol

| Doc | Content |
|---|---|
| [api-contracts.md](api-contracts.md) | OpenAI-compatible HTTP endpoints, auth, headers, errors |
| [protocol-messages.md](protocol-messages.md) | WebSocket message types between coordinator and provider |

## Schemas and formats

| Doc | Content |
|---|---|
| [telemetry-schema.md](telemetry-schema.md) | Telemetry event schema, field allowlist, and symmetry rules |
| [model-registry-format.md](model-registry-format.md) | Manifest schema, model registration, and alias format |
| [pricing-model.md](pricing-model.md) | Micro-USD pricing, provider custom prices, service accounts |

## SSD KV cache reference

| Doc | Content |
|---|---|
| [ssd-kv-cache.md](ssd-kv-cache.md) | SSD cache wire format and configuration |
| [ssd-kv-cache-design.md](ssd-kv-cache-design.md) | Design details for the checkpoint tier |
| [ssd-kv-cache-hybrid-models.md](ssd-kv-cache-hybrid-models.md) | Exact-checkpoint tier for hybrid sliding-window models |

These documents are intended to be consulted, not read front-to-back. For narrative explanations, see the [architecture docs](../architecture/README.md).
