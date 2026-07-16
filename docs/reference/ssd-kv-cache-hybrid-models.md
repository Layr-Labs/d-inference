# SSD KV Cache for Hybrid Models

Hybrid sliding-window models are deliberately cold-only in the production SSD
cache. The retired `PrefixCacheManager` exact-checkpoint tier is no longer part
of the provider.

## Why partial hybrid adoption is unsafe

A sliding-window layer needs prior tokens at a replay boundary. If a
storage-owning full-attention layer follows it, that full layer permanently
caches keys and values derived from the incomplete sliding context. Replaying a
larger suffix does not repair those polluted full-attention entries because
later decode continues to attend them.

`cbv2RequiredRecompute` therefore requires the entire matched prefix to be
recomputed whenever a storage-owning full layer follows sliding attention.
Such a match saves zero prefill tokens.

## Production behavior

`PrefixCachePolicy.supportsReusablePrefixes` mirrors the engine rule before an
SSD cache is constructed. Unsafe hybrid layouts advertise no reusable cache
capability, create no receipt-confirmed routing holder, and serve through the
ordinary cold path. This includes the currently supported Gemma 4 and GPT-OSS
layouts.

Pure full-attention layouts, all-windowed layouts, and layouts whose windowed
layers trail every storage-owning full layer remain structurally eligible. They
still pass the weight binding, prompt-contract, disk, staging, and effective
token gates described in `ssd-kv-cache.md`.

Supporting interleaved hybrids in the future requires an exact prompt-boundary
snapshot that restores every storage-owning row, including the retained
sliding-window state. Relaxing the replay rule without that state would change
model outputs and is prohibited.

## Code locations

- Recompute rule: `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/CBv2Contracts.swift`
- Layout gate: `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift`
- SSD construction: `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheFactory.swift`
- Regression tests: `provider-swift/Tests/ProviderCoreTests/PrefixCachePolicyTests.swift`
