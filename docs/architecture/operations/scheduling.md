# Scheduling and Admission

Scheduling in Darkbloom has two layers: the **request queue** absorbs transient overload, and the **admission gate** decides whether a specific provider can accept a request without exhausting memory or concurrency limits. This doc describes the queue, token-budget admission, backend slot states, and demand-driven model loading.

Canonical code lives in `coordinator/registry/scheduler.go`, `coordinator/registry/queue.go`, and `coordinator/protocol/messages.go`.

## Privacy boundary

The coordinator decrypts request bodies inside Confidential-VM memory to estimate token counts for admission and billing, then immediately re-encrypts the body to the selected provider's X25519 key. Prompt content is not logged or retained. See the canonical privacy model in [`../../AGENTS.md`](../../AGENTS.md).

## Request queue

When every eligible provider is full, requests are held in a per-model `RequestQueue` (`coordinator/registry/queue.go:70-76`) instead of failing immediately.

Defaults (`coordinator/registry/registry.go:772`):

| Limit | Value |
|---|---|
| Max size per model | `10` |
| Max wait | `120` seconds |

Queue behavior:

* `Enqueue` (`queue.go:89-106`) adds a request; returns `ErrQueueFull` when the per-model limit is reached.
* `WaitForProviderContext` (`queue.go:110-132`) blocks until a provider is assigned, the timeout fires, or the request context is cancelled.
* `PopNextFresh` (`queue.go:148-175`) removes stale requests lazily and returns the first fresh request for a model.
* `RequeueFront` (`queue.go:177-186`) puts a request back at the head of its model queue when a candidate was selected but then became unavailable before the waiter could claim it.

Queued requests are drained by `drainQueuedRequestsForModels` (`scheduler.go:1214-1269`), called when a provider finishes a request (`SetProviderIdle`) or when a model finishes loading (`DrainQueuedRequestsForModel`).

## Token-budget admission

The primary admission gate is `freeMemoryAdmits` (`coordinator/registry/scheduler.go:723-772`). It uses the provider-reported token budget when available; otherwise it falls back to a memory-based estimate.

### Budget-based admission

When `BackendCapacity.Slots.ActiveTokenBudgetMax > 0`:

```text
activeTokenBudgetUsed + queuedTokenBudget + coordinatorExtra + requestTokens <= activeTokenBudgetMax
```

* `activeTokenBudgetUsed` — tokens reserved by active requests (`prompt + max_output`).
* `queuedTokenBudget` — tokens reserved by backend-queued requests.
* `coordinatorExtra` — coordinator-side pending tokens not yet reflected in the heartbeat, capped at zero (`max(0, pendingMaxTokens - committedTokenBudget)`).
* `requestTokens` — `estimatedPromptTokens + requestedMaxTokens` for the incoming request.

### Memory-based fallback

For legacy providers without a token budget:

```text
required = modelSizeGB (0 if already resident) + kvCacheGB
totalMemoryGB - gpuMemoryActiveGB >= required
```

`kvCacheGB` is estimated as `tokens × kvCacheBytesPerToken / bytesPerGB` with `kvCacheBytesPerToken = 400_000` (~0.38 MB per token, `scheduler.go:49`).

A model that is available on disk but not loaded may be cold-loaded if the provider has no in-flight requests: the scheduler checks whether the model individually fits in total memory rather than requiring room alongside currently-loaded models (`scheduler.go:765-768`).

### Absolute hardware-fit gate

Before the capacity gate, `buildCandidateWithReason` (`scheduler.go:839-842`) checks whether the model can ever fit the node's total memory. It prefers the catalog's `min_ram_gb` and falls back to a heuristic multiple (`modelMemoryHeadroomFactor = 2.0`) of the on-disk weight size only when `min_ram_gb` is unknown (`scheduler.go:126-153`). A resident model (`running` or `idle`) skips this gate because it has already demonstrably fit.

## Backend capacity and slot states

Swift providers report live capacity in `BackendCapacity` (`coordinator/protocol/messages.go:214-220`):

```go
type BackendCapacity struct {
    Slots             []BackendSlotCapacity
    GPUMemoryActiveGB float64
    GPUMemoryPeakGB   float64
    GPUMemoryCacheGB  float64
    TotalMemoryGB     float64
}
```

Each `BackendSlotCapacity` (`protocol/messages.go:195-209`) describes one model slot:

| Field | Meaning |
|---|---|
| `Model` | Model ID for this slot |
| `State` | `running`, `idle`, `idle_shutdown`, `crashed`, `reloading` |
| `NumRunning` | Requests actively generating |
| `NumWaiting` | Requests queued inside the backend scheduler |
| `MaxConcurrency` | Provider-reported concurrent request cap for this slot |
| `ActiveTokens` | Sum of `prompt + completion` across running requests |
| `MaxTokensPotential` | Sum of `max_tokens` across running requests |
| `ObservedDecodeTPS` | EWMA of measured decode TPS |
| `ActiveTokenBudgetUsed` | Tokens reserved by active requests |
| `ActiveTokenBudgetMax` | Maximum token budget for this slot |
| `QueuedTokenBudget` | Tokens reserved by queued requests |

When `BackendCapacity` is present it is **authoritative** for warm detection, slot state, and concurrency. `WarmModels` is only a fallback for legacy providers (`coordinator/registry/registry.go:2429-2446`).

## Concurrency headroom

`hasConcurrencyHeadroomForModelLocked` (`coordinator/registry/registry.go:652-664`) checks whether the provider can accept another request for the model. For Swift providers it uses the per-slot `MaxConcurrency`; for legacy providers it falls back to a global concurrency cap derived from hardware memory.

The under-lock re-check in `providerCanAdmitLocked` (`scheduler.go:1029-1050`) also rejects slots whose state is `crashed` or `reloading` at reservation time.

## Demand-driven model swapping

When requests queue for a model that has no warm provider, the coordinator proactively triggers a model load on an idle provider that has the model available on disk.

`TriggerModelSwaps` (`coordinator/registry/registry.go:2335-2351`) runs after heartbeat processing and queue drain:

1. `expirePendingModelLoads` removes load reservations older than `pendingModelLoadTTL`.
2. `planModelLoadActions` finds queued models with no warm provider and picks the eligible provider with the fewest pending requests (`bestModelLoadProviderLocked`, `registry.go:2451-2477`).
3. `reservePendingModelLoads` marks the chosen provider-model pairs in-flight.
4. `sendModelLoadActions` sends `load_model` commands over the provider WebSocket.

A provider already has a pending `load_model` is never selected for a second one, to avoid swap oscillation on single-slot providers (`registry.go:2457-2460`). Only idle providers (zero pending requests) are chosen, because an active slot cannot be evicted (`registry.go:2468-2471`).

## Coordinator → provider loading commands

Three WebSocket messages drive model state on the provider (`coordinator/protocol/messages.go`):

| Message | Type | Purpose |
|---|---|---|
| `LoadModelMessage` | `load_model` | Eagerly load and pin a model in GPU memory |
| `PrefetchModelMessage` | `prefetch_model` | Download and verify a build on disk without loading it |
| `DesiredModelsMessage` | `desired_models` | Declarative statement of the desired build per public alias |

`DesiredModelsMessage` is sent at registration and whenever an alias changes (`coordinator/api/model_alias_handlers.go:246-270`). The provider reconciles: it background-prefetches missing desired builds, then hard-swaps and emits `models_update` once verified (`protocol/messages.go:395-406`).

## Multi-model slots

The Swift runtime can keep multiple model slots loaded simultaneously. The default configured cap is `3` (`provider-swift/Sources/ProviderCore/Config/ProviderConfig.swift:74`). The effective cap at runtime is clamped to the number of live models the provider advertises (`provider-swift/Sources/ProviderCore/ProviderLoop.swift:191`). When a new load exceeds the cap, the provider evicts the least-recently-used idle slot (`provider-swift/Sources/ProviderCore/ProviderLoop.swift:2523-2538`).

The coordinator's scheduler does not enforce `maxModelSlots` directly; it relies on the provider-reported `BackendCapacity.Slots` and the token-budget/memory admission gates.

## Preflight capacity check

`QuickCapacityCheck` (`scheduler.go:1079-1193`) performs a fast, read-only scan using the same gates as dispatch. It returns:

* `candidateCount` — providers that could route right now.
* `capacityRejections` — providers that serve the model but are full (used to emit a 429).
* `modelTooLarge` — providers that can never fit the model (used to emit a 503 instead of a retry loop).

The consumer handler uses these counts to decide between `404`/`503` and a retryable `429` with `Retry-After` (`coordinator/api/consumer.go:1504`, `consumer.go:918-943`).
