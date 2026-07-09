# SSD KV Cache for Hybrid Models

The v0.7.5 EngineV2 cache uses one layer-aware block format for both
pure-attention and supported hybrid sliding-window models. The retired
`PrefixCacheManager` exact-checkpoint tier is no longer part of the provider.

## Why hybrid adoption is different

A full-attention layer can reuse every matched prefix token. A sliding-window
layer needs a suffix recomputed so its rotating state is correct at the resume
point. ContinuousBatchingV2 derives that recompute amount from the model's
`CBv2LayerKind` values:

```text
recompute bound = sliding-window layer count * largest window
effective reuse = matched prefix - recompute bound
```

The product saturates on overflow. A cache hit is adopted only when effective
reuse is positive; otherwise inference performs a cold prefill.

## SSD donation and adoption

The default SSD tier is constructed for each CBv2-supported model. At request
completion it donates 256-token, layer-aware snapshots only when the matched
prefix clears both the model's recompute bound and the 1,024-token default
benefit floor. This lets a large-bound model keep only prefixes that can pay
back their staging cost without taking RAM from live serving.

On lookup, `SSDPrefixCache` requires a contiguous chain of blocks, reserves the
staging bytes in `GlobalKVCacheBudget`, authenticates every block, and hands the
snapshot run to EngineV2. The engine applies the same recompute rule before
resuming prefill. Any missing block, binding mismatch, decryption failure, or
staging-budget refusal becomes a cold miss.

## RAM tier

The experimental RAM `PrefixCacheV2` tier is selected only when SSD is disabled
and `DARKBLOOM_PREFIX_CACHE=1`. Because RAM retention reduces live concurrency,
its per-model funding gate defaults to an adoption-bound limit of 4,096 tokens.
This gate does not apply to SSD; SSD uses its per-donation benefit test instead.

## Code locations

| Concern | File |
|---|---|
| Recompute rule | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/CBv2Contracts.swift` |
| Adoption-bound policy | `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift` |
| Layer-kind derivation and wiring | `provider-swift/Sources/ProviderCore/Inference/EngineV2SlotFactory.swift` |
| SSD donation and staging | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCache.swift` |
| Regression tests | `provider-swift/Tests/ProviderCoreTests/EngineV2SSDPrefixCacheLiveTests.swift` |
