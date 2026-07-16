# Inference Architecture

Darkbloom runs inference **in-process** inside the provider CLI. There is no
subprocess or local server; the MLX engine is linked directly via
`mlx-swift-lm`.

```
HTTP/WebSocket request
        │
        ▼
ProviderLoop / StandaloneServer
        │
        ▼
MultiModelBatchSchedulerEngine (OpenAI translation and model acquire)
        │
        ▼
EngineV2Bridge (one per resident model)
        │
        ▼
mlx-swift-lm ContinuousBatchingV2
        │
        ▼
Apple Silicon GPU (Metal)
```

## Continuous batching

The provider uses `mlx-swift-lm`'s continuous-batching scheduler:

- Prompts are prefilled in batches.
- Decode steps are run together for all active requests.
- New requests are added to the running batch when capacity allows.

Key files are `EngineV2Bridge.swift`, `EngineV2Runtime.swift`,
`ProviderLoop+ModelLoading.swift`, and `Server/StandaloneServer.swift`.

## Capacity reporting

Providers report `BackendCapacity.Slots` to the coordinator. The coordinator
scheduler uses this as the authoritative capacity source. Each slot reports a state such as
`running`, `idle`, `crashed`, `reloading`, or `idle_shutdown`.

Code:

- Provider side: `provider-swift/Sources/ProviderCore/Protocol/Messages.swift`
  and the heartbeat path in `ProviderLoop.swift`.
- Coordinator side: `coordinator/registry/registry.go` `snapshotProviderLocked`
  and `coordinator/registry/scheduler.go`.

## Prefix cache

An EngineV2 prefix cache accelerates repeated or shared prompts. The encrypted
SSD tier is the only production tier. It is selected by default and can be
disabled with `DARKBLOOM_PREFIX_CACHE=0`; there is no production RAM cache or
persistent memory carve. Pure-attention and supported hybrid sliding-window
models use CBv2 layer-aware block snapshots and adoption bounds. The production
gate is `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift`.

See [`reference/ssd-kv-cache.md`](../reference/ssd-kv-cache.md) for the as-built reference and
[`reference/ssd-kv-cache-hybrid-models.md`](../reference/ssd-kv-cache-hybrid-models.md) for the hybrid-model design.

## KV cache on disk

Cache files are AES-256-GCM encrypted with a Secure-Enclave-wrapped KEK and
per-file DEK. Plaintext KV never touches disk. See [`reference/ssd-kv-cache.md`](../reference/ssd-kv-cache.md)
for the file format and threat model.

## Model catalog

The coordinator registry holds model metadata and points to R2 manifests at
`https://models.darkbloom.ai`. Providers do not hardcode a model catalog; they
receive `desired_models` pushes and reconcile their local state.

Code:

- Coordinator registry: `coordinator/registry/` and `coordinator/api/model_alias_handlers.go`.
- Provider download/publish: `provider-swift/Sources/ProviderCore/ModelRegistry/`.
