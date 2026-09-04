# System overview — how a Darkbloom request works

> Last updated: 2026-09-03 · commit `5d400cf75`

Darkbloom sells inference on other people's Apple Silicon Macs. A Go
**coordinator** accepts OpenAI- and Anthropic-shaped HTTP requests, picks an
attested **provider** (a Mac running the Swift `darkbloom` CLI), re-encrypts the
request to that provider, relays the streamed answer back, and settles money
between the two accounts. This page names every component and walks one request
through them; each section links to the page that owns the detail.

## Context

The system has to satisfy three parties at once: consumers want a drop-in
replacement for a hosted API (same wire format, same SDKs, lower price);
providers want to earn from idle hardware without exposing it; and neither
party trusts the other or the operator with more than necessary. The design
answer is a thin control plane that never runs a model, a fat client that runs
the model in-process on hardware whose identity Apple can vouch for, and
per-hop encryption so that each party sees only what its role needs
([`security/encryption.md`](security/encryption.md)).

## Components

| Component | Code | Runs where | Job |
|---|---|---|---|
| Coordinator | `coordinator/` (Go) | GCP Confidential VM (AMD SEV); prod `api.darkbloom.dev`, dev `api.dev.darkbloom.xyz` | HTTP API, provider WebSocket, registry and routing, attestation, billing, model catalog, telemetry |
| Provider | `provider-swift/` (Swift; product `darkbloom`) | Operators' Macs, as a LaunchAgent | Connect out to the coordinator, prove identity, run models in-process with MLX, encrypt responses |
| Prompt-contract sidecar | `coordinator/promptsidecar/` (Rust) | Beside the coordinator | Token-boundary planning for prefix-cache routing; failure-isolated |
| Console | `console-ui/` (Next.js 16 / React 19) | Vercel, `console.darkbloom.dev` | Sign-in, API keys, balance, usage, chat, provider dashboard |
| Admin UI | `admin-ui/` (Next.js) | Internal | Read-only operator dashboard over the Postgres read replica |
| Landing | `landing/` (static) | `darkbloom.dev` | Marketing site |
| E2E harness | `e2e/` | CI and developer machines | Full-stack integration and benchmark runs |
| MLX forks | `libs/mlx`, `libs/mlx-swift`, `libs/mlx-swift-lm` (submodules) | Compiled into the provider | The inference engine, pinned by commit |

Detail: [`components/coordinator.md`](components/coordinator.md),
[`components/provider.md`](components/provider.md),
[`components/console-ui.md`](components/console-ui.md),
[`components/admin-ui.md`](components/admin-ui.md),
[`components/mlx-swift.md`](components/mlx-swift.md),
[`prompt-contract-sidecar.md`](prompt-contract-sidecar.md).

![Darkbloom system architecture](../assets/diagrams/system-architecture.svg)

## One request, end to end

```mermaid
sequenceDiagram
  autonumber
  participant C as Consumer (SDK / curl)
  participant K as Coordinator
  participant P as Provider (darkbloom)
  P->>K: WebSocket register + attestation, heartbeat every 5 s
  K->>P: challenge every 5 min (30 s to answer)
  C->>K: POST /v1/chat/completions (TLS; optional sealed body)
  K->>K: auth, rate limit, validate, resolve alias → build, reserve balance
  K->>K: select provider (eligibility gates → cost model → reserve slot)
  K->>P: inference_request, NaCl Box to provider key
  P->>P: decrypt, run model in-process, encrypt each chunk
  P-->>K: encrypted SSE chunks
  K-->>C: SSE chunks (first byte only after first content)
  P->>K: inference_complete (usage, timings, profile)
  K->>K: settle: charge consumer, credit provider, write telemetry
```

1. **Provider joins.** `darkbloom start` connects outbound to `GET /ws/provider`
   and sends `register` with a Secure Enclave–signed attestation blob. The
   coordinator verifies it (`coordinator/attestation/attestation.go`), assigns a
   trust level, and re-challenges every `DefaultChallengeInterval` (5 min) with a
   `ChallengeResponseTimeout` of 30 s (`coordinator/api/provider.go`). The
   provider heartbeats every `heartbeat_interval_secs` (5;
   `provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift`) with
   capacity, slot state, and telemetry. Messages:
   [`../reference/protocol-messages.md`](../reference/protocol-messages.md).
2. **Consumer calls.** Every route passes
   `corsMiddleware → recoverMiddleware → loggingMiddleware → bodyLimitMiddleware`;
   inference routes add `drainGate → requireAuth → rateLimitConsumer →
   sealedTransport` (`coordinator/api/server.go`, `routes`). `/v1/chat/completions`
   and `/v1/responses` share `handleChatCompletions`; `/v1/completions` and
   `/v1/messages` share `handleGenericInference` (`coordinator/api/consumer.go`).
   Routes and shapes: [`../reference/api-contracts.md`](../reference/api-contracts.md).
3. **Admission.** The handler validates the body (16 MiB cap, tool-schema
   normalisation), resolves the public alias to a concrete build
   ([`model-registry.md`](model-registry.md)), reserves the consumer's balance for
   the worst-case output ([`billing.md`](billing.md)), and applies token-rate
   admission ([`../reference/api-contracts.md`](../reference/api-contracts.md)).
4. **Selection.** The registry filters providers through one ordered liveness
   gate (`providerLivenessGateReasonLocked`,
   `coordinator/registry/routing_eligibility.go`) — online, trusted at or above
   the floor, runtime-verified, private-text capable, challenge verified within
   `challengeFreshnessMaxAge` (16 min) — then scores survivors with an
   estimated-completion-time cost model and reserves the cheapest
   (`coordinator/registry/scheduler.go`). Every rejection has a name from a
   closed vocabulary (`coordinator/registry/gate_reason.go`).
   [`routing.md`](routing.md), [`scheduling.md`](scheduling.md).
5. **Dispatch.** The request body is sealed with a per-request NaCl Box to the
   provider's attested X25519 key (`coordinator/internal/e2e/e2e.go`) and sent
   as `inference_request`. If the first content is late, a speculative second
   dispatch starts at `speculativeTimerRatio` (0.5) of the first-content
   deadline; the coordinator tries at most `maxDispatchAttempts` (64) providers
   (`coordinator/api/consumer.go`). [`data-flow.md`](data-flow.md).
6. **Inference.** The provider decrypts in-process, runs the continuous-batching
   engine over the pinned MLX forks, and encrypts every response chunk to the
   coordinator's ephemeral key. [`inference.md`](inference.md),
   [`prefix-cache.md`](prefix-cache.md).
7. **Relay.** The coordinator commits the HTTP response only when the first
   content chunk arrives; failures before that are plain JSON errors, never a
   broken SSE stream. Chunks are normalised and relayed; one trailing extras
   event carries the provider's signature and response hash, then `[DONE]`.
   Post-commit trust and timing appear as `X-Provider-*`, `X-Timing`, and
   `X-Inference-Job-ID` headers.
8. **Settlement.** `inference_complete` carries usage and timings; the
   coordinator charges the reservation's actual cost, credits the provider's
   account, releases the remainder, and records telemetry and a request profile
   ([`billing.md`](billing.md), [`telemetry.md`](telemetry.md),
   [`system-profiler.md`](system-profiler.md)).

## Trust and privacy in one paragraph

Providers hold one of three trust levels — `none`, `self_signed`, `hardware`
(`TrustLevel`, `coordinator/registry/registry.go`). Public traffic requires at
least `MinTrustLevel`, default `hardware` (`EIGENINFERENCE_MIN_TRUST`,
`coordinator/registry/config.go`), which means a Secure Enclave key bound to an
Apple Managed Device Attestation chain plus an MDM posture check; APNs
code-identity attestation additionally proves the running binary is the
released one. The only backend is `mlx-swift` (`BackendMLXSwift`); providers
that proxy text to another process, disable anti-debug, or fail the SIP check
are not routable for private text (`providerSupportsPrivateTextLocked`,
`coordinator/registry/registry.go`). Consumer bodies are decrypted inside the
coordinator's confidential-VM memory for routing and billing and are not logged
or retained; the provider is the plaintext endpoint. Exact conditions:
[`security/attestation.md`](security/attestation.md); exact crypto and what is
retained: [`security/encryption.md`](security/encryption.md).

## Money in one paragraph

The ledger is in micro-USD. A request reserves the consumer's balance for its
worst-case cost before dispatch and settles the actual cost from
`inference_complete`; the provider's account is credited net of the platform
fee, whose value is stated once, in [`billing.md`](billing.md#invariants).
Default per-token prices and the price-resolution order are in
[`../reference/pricing-model.md`](../reference/pricing-model.md). Consumers
fund balances through Stripe; providers withdraw through Stripe Connect. A
consumer routing to a provider it owns (self-route) pays nothing.

## Invariants

1. The coordinator never executes a model; the provider never accepts inbound
   connections from the coordinator (it connects out over `GET /ws/provider`).
2. A provider is routable for public traffic only if every clause of
   `providerLivenessGateReasonLocked` passes; there is no second code path
   (`coordinator/registry/routing_eligibility.go`).
3. Every coordinator → provider request body is a fresh NaCl Box to the key the
   provider attested at registration (`coordinator/internal/e2e/e2e.go`).
4. Nothing is written to the consumer's HTTP response before the first content
   chunk, so a failed dispatch can always fail over or return a JSON error
   (`handleChatCompletions`, `coordinator/api/consumer.go`).
5. Balance is reserved before dispatch (`reserveInferenceBalance`,
   `coordinator/api/inference_admission.go`) and settled from
   `inference_complete` (`handleComplete`, `coordinator/api/provider.go`): the
   difference is refunded, an overage is charged. A request that fails before
   any provider usage is reported is refunded in full (`refundReservedBalance`,
   `coordinator/api/consumer.go`).
6. The provider version the coordinator advertises (`LatestProviderVersion`,
   `coordinator/api/server.go`) equals `ProviderCore.version`; the test
   `coordinator/api/provider_version_sync_test.go` enforces it.
7. Telemetry wire types are mirrored in Go, Swift, and TypeScript and pinned by
   symmetry tests; the ingestion allowlist never admits prompt or completion
   text ([`telemetry.md`](telemetry.md)).
8. Production persistence is Postgres; the coordinator refuses to start
   without `EIGENINFERENCE_DATABASE_URL` unless
   `EIGENINFERENCE_ALLOW_MEMORY_STORE=true` (`coordinator/cmd/coordinator/main.go`).
   [`storage.md`](storage.md).

## Failure modes

| Failure | What happens | Where described |
|---|---|---|
| No eligible provider for a model | 503 with a structured error before any bytes are streamed; rejection reasons tallied | [`routing.md`](routing.md) |
| Provider slow to first content | Speculative second dispatch; the first to produce content wins; the other is cancelled | [`data-flow.md`](data-flow.md) |
| Provider fails after commit | In-band error event on the SSE stream (the HTTP status is already sent); settlement follows whatever usage the provider reported | [`data-flow.md`](data-flow.md), [`billing.md`](billing.md) |
| Consumer disconnects before the provider finishes | Billing record parked for `defaultTerminalSettleGrace` (30 s), then settled or refunded (`coordinator/api/settlement.go`) | [`billing.md`](billing.md) |
| Attestation challenge fails or goes stale | Provider marked untrusted / `challenge_stale`; leaves routing until re-verified | [`security/attestation.md`](security/attestation.md) |
| Coordinator restart | Providers reconnect with backoff 1 → 30 s; state is in Postgres; trust may be reused within a window | [`components/provider.md`](components/provider.md), [`security/attestation.md`](security/attestation.md) |

## Code map

| Concern | Entry point |
|---|---|
| Route table and middleware | `coordinator/api/server.go` (`routes`) |
| Chat / Responses handler | `coordinator/api/consumer.go` (`handleChatCompletions`) |
| Completions / Messages handler | `coordinator/api/consumer.go` (`handleGenericInference`) |
| Provider WebSocket, registration, challenges | `coordinator/api/provider.go` |
| Attestation verification | `coordinator/attestation/attestation.go` |
| Eligibility gate | `coordinator/registry/routing_eligibility.go` (`providerLivenessGateReasonLocked`) |
| Cost model and reservation | `coordinator/registry/scheduler.go` |
| Per-request encryption | `coordinator/internal/e2e/e2e.go`; optional sender sealing `coordinator/api/sender_encryption.go` |
| Pricing and ledger | `coordinator/payments/pricing.go`, `coordinator/billing/` |
| Provider main loop | `provider-swift/Sources/ProviderCore/ProviderLoop.swift` |
| Provider CLI entry | `provider-swift/Sources/darkbloom/Darkbloom.swift` |
| Engine bridge, KV caches, scheduling | `provider-swift/Sources/ProviderCore/Inference/`, `provider-swift/Sources/ProviderCore/KVCache/`, `provider-swift/Sources/ProviderCore/KVCacheSSD/`, `provider-swift/Sources/ProviderCore/Scheduling/` |
| Console API relay | `console-ui/src/app/api/` |

## Related

[`data-flow.md`](data-flow.md) ·
[`../consumer/quickstart.md`](../consumer/quickstart.md) ·
[`../provider/quickstart.md`](../provider/quickstart.md) ·
[`../operations/README.md`](../operations/README.md) ·
[`../glossary.md`](../glossary.md)
