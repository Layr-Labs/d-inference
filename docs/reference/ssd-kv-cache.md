# SSD KV cache reference

> Last updated: 2026-09-06 · commit `e21e4cc75`

Exact on-disk format, paths, identity binding, environment knobs, size and
eviction rules, and per-family reuse capability of the provider's encrypted SSD
prefix-cache tier (`provider-swift/Sources/ProviderCore/KVCacheSSD/`). For how
attention snapshots and complete recurrent checkpoints differ, and which slots
can use them by default, read
[`../architecture/prefix-cache.md`](../architecture/prefix-cache.md).
Resident paged blocks and recurrent checkpoints use separate eligibility and
lifetime rules; this reference's capability and status tables describe SSD.

## Paths

The tier owns one root per user, one directory per model.

| Item | Value | Code |
|---|---|---|
| Root | `~/Library/Caches/darkbloom/kv3/` (`FileManager.urls(for: .cachesDirectory)` + `ssdRootDirectoryName = "darkbloom/kv3"`) | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheFactory.swift` (`cacheRootDirectory`) |
| Per-model directory | `<root>/<modelKey>/`, `modelKey = SHA256(modelId)` first 12 hex characters | `SSDPrefixCacheFactory.swift` (`cacheDirectory`) |
| Block file | `<tag>.dbk3`, one file per attention block or complete recurrent checkpoint ([block size](../architecture/prefix-cache.md#block-hashing)); `fileExtension = "dbk3"` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockStore.swift` |
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
| KEK | Secure-Enclave-rooted and Keychain-persisted; `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` permits fallback to an in-memory KEK whose ciphertext cannot be reused after process exit | `SSDCacheKeyMaterial.swift` (`load`), `SSDPrefixCacheFactory.swift` (`ephemeralAllowed`) |
| Lookup key | `K_lookup = HKDF-SHA256-Expand(PRK: KEK, info: "dbkv3-lookup-v1", L = 32)` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDLookupKeys.swift` |
| File-name tag | `HMAC-SHA256(K_lookup, "dbkv3-name-v1" ‖ u64le(len(salt)) ‖ salt ‖ chainHash)`, truncated to `truncatedTagLength = 16` bytes; full tag authenticated in metadata | `SSDLookupKeys.swift` |
| Window sidecar tags | `"dbkv3-window-v1"`, `"dbkv3-window-base-v1"` domains (format only; `DARKBLOOM_PREFIX_CACHE_SSD_WINDOW_SIDECAR` off; no restore consumer) | `SSDLookupKeys.swift`, `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWindowSidecar.swift` |
| Temp files | `tempMarker = "darkbloom-tmp"`, crash-orphan TTL `crashTempTTLSeconds = 3600` | `SSDBlockStore.swift` |
| Symlink defence | Descriptor-based no-follow I/O and path guard | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDNoFollowIO.swift`, `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockPathGuard.swift` |

A disk observer sees the lookup tag, the weight hash, the layout epoch, block
shape descriptors and `createdAt`; never raw chain hashes, token ids or counts,
scope values, or request ids (`SSDBlockStore.swift` header).

## Bounded attention-block staging

Attention snapshots retain their existing DBK3 block format. Staging validates
and reserves one final native destination per tensor, then copies each
authenticated chunk directly into its head/token position. It does not collect
the entire decrypted run or concatenate per-block arrays. The window-sidecar
reader uses the same bounded builder; sidecar restoration still has no engine
consumer (`SSDNativePrefixBuilder.swift`, `SSDPrefixCache.swift`, `stage`).

| Contract | Bound / behavior | Code |
|---|---|---|
| Encrypted chunk / metadata | `maximumChunkBytes = 16 * 1_024 * 1_024`; `maximumMetadataBytes = 1_024 * 1_024`; invalid geometry or sizes fail before tensor allocation | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDNativePrefixBuilder.swift` |
| Initial shared reservation | Encoded run bytes plus `4 * min(runBytes, maximumChunkBytes) + 4 * min(runBytes, maximumMetadataBytes)`; scratch is at most 68 MiB regardless of prefix length | `SSDNativePrefixBuilder.swift` (`stagingPeakBytes`) |
| Corrupt suffix | Only fully authenticated blocks commit. A still-useful shorter run reserves original destination bytes plus its largest compact tensor, then replaces one tensor at a time before reducing the charge | `SSDNativePrefixBuilder.swift` (`compactionPeakBytes`, `finish`), `SSDPrefixCache.swift` (`stage`) |
| Refusal / cancellation | Drop private destinations before returning the reservation; successful staging retains exactly the resulting native bytes | `SSDPrefixCache.swift` (`stage`) |

## Complete checkpoint payload

Complete recurrent and historical attention checkpoints use separate
domain-separated model roots within the same `kv3/`
hierarchy and box-wide maintainer. Its DBK3 header describes opaque byte
segments; encrypted chunk 0 contains the complete manifest, including exact
prefix token IDs, tenant scope, checkpoint position, tensor roles/shapes/dtypes
and MTP codec. No public header field exposes those token boundaries
(`SSDHybridCheckpointStoreFactory.swift`, `SSDHybridCheckpointEnvelope.swift`).

| Contract | Bound / behavior | Code |
|---|---|---|
| Encrypted manifest | `maximumEncodedBytes = 1 << 20`; validated before allocation | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Prefix/CompleteCheckpointContract.swift` |
| Tensor segment | `maximumSegmentBytes = 4 << 20`; logical segments stream through authenticated DBK3 chunks | `CompleteCheckpointContract.swift`, `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockStore+Streaming.swift` |
| Initial read admission | Metadata-only candidate match precedes any file read. Shared mode reserves `ioScratchBytes = 20 << 20` once in the provider ledger; its native IO lease does not duplicate that charge. Contiguous compatibility keeps its existing two-ledger path | `SSDHybridCheckpointStore+Read.swift` (`stage`), `EngineV2+CompleteCheckpoint.swift` (`reserveCompleteCheckpointReadScratch`) |
| Import admission | Authenticate manifest → allocation-free import plan → native per-buffer destination, scratch and metadata admission → bounded whole-file read. Shared native ownership is separate from provider host IO | `SSDHybridCheckpointStore+Read.swift` (`readCheckpoint`), `CompleteCheckpointCodec.swift` (`allocate`) |
| Idle state | Metadata index only; no resident tensor bank or persistent slot carve | `SSDHybridCheckpointStore.swift`, `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift` (`isMemoryEnabled`) |
| Imported lifetime | Single-use staged state retains native owners through aliases. Paged adoption replaces temporary staging with the full request promise and actual backing; recurrent/MTP auxiliary state has its own charge | `CompleteCheckpointTransfer.swift` |
| Host IO lifetime | Read/decrypt aliases retire before the read charge returns; writers claim host buffers before encoding and release them after the complete write stack drains | `SSDHybridCheckpointStore+Read.swift` (`readCheckpoint`), `SSDHybridCheckpointStore+Write.swift` (`write`) |
| Durable ready | Only supplied actual input checkpoint after committed write and engine donor/export retirement; requires request mode echo | `SSDHybridCheckpointStore+Write.swift`, `provider-swift/Sources/ProviderCore/Inference/PrefixCacheEvidenceSequencer.swift` |
| Disk compatibility | Verified model/template, binary, loaded metallib, OS and numerical/MTP settings, plus actual native dtype and storage geometry | `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy+CheckpointIdentity.swift`, `CompleteCheckpointStorageIdentity.swift` |
| Numerical environment identity | Process and slot values whose keys start with `MLX_`, `DARKBLOOM_CBV2_`, `DARKBLOOM_QWEN_`, `DARKBLOOM_MTP_`, `DARKBLOOM_GPTOSS_` or `DARKBLOOM_GEMMA4_`; changing an included optimization or rollback setting selects a different disk namespace | `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy+CheckpointIdentity.swift` (`completeCheckpointIdentity`) |

| Complete layout | Payload | Loaded gate |
|---|---|---|
| `native-contiguous-full-recurrent-v1` | Native full KV, recurrent state and optional typed MTP history | Owning full-attention rows, supported native types and complete recurrent codec |
| `native-paged-full-recurrent-v1` | Same complete recurrent state, imported into independent segmented pages | Same codec plus resolved segmented paging and observed native types |
| `native-paged-historical-attention-v2` | Owning full rows and exact historical window contents, with absolute positions and borrower map | Loaded historical capability, resolved segmented paging, exact ordered attention map; assistant absent or stateless |

Layout constants and validation live in `CompleteCheckpointContract.swift` and
`HistoricalAttentionLayout.swift`; provider selection is
`EngineV2SlotFactory+CompletePrefixCache.swift` (`completeCheckpointStorage`).
Historical windows capture the last `min(M, W)` tokens at boundary M and restore
with base `max(0, M - W)`. Window copies finish before successor writes. Ordinary
attention snapshots and their optional unused window sidecar remain separate.

Validation artifacts, source scopes and model-measurement limits are linked from
[the cache architecture](../architecture/prefix-cache.md#streamed-complete-checkpoints).
Earlier resident-cache measurements do not establish SSD latency or restart reuse.

## Identity binding

A block is readable only when every binding below matches; any mismatch,
parse or authentication failure deletes the file and is served as a cold miss
(`provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCache.swift`).

| Binding | Value | Code |
|---|---|---|
| `weightHash` | Verified SHA-256 aggregate of the live weights; absent ⇒ tier disabled (`weight_hash_unavailable`) | `SSDPrefixCacheFactory.swift` (`make`) |
| `promptContractId` | `PromptContractIdentity.compute(modelDirectory:)`; absent ⇒ tier disabled (`runtime_identity_unavailable`) | `provider-swift/Sources/ProviderCoreFoundation/PromptContractIdentity.swift` |
| `layoutEpoch` | `"cbv2-frozen-full-3\|native-fp\|<blockSize>\|<layerKindsDigest>"`, digest = SHA-256 of the canonical layer-kind list, hex prefix | `SSDBlockStore.swift` (`layoutEpoch(blockSize:layerKinds:)`) |
| `blockSize` | `CBv2BlockHasher.defaultBlockSize`, mirrored by `PrefixCachePolicy.blockSize`; value in [`../architecture/prefix-cache.md#block-hashing`](../architecture/prefix-cache.md#block-hashing) | `provider-swift/Sources/ProviderCore/Inference/PrefixCachePolicy.swift` (`blockSize`) |
| `blockHashVersion` | `PromptContractIdentity.blockHashVersion`; value in [`../architecture/prefix-cache.md#block-hashing`](../architecture/prefix-cache.md#block-hashing) | `PromptContractIdentity.swift` |
| `keyFingerprint` | Fingerprint of the KEK in use | `SSDCacheEpochStore.swift` (`Binding`) |
| Epoch | Random per-model generation in `cache-epoch.json`; any binding drift (for example the legacy `cbv2-snap-2\|f16\|…` layout that `SSDCacheEpochStoreTests` rotates away) wipes the model's blocks and mints a new epoch before `ready` is advertised | `SSDCacheEpochStore.swift` |

## Environment variables

Names and effects only; defaults and parsing rules are in
[`configuration.md`](configuration.md). Installed launchd daemons receive only
the allowlisted variables in `passthroughEnvKeys`
(`provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift`). The cache
switches `DARKBLOOM_PREFIX_CACHE` and `DARKBLOOM_PREFIX_CACHE_MEMORY` are on that
list; the test-root and persistent-key benchmark controls are not.

| Variable | Effect | Code |
|---|---|---|
| `DARKBLOOM_PREFIX_CACHE` | Process-wide kill switch for the tier (`environmentFlag`) | `PrefixCachePolicy.swift` (`isEnabled`) |
| `DARKBLOOM_PREFIX_CACHE_DISK_GB` | Box-wide disk budget override | `PrefixCachePolicy.swift` (`ssdDiskBudgetBytes`) |
| `DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS` | Cadence of the local stats line and typed per-store heartbeat snapshot; `0` disables both | `PrefixCachePolicy.swift` (`statsIntervalSecs`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS` | Sliding TTL; can only shorten `maxTTLSeconds` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` (`ttlSeconds`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY` | Daily write cap; `0` = unlimited | `SSDPrefixCachePolicy.swift` (`maxWriteBytesPerDay`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_MIN_EFFECTIVE_TOKENS` | Adoption-benefit floor (raise-only against the long-hybrid floor) | `SSDPrefixCachePolicy.swift` (`minEffectiveTokens`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB` | Max staged bytes per adoption | `SSDPrefixCachePolicy.swift` (`maxStageBytes`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MS` | Max estimated staging time | `SSDPrefixCachePolicy.swift` (`maxStageMillis`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_WINDOW_SIDECAR` | Enables writing window sidecar files (format only) | `SSDPrefixCachePolicy.swift` (`windowSidecarEnabled`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_STRICT_FSYNC` | fsync every block write (GCM auth otherwise catches torn writes) | `SSDPrefixCachePolicy.swift` (`strictFsync`) |
| `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL`, `DARKBLOOM_PREFIX_CACHE_TEST_ROOT` | Permit an in-memory KEK fallback and an isolated payload root; an accepted test root normally forces an ephemeral key | `SSDPrefixCacheFactory.swift` |
| `DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY` | Exactly `1` requests the normal persistent KEK within an accepted test root; benchmark-only, not forwarded to LaunchAgents | `SSDPrefixCacheFactory.swift` (`forceEphemeralKey`) |

An isolated restart benchmark sets `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1`
to enable `DARKBLOOM_PREFIX_CACHE_TEST_ROOT`, then sets
`DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY=1` to attempt the normal
Secure Enclave/Keychain KEK.
The allowance still permits an ephemeral fallback, so the benchmark session's
`requirePersistentKey` defaults to true and refuses an actual ephemeral complete
store. `CacheSnapshot.keyMode` reports the observed key mode. No key bytes are
written into the test root (`EngineV2Factory+BenchmarkSession.swift`,
`SSDCacheKeyMaterial.swift`). Restart requires a new OS process; see
[benchmark validation](../developer/test.md#resident-prefix-benchmark-validation).

The standalone benchmark can instead select an isolated persistent hierarchy with
paired `--persistent-test-namespace UUID` and `--persistent-test-access-group GROUP`
options. The UUID derives a unique enclave label and wrapped-KEK service/account;
the concrete access group remains subject to ordinary entitlement enforcement.
This requires explicit persistent-key SSD mode and an affirmative isolated-root
context. Invalid or partial selection refuses before model/config/root/native/key
work. Existing symlink ancestors of candidate and protected cache roots are
resolved even when the final directories do not exist; dangling links, loops and
raw traversal refuse. No root is created by that validation.

Namespaced key failure cannot fall back to an ephemeral key. Omitting the namespace
preserves the existing production selection and fallback behavior. Reports record
namespace, selectors, isolated root and observed key mode without key bytes. This
seam applies only to the standalone benchmark: the full provider loop still has a
separate default attestation path. The [namespace validation report](../reports/2026-09-06-persistent-ssd-test-namespace.md)
records source/fixture coverage; actual signed persistent restart remains unproved.

## Size and eviction rules

All constants are code constants of `SSDPrefixCachePolicy` and
`PrefixCachePolicy`; the env variables above may narrow some of them.

| Rule | Constant | Code |
|---|---|---|
| Disk budget | `defaultSSDDiskBudgetBytes = 100 * 1_073_741_824` (100 GiB); default `max(1, min(defaultSSDDiskBudgetBytes, volumeFree / 2))`, re-evaluated during enforcement across all models. Unknown free space uses the fixed default; a valid positive environment override wins verbatim. | `PrefixCachePolicy.swift` (`ssdDiskBudgetBytes`) |
| Eviction order | LRU by last hit across the whole `kv3/` root; eviction is `unlink` + index removal | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockIndex.swift` |
| Maintenance sweep | `SSDWholeRootMaintainer`, `intervalSeconds = 60`: TTL expiry, budget eviction, crash-temp cleanup | `SSDPrefixCacheFactory.swift` (`startWholeRootMaintenance`), `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWholeRootMaintainer.swift` |
| TTL | `defaultTTLSeconds = 900`, `maxTTLSeconds = 900`, sliding on hit | `SSDPrefixCachePolicy.swift` |
| Daily write cap | `defaultMaxWriteBytesPerDay = 150 * 1_000_000_000` | `SSDPrefixCachePolicy.swift` |
| Low-disk write stop | `lowDiskFloorBytes = max(lowDiskAbsoluteFloorBytes = 20 * 1_073_741_824, lowDiskCapacityFraction = 0.05 × volume)`; reads continue; ENOSPC starts `enospcCooldownSeconds = 600` | `SSDPrefixCachePolicy.swift` |
| Payload/staging cap | `defaultMaxStageBytes = 1024 * 1_048_576`; `defaultMaxStageMillis = 1000` at `conservativeStageBytesPerSecond = 1_500_000_000` | `SSDPrefixCachePolicy.swift` |
| Attention donation floor | `prefixTokens > adoptionBoundTokens + minEffectiveTokens`, whole blocks only; `defaultMinEffectiveTokens = 1024`, raised to 1_536 for `.frozenFullReplay` with bound ≥ 25_600 | `SSDPrefixCache.swift` (`donate`), `PrefixCachePolicy.swift` |
| Write-behind queue | `writeQueueMaxJobs = 2`, `writeQueueMaxBytes = 512 * 1_048_576`, `writeQueueSlackBytes = 256 * 1_048_576`; overflow drops the donation | `SSDPrefixCachePolicy.swift`, `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWriteBehind.swift` |
| Staging RAM | Reserved per staged entry in `GlobalKVCacheBudget`; the engine keeps its full slot grant | `provider-swift/Sources/ProviderCore/Inference/GlobalKVCacheBudget.swift` |

## Per-family reuse capability

Complete-store selection uses the effective loaded serving model and resolved
backend in `EngineV2SlotFactory+CompletePrefixCache.swift`
(`prepareCompletePrefixCache`). The ordinary attention-block codec separately
uses `CBv2PrefixReuseCapability.derive`; its replay strategy does not govern
complete checkpoint restoration. These are source eligibility gates, not an
exact-artifact release validation claim.

| Family (`model_type`) | Complete payload | Supported backend | Cache built when |
|---|---|---|---|
| GPT-OSS (`gpt_oss`) | Historical full/window attention | Segmented paged | Loaded historical capability, exact native attention map and verified identity |
| Gemma 4 (`gemma4`, `gemma4_text`) | Historical full/window attention | Segmented paged | Effective text target has historical capability; normal stateless assistant is compatible; vision requests still stage cold |
| Qwen 3.5/3.8 dense (`qwen3_5`) | Full KV, recurrent state and optional typed MTP | Native contiguous or segmented paged | Supported floating/affine embedding typing, full owners and verified complete codec/storage identity |
| Qwen 3.5/3.6 MoE (`qwen3_5_moe`) | Same recurrent complete codec | Native contiguous or segmented paged | Same gate as dense Qwen |
| Qwen3-VL MoE (`qwen3_vl_moe`) | Unsupported | No paged capability | No complete store (`unsupported_layout`) |

The global cache switch defaults on and the resident-memory switch defaults off.
Backend `auto` still resolves contiguous: eligible Qwen can build its complete
store there; GPT-OSS and Gemma require explicit paged selection for their
historical complete store. Runtime identity, disk/key and loaded capability
checks apply independently of family names.

All families also require a valid artifact prompt contract. The directory-based
check requires `chat_template.jinja` and a passing render self-check. The versioned
request-clock renderer supports `strftime_now` without changing the artifact
template. A supported family or backend alone does not grant
SSD eligibility (`provider-swift/Sources/ProviderCoreFoundation/PromptContractIdentity.swift`,
`compute(modelDirectory:)`).

Dense and MoE Qwen may use quantized model weights while keeping native-precision KV.
For complete checkpoints, an ordinary embedding must have `float16`, `bfloat16`
or `float32` weights. An affine `QuantizedEmbedding` instead binds activation
dtype to matching floating scales and biases; its packed integer weight dtype
is not used as KV or recurrent convolution-state dtype. Both declarations use
the same resolver. Other quantization modes, mismatched scale/bias dtypes or
unsupported types return no complete checkpoint capability
(`libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35+CompleteCheckpoint.swift`,
`cbv2CheckpointActivationDType`, `cbv2CompleteCheckpointKVDTypes`;
`libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift`, `cbv2RecurrentStateSpec`).

Capability constants: `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/RecurrentStateV2.swift`
(`CBv2ModelCapabilities`); the per-family switch is in
`provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+ModelAdapter.swift` (`ProductionModelAdapter`). An explicit `paged` selection is refused when the
model lacks the required capability (reason `model_capability`); the kill switch
can separately degrade it to contiguous.
Eligible dense and MoE Qwen now support explicit paging only with segmented
storage and a per-layer native type table measured from the loaded target.
Complete Qwen restoration supports both native storage layouts; `auto` remains
contiguous until the release validation gates are complete.

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
| `darkbloom logs` | `prefix cache stats (engine=v2, tier=ssd, model=…)` line every `DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS` with cache kind, index/disk/staging counts and cumulative writes/drops; complete stores add I/O totals | `provider-swift/Sources/ProviderCore/KVCacheSSD/EngineV2Bridge+SSDPrefixCache.swift` (`startSSDPrefixCacheStatsLogger`) |
| Typed heartbeat | Optional `slots[].prefix_cache` observation with advancing age; cumulative units, freshness and bounded metrics are in [telemetry](../architecture/telemetry.md#durable-prefix-cache-observations) | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheTelemetry.swift` (`SSDPrefixCacheTelemetryBox`) |
| Heartbeat → coordinator `GET /v1/cache/status` | `prefix_cache_statuses` per loaded model (`state`, `reason`, `backend`, `replay_strategy`) and aggregated donation outcomes | `Messages.swift` (`prefixCacheStatuses`), `coordinator/api/server.go` (`handleExactCacheStatus`) |
| `darkbloom benchmark --parity` | Loads the model on both KV backends and reports the prefix-reuse probe as PASS/FAIL/UNAVAILABLE | `provider-swift/Sources/darkbloom/BenchmarkCommand+Parity.swift` |

## Related

- [`../architecture/prefix-cache.md`](../architecture/prefix-cache.md) — layouts, reuse plan, construction gate
- [`../architecture/cache-aware-routing.md`](../architecture/cache-aware-routing.md) — coordinator side
- [`../architecture/security/encryption.md`](../architecture/security/encryption.md) — key hierarchy
- [`../design/ssd-kv-cache.md`](../design/ssd-kv-cache.md), [`../design/ssd-kv-cache-v1-design.md`](../design/ssd-kv-cache-v1-design.md) — superseded design records
- Tests: `provider-swift/Tests/ProviderCoreTests/SSDPrefixCacheTests.swift`
