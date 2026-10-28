# SSD KV cache reference

> Last updated: 2026-10-28

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
| Root | By default `~/Library/Caches/<encryptedCacheNamespace>/kv3/`; a saved `cache.directory` selects `<directory>/<encryptedCacheNamespace>/kv3/`. The namespace is `darkbloom` for production; a dev build has its own ([Dev build identity](../operations/provider-release.md#dev-build-identity)), so the two never share blocks or epochs | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheFactory.swift` (`cacheRootDirectory`) |
| Per-model directory | `<root>/<modelKey>/`, `modelKey = SHA256(modelId)` first 12 hex characters | `SSDPrefixCacheFactory.swift` (`cacheDirectory`) |
| Block file | `<tag>.dbk3`, one file per attention block or complete recurrent checkpoint ([block size](../architecture/prefix-cache.md#block-hashing)); `fileExtension = "dbk3"` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockStore.swift` |
| Epoch record | `<modelKey>/cache-epoch.json`, schema `darkbloom.cache-epoch.v1` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDCacheEpochStore.swift` |
| Test root | `DARKBLOOM_PREFIX_CACHE_TEST_ROOT`, honoured only with `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` affirmative | `SSDPrefixCacheFactory.swift` (`isolatedTestRoot`) |
| Retired root | `darkbloom/kv/` (the pre-v0.7.5 tier) is never read or written; `kv3/` is a sibling, not a subtree | `SSDPrefixCacheFactory.swift` (`ssdRootDirectoryName`) |

The selected volume must pass `CacheVolume.inspect`: local writable APFS with
ownership enabled, an operator-owned directory without group/other write access,
and APFS encryption on external volumes. Missing storage or a UUID mismatch
refuses cache I/O; it never redirects to the default disk. Descriptor walks check
the pinned UUID before creating directories and opening active cache files
(`CacheStorage.validateOpenedDirectory`, `SSDNoFollowIO`).

The `.write-budget` ledger remains at the built-in root for production even when
payloads use another disk. Existing internal usage survives disk selection and
restart; an external volume cannot reset it. Explicit isolated test roots keep
their own ledgers (`CacheStorage.writeBudgetRoot`).

## DBK3 file format

Every `.dbk3` file is the reviewed v1 `DBKV` chunked AES-GCM scheme (the
retired `EncryptedKVStore`) with `formatVersion = 3` (`SSDBlockStore.swift`,
header comment and `enum SSDBlockStore`).

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
| KEK | Secure-Enclave-rooted and Keychain-persisted (service `io.darkbloom.kv.kek.v1`; a dev build uses `io.darkbloom.dev.kv.kek.v1`). An entry that fails authentication under the current Secure Enclave identity, or holds no 32-byte key, is replaced by a fresh KEK; a backend failure such as a locked keychain is reported and leaves it. `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` permits fallback to an in-memory KEK whose ciphertext cannot be reused after process exit. A DEBUG build with `DARKBLOOM_DEBUG_CACHE_KEY_FILE` derives a persistent KEK from that operator-created file instead; release builds do not contain this path | `SSDCacheKeyMaterial.swift` (`load`), `provider-swift/Sources/ProviderCore/KVCache/KVCacheKEK.swift` (`replaceUnusable`), `SSDPrefixCacheFactory.swift` (`ephemeralAllowed`), `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDDebugCacheKeyFile.swift` |
| Lookup key | `K_lookup = HKDF-SHA256-Expand(PRK: KEK, info: "dbkv3-lookup-v1", L = 32)` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDLookupKeys.swift` |
| File-name tag | `HMAC-SHA256(K_lookup, "dbkv3-name-v1" ‖ u64le(len(salt)) ‖ salt ‖ chainHash)`, truncated to `truncatedTagLength = 16` bytes; full tag authenticated in metadata | `SSDLookupKeys.swift` |
| Window sidecar tags | `"dbkv3-window-v1"`, `"dbkv3-window-base-v1"` domains (format only; `DARKBLOOM_PREFIX_CACHE_SSD_WINDOW_SIDECAR` off; no restore consumer) | `SSDLookupKeys.swift`, `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWindowSidecar.swift` |
| Streaming read | `SSDBlockChunkCursor` returns one authenticated chunk per call in file order, or skips one unread, then checks EOF and file identity; `readStreaming` drives one cursor. A field or chunk that one read returns whole is kept as read rather than copied into a second buffer (`SSDBlockStore.readExactly`) | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockChunkCursor.swift` |
| Temp files | `tempMarker = "darkbloom-tmp"`, crash-orphan TTL `crashTempTTLSeconds = 3600` | `SSDBlockStore.swift` |
| Path safety | Descriptor-relative no-follow traversal; nonblocking final read/touch opens followed by regular-file validation | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDNoFollowIO.swift`, `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockPathGuard.swift` |

Read and touch open the final entry with `O_NONBLOCK` before descriptor-based
regular-file validation. Replacing a cache entry with a FIFO cannot make
these opens wait for a writer. Invalid targets are rejected; normal file
reads and timestamp updates retain their existing behavior. Epoch metadata
reads use the same helper. This is local filesystem availability hardening,
not a change to authentication, encryption, retention or cache identity
(`SSDNoFollowIO.swift`, `openRegularFileForReading`, `touchRegularFile`;
`SSDCacheEpochStore.swift`, `readRecord`).

A disk observer sees the lookup tag, the weight hash, the layout epoch, block
shape descriptors and `createdAt`; never raw chain hashes, token ids or counts,
scope values, or request ids (`SSDBlockStore.swift` header). A delta checkpoint
adds `parentCommitment`, which only a holder of `K_lookup` can pair with its
parent file ([delta checkpoints](#delta-complete-checkpoints)).

A confirmed missing parent directory is file absence, not corruption. The
resident-preflight regression creates actual malformed DBK3 files: equal or
shorter SSD matches must avoid reading them, while a longer match must reject
the malformed data. Missing-parent status and typed `ENOENT` reads have separate
coverage (`SSDNoFollowIOSpecialFileTests`, `EngineV2BridgeTests`).

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
| Import admission | Authenticate manifest → allocation-free import plan → native per-buffer destination, scratch and metadata admission → bounded whole-file read. Shared native ownership is separate from provider host IO | `SSDHybridCheckpointStore+ReadAttempt.swift` (`readCheckpoint`), `CompleteCheckpointImportPlan.swift` (`allocate`) |
| Provider-staged destinations | The provider-staged (non-native-bound) import creates contiguous destinations, paged segment storage and recent rows already available from zeroed host bytes, then skips `eval` and stream fences for them. Staging therefore never waits for MLX-Swift's process-wide `evalLock`, which the engine holds for a whole prefill chunk. The zero source is read by the copy and can briefly commit up to one destination outside the MLX allocator, so the import plan charges the largest as staging scratch. Native-bound imports and engine pool growth keep device allocation | `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Prefix/CheckpointHostZeros.swift` (`MLXArray.cbv2HostZeros`), `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Prefix/CompleteCheckpointTransfer.swift` (`CBv2CompleteCheckpointImport`), `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Prefix/PagedCheckpointStorage.swift` (`CBv2PagedCheckpointStorage`, `hostMaterialized`), `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Prefix/CompleteCheckpointImportPlan.swift` (`CBv2CompleteCheckpointImportPlan.scratchBytes`, `evaluateUnavailable`) |
| Lossy-to-native conversion | CPU row encoding/decoding; `64 << 10` bytes of conversion scratch, reserved per export read and in the import plan. Import reuses row buffers, retains at most one fragmented input row, and batches validated native writes up to `16 << 10` bytes within that allowance. Native destination sizes, not encoded bytes, price restored state | `NativeCheckpointRowCodec.swift`, `NativeQuantizedCheckpointTensorSource.swift`, `CompleteCheckpointImportPlan.swift`, `NativeQuantizedCheckpointRestore.swift` |
| Idle state | Metadata index only; no resident tensor bank or persistent slot carve | `SSDHybridCheckpointStore.swift`, `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy.swift` (`isMemoryEnabled`) |
| Imported lifetime | Single-use staged state retains native owners through aliases. Paged adoption replaces temporary staging with the full request promise and actual backing; recurrent/MTP auxiliary state has its own charge | `CompleteCheckpointTransfer.swift` |
| Host IO lifetime | Read/decrypt aliases retire before the read charge returns; writers claim host buffers before encoding and release them after the complete write stack drains | `SSDHybridCheckpointStore+ReadAttempt.swift` (`readCheckpoint`), `SSDHybridCheckpointStore+Write.swift` (`write`) |
| Durable ready | Only supplied actual input checkpoint after committed write and engine donor/export retirement; requires request mode echo | `SSDHybridCheckpointStore+Write.swift`, `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCacheEvidenceSequencer.swift` |
| Ready stage estimate | `stage_ms` is the largest ready file's bytes at `conservativeStageBytesPerSecond` plus an exponentially weighted average (newest weight 0.25) of how much longer this store's first-attempt restores took than their byte price. The first restore replaces the layout's prior: `glm5NextPriorOverheadMilliseconds = 935` for both GLM5-Next layouts (median of nine M5 Ultra restores of the exact layout), 0 otherwise. The coordinator scores a holder with it until a hit's measured lookup `stage_ms` replaces it ([`Holder.StageCostAt`](https://github.com/Layr-Labs/darkbloom-platform/blob/d7be846198448baded8c933cacce63f20541f7ed/coordinator/internal/registry/cachetracker/holder.go)) | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDCheckpointStageCost.swift`, `SSDHybridCheckpointStore+Maintenance.swift` (`publishReady`), `SSDHybridCheckpointStore+Read.swift` (`stage`) |
| Disk compatibility | Verified model/template, binary, loaded metallib, OS and numerical/MTP settings, plus actual native dtype, effective checkpoint profile and storage geometry | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+CheckpointIdentity.swift`, `CompleteCheckpointStorageIdentity.swift` |
| Numerical environment identity | Process and slot values whose keys start with `MLX_`, `DARKBLOOM_CBV2_`, `DARKBLOOM_QWEN_`, `DARKBLOOM_MTP_`, `DARKBLOOM_GPTOSS_` or `DARKBLOOM_GEMMA4_`; native `mimo_v2` additionally binds its `DARKBLOOM_MIMO_` controls. Changing an included optimization or rollback setting selects a different disk namespace | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+CheckpointIdentity.swift` (`completeCheckpointIdentity`) |

| Complete layout | Payload | Loaded gate |
|---|---|---|
| `native-contiguous-full-recurrent-v1` | Native full KV, recurrent state and optional typed MTP history | Owning full-attention rows, supported native types and complete recurrent codec |
| `native-paged-full-recurrent-v1` | Same complete recurrent state, imported into independent segmented pages | Same codec plus resolved segmented paging and observed native types |
| `affine-paged-full-recurrent-v1` | Packed mirror of all attention rows plus exact native recent band, native recurrence and optional MTP history | Resolved quantized segmented pool and exact complete codec |
| `affine-paged-historical-attention-v1` | Packed/native owning rows and exact historical windows, with borrower map | Resolved mixed storage and exact historical codec |
| `native-paged-historical-attention-v2` | Owning full rows and exact historical window contents, with absolute positions and borrower map | Loaded historical capability, resolved segmented paging, exact ordered attention map; assistant absent or stateless |
| `native-contiguous-historical-attention-v1` | Exact native owning full/window rows, imported into contiguous native capacity | Loaded historical capability and explicitly observed native types; assistant absent or stateless |
| `native-paged-affine-checkpoint-full-recurrent-v1` | Older attention rows encoded, exact native recent rows and recurrent state; native paged restore | Eligible native segmented pool and recurrent complete codec; no persistent assistant |
| `native-paged-affine-checkpoint-full-recurrent-mtp-v1` | Same payload plus the assistant's exact typed MTP history and its codec ID | Same, beside an assistant declaring `CBv2MTPExactHistoryPrefixCheckpointCoding` (the Nemotron Super assistant) |
| `native-paged-glm5next-affine-checkpoint-full-state-v1` | GLM5-Next full state with only the older latent rows encoded; see below | Eligible GLM latent geometry, unquantized segmented pool, assistant absent or exact-history (`resolveGLM5Next`) |
| `native-paged-affine-checkpoint-historical-attention-v1` | Encoded older owning full/window rows and native recent rows; native paged restore | Eligible loaded historical capability and native segmented pool |
| `native-contiguous-affine-checkpoint-full-recurrent-v1` | Same lossy/native recurrent payload; native contiguous restore | Eligible native contiguous recurrent complete codec; no persistent assistant |
| `native-contiguous-affine-checkpoint-historical-attention-v1` | Same lossy/native historical payload; native contiguous restore | Eligible loaded historical capability and observed native types |

Layout constants and validation live in `CompleteCheckpointContract.swift` and
`HistoricalAttentionLayout.swift`; provider selection is
`EngineV2SlotFactory+CompletePrefixCache.swift` (`completeCheckpointStorage`).
Without an effective checkpoint profile, GLM5-Next uses
`native-paged-glm5next-full-state-v2`: asymmetric
latent/index/gate/validity rows, the KDA convolution history and the exact FP32
KDA recurrent state, plus the MTP prefix tensors at their own native dtypes. The
live pool and state keep these rows in FP32, but the latent keys, the `[index
keys, pool gates, 0/1 validity]` values row and the convolution history only
widen the model's activation dtype. The encrypted manifest's
`glm5NextState.storage` records each of those three roles' wire dtype, and the
export writes them at that dtype: BF16 for `glm-5.3-flash`, whose producing
weights, norms and pool gates are all BF16. Narrowing refuses (the donation
fails, no file is written) if any element is not exactly representable, and
import widens back to the original FP32 bits, so restore stays lossless. The
recurrent state is accumulated in FP32 and is always written in FP32. The
loaded target declares the role dtypes by the same promotion its forward pass
applies (`GLM5NextTextModel.glm5NextPagedPayloadStorage`); a target with FP32
activations keeps every role FP32. The retired all-FP32
`native-paged-glm5next-full-state-v1` spelling is refused, and its different
layout epoch keeps v1 files outside a v2 store's namespace until the TTL sweep
removes them. The shared narrowing/widening helper is
`CBv2CheckpointHalfPrecision`
(`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Prefix/GLM5Next/GLM5NextCompleteCheckpointLayout.swift`,
`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Prefix/CheckpointHalfPrecision.swift`,
`provider-swift/Sources/ProviderCore/KVCacheSSD/SSDHybridCheckpointStoreFactory.swift`).

With an effective checkpoint profile GLM5-Next writes
`native-paged-glm5next-affine-checkpoint-full-state-v1` instead. Only the latent
keys role changes: a `uint8` stream per layer of the older coded rows followed
by the last `min(recentTokenCount, retainedTokens)` rows at the latent wire dtype
(BF16 for `glm-5.3-flash`). Import decodes the coded rows and widens the band
into the FP32 pages. The odd-width values row, the convolution history, the FP32
recurrent state and the MTP prefix tensors keep the v2 payload and restore bit
for bit; older latent rows are approximate
(`CBv2CompleteCheckpointStorageQuantization.resolveGLM5Next`,
`CBv2GLM5NextCompleteCheckpointLayout.latentQuantization`,
`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Prefix/CheckpointStorageQuantization.swift`).

| `glm-5.3-flash` checkpoint (DBK3 file, M5 Ultra, 2026-10-24) | `native` | `balanced` |
|---|---:|---:|
| 1,024 tokens (the donation anchor) | 168.2 MB | 161.3 MB |
| 1,792 tokens | 182.4 MB | 169.5 MB |
| 8,192 tokens | 300.5 MB | 238.1 MB |
| 32,768 tokens | 754.2 MB | 501.5 MB |

| `glm-5.3-flash` checkpoint (DBK3 file, measured on an M5 Ultra) | Size |
|---|---:|
| 2,048 tokens | 187.1 MB |
| 8,192 tokens | 300.5 MB |
| 30,720 tokens | 716.4 MB |
| Per token | 18.5 KB |
| Fixed part (mostly the FP32 KDA recurrent state) | 149.3 MB |

A donation also writes the 2,048-token anchor, so a 30,720-token donation
writes 904 MB. A full 262,144-token context checkpoint is about 5.0 GB, inside
the 7 GiB large-memory staging cap.
See the [GLM integration gates](../design/glm53-flash-native.md).

The managed `nvidia-nemotron-3.5-super` slot writes
`native-paged-affine-checkpoint-full-recurrent-mtp-v1` while it speculates and
`native-paged-affine-checkpoint-full-recurrent-v1` target-only at the default
`balanced` precision. Its 8 attention layers (2 KV heads × 128) shrink from
8 KiB to 2.5 KiB per token past the exact 128-token band; the MTP history
(1 KiB per token) and the fixed part (the FP32 SSM state, convolution state and
MTP frontier, 173.9 MB) stay exact.

| `nvidia-nemotron-3.5-super` checkpoint (DBK3 file, measured on an M3 Ultra) | `native` | `balanced` |
|---|---:|---:|
| 2,048 tokens | 192.8 MB | 182.0 MB |
| 8,192 tokens | 249.5 MB | 204.0 MB |
| 30,720 tokens | 457.2 MB | 284.9 MB |
| Per token | 9.2 KB | 3.6 KB |

Historical windows capture the last `min(M, W)` tokens at boundary M and restore
with base `max(0, M - W)`. Window copies finish before successor writes. Ordinary
attention snapshots and their optional unused window sidecar remain separate.

The six lossy layouts (the four `native-*-affine-checkpoint-*` layouts, the
`-mtp-v1` recurrent variant and the GLM5-Next variant) set
`checkpointQuantization` and `checkpointNativeDTypes` in the encrypted manifest.
`CBv2CompleteCheckpointManifest.usesLossyNativeCheckpoint` identifies those
layouts; it is a derived property, not another serialized field. Other layouts
reject the new fields rather than reinterpret their payloads. The `-mtp-v1`
variant requires an assistant codec ID and the GLM5-Next variant may carry one;
the other four refuse it.
The codec checks exact profile, native types, layout, identity, tenant salt,
prefix and tensor descriptors before creating an import stage.

For these lossy layouts, an encoded K/V head is a `uint8` stream of older coded
rows followed by the exact last `min(recentTokenCount, retainedTokens)` native
rows, with no packed recent mirror. Native owners and permitted auxiliary
tensors keep typed native payloads. Restore reconstructs private native state;
its older rows are approximate and do not recover their original bits.

The existing live-packed `affine-paged-*` layouts instead retain **all** coded
rows followed by the original native recent band. That band is private input
scratch until the active row's own copy completes; its pre-existing packed
mirror survives aging without another encoder. The separate checkpoint request
does not replace this live-packed format. Resolved profiles and native-owner
exemptions separate compatibility identities. See the
[execution and checkpoint contract](../architecture/kv-cache-quantization.md).

Validation artifacts, source scopes and model-measurement limits are linked from
[the cache architecture](../architecture/prefix-cache.md#streamed-complete-checkpoints).
Earlier resident-cache measurements do not establish SSD latency or restart reuse.

### Delta complete checkpoints

A request whose stage the engine consumed holds the restored file's rows byte
for byte, so its later checkpoints store only the rows that file lacks.

| Contract | Bound / behavior | Code |
|---|---|---|
| Eligible layout | `native-paged-full-recurrent-v1` and `native-contiguous-full-recurrent-v1`: K/V and Qwen MTP history store rows `[P, D)`; recurrent, convolution and frontier state are stored whole. Other layouts, cold requests and a negative `DARKBLOOM_PREFIX_CACHE_SSD_INCREMENTAL_CHECKPOINTS` write complete files | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDCheckpointDeltaLayout.swift`, `SSDHybridCheckpointStore+Write.swift` (`deltaEnvelope`) |
| Parent | The restored file, or its chain's root once the chain holds `maximumChainFiles = 8` files; a chain must also fit `maxReadBytes`, else the file is complete | `SSDHybridCheckpointStore+Write.swift` (`deltaEnvelope`) |
| Binding | Public `parentCommitment = HMAC(K_lookup, "dbkv3-checkpoint-parent-v1" ‖ parent full tag ‖ parent file IV)`, in the AAD; the scan pairs it with each file's own tag and IV | `SSDLookupKeys.swift` (`checkpointParentCommitmentHex`), `SSDHybridCheckpointStore+Maintenance.swift` (`scanOnDisk`) |
| Restore | A candidate is the whole chain, every link fresh and its bytes within the stage caps. The reader holds only the leaf: ancestors are read unlocked, their chunks authenticated and pinned by the commitment, so readers sharing a root never wait for each other. It checks every commitment and manifest, then streams the leaf's tensors with one forward cursor per file, skipping replaced tensors unread; each extra file adds one `maximumSegmentBytes` of IO scratch | `SSDHybridCheckpointStore+ChainRead.swift` (`openChain`, `streamChain`), `SSDBlockIndex.swift` (`chain`) |
| Failure and recency | A failure retires the file in use; files built on a missing link are never candidates and age out. A hit or a new child refreshes the whole chain, and ready evidence prices a delta at its chain's bytes | `SSDHybridCheckpointStore+ReadAttempt.swift` (`readAttempt`), `SSDHybridCheckpointStore+Maintenance.swift` (`publishReady`) |

### Bounded shorter complete-checkpoint fallback

These rules apply to complete AR and native-block imports, not attention-block
suffix compaction. They do not raise capture/read caps or infer a shorter
checkpoint from a longer file.

| Contract | Bound / behavior | Code |
|---|---|---|
| Retry authority | At most one strictly shorter indexed endpoint after an authenticated import plan's typed `CBv2KVError.capacityExhausted`, a typed native-block pre-allocation reservation refusal, or the provider's pre-allocation destination-peak refusal | `SSDHybridCheckpointStore+Read.swift` (`stageTransfer`), `SSDHybridCheckpointStore+ReadAttempt.swift` (`readCheckpoint`) |
| No retry | AR allocation refusal without a native retirement receipt, initial scratch/host authority refusal, arithmetic overflow, unknown/generic allocation or post-materialization failure, policy, corruption, cancellation, close, epoch drift or same-ID replacement | `SSDHybridCheckpointStore+ReadAttempt.swift` (`ReadControl`, `readAttempt`), `SSDHybridCheckpointStore+Read.swift` (`readIsCurrent`) |
| First attempt | Existing candidate size/estimated-time and per-file plaintext limits remain unchanged; the new meter only records first-attempt reads and elapsed time | `SSDCheckpointReadBudget.swift` (`beforeRead`, `checkTime`) |
| Retry raw-byte ceiling | The original `maxReadBytes`, less the already-spent first manifest probe; the retry's own manifest probe and whole-file read share that remainder. Every header/framing span is charged before allocation/read, plus a conservative one-byte EOF allowance. Partial OS reads do not grant another allowance | `SSDCheckpointReadBudget.swift` (`beginRetry`, `beforeRead`), `SSDBlockStore.swift` (`readExactly`), `SSDBlockStore+Streaming.swift` (`readStreaming`) |
| Retry time checks | The original start plus `maxStageMillis`, including first-attempt work, file waits and refunds. Remaining time must also admit the candidate's existing estimated cost. Checks are cooperative, including awaited file-access/refund/native work: they do not impose a timer on those waits, preempt an OS/native operation, or guarantee return/cancellation at `maxStageMillis`. The original request cancellation remains authoritative; elapsed time is rechecked before further retry work and publication | `SSDCheckpointReadBudget.swift` (`beginRetry`, `checkTime`), `SSDHybridCheckpointStore+ReadAttempt.swift` (`readAttempt`) |
| Retirement and identity | Failed import/plan aliases unwind, scratch/native owners retire and the original host refund completes before another reservation. A cold result returns only after its attempt's host IO refund has completed. One continuous logical registration atomically changes file access; lifecycle invalidation cannot resurrect it or erase its replacement | `SSDHybridCheckpointStore+Read.swift` (`stageTransfer`), `SSDCheckpointStageReservation.swift` (`waitForRefund`) |

The pinned AR `CompleteCheckpointImportPlan.allocate` API may retain its charged
manifest on queued native retirement after capacity refusal. It exposes no
tracking discriminator or completion receipt, so this refusal remains cold;
provider host refund does not authorize a shorter attempt. Native-block typed
reservation refusals unwind synchronously. Plan-creation and provider destination
peak refusals retain the bounded retry. Future SDK changes must establish actual
retirement completion before expanding this authority. The successful shorter
file still requires full authenticated metadata, manifest, payload and EOF, then
ordinary native adoption. A staged endpoint alone is not a hit or saved usage.

## Identity binding

A block is readable only when every binding below matches; any mismatch,
parse or authentication failure deletes the file and is served as a cold miss
(`provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCache.swift`).

| Binding | Value | Code |
|---|---|---|
| `weightHash` | Verified SHA-256 aggregate of the live weights; absent ⇒ tier disabled (`weight_hash_unavailable`) | `SSDPrefixCacheFactory.swift` (`make`) |
| `promptContractId` | `PromptContractIdentity.compute(modelDirectory:)`; absent ⇒ tier disabled (`runtime_identity_unavailable`) | `provider-swift/Sources/ProviderCoreFoundation/PromptContractIdentity.swift` |
| `layoutEpoch` | `"cbv2-frozen-full-3\|native-fp\|<blockSize>\|<layerKindsDigest>"`, digest = SHA-256 of the canonical layer-kind list, hex prefix | `SSDBlockStore.swift` (`layoutEpoch(blockSize:layerKinds:)`) |
| `blockSize` | `CBv2BlockHasher.defaultBlockSize`, mirrored by `PrefixCachePolicy.blockSize`; value in [`../architecture/prefix-cache.md#block-hashing`](../architecture/prefix-cache.md#block-hashing) | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy.swift` (`blockSize`) |
| `blockHashVersion` | `PromptContractIdentity.blockHashVersion`; value in [`../architecture/prefix-cache.md#block-hashing`](../architecture/prefix-cache.md#block-hashing) | `PromptContractIdentity.swift` |
| `keyFingerprint` | Fingerprint of the KEK in use | `SSDCacheEpochStore.swift` (`Binding`) |
| Epoch | Random per-model generation in `cache-epoch.json`; any binding drift (for example the legacy `cbv2-snap-2\|f16\|…` layout that `SSDCacheEpochStoreTests` rotates away) wipes the model's blocks and mints a new epoch before `ready` is advertised. Per-file removals (budget eviction, TTL expiry, corrupt-file drops, whole-root maintenance on loaded or unloaded roots) never rewrite the record, so the epoch and `nextSequence` continue across evictions, restarts and in-place model switches | `SSDCacheEpochStore.swift` |

## Environment variables

Names and effects only; defaults and parsing rules are in
[`configuration.md`](configuration.md). Installed launchd daemons receive only
the allowlisted variables in `passthroughEnvKeys`
(`provider-swift/Sources/ProviderCore/Service/LaunchAgent.swift`). The cache
switches `DARKBLOOM_PREFIX_CACHE` and `DARKBLOOM_PREFIX_CACHE_MEMORY`, and the
delta-checkpoint rollback `DARKBLOOM_PREFIX_CACHE_SSD_INCREMENTAL_CHECKPOINTS`, are
on that list; the test-root and persistent-key benchmark controls are not.

| Variable | Effect | Code |
|---|---|---|
| `DARKBLOOM_PREFIX_CACHE` | Process-wide kill switch for the tier (`environmentFlag`) | `PrefixCachePolicy.swift` (`isEnabled`) |
| `DARKBLOOM_PREFIX_CACHE_DISK_GB` | Box-wide disk budget override | `PrefixCachePolicy.swift` (`ssdDiskBudgetBytes`) |
| `DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS` | Cadence of the local stats line and typed per-store heartbeat snapshot; `0` disables both | `PrefixCachePolicy.swift` (`statsIntervalSecs`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_TTL_SECONDS` | Sliding TTL; can only shorten `maxTTLSeconds` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCachePolicy.swift` (`ttlSeconds`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_WRITE_GB_PER_DAY` | Daily write cap; `0` = unlimited | `SSDPrefixCachePolicy.swift` (`maxWriteBytesPerDay`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_MIN_EFFECTIVE_TOKENS` | Adoption-benefit floor (raise-only against the long-hybrid floor) | `SSDPrefixCachePolicy.swift` (`minEffectiveTokens`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MB` | Max staged bytes per adoption; when set, also overrides the large-memory complete-checkpoint default | `SSDPrefixCachePolicy.swift` (`maxStageBytes`, `completeCheckpointMaxStageBytes`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_MAX_STAGE_MS` | Max estimated staging time; when set, also overrides the large-memory complete-checkpoint default | `SSDPrefixCachePolicy.swift` (`maxStageMillis`, `completeCheckpointMaxStageMillis`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_WINDOW_SIDECAR` | Enables writing window sidecar files (format only) | `SSDPrefixCachePolicy.swift` (`windowSidecarEnabled`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_STRICT_FSYNC` | fsync every block write (GCM auth otherwise catches torn writes) | `SSDPrefixCachePolicy.swift` (`strictFsync`) |
| `DARKBLOOM_PREFIX_CACHE_SSD_INCREMENTAL_CHECKPOINTS` | A negative value writes complete checkpoints whole instead of as [deltas](#delta-complete-checkpoints) | `SSDPrefixCachePolicy.swift` (`incrementalCheckpoints`) |
| `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL`, `DARKBLOOM_PREFIX_CACHE_TEST_ROOT` | Permit an in-memory KEK fallback and an isolated payload root; an accepted test root normally forces an ephemeral key | `SSDPrefixCacheFactory.swift` |
| `DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY` | Exactly `1` requests the normal persistent KEK within an accepted test root; benchmark-only, not forwarded to LaunchAgents | `SSDPrefixCacheFactory.swift` (`forceEphemeralKey`) |
| `DARKBLOOM_DEBUG_CACHE_KEY_FILE` | DEBUG builds only: the persistent KEK source for qualification of an ad hoc signed build without a keychain access group; ignored by release builds, not forwarded to LaunchAgents | `SSDDebugCacheKeyFile.swift` (`load`), `SSDCacheKeyMaterial.swift` (`defaultPersistentLoader`) |

An isolated restart benchmark sets `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL=1`
to enable `DARKBLOOM_PREFIX_CACHE_TEST_ROOT`, then sets
`DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY=1` to attempt the normal
Secure Enclave/Keychain KEK.
The allowance still permits an ephemeral fallback, so the benchmark session's
`requirePersistentKey` defaults to true and refuses an actual ephemeral complete
store. `CacheSnapshot.keyMode` reports the observed key mode. No key bytes are
written into the test root (`EngineV2Factory+BenchmarkSession.swift`,
`SSDCacheKeyMaterial.swift`). Restart requires a new OS process; see
[benchmark validation](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/developer/test.md#resident-prefix-benchmark-validation).

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
separate default attestation path. The [namespace validation report](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/reports/2026-09-06-persistent-ssd-test-namespace.md)
records source/fixture coverage; actual signed persistent restart remains unproved.

## Size and eviction rules

All constants are code constants of `SSDPrefixCachePolicy` and
`PrefixCachePolicy`; the env variables above may narrow some of them.

| Rule | Constant | Code |
|---|---|---|
| Disk budget | Default `max(1, volumeFree / 2)`, with no fixed ceiling, re-evaluated during enforcement across all models. Unknown free space uses `fallbackSSDDiskBudgetBytes = 20 * 1_073_741_824` (20 GiB); a valid positive environment override wins verbatim. The separate low-disk write stop still applies. | `PrefixCachePolicy.swift` (`ssdDiskBudgetBytes`) |
| Eviction order | LRU by last hit across the whole `kv3/` root; eviction is `unlink` + index removal | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockIndex.swift` |
| Maintenance sweep | `SSDWholeRootMaintainer`, `intervalSeconds = 60`: TTL expiry, budget eviction, crash-temp cleanup | `SSDPrefixCacheFactory.swift` (`startWholeRootMaintenance`), `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWholeRootMaintainer.swift` |
| TTL | `defaultTTLSeconds = 1800`, `maxTTLSeconds = 1800`, sliding on hit. Raising either needs the sign-off recorded in `docs/threat-model.yaml` (T-041, SEC-035) | `SSDPrefixCachePolicy.swift` |
| Daily write cap | `defaultMaxWriteBytesPerDay = 4_000 * 1_000_000_000` | `SSDPrefixCachePolicy.swift` |
| Complete-checkpoint repeat reserve | Demand gate first: a not-yet-durable checkpoint is written only when the coordinator's `cache_repeated_prefix_tokens >= minEffectiveTokens` or the local `SSDCheckpointDemand` history has seen the tag within the cache TTL; otherwise it settles `skipped_novel` with no bytes written and no write budget charged. Without a hint (older coordinator, standalone/local serving) the legacy write-every-checkpoint behavior stays (`SSDCheckpointDemand.admitsWrite`, `SSDHybridCheckpointStore.donationWritePolicy`). Admitted novel checkpoint tags use a 90% burst/refill sub-budget. A checkpoint whose own position is covered by the authenticated `cache_repeated_prefix_tokens` hint, or whose tag was observed again locally within the cache TTL, can use the full shared budget. Merely satisfying the donation floor does not classify a deeper unique extension as repeated. Both debit the original total cap; unlimited mode stays unlimited. The 4,096-entry volatile tag history is an admission input as well as a priority signal; durable duplicates authenticate and bypass both the gate and write consumption. Novel-share exhaustion reports `write_priority_limited`; total-budget exhaustion remains `write_rate_limited`. | `SSDCheckpointDemand.swift`, `SSDHybridCheckpointStore+DemandAdmission.swift`, `SSDHybridCheckpointStore+Write.swift`, `SSDWriteRateLimiter.swift` |
| Complete-checkpoint maintenance | Per-file removals run under the store's `removalLock` (`performIndexedRemoval`): unlink plus index and accounting update, serialized with other removals, refused once the store is closed or no longer owns its epoch. Whole-root external deletion reconciles missing index entries before the barrier lifts. Targeted eviction and corrupt-file removal update only their known index entries, avoiding a full filesystem scan per victim. No per-file removal rotates the model epoch; the coordinator learns of a removed checkpoint through the next lookup miss, or a hit at a shorter boundary, on that provider. A reader that finds its file gone reports `miss_absent` without counting corruption. Whole-root maintenance brackets a removal only through a registered store that still owns its root (`ownsEvictionRoot`); if every registered store for the root is closed or disowned it uses the unloaded-root path, so TTL expiry and budget eviction never wait for a disowned store to close. | `SSDHybridCheckpointStore+Maintenance.swift`, `performExternalDestructiveChange`, `reconcileExternalRemovals` |
| Owned retirement coordination | Capacity/TTL and active-owner whole-root retirement acquire the store removal lock, validate the durable epoch/binding and try the shared per-file lease without waiting. A busy renamed-but-not-indexed file is skipped; its writer commits the index before releasing that lease. Survivor identity and sequence are unchanged. | `SSDOwnedEntryRetirement.swift`, `SSDCacheEpochStore.performOwnedRetirement`, `SSDDiskBudget.retireActiveEntries` |
| Epoch record read failure | Owned retirement and whole-root rotation reread the persisted record first. A failed no-follow parent open, status probe, descriptor stat or read (EACCES, EIO, EBUSY and the like) proves nothing about the record: that operation is refused, nothing is written, the first such failure after a successful read is logged, and the store keeps its epoch; the next owned operation rereads and proceeds once the record matches. Sequence issue also refuses without disowning. Confirmed absence (the record is replaced by rename, never unlinked), an unsafe parent, an observed symlink, directory or other non-regular entry, or a read record that is unparseable, oversized or names another schema, epoch or binding disowns the store permanently. | `SSDCacheEpochStore.swift` (`performOwnedRetirement`, `performOwnedDestructiveChange`), `SSDNoFollowIO.swift` (`checkedRegularFileStatus`, `openRegularFileForReading`) |
| Low-disk write stop | `lowDiskFloorBytes = lowDiskAbsoluteFloorBytes = 20 * 1_073_741_824` (20 GiB), independent of total disk capacity; reads continue; ENOSPC starts `enospcCooldownSeconds = 600` | `SSDPrefixCachePolicy.swift` |
| Payload/staging cap | `defaultMaxStageBytes = 1024 * 1_048_576`; `defaultMaxStageMillis = 1000` at `conservativeStageBytesPerSecond = 1_500_000_000`. Complete checkpoints on Macs with at least `largeMemoryThresholdBytes = 48 << 30` physical memory default to `largeMemoryCompleteCheckpointStageBytes = 7168 * 1_048_576` and `largeMemoryCompleteCheckpointStageMillis = 15_000`; a full-size file estimates about 5 s at the planning rate, so the byte cap binds. Both caps gate capture and read. Measured Qwen 3.8 MTP checkpoint files grow about 76 KB per token over a 154 MB base ([publication cost](../reports/2026-09-05-ssd-prefix-cache-model-check.md#publication-cost-and-memory)), so on the 4,096-token prefill grid 1 GiB fits 8,192 restored tokens and 7 GiB about 94,000. Explicit settings win where the process receives them; the daily write cap is unchanged | `SSDPrefixCachePolicy.swift` (`completeCheckpointMaxStageBytes`), `SSDHybridCheckpointStoreFactory.swift`, `SSDHybridCheckpointStore.swift` (`acceptsCheckpoint`) |
| Attention donation floor | `prefixTokens > adoptionBoundTokens + minEffectiveTokens`, whole blocks only; `defaultMinEffectiveTokens = 1024`, raised to 1_536 for `.frozenFullReplay` with bound ≥ 25_600 | `SSDPrefixCache.swift` (`donate`), `PrefixCachePolicy.swift` |
| Write-behind queue | Attention blocks: `writeQueueMaxJobs = 6` jobs may wait behind the one being written, and their host bytes must fit `max(writeQueueMaxBytes, maxStageBytes + writeQueueSlackBytes)`, with `writeQueueMaxBytes = 512 * 1_048_576` and `writeQueueSlackBytes = 256 * 1_048_576` (1,280 MiB at the default stage cap). The job being written leaves both counts. Overflow drops the donation as `write_queue_full` | `SSDPrefixCachePolicy.swift`, `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWriteBehind.swift` (`submitWithResult`), `SSDPrefixCache.swift` (`init`) |
| Complete-checkpoint write queue | At most `writeQueueMaxJobs` unsettled checkpoint jobs, the one being written included; another settles `write_queue_full`. There is no queued-byte cap: a queued job references donor state that stays charged to the engine admission ledger until the donor's checkpoints settle, and a process-memory-owner or diffusion-layout donation first reserves `ioScratchBytes` (`maximumProviderScratchBytes = 20 << 20`) of host I/O in the process ledger, settling `host_memory_unavailable` when refused. The engine delivers the donor's terminal after its checkpoints settle, so a write backlog delays stream end instead of dropping the checkpoint | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDHybridCheckpointStore+Write.swift` (`donate`, `prepareWriteJob`), `SSDHybridCheckpointStore.swift` (`init`), `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/EngineLoopV2.swift` (`retire`) |
| Staging RAM | Reserved per staged entry in `GlobalKVCacheBudget`; the engine keeps its full slot grant | `provider-swift/Sources/ProviderCore/Inference/Memory/GlobalKVCacheBudget.swift` |

The production factories attach one persistent, root-wide rolling-day accounting
domain through `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWriteBudget.swift`.
Its 25 hourly buckets retain each charge for at least 24 hours, with up to one
extra hour of conservatism at bucket boundaries. Cache reconstruction and process
restart do not replenish this budget. Charges
precede writes and are not refunded on failure or eviction. Attention blocks,
window sidecars and complete checkpoints charge their complete serialized DBK3
size, not just plaintext. Exhaustion reports `write_rate_limited`; existing cache
reads remain available. Corrupt or inaccessible accounting fails closed rather
than restoring a full allowance. The ledger records only time buckets and byte
counts, never cache keys, tokens or model identifiers.

This bounds application cache-file writes, not total physical SSD wear: filesystem
metadata, the small accounting ledger, swap and device write amplification are
outside that byte count. Existing writes from before the ledger was installed
cannot be reconstructed from the surviving cache files because eviction deletes
history. The first installation starts a new accounting window.

## Per-family reuse capability

Complete-store selection uses the effective loaded serving model and resolved
backend in `EngineV2SlotFactory+CompletePrefixCache.swift`
(`prepareCompletePrefixCache`). The ordinary attention-block codec separately
uses `CBv2PrefixReuseCapability.derive`; its replay strategy does not govern
complete checkpoint restoration. These are source eligibility gates, not an
exact-artifact release validation claim.

| Family (`model_type`) | Complete payload | Supported backend | Cache built when |
|---|---|---|---|
| GPT-OSS (`gpt_oss`) | Historical full/window attention | Native contiguous or segmented paged | Loaded historical capability, observed native attention map and verified identity |
| Gemma 4 (`gemma4`, `gemma4_text`) | Historical full/window attention | Native contiguous or segmented paged | Effective text target has historical capability and observed native types; normal stateless assistant is compatible; vision requests still stage cold |
| Qwen 3.5/3.8 dense (`qwen3_5`) | Full KV, recurrent state and optional typed MTP | Native contiguous or segmented paged | Supported floating/affine embedding typing, full owners and verified complete codec/storage identity |
| Qwen 3.5/3.6 MoE (`qwen3_5_moe`) | Same recurrent complete codec | Native contiguous or segmented paged | Same gate as dense Qwen |
| Selected Nemotron 3.5 Lightning (`nemotron_h`) | Native attention KV, Mamba convolution/FP32 SSM state, and optional shifted trusted MTP history | Native contiguous or segmented paged target | Exact Lightning model ID, loaded native types, complete checkpoint identity and typed Nemotron assistant codec when MTP is active |
| Qwen3-VL MoE (`qwen3_vl_moe`) | Unsupported | No paged capability | No complete store (`unsupported_layout`) |
| MiMo V2.6 (`mimo_v2`) | Asymmetric full/window target KV and optional trained-head checkpoint state | Native contiguous, text-only profile | Explicit MiMo COMPLETE-prefix opt-in, enabled model cache policy, exact loaded/store/process binding and observed native geometry; media profiles decline this checkpoint path |

MiMo's dedicated factory uses `EngineV2SlotFactory+MiMoPrefix.swift`, rather
than treating its generic prefix capability as supported. The complete storage
identity binds separate key/value widths and the actual active assistant codec
(`CompleteCheckpointStorageIdentity.swift`). `SSDHybridCheckpointStoreFactory`
threads native IO/work ownership through capture, import and publication;
returned host IO is not proof of native retirement. Full selected-artifact
reuse, encrypted restart, paging composition and media-prefix qualification
remain open; see the [MiMo qualification scope](https://github.com/Layr-Labs/mlx-swift-lm/blob/3fd4944c3b3ee5cb45c5cbfac8805876332d3a29/docs/mimo-v26/qualification.md).

SSD activation and backend selection have separate exact-model defaults; see
the [backend and cache cohorts](../architecture/prefix-cache.md#kv-layouts).
Resident-memory retention defaults off. Runtime identity, disk/key and loaded
capability checks apply independently of family names. A paging fallback may
still use eligible complete recurrent or historical checkpoints on native
contiguous storage. Generic contiguous historical construction requires the
observed `completeCheckpointKVDTypes` input, not an inferred weight dtype.
Requested checkpoint compression can resolve to native without disabling the
eligible complete cache; the
[effective-profile rules](../architecture/kv-cache-quantization.md#native-execution-with-quantized-checkpoints)
cover persistent assistants and unsupported layouts.

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
`provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+ModelAdapter.swift` (`ProductionModelAdapter`). Resolved paged execution requires the model's
paged capability. Selection, kill-switch effects and refusal or fallback depend
on live precision; see the
[backend and precision controls](../provider/cli-reference.md#providertoml-keys-read-by-the-cli).
When native recurrent targets use segmented paging, their per-layer native type
table is measured from the loaded target. Complete restoration supports both
native target storage layouts. For native live precision, model-scoped automatic
selection is defined by `EngineV2KVBackendPolicy.preferredBackend`; it does not
replace the loaded capability or checkpoint-identity gates.

## Status and outcome vocabularies

Closed enums in `provider-swift/Sources/ProviderCore/Protocol/Messages.swift`;
the coordinator's consumption is in
[../architecture/cache-aware-routing.md](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/cache-aware-routing.md).

| Enum | Values |
|---|---|
| `PrefixCacheStatusReason` | `ready`, `config_disabled`, `weight_hash_unavailable`, `runtime_identity_unavailable`, `unsupported_layout`, `unsupported_backend`, `paged_hybrid_unsupported`, `scan_pending`, `scan_failed`, `disk_unavailable`, `cache_init_failed` |
| `PrefixCacheDonationOutcome` | `donated`, `below_effective_token_floor`, `no_complete_block`, `lossy_snapshot`, `incomplete_layer_state`, `stage_size_exceeded`, `write_rate_limited`, `write_priority_limited`, `write_queue_full`, `already_durable`, `already_queued`, `cache_closed`, `disk_unavailable`, `write_failed`, `host_memory_unavailable`, `cache_epoch_changed`, `cache_maintenance_busy`, `disk_space_insufficient`, `unsafe_cache_root`, `write_io_failed`, `existing_cache_unreadable`, `cache_entry_evicted`, `skipped_novel` |

Store construction refusals use the closed enum
`SSDPrefixCacheConstructionFailure` (`SSDPrefixCacheFactory.swift`): `missing_weight_hash`,
`unsupported_plan`, `unsafe_path`, `key_unavailable`, `ephemeral_key_unavailable`,
`block_contract_mismatch`, `epoch_unavailable`, `prompt_contract_unavailable`,
`identity_unavailable`, `layout_unavailable`, `write_budget_unavailable`, plus
`cache_closed` for a built store closed with its slot. Both factories log them;
the attention-block factory also sends them as `prefix_construction_failure`
engine-health telemetry. Every store maps a refusal to the heartbeat status the
same way (`PrefixCacheConstructionStatus(refusal:)`,
`provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCacheEligibilityStatus.swift`):

| Refusal | `state` / `reason` |
|---|---|
| `unsafe_path` | `error` / `disk_unavailable` |
| `layout_unavailable`, `unsupported_plan` | `disabled` / `unsupported_layout` (or `paged_hybrid_unsupported`) |
| `missing_weight_hash` | `disabled` / `weight_hash_unavailable` |
| Every other refusal, and `cache_closed` | `error` / `cache_init_failed` |

An `error` status carries its cause as the optional heartbeat `detail`, which
local `/metrics`, `darkbloom status` and `darkbloom doctor` show too. An
attention-block store whose epoch was disowned at runtime reports
`epoch_unavailable`.

A refusal is never cached: each model load builds its store again, so a cause
that clears (a remounted volume, freed disk space, an unlocked keychain) heals
at the next load. Nothing retries during a load, and a built engine never
attaches a store later.

`PrefixCacheDonationOutcome` has 23 known buckets.
Outcomes are cumulative process-local counters carrying no identifiers; each
donation call settles exactly one outcome
(`provider-swift/Sources/ProviderCore/KVCacheSSD/PrefixCacheDonationTelemetry.swift`).

`disk_space_insufficient` includes both failed free-space preflight and typed
`ENOSPC` errors during atomic file creation/rename. When maintenance removes
the donated endpoint before its receipt is published, the donation reports
`cache_entry_evicted`; the epoch is unchanged and no ready endpoint is
published (`SSDHybridCheckpointStore.performWrite`, `SSDNoFollowIO.posixError`).
`cache_epoch_changed` now occurs only across a whole-root rebuild, and
`cache_maintenance_busy` is reported only by providers older than the per-file
eviction change; both values stay in the vocabulary for them.

## Verification

`darkbloom cache status` checks saved storage settings and volume suitability;
it does not certify hardware firmware or prove a runtime cache hit. Runtime
observations remain available through these surfaces.

| Surface | What to look for | Code |
|---|---|---|
| Unified log subsystem `com.darkbloom.provider` (dev: `com.darkbloom.provider.dev`), category `prefix_cache` | Info-level `prefix cache stats (engine=v2, tier=ssd, model=…)` line every `DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS` with cache kind, index/disk/staging counts and cumulative writes/drops; complete stores add I/O totals. `darkbloom logs` reads only the service subsystem `dev.darkbloom.provider` and does not show it; use `log show --info --last 1h --predicate 'subsystem == "com.darkbloom.provider" AND category == "prefix_cache"'` | `provider-swift/Sources/ProviderCore/KVCacheSSD/EngineV2Bridge+SSDPrefixCache.swift` (`startSSDPrefixCacheStatsLogger`), `provider-swift/Sources/ProviderBuildEnvironment/Identity.generated.swift` (`logSubsystem`, `serviceLogSubsystem`) |
| Same subsystem, category `ssd_prefix_cache` | One public warning per refused complete store: `complete prefix cache disabled for <model>: <failure> (<cause>)`, for example `key_unavailable` with the Secure Enclave/Keychain `OSStatus`. The cause is an error description, never key bytes or file contents. Attention-block stores log `ssd prefix cache disabled for <model>: …` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDHybridCheckpointStoreFactory.swift` (`build`), `SSDPrefixCacheFactory.swift` (`make`) |
| `darkbloom status`, `darkbloom doctor` | `prefix_cache=ready`, `starting`, `off (<reason>)` or `FAILED (<reason>: <detail>)` on each slot line, with the cause and `→ fix:` under a failed one; `doctor` (and the desktop app's diagnostics) adds a `prefix cache` check. A load whose store failed also logs a fixed line for `darkbloom logs` and the model, cause and fix to `provider.log` | `provider-swift/Sources/ProviderCore/Diagnostics/PrefixCacheDiagnosis.swift`, `provider-swift/Sources/darkbloom/Diagnostics/KVBackendPosture.swift`, `provider-swift/Sources/ProviderCore/ProviderLoop+EngineV2.swift` (`reportPrefixCacheFailure`) |
| Local `/metrics` | `prefix_cache_status{model,state,reason}` mirrors the heartbeat status; an `error` status adds `detail="<construction failure>"`. `complete_prefix_key_persistent` is `1` only when the complete store's key is persistent | `provider-swift/Sources/ProviderCore/Server/LocalServingPosture.swift` (`LocalServingPostureRenderer`) |
| Typed heartbeat | Optional `slots[].prefix_cache` observation with advancing age; cumulative units, freshness and bounded metrics are in [telemetry](../architecture/telemetry.md#durable-prefix-cache-observations) | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheTelemetry.swift` (`SSDPrefixCacheTelemetryBox`) |
| Heartbeat → coordinator `GET /v1/cache/status` | `prefix_cache_statuses` per loaded model (`state`, `reason`, `backend`, `replay_strategy`, and `detail` behind an error) and aggregated donation outcomes | `Messages.swift` (`prefixCacheStatuses`), [coordinator/api/inference/exact_cache_status.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/api/inference/exact_cache_status.go) (`HandleExactCacheStatus`) |
| `darkbloom benchmark --parity` | Loads the model on both KV backends and reports the prefix-reuse probe as PASS/FAIL/UNAVAILABLE | `provider-swift/Sources/darkbloom/BenchmarkCommand+Parity.swift` |

## Related

- [`../provider/cache-storage.md`](../provider/cache-storage.md) — set daily writes and select a disk

- [`../architecture/prefix-cache.md`](../architecture/prefix-cache.md) — layouts, reuse plan, construction gate
- [../architecture/cache-aware-routing.md](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/cache-aware-routing.md) — coordinator side
- [`../architecture/security/encryption.md`](../architecture/security/encryption.md) — key hierarchy
- [`../design/ssd-kv-cache.md`](../design/ssd-kv-cache.md), [`../design/ssd-kv-cache-v1-design.md`](../design/ssd-kv-cache-v1-design.md) — superseded design records
- Tests: `provider-swift/Tests/ProviderCoreTests/KVCacheSSD/SSDPrefixCacheTests.swift`
