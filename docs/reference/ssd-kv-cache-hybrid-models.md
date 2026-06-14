# SSD KV Cache for Hybrid Models

Reference for the exact-checkpoint SSD KV-cache tier that serves hybrid
sliding-window models (Gemma-4, GPT-OSS) and coexists with the engine block
tier for pure-attention models.

## Why hybrid models need a separate tier

The engine block cache (`MLXLMCommon.PrefixCache`) stores prompt KV in fixed
256-token blocks and requires all layers to be `KVCacheSimple`. Hybrid models
mix `KVCacheSimple` with `RotatingKVCache`:

| Model | Per-layer caches |
|---|---|
| Gemma-4 | `KVCacheSimple` (full-attention) + `RotatingKVCache` (sliding, w=1024) |
| GPT-OSS | `KVCacheSimple` + `RotatingKVCache` (w=128) |
| Qwen3.5 / Qwen3-Next | `KVCacheSimple` + `MambaCache` (recurrent) — **not cached** |

`RotatingKVCache` cannot be sliced by token position because it deliberately
retains only the last `maxSize` tokens and its physical layout rotates. The
exact-checkpoint tier snapshots the **entire multi-layer cache** at fixed
boundaries and restores it wholesale.

## Capture

At the end of prefill, before any decode step slides the window, if the prompt
length hits a checkpoint boundary the provider:

1. Extracts one batch row from every layer cache (`extractBatched`).
2. Serializes state + `metaState` together.
3. Encrypts with the shared SSD crypto layer.
4. Indexes by `(weightBinding, digest(tokens[0..L]))`.

## Restore

On a matching request:

1. `PrefixCacheManager.lookup` finds the longest present checkpoint.
2. The file is decrypted and deserialized.
3. A B=1 batched cache is rebuilt (`merge` for simple, `fromSingleRow` for
   rotating).
4. The engine prefills only the suffix tokens.

Any failure degrades to a cold prefill.

## Checkpoint boundaries

Default in-window ladder: `[256, 512, 1024]` (or smaller for very short
windows). Proven families get an extended tail ladder
`[2048, 4096, 8192, 16384, 32768]` up to `maxContextLength`.

Proven families (case-insensitive arch substring match):

- `gemma`
- `gpt-oss`
- `gptoss`

Unproven families keep the within-window ladder as a safe default.

> The sliding window does **not** cap reusable prefix length. A snapshot at any
> L is correct: full-attention layers retain all L tokens; sliding layers retain
> exactly the last `window` tokens they need.

## Isolation guarantees

1. Engine block path is unchanged; pure-attention models keep using it.
2. Checkpoint tier activates only when `DARKBLOOM_PREFIX_CACHE` is on AND all
   caches are in {`KVCacheSimple`, `RotatingKVCache`}.
3. A model is served by **either** engine block tier or checkpoint tier, never
   both.
4. Any capture/restore/serialize/decrypt error → cold miss.

## Known finding: short checkpoints shadow SSD

For small-window hybrids like GPT-OSS (w=128), tiny 64/128-token checkpoints
stay resident in RAM and satisfy lookups before the SSD tier is consulted,
shadowing the larger 2048-token checkpoint. This is correct but under-uses SSD.
See `architecture/decisions/kv-cache-lookup-shadowing.md`.

## Code locations

| Concern | File |
|---|---|
| Capability classifier | `provider-swift/Sources/ProviderCore/KVCache/PrefixCacheStrategy.swift` |
| Boundary derivation | `PrefixCachePastWindow.swift`, `PrefixDigest.swift` |
| Checkpoint manager | `PrefixCacheManager.swift`, `PrefixCacheIndex.swift`, `PrefixCacheRAM.swift` |
| Serializer | `KVCacheSerializer.swift` |
| BatchScheduler wiring | `Inference/BatchScheduler.swift` |
| Live equivalence tests | `provider-swift/Tests/ProviderCoreTests/KVCache/HybridCheckpointLiveTests.swift` |
