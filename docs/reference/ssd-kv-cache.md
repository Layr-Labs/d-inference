# SSD KV cache reference

> Last updated: 2026-09-03 · commit `5d400cf75`

Exact on-disk format, paths, identity binding, environment knobs, size and
eviction rules, and per-family reuse capability of the provider's encrypted SSD
prefix-cache tier (`provider-swift/Sources/ProviderCore/KVCacheSSD/`) as built
in v0.8.16. For how the tier fits into KV layouts and why a default box builds
no cache, read [`../architecture/prefix-cache.md`](../architecture/prefix-cache.md).

## Paths

The tier owns one root per user, one directory per model.

| Item | Value | Code |
|---|---|---|
| Root | `~/Library/Caches/darkbloom/kv3/` (`FileManager.urls(for: .cachesDirectory)` + `ssdRootDirectoryName = "darkbloom/kv3"`) | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheFactory.swift` (`cacheRootDirectory`) |
| Per-model directory | `<root>/<modelKey>/`, `modelKey = SHA256(modelId)` first 12 hex characters | `SSDPrefixCacheFactory.swift` (`cacheDirectory`) |
| Block file | `<tag>.dbk3`, one file per 256-token block; `fileExtension = "dbk3"` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockStore.swift` |
| Epoch record | `<modelKey>/cache-epoch.json`, schema `darkbloom.cache-epoch.v1` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDCacheEpochStore.swift` |
| Test root | `DARKBLOOM_PREFIX_CACHE_TEST_ROOT`, honoured only with `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` affirmative | `SSDPrefixCacheFactory.swift` (`isolatedTestRoot`) |
| Legacy roots | `darkbloom/kv/` is swept at startup by `LegacyKVCacheSweeper`; `kv3/` is never touched by that sweep | `provider-swift/Sources/ProviderCore/KVCache/LegacyKVCacheSweeper.swift` |

## DBK3 file format

Every `.dbk3` file is the reviewed `EncryptedKVStore` scheme with
`formatVersion = 3` (`SSDBlockStore.swift`, header comment and `enum SSDBlockStore`).

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `magic` = `"DBKV"` (`0x44 0x42 0x4B 0x56`) |
| 4 | 2 | uint16 LE `format_version` = 3 |
| 6 | 2 | uint16 LE flags (reserved, 0) |
| 8 | 12 | `file_IV` (random per file; folded into HKDF info) |
| 20 | 4 | uint32 LE wrapped-DEK length N |
| 24 | N | wrapped DEK = AES-256-GCM(KEK, DEK, AAD = metadata) |
| 24+N | 4 | uint32 LE metadata length M |
| 28+N | M | canonical (sorted-keys) JSON metadata; AAD on every chunk seal |
| 28+N+M | 4 | uint32 LE chunk count |
| … | per chunk | uint32 LE ciphertext length ‖ AES-256-GCM ciphertext ‖ tag |

| Cryptographic detail | Value | Code |
|---|---|---|
| Per-chunk nonce | HKDF-Expand(DEK, info = `"dbkv-chunk-v3"` ‖ `file_IV` ‖ uint32 BE chunk index, L = 12) | `SSDBlockStore.swift` (`chunkInfoPrefix`) |
| KEK | Secure-Enclave-rooted; `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` substitutes an in-memory KEK for unsigned builds (no data survives restart) | `SSDPrefixCacheFactory.swift` (`ephemeralAllowed`) |
| Lookup key | `K_lookup = HKDF-SHA256-Expand(PRK: KEK, info: "dbkv3-lookup-v1", L = 32)` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDLookupKeys.swift` |
| File-name tag | `HMAC-SHA256(K_lookup, "dbkv3-name-v1" ‖ u64le(len(salt)) ‖ salt ‖ chainHash)`, truncated to `truncatedTagLength = 16` bytes; full tag authenticated in metadata | `SSDLookupKeys.swift` |
| Window sidecar tags | `"dbkv3-window-v1"`, `"dbkv3-window-base-v1"` domains (format only; `DARKBLOOM_PREFIX_CACHE_SSD_WINDOW_SIDECAR` off; no restore consumer) | `SSDLookupKeys.swift`, `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWindowSidecar.swift` |
| Temp files | `tempMarker = "darkbloom-tmp"`, crash-orphan TTL `crashTempTTLSeconds = 3600` | `SSDBlockStore.swift` |
| Symlink defence | Descriptor-based no-follow I/O and path guard | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDNoFollowIO.swift`, `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockPathGuard.swift` |

A disk observer sees the lookup tag, the weight hash, the layout epoch, block
shape descriptors and `createdAt`; never raw chain hashes, token ids or counts,
scope values, or request ids (`SSDBlockStore.swift` header).

## Identity binding

A block is readable only when every binding below matches; any mismatch,
parse or authentication failure deletes the file and is served as a cold miss
(`provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCache.swift`).

| Binding | Value | Code |
|---|---|---|
| `weightHash` | Verified SHA-256 aggregate of the live weights; absent ⇒ tier disabled (`weight_hash_unavailable`) | `SSDPrefixCacheFactory.swift` (`make`) |
| `promptContractId` | `PromptContractIdentity.compute(modelDirectory:)`; absent ⇒ tier disabled (`runtime_identity_unavailable`) | `provider-swift/Sources/ProviderCoreFoundation/PromptContractIdentity.swift` |
| `layoutEpoch` | `"cbv2-frozen-full-3\|native-fp\|<blockSize>\|<layerKindsDigest>"`, digest = SHA-256 of the canonical layer-kind list, hex prefix | `SSDBlockStore.swift` (`layoutEpoch(blockSize:layerKinds:)`) |
| `blockSize` | `CBv2BlockHasher.defaultBlockSize = 256` | `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift` (`blockSize`) |
| `blockHashVersion` | `darkbloom-block-chain-v1` | `PromptContractIdentity.swift` |
| `keyFingerprint` | Fingerprint of the KEK in use | `SSDCacheEpochStore.swift` (`Binding`) |
| Epoch | Random per-model generation in `cache-epoch.json`; any binding drift (for example the legacy `cbv2-snap-2\|f16\|…` layout that `SSDCacheEpochStoreTests` rotates away) wipes the model's blocks and mints a new epoch before `ready` is advertised | `SSDCacheEpochStore.swift` |

## Environment variables

Names and effects only; defaults and parsing rules are in
[`configuration.md`](configuration.md). Installed launchd daemons receive only
the allowlisted variables in `passthroughEnvKeys`
(`provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift`); of this
table only `DARKBLOOM_PREFIX_CACHE` is on that list.

| Variable | Effect | Code |
|---|---|---|
| `DARKBLOOM_PREFIX_CACHE` | Process-wide kill switch for the tier (`environmentFlag`) | `PrefixCachePolicy.swift` (`isEnabled`) |
| `DARKBLOOM_PREFIX_CACHE_DISK_GB` | Box-wide disk budget override | `PrefixCachePolicy.swift` (`ssdDiskBudgetBytes`) |
| `DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS` | Cadence of the `prefix cache stats (engine=v2, tier=ssd, …)` log line | `PrefixCachePolicy.swift` (`statsIntervalSecs`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS` | Sliding TTL; can only shorten `maxTTLSeconds` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` (`ttlSeconds`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY` | Daily write cap; `0` = unlimited | `SSDPrefixCachePolicy.swift` (`maxWriteBytesPerDay`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_MIN_EFFECTIVE_TOKENS` | Adoption-benefit floor (raise-only against the long-hybrid floor) | `SSDPrefixCachePolicy.swift` (`minEffectiveTokens`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB` | Max staged bytes per adoption | `SSDPrefixCachePolicy.swift` (`maxStageBytes`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MS` | Max estimated staging time | `SSDPrefixCachePolicy.swift` (`maxStageMillis`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_WINDOW_SIDECAR` | Enables writing window sidecar files (format only) | `SSDPrefixCachePolicy.swift` (`windowSidecarEnabled`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_STRICT_FSYNC` | fsync every block write (GCM auth otherwise catches torn writes) | `SSDPrefixCachePolicy.swift` (`strictFsync`) |
| `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL`, `DARKBLOOM_PREFIX_CACHE_TEST_ROOT` | Unsigned-build in-memory KEK; isolated test root | `SSDPrefixCacheFactory.swift` |

## Size and eviction rules

All constants are code constants of `SSDPrefixCachePolicy` and
`PrefixCachePolicy`; the env variables above may narrow some of them.

| Rule | Constant | Code |
|---|---|---|
| Disk budget | `defaultSSDDiskBudgetBytes = 20 * 1_073_741_824`; effective budget `min(20 GiB, volumeFree / 2)`, box-wide | `PrefixCachePolicy.swift` (`ssdDiskBudgetBytes`) |
| Eviction order | LRU by last hit across the whole `kv3/` root; eviction is `unlink` + index removal | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockIndex.swift` |
| Maintenance sweep | `SSDWholeRootMaintainer`, `intervalSeconds = 60`: TTL expiry, budget eviction, crash-temp cleanup | `SSDPrefixCacheFactory.swift` (`startWholeRootMaintenance`), `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWholeRootMaintainer.swift` |
| TTL | `defaultTTLSeconds = 900`, `maxTTLSeconds = 900`, sliding on hit | `SSDPrefixCachePolicy.swift` |
| Daily write cap | `defaultMaxWriteBytesPerDay = 150 * 1_000_000_000` | `SSDPrefixCachePolicy.swift` |
| Low-disk write stop | `lowDiskFloorBytes = max(lowDiskAbsoluteFloorBytes = 20 GiB, lowDiskCapacityFraction = 0.05 × volume)`; reads continue; ENOSPC starts `enospcCooldownSeconds = 600` | `SSDPrefixCachePolicy.swift` |
| Staging cap | `defaultMaxStageBytes = 1024 * 1_048_576`; `defaultMaxStageMillis = 1000` at `conservativeStageBytesPerSecond = 1_500_000_000` | `SSDPrefixCachePolicy.swift` |
| Donation floor | `prefixTokens > adoptionBoundTokens + minEffectiveTokens`, whole blocks only; `defaultMinEffectiveTokens = 1024`, raised to 1_536 for `.frozenFullReplay` with bound ≥ 25_600 | `SSDPrefixCache.swift` (`donate`), `PrefixCachePolicy.swift` |
| Write-behind queue | `writeQueueMaxJobs = 2`, `writeQueueMaxBytes = 512 * 1_048_576`, `writeQueueSlackBytes = 256 * 1_048_576`; overflow drops the donation | `SSDPrefixCachePolicy.swift`, `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWriteBehind.swift` |
| Staging RAM | Reserved per staged entry in `GlobalKVCacheBudget`; the engine keeps its full slot grant | `provider-swift/Sources/ProviderCore/Inference/GlobalKVCacheBudget.swift` |

## Per-family reuse capability

Derived from `CBv2PrefixReuseCapability.derive`
(`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/PrefixReusePlan.swift`)
and the construction gate in
`provider-swift/Sources/ProviderCore/Inference/EngineV2SlotFactory.swift`. The
engine strategy is what a hit would use; the last column is whether a cache
object exists at all in v0.8.16 (`PrefixCachePolicy.adoptionIsExact` is `true`
only for a resolved-paged slot).

| Family (`model_type`) | `CBv2ModelCapabilities` | Layout | Engine strategy (contiguous / paged) | Cache built when |
|---|---|---|---|---|
| GPT-OSS (`gpt_oss`) | `.attentionOnly` (`prepareProductionBackend`) | Interleaved sliding/full hybrid | `.frozenFullReplay` / `.frozenFullReplay` | `engine_v2_kv_backend = "paged"` resolved paged |
| Gemma 4 (`gemma4`, `gemma4_text`) | `.attentionOnly` | Interleaved sliding/full hybrid | `.frozenFullReplay` / `.frozenFullReplay` (bound ≥ 25_600 ⇒ 1_536-token floor) | `engine_v2_kv_backend = "paged"` resolved paged |
| Qwen 3.5/3.8 dense (`qwen3_5`) | `.initialRecurrentTarget`: `supportsPrefixReuse: false`, `supportsPagedKV: false` | Recurrent state | unsupported (`.modelRequestStateUnsupported`) | never (`unsupported_layout`) |
| Qwen 3.5/3.6 MoE (`qwen3_5_moe`) | `.initialRecurrentTarget` | Recurrent state | unsupported | never (`unsupported_layout`) |
| Qwen3-VL MoE (`qwen3_vl_moe`) | `MLXVLM.Qwen3VL.cbv2Capabilities`: all `false` | Full attention | unsupported | never (`unsupported_layout`) |
| Any family, default `auto` config | — | — | — | never (`unsupported_backend`) |

Capability constants: `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/RecurrentStateV2.swift`
(`CBv2ModelCapabilities`); the per-family switch is in
`provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Production.swift`
(`prepareProductionBackend`). A family with `supportsPagedKV: false` resolves
contiguous even under an explicit `paged` selection (reason `model_capability`).

## Status and outcome vocabularies

Closed enums in `provider-swift/Sources/ProviderCore/Protocol/Messages.swift`;
the coordinator's consumption is in
[`../architecture/cache-aware-routing.md`](../architecture/cache-aware-routing.md).

| Enum | Values |
|---|---|
| `PrefixCacheStatusReason` | `ready`, `config_disabled`, `weight_hash_unavailable`, `runtime_identity_unavailable`, `unsupported_layout`, `unsupported_backend`, `paged_hybrid_unsupported`, `scan_pending`, `scan_failed`, `disk_unavailable`, `cache_init_failed` |
| `PrefixCacheDonationOutcome` | `donated`, `below_effective_token_floor`, `no_complete_block`, `lossy_snapshot`, `incomplete_layer_state`, `stage_size_exceeded`, `write_rate_limited`, `write_queue_full`, `already_durable`, `already_queued`, `cache_closed`, `disk_unavailable`, `write_failed` |

Outcomes are cumulative process-local counters carrying no identifiers; each
donation call settles exactly one outcome
(`provider-swift/Sources/ProviderCore/KVCacheSSD/PrefixCacheDonationTelemetry.swift`).

## Verification

Three observable surfaces exist; there is no dedicated CLI verifier.

| Surface | What to look for | Code |
|---|---|---|
| `darkbloom logs` | `prefix cache stats (engine=v2, tier=ssd, model=…)` line every `DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS` with `lookups`, `hits`, `tokensSaved`, `blocksWritten`, `evictions`, `ttlExpired`, `bytesOnDisk` | `provider-swift/Sources/ProviderCore/KVCacheSSD/EngineV2Bridge+SSDPrefixCache.swift` (`logSSDPrefixCacheStats`) |
| Heartbeat → coordinator `GET /v1/cache/status` | `prefix_cache_statuses` per loaded model (`state`, `reason`, `backend`, `replay_strategy`) and aggregated donation outcomes | `Messages.swift` (`prefixCacheStatuses`), `coordinator/api/server.go` (`handleExactCacheStatus`) |
| `darkbloom benchmark --parity` | Loads the model on both KV backends and reports the prefix-reuse probe as PASS/FAIL/UNAVAILABLE | `provider-swift/Sources/darkbloom/BenchmarkCommand+Parity.swift` |

## Related

- [`../architecture/prefix-cache.md`](../architecture/prefix-cache.md) — layouts, reuse plan, construction gate
- [`../architecture/cache-aware-routing.md`](../architecture/cache-aware-routing.md) — coordinator side
- [`../architecture/security/encryption.md`](../architecture/security/encryption.md) — key hierarchy
- [`../design/ssd-kv-cache.md`](../design/ssd-kv-cache.md), [`../design/ssd-kv-cache-v1-design.md`](../design/ssd-kv-cache-v1-design.md) — superseded design records
- Tests: `provider-swift/Tests/ProviderCoreTests/SSDPrefixCacheTests.swift`
