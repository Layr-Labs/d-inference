# Inference Architecture

Darkbloom runs inference **in-process** inside the provider CLI. There is no
subprocess or local server; the MLX engine is linked directly via
`mlx-swift-lm`.

```
HTTP/WebSocket request
        │
        ▼
BatchScheduler (actor)
        │
        ▼
MLXLMCommon continuous-batching engine
        │
        ▼
Apple Silicon GPU (Metal)
```

## Continuous batching

The provider uses `mlx-swift-lm`'s continuous-batching scheduler:

- Prompts are prefilled in batches.
- Decode steps are run together for all active requests.
- New requests are added to the running batch when capacity allows.

Key file: `provider-swift/Sources/ProviderCore/Inference/BatchScheduler.swift`.

## Capacity reporting

Providers report `BackendCapacity.Slots` to the coordinator. The scheduler uses
this as the authoritative capacity source. Each slot reports a state such as
`running`, `idle`, `crashed`, `reloading`, or `idle_shutdown`.

Code:

- Provider side: `provider-swift/Sources/ProviderCore/Protocol/Messages.swift`
  and the heartbeat path in `ProviderLoop.swift`.
- Coordinator side: `coordinator/registry/registry.go` `snapshotProviderLocked`
  and `coordinator/registry/scheduler.go`.

## Prefix cache

An encrypted SSD-backed prefix cache accelerates repeated or shared prompts.
It is on by default and can be disabled with `DARKBLOOM_PREFIX_CACHE=0`.

- Pure-attention models use the engine's `PrefixCache` block tier.
- Hybrid sliding-window models (Gemma-4, GPT-OSS) use the exact-checkpoint
  `PrefixCacheManager` tier.
- Models with `MambaCache`/recurrent layers are excluded from caching.

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
