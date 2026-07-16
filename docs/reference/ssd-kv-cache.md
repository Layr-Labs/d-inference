# SSD KV Cache Reference

This is the as-built v0.7.5 reference for the ContinuousBatchingV2 encrypted
SSD prefix cache. The pre-v0.7.5 `BatchScheduler`, `PrefixCacheManager`, and
`EncryptedPrefixCachePersistence` implementations are retired.

## Status

The encrypted SSD tier is selected by default for CBv2-supported models. It
keeps the engine's full live-KV memory grant and stores donated prefix blocks
under `~/Library/Caches/darkbloom/kv3/`.

| State | Selection | Memory behavior |
|---|---|---|
| Encrypted SSD | Default, unless a kill switch disables it | No persistent RAM carve; read staging is reserved per staged entry; bounded host buffers back the write-behind queue |
| Off | `DARKBLOOM_PREFIX_CACHE=0` | Entire slot grant remains available for live KV |

Production has no RAM prefix-cache mode and performs no persistent KV-memory
carve. The single production gate is
`ProviderCore/Inference/PrefixCachePolicy.swift`.

The SSD tier requires the Secure-Enclave-rooted KEK. If key creation is not
available, it fails closed to uncached serving. The ephemeral KEK escape hatch
is for unsigned tests only and does not preserve cache data across restarts.

## Request flow

1. `EngineV2` hashes 256-token prefix blocks with the model and request cache
   scope.
2. `SSDPrefixCache` probes its in-memory HMAC-tag index before submission.
3. On a hit, it reserves staging bytes in `GlobalKVCacheBudget`, reads and
   authenticates a contiguous block run, and seeds the engine's staging map.
4. ContinuousBatchingV2 adopts only the reusable prefix and recomputes the
   model-specific sliding-window bound.
5. Completed requests donate eligible block snapshots to a bounded write-behind
   queue. Admission, write-rate, low-disk, TTL, and box-wide LRU guards apply.

Pure-attention and supported hybrid sliding-window models share this layer-aware
CBv2 block path. Hybrid reuse is useful only after the engine's recompute bound;
the SSD tier therefore persists a donation only when it also clears the
configured effective-token floor. See
[`ssd-kv-cache-hybrid-models.md`](./ssd-kv-cache-hybrid-models.md).

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `DARKBLOOM_PREFIX_CACHE` | unset/on | Single production kill switch; any explicit non-affirmative value disables encrypted SSD |
| `DARKBLOOM_PREFIX_CACHE_DISK_GB` | min(20 GiB, free/2) | Box-wide SSD budget |
| `DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS` | 900 | Sliding TTL; overrides can only shorten the 15-minute maximum |
| `DARKBLOOM_PREFIX_CACHE_SSD_MIN_EFFECTIVE_TOKENS` | 1024 | Minimum reusable tokens after the hybrid recompute bound |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB` | 1024 | Per-request staging-memory cap |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MS` | 1000 | Maximum estimated staging time |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY` | 150 | Daily endurance limit; `0` means unlimited |
| `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` | disabled | Unsigned test-only in-memory KEK |

Installed launchd services preserve `DARKBLOOM_PREFIX_CACHE`. The remaining
tuning variables are available to foreground/test processes or must be added
explicitly to the launchd environment with `launchctl`; exporting them in an
interactive shell does not change an already-installed daemon. The passthrough
allowlist is in `ProviderCore/Service/LaunchAgent.swift`.

Writes stop when free space drops below the greater of 20 GiB or 5% of the
volume. Reads remain available. An ENOSPC write starts a ten-minute write
cooldown.

## Storage and cryptography

Each model uses `~/Library/Caches/darkbloom/kv3/<modelKey>/`, where `modelKey`
is the first 12 hex characters of SHA-256(model ID). Each `.dbk3` file contains
one 256-token KV block. Files are AES-256-GCM encrypted with a fresh DEK wrapped
by the Secure-Enclave-rooted KEK; canonical metadata is authenticated as AAD.

File names and the in-memory index use truncated HMAC-SHA256 lookup tags derived
from the KEK. The full tag is authenticated in metadata. Raw token IDs, raw
prefix hashes, request IDs, and cache-scope values never touch disk.
Reusable entries require both a verified weight hash and a prompt contract
computed from the loaded model's tokenizer, template, and config artifacts.
If either identity is unavailable, the SSD tier stays disabled. Reads also
verify that binding, the layout epoch, block size, and full lookup tag. Any
parse, binding, or authentication failure is deleted and treated as a cold miss.

The legacy `darkbloom/kv/` tree is swept on startup. The `kv3/` root is
separate and is not touched by that cleanup; the retired `kv2/` layout is
ignored after the hash-contract rotation.

## Security boundary

Encryption and HMAC-keyed names close the legacy disk confirmation oracle. A
shared prefix can still change time-to-first-token inside the trusted provider
process, and SSD warmth can survive restart within the 15-minute TTL. Request
cache scope narrows that channel; `DARKBLOOM_PREFIX_CACHE=0` removes it.

## Code locations

| Concern | File |
|---|---|
| Production gate and SSD budget | `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift` |
| Slot wiring | `provider-swift/Sources/ProviderCore/Inference/EngineV2SlotFactory.swift` |
| Engine integration | `provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge.swift` |
| SSD cache | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCache.swift` |
| File codec | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockStore.swift` |
| HMAC lookup names | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDLookupKeys.swift` |
| TTL and box-wide LRU | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockIndex.swift` |
| Write-behind and endurance | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWriteBehind.swift` |
| Tests | `provider-swift/Tests/ProviderCoreTests/SSDPrefixCacheTests.swift` |
