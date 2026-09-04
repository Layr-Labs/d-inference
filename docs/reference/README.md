# Reference — exact shapes and values

> Last updated: 2026-09-03 · commit `5d400cf75`

Tables and schemas for Darkbloom's public interfaces, wire protocol,
configuration, and formats. Consult these; do not read them front to back.
Every row cites the code that defines it. For how and why things work, use
[`../architecture/README.md`](../architecture/README.md).

## Interfaces

| Page | Content |
|---|---|
| [api-contracts.md](api-contracts.md) | Every coordinator HTTP route: method, path, auth, request and response shapes, headers, status codes, SSE framing |
| [protocol-messages.md](protocol-messages.md) | Every WebSocket message between coordinator and provider, field by field, with the Go and Swift types |

## Configuration and schemas

| Page | Content |
|---|---|
| [configuration.md](configuration.md) | Every environment variable of the coordinator, provider CLI, console UI, and admin UI: default, where read, effect |
| [telemetry-schema.md](telemetry-schema.md) | Telemetry event types, field allowlist, optional-field and casing rules pinned by the symmetry tests |
| [telemetry-inventory.md](telemetry-inventory.md) | Every telemetry datum collected: producer, sink, cadence, retention |
| [pricing-model.md](pricing-model.md) | Micro-USD units, price resolution order, fees, reservations, service accounts |
| [model-registry-format.md](model-registry-format.md) | Manifest schema, registration payload, alias format |

## Prefix cache formats

| Page | Content |
|---|---|
| [ssd-kv-cache.md](ssd-kv-cache.md) | On-disk format, paths, and configuration of the encrypted SSD prefix cache |
| [ssd-kv-cache-hybrid-models.md](ssd-kv-cache-hybrid-models.md) | Adoption and recompute rules on hybrid sliding-window models |

## Vocabulary

| Page | Content |
|---|---|
| [`../glossary.md`](../glossary.md) | Canonical term for each thing and the page that owns its definition |

Superseded designs (for example the pre-v0.7.5 SSD cache design) live under
[`../design/README.md`](../design/README.md).
