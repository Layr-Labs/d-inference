# SSD KV Cache Reference

The Swift provider caches prefill KV in GPU memory and on encrypted SSD so
later requests with a matching prefix skip the prefill pass.

## Status

On by default. Opt out with `DARKBLOOM_PREFIX_CACHE=0`. Requires a Secure
Enclave-wrapped KEK; if the SE/entitlement is missing the cache stays off.

## Tiers

| Tier | Models | Implementation |
|---|---|---|
| Engine block cache | Pure-attention (`KVCacheSimple`-only) | `MLXLMCommon.PrefixCache` + `EncryptedPrefixCachePersistence` |
| Exact-checkpoint cache | Hybrid sliding-window (Gemma-4, GPT-OSS) | `PrefixCacheManager` + `PrefixCacheIndex` + `PrefixCacheRAM` |

Models with `MambaCache`/recurrent layers are excluded.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `DARKBLOOM_PREFIX_CACHE` | `1` (on) | Master toggle; set `0` to disable. |
| `DARKBLOOM_PREFIX_CACHE_MAX_GB` | physical RAM / 8 | In-GPU block-cache budget. |
| `DARKBLOOM_PREFIX_CACHE_DISK_GB` | min(10 GB, free/2) | Global on-disk budget across all models. |
| `DARKBLOOM_PREFIX_CACHE_MIN_PERSIST_TOKENS` | 16384 Gemma, 0 otherwise | 2nd-use SSD admission threshold. |
| `DARKBLOOM_PREFIX_CACHE_TTL_SECONDS` | 300 | Sliding TTL for SSD checkpoints; `0` = infinite. |

## File format

`<hashHex>.darkbloom-kv`:

| offset | size | field |
|---|---|---|
| 0 | 4 | magic `DBKV` |
| 4 | 2 | format_version (LE u16) |
| 6 | 2 | flags |
| 8 | 12 | file_IV |
| 20 | 4 | wrapped_DEK length |
| 24 | N | wrapped_DEK |
| 24+N | 4 | metadata length |
| 28+N | M | metadata JSON (AAD) |
| 28+N+M | 4 | chunk_count |
| … | … | encrypted chunks |

Metadata is plaintext (it is the GCM AAD); KV tensors are encrypted.

## Cryptography

- Secure Enclave P-256 identity wraps a long-lived KEK.
- KEK is stored in Keychain (`KeychainWrappedKEKStorage`).
- Each file gets a fresh DEK, wrapped under KEK with metadata as AAD.
- Chunks use AES-256-GCM with HKDF-derived nonces.
- All primitives are Apple CryptoKit.

## Load-path verification ladder

Every load independently verifies:

1. Path is derived from trusted values, not stored index.
2. Metadata readable.
3. `meta.modelHash` matches binding.
4. Shape integers match binding.
5. `meta.tokenPrefixHash` matches requested prefix.
6. GCM decrypt succeeds.
7. Tensor shape and byte length match.
8. `metaState` is well-formed for the cache type.

Any failure is a recoverable cold miss.

## Global disk budget

`GlobalDiskAccountant` enforces a process-wide ceiling across all loaded models.
When the total exceeds the budget, it evicts the lowest benefit-per-byte entries
cross-model. Live managers are signaled; unowned directories are deleted directly.

## On-disk layout

```
~/Library/Caches/darkbloom/kv/
└── <modelKey>/
    └── <blockHashHex>.darkbloom-kv
```

`<modelKey>` = `sha256(modelId)[:12]`. MB-1 binding uses `weightHash` when
available; stale-weight files are rejected and deleted on access.

## Security model (TB-007)

The cache adds encryption-at-rest. It does **not** close the in-process cross-
tenant TTFT side-channel: a shared prefix block is shared across consumers, and
the timing difference between hit and miss is an oracle. Untrusted multi-tenant
deployments MUST opt out.

Plaintext metadata (token count, prefix hash, model binding) is a known-prefix
oracle for a disk observer.

## Code locations

| Concern | File |
|---|---|
| File format / crypto seal | `provider-swift/Sources/ProviderCore/KVCache/EncryptedKVStore.swift` |
| KEK envelope | `KVCacheKEK.swift`, `KeyWrappingService.swift`, `SecureEnclaveKeyWrappingService.swift`, `WrappedKEKStorage.swift` |
| `[KVCache]` ↔ bytes | `KVCacheSerializer.swift` |
| Engine tier | `EncryptedPrefixCachePersistence.swift` |
| Checkpoint tier | `PrefixCacheManager.swift`, `PrefixCacheIndex.swift`, `PrefixDigest.swift`, `PrefixCacheRAM.swift`, `PrefixCachePastWindow.swift` |
| Global disk accountant | `GlobalDiskAccountant.swift` |
| Flag wiring | `Inference/BatchScheduler.swift` |
| Tests | `provider-swift/Tests/ProviderCoreTests/KVCache/*` |
