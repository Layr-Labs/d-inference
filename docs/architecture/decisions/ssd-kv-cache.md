# Encrypted SSD prefix KV cache

**Status:** Implemented

## Context

Prefill dominates time-to-first-token (TTFT), and shared prefixes (system prompts, RAG context blocks) are recomputed for every request. We want to skip that prefill on repeat prefixes and survive process restart / model unload without losing the expensive precomputed state. Because KV tensors are prompt-correlated, any on-disk storage must be encrypted at rest.

This cache re-introduces a cross-tenant TTFT side-channel: a tenant who knows a target prompt can detect whether it was cached by measuring TTFT. Encryption at rest does **not** close this in-process channel. The cache is therefore on by default only for trusted / single-tenant deployments; untrusted multi-tenant deployments must opt out with `DARKBLOOM_PREFIX_CACHE=0`.

## Decision

Use two mutually-exclusive prefix-cache tiers, selected at model-load time by inspecting the per-layer cache types the model produces.

| Tier | Served models | Storage unit | Key types |
|---|---|---|---|
| **Engine block** | Pure-attention models (Llama, Qwen2/3, Phi, Mistral, …) | 256-token blocks, content-addressed by chain hash | `KVCacheSimple` only |
| **Checkpoint** | Hybrid sliding-window models (Gemma-4, GPT-OSS) | Whole-cache snapshots at exact prefix lengths | `KVCacheSimple` + `RotatingKVCache` |
| **None** | Recurrent / unsupported models (Qwen3.5 MoE/Next, quantized, chunked, unknown) | — | excluded at load |

Selection is performed by `PrefixCacheStrategy.classify`; it never hardcodes model names.

### Enablement

- Default **on**. Opt out with `DARKBLOOM_PREFIX_CACHE=0` (also `false`/`off`/`no`).
- Requires a Secure-Enclave-wrapped KEK persisted in the Keychain. If unavailable, the cache is disabled rather than silently using an ephemeral key. A test-only escape hatch `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1` exists for unsigned builds.
- Wired in `BatchScheduler.makeBatchedEngine` behind the flag.

### Encryption

- Envelope encryption: one per-provider KEK wraps a per-file random DEK.
- KEK is generated once, wrapped by an ECIES key derived from the persistent SE identity, and stored in the Keychain (`KVCacheKEK`).
- DEK is wrapped under the KEK with the file metadata as AAD, stored in the file header.
- KV chunks are AES-256-GCM with HKDF-derived per-chunk nonces; the metadata JSON is AAD for every chunk seal.
- Format: `DBKV` magic, version, flags, 12-byte file IV, wrapped DEK, metadata JSON, encrypted chunks. Writes are atomic (temp file + rename + `F_FULLFSYNC`).
- Plaintext metadata (model hash, token count, prefix hash) is authenticated but **not confidential**; it lets the reader reject a file before paying the KEK unwrap cost, but it is also a known-prefix equality oracle for a disk observer.

### Model-binding guard (MB-1)

A structurally valid cache file from the wrong model decrypts cleanly because AES-GCM authenticates the file against its own metadata. Before seeding any KV into the engine, both tiers verify:

1. `metadata.modelHash == loaded model binding`
2. architectural shape (`numLayers`, `kvHeads`, `headDim`) matches
3. prefix identity (`tokenPrefixHash` == requested hash / digest)
4. deserialized tensor layout matches the live model's per-layer shapes

Any mismatch is a recoverable **cold miss** — the file is dropped, never wrong KV.

### Disk budget

- A process-wide `GlobalDiskAccountant` enforces a single global ceiling across all loaded models.
- Explicit cap: `DARKBLOOM_PREFIX_CACHE_DISK_GB`. If unset/0, ceiling = `min(10 GiB, 50% of free disk)`, recomputed on each tick.
- Eviction is cross-model value-based (benefit-per-byte score, recency-weighted). The accountant signals live model owners to evict on their own executor; it only deletes files in unowned directories directly.
- If the global accountant is not wired (backward-compat / tests), each tier falls back to its own local budget.

### Other policy knobs

| Env var | Purpose | Default |
|---|---|---|
| `DARKBLOOM_PREFIX_CACHE_MAX_GB` | In-memory block/RAM budget | 1/8 physical RAM |
| `DARKBLOOM_PREFIX_CACHE_DISK_GB` | Global on-disk budget cap | derive `min(10 GiB, free/2)` |
| `DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS` | 2nd-use SSD admission threshold | 16384 for Gemma, 0 otherwise |
| `DARKBLOOM_PREFIX_CACHE_TTL_SECONDS` | Sliding TTL for SSD entries | 300 (0 = infinite) |

### Hybrid / sliding-window correctness

- Sliding-window layers discard old KV and rotate their buffers, so per-token-position slicing is unsound. The checkpoint tier snapshots the whole multi-layer cache at exact lengths before any decode step slides the window.
- For **proven** families (Gemma, GPT-OSS), the checkpoint ladder extends past the sliding window (up to 32k) because restore has been verified bit-exact on real weights. Unproven families keep the within-window ladder only.
- Capture and restore use `extractBatched(row)` / `BatchRotatingKVCache.fromSingleRow`; metaState is persisted and restored together with state.

### Per-consumer scope

The checkpoint tier supports an optional per-request scope derived from `prompt_cache_key` or `user` in the sealed request body (`ProviderLoop+InboundDecode.extractCacheScope`). A non-empty scope makes a cached prefix undiscoverable by other consumers, closing the TB-007 cross-tenant sharing channel for that tier. An empty scope keeps the legacy shared-cache behavior.

## Consequences

| Positive | Negative / Risk |
|---|---|
| Major TTFT reduction for repeated / shared prefixes. | Re-introduces a cross-tenant TTFT side-channel when no per-consumer scope is used. |
| Cache survives process restart and model reload. | Encryption does not hide plaintext metadata (prefix hash, token count, model) from a disk observer. |
| Wrong-model / stale-weight files are rejected by MB-1 and deleted. | Recurrent/quantized/chunked models cannot be cached and run cold. |
| Global budget prevents N models from filling the volume. | Small-window hybrid models can suffer SSD-tier shadowing (see `kv-cache-lookup-shadowing.md`). |

## Relevant code paths

| Concern | Code path |
|---|---|
| Flag wiring, tier selection, budget resolution | `provider-swift/Sources/ProviderCore/Inference/BatchScheduler.swift:960-1080`, `1172-1269`, `1368-1448` |
| Model cache-type classifier | `provider-swift/Sources/ProviderCore/KVCache/PrefixCacheStrategy.swift:34-69` |
| Smallest sliding window read from live caches | `provider-swift/Sources/ProviderCore/KVCache/PrefixCacheStrategy.swift:78-82` |
| Exact-checkpoint digest computation | `provider-swift/Sources/ProviderCore/KVCache/PrefixDigest.swift:30-88` |
| Proven past-window families | `provider-swift/Sources/ProviderCore/KVCache/PrefixCachePastWindow.swift:13-30` |
| File format + crypto | `provider-swift/Sources/ProviderCore/KVCache/EncryptedKVStore.swift:7-646` |
| KEK lifecycle | `provider-swift/Sources/ProviderCore/KVCache/KVCacheKEK.swift:1-219` |
| Engine-tier SSD backend | `provider-swift/Sources/ProviderCore/KVCache/EncryptedPrefixCachePersistence.swift:37-210` |
| Checkpoint-tier manager | `provider-swift/Sources/ProviderCore/KVCache/PrefixCacheManager.swift:8-613` |
| Checkpoint index + reconcile | `provider-swift/Sources/ProviderCore/KVCache/PrefixCacheIndex.swift:74-169` |
| Global disk accountant | `provider-swift/Sources/ProviderCore/KVCache/GlobalDiskAccountant.swift:1-120` |
| Per-consumer scope extraction | `provider-swift/Sources/ProviderCore/ProviderLoop+InboundDecode.swift:87-97` |
| Tests | `provider-swift/Tests/ProviderCoreTests/KVCache/*`, `libs/mlx-swift-lm/Tests/MLXLMTests/CBPrefixCacheTests.swift` |
