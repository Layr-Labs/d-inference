# Architecture — how Darkbloom works

> Last updated: 2026-09-03 · commit `5d400cf75`

Explanation pages: context, mechanism, invariants, failure modes, and a code
map for each part of the system. The code in `coordinator/`,
`provider-swift/`, `console-ui/`, `admin-ui/`, and `e2e/` is canonical; these
pages describe and cite it by path and symbol. For exact shapes and values use
[`../reference/README.md`](../reference/README.md); for procedures use the
how-to and runbook directories listed in [`../README.md`](../README.md).

![Darkbloom system architecture](../assets/diagrams/system-architecture.svg)

## Start here

| Page | Covers |
|---|---|
| [overview.md](overview.md) | Components, trust boundaries, and the request path in one page |
| [data-flow.md](data-flow.md) | One request end to end: HTTP ingress, routing, encryption, provider WebSocket, SSE egress, settlement |

## Components

| Page | Component |
|---|---|
| [components/coordinator.md](components/coordinator.md) | Go control plane: process layout, HTTP and WebSocket servers, store, background jobs |
| [components/provider.md](components/provider.md) | Swift `darkbloom` provider: connection loop, engine bridge, hardened runtime, service management, auto-update |
| [components/consumer.md](components/consumer.md) | Consumer surface: OpenAI and Anthropic compatibility, SDKs, console |
| [components/console-ui.md](components/console-ui.md) | Next.js 16 / React 19 console: pages, `/api/*` relay handlers, Privy and console-key credential paths, SSE chat, optional browser-side sealing; the static `landing/` site |
| [components/admin-ui.md](components/admin-ui.md) | Internal read-only operator dashboard: HTTP Basic gate, single `pg.Pool` on the read replica, SELECT-only server components |
| [components/mlx-swift.md](components/mlx-swift.md) | The three pinned submodules (`mlx`, `mlx-swift`, `mlx-swift-lm`), what each provides, what `MLXLMServer` is used for, and the source-matched `mlx.metallib` |

## Security

| Page | Concern |
|---|---|
| [security/encryption.md](security/encryption.md) | The privacy model: NaCl Box on each hop, what the coordinator decrypts and does not retain, key lifetimes. The only page that states it |
| [security/attestation.md](security/attestation.md) | Trust levels and the exact condition for each: Secure Enclave signature, MDM cross-check, MDA, APNs code identity |
| [security/enrollment.md](security/enrollment.md) | Device enrollment: MDM profile generation and signing, SCEP, webhook |
| [security/identity-binding.md](security/identity-binding.md) | How APNs, X25519, SE P-256, and MDA identities bind to one provider |

## Routing and scheduling

| Page | Concern |
|---|---|
| [routing.md](routing.md) | How a request becomes a provider choice: eligibility gates, cost model, selection, hedged dispatch, servability, breakers |
| [scheduling.md](scheduling.md) | Per-model queue, slot states, token-budget admission, concurrency caps, model swaps, warm pool, heartbeat and eviction |
| [cache-aware-routing.md](cache-aware-routing.md) | Provider-confirmed exact prefix-cache routing: proof, holders, cost discount, `EIGENINFERENCE_CACHE_ROUTING_MODE` (default `off`) |
| [prompt-contract-sidecar.md](prompt-contract-sidecar.md) | The Rust `promptsidecar`: token-boundary planning for cache routing, artifact identity, failure isolation |

## Inference engine

| Page | Concern |
|---|---|
| [inference.md](inference.md) | CBv2 request lifecycle and `CBv2RequestTiming`, scheduler and lease defaults, deadlines, MTP, sampling, tool parsers, vision constraints, supported families and quantization |
| [prefix-cache.md](prefix-cache.md) | KV layouts (contiguous default, paged), 256-token block hashing, prefix-reuse plan per family, RAM staging and the encrypted SSD tier; why a default box builds no SSD cache |
| [hardware-support.md](hardware-support.md) | Memory model: unified-memory cap, activation floors, load gate, KV budget and re-slice; platform and hardware gates |
| [model-registry.md](model-registry.md) | Model manifests, aliases, publishing to R2, registration, provider downloads |

## Data, money, and observability

| Page | Concern |
|---|---|
| [storage.md](storage.md) | Coordinator persistence: Postgres tables and migrations, memory store, retention jobs |
| [billing.md](billing.md) | Pricing, reservations, ledger, Stripe deposits and Connect payouts, referrals, base rewards |
| [telemetry.md](telemetry.md) | What telemetry exists, Go/Swift/TS symmetry, ingestion allowlist, Datadog |
| [request-outcome-observability.md](request-outcome-observability.md) | Closed outcome taxonomy across client, provider, and billing dimensions |
| [system-profiler.md](system-profiler.md) | Per-attempt request profiles and fleet snapshots: schema, clocks, validation, query recipes |

## Not here

- Decisions and plans, each with a shipped/superseded status: [`../design/README.md`](../design/README.md).
- Dated measurements and incidents: [`../reports/README.md`](../reports/README.md).
- Authoring rules (page skeletons, citing, stamps, checks): [`../AGENTS.md`](../AGENTS.md).
