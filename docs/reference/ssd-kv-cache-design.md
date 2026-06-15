# SSD KV Cache Design

Design rationale, threat model, and phased plan for the encrypted SSD KV cache.
For the as-built reference see [`reference/ssd-kv-cache.md`](./ssd-kv-cache.md).

## Goal

Add a persistent, encrypted, on-disk tier for the model's KV cache so the
provider can skip prefill on repeat prefixes and survive process restart/model
unload without losing expensive precomputed state.

## Non-goals

- Cross-machine cache sharing.
- Tensor-parallel / pipeline-parallel cluster KV persistence.
- Live-request offload to SSD under pressure (v1 only saves idle state).
- Cross-model cache reuse.
- Arbitrary longest-prefix match for hybrid models.
- Models whose per-layer caches are not `KVCacheSimple` / `RotatingKVCache`.

## Threat model

| Adversary | In scope? |
|---|---|
| Cold-boot disk theft / forensics | yes |
| Backup snapshots (Time Machine) | yes |
| Another process on same Mac (no SIP bypass) | yes |
| The provider process itself | no (already trusted) |
| Compromised root with SE identity | partial |
| Network adversary | no (cache never leaves machine) |

Confidentiality and integrity are hard requirements. Silently loading tampered
KV would corrupt outputs, so AES-GCM authentication is non-negotiable.

## Three-tier hierarchy

```
VRAM  BatchKVCache (active in-flight)
  │
  ▼ evict
RAM   PrefixCacheRAM (LRU, decrypted in-process)
  │
  ▼ evict
SSD   EncryptedKVStore (~/.cache/darkbloom/kv)
```

A request matches its longest shared prefix across all three tiers.

## Exact-checkpoint model

A cached entry is reusable only when the incoming prompt's first *N* tokens are
byte-identical to a checkpoint boundary (256, 512, 1024, …). This is forced by:

- Recurrent layers (Mamba / GatedDeltaNet): state is non-invertible.
- Sliding-window layers: rotating buffer layout depends on exact length.
- Hybrid models are only as flexible as their least-flexible layer.

Pure-attention layers could support arbitrary slicing, but we use one policy.

## Verified cacheability

| Model family | Per-layer caches | Cacheable? |
|---|---|---|
| Llama, Qwen2/3, Phi, Mistral, GLM4, Cohere | all `KVCacheSimple` | yes |
| Qwen3.5 MoE / Qwen3-Next | `MambaCache` + `KVCacheSimple` | exact-checkpoint only |
| Gemma-4 | `RotatingKVCache` + `KVCacheSimple` | exact-checkpoint, proven past window |
| GPT-OSS | `RotatingKVCache` + `KVCacheSimple` | exact-checkpoint, proven past window |

## Write paths

| Trigger | Source | Destination |
|---|---|---|
| Request finishes | VRAM → RAM | RAM promotes to SSD on eviction |
| Idle-monitor unload | RAM | SSD flush before VRAM unload |
| Graceful shutdown | RAM | SSD flush all models |
| Model swap | RAM | SSD flush outgoing model |
| Crash / SIGKILL | — | prior SSD writes survive |

## File format

One `.darkbloom-kv` file per cache entry:

- magic `DBKV`
- version 1
- file_IV
- wrapped_DEK = AES-256-GCM(KEK, DEK)
- metadata JSON (AAD)
- encrypted chunk stream

Per-chunk nonces are HKDF-derived from DEK + file_IV + chunk_index.

## Metadata-as-AAD limitation

Metadata is tamper-evident (editing any field breaks GCM tags) but is **not**
model-binding. The crypto layer uses the file's own metadata as AAD, so a
structurally valid file for model A decrypts cleanly while model B is loaded.
The load path must therefore independently verify model and prefix identity.

## Code locations

| Concern | File |
|---|---|
| Crypto primitives | `EncryptedKVStore.swift`, `KVCacheKEK.swift` |
| Serializer | `KVCacheSerializer.swift` |
| Engine tier | `EncryptedPrefixCachePersistence.swift` |
| Checkpoint tier | `PrefixCacheManager.swift` |
| Continuous batching integration | `BatchScheduler.swift` |
| Tests | `provider-swift/Tests/ProviderCoreTests/KVCache/*` |
