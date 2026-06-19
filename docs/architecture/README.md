# Architecture

This directory is the source of truth for how Darkbloom works. The code in `coordinator/`, `provider-swift/`, `console-ui/`, and `e2e/` is canonical; these docs describe and cite it.

![Darkbloom system architecture](../assets/diagrams/system-architecture.svg)

## Start here

| Doc | What it covers |
|---|---|
| [overview.md](overview.md) | High-level system architecture, components, and trust model |
| [data-flow.md](data-flow.md) | End-to-end request lifecycle from consumer to provider and back |

## Components

| Doc | Component |
|---|---|
| [components/coordinator.md](components/coordinator.md) | Go control plane (HTTP API, WebSocket, registry, billing) |
| [components/provider.md](components/provider.md) | Swift `darkbloom` provider CLI and inference engine |
| [components/console-ui.md](components/console-ui.md) | Next.js / React consumer web interface |
| [components/mlx-swift.md](components/mlx-swift.md) | MLX-Swift inference backend and model execution |
| [components/consumer.md](components/consumer.md) | Consumer surface: OpenAI-compatible API, SDKs, and console |

## Security

| Doc | Concern |
|---|---|
| [security/encryption.md](security/encryption.md) | NaCl Box encryption between consumer, coordinator, and provider |
| [security/attestation.md](security/attestation.md) | Secure Enclave, MDM/MDA, APNs code identity, and trust levels |
| [security/enrollment.md](security/enrollment.md) | Device enrollment: MDM, SCEP, ACME, and profile generation |
| [security/identity-binding.md](security/identity-binding.md) | How APNs, X25519, SE P-256, and MDA identities bind together |

## Operations inside the architecture

| Doc | Concern |
|---|---|
| [operations/routing.md](operations/routing.md) | Provider selection and cost-based scheduling |
| [operations/scheduling.md](operations/scheduling.md) | Queues, slot states, token budgets, and model swaps |
| [operations/billing.md](operations/billing.md) | Pricing, reservations, ledger, and payouts |
| [operations/model-registry.md](operations/model-registry.md) | Model manifests, aliases, and provider downloads |
| [operations/telemetry.md](operations/telemetry.md) | Telemetry schema, symmetry, and ingestion |

## Cross-cutting topics

| Doc | Topic |
|---|---|
| [inference.md](inference.md) | How inference requests are decoded, batched, and served |
| [request-outcome-observability.md](request-outcome-observability.md) | Request outcome taxonomy across client, provider, and billing paths |
| [storage.md](storage.md) | KV cache, prefix cache, and on-disk model storage |
| [payments.md](payments.md) | Payments architecture (Stripe Connect, ledger, withdrawals) |
| [hardware-support.md](hardware-support.md) | Supported Apple Silicon tiers and capability mapping |

## Design decisions (ADRs)

| Doc | Decision |
|---|---|
| [decisions/apns-code-attestation.md](decisions/apns-code-attestation.md) | APNs-based code-identity attestation for genuine-binary proof |
| [decisions/ssd-kv-cache.md](decisions/ssd-kv-cache.md) | SSD-backed prefix cache architecture |
| [decisions/kv-cache-lookup-shadowing.md](decisions/kv-cache-lookup-shadowing.md) | RAM-first lookup shadowing on hybrid sliding-window models |

## Rules

- Claims must cite canonical code paths.
- The privacy model is hop-by-hop encryption: the coordinator decrypts consumer bodies in Confidential VM memory for routing and billing, but does not log or retain prompt content.
- If code and docs disagree, the code wins; open a PR to fix the docs.
