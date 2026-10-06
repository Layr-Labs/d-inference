# SSD KV cache reference

> Last updated: 2026-10-06

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
| Retired root | `darkbloom/kv/` (the pre-v0.7.5 tier) is never read or written; `kv3/` is a sibling, not a subtree | `SSDPrefixCacheFactory.swift` (`ssdRootDirectoryName`) |

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
| KEK | Secure-Enclave-rooted and Keychain-persisted; `DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL` permits fallback to an in-memory KEK whose ciphertext cannot be reused after process exit | `SSDCacheKeyMaterial.swift` (`load`), `SSDPrefixCacheFactory.swift` (`ephemeralAllowed`) |
| Lookup key | `K_lookup = HKDF-SHA256-Expand(PRK: KEK, info: "dbkv3-lookup-v1", L = 32)` | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDLookupKeys.swift` |
| File-name tag | `HMAC-SHA256(K_lookup, "dbkv3-name-v1" ‖ u64le(len(salt)) ‖ salt ‖ chainHash)`, truncated to `truncatedTagLength = 16` bytes; full tag authenticated in metadata | `SSDLookupKeys.swift` |
| Window sidecar tags | `"dbkv3-window-v1"`, `"dbkv3-window-base-v1"` domains (format only; `DARKBLOOM_PREFIX_CACHE_SSD_WINDOW_SIDECAR` off; no restore consumer) | `SSDLookupKeys.swift`, `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWindowSidecar.swift` |
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
| Import admission | Authenticate manifest → allocation-free import plan → native per-buffer destination, scratch and metadata admission → bounded whole-file read. Shared native ownership is separate from provider host IO | `SSDHybridCheckpointStore+ReadAttempt.swift` (`readCheckpoint`), `CompleteCheckpointImportPlan.swift` (`allocate`) |
| Idle state | Metadata index only; no resident tensor bank or persistent slot carve | `SSDHybridCheckpointStore.swift`, `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy.swift` (`isMemoryEnabled`) |
| Imported lifetime | Single-use staged state retains native owners through aliases. Paged adoption replaces temporary staging with the full request promise and actual backing; recurrent/MTP auxiliary state has its own charge | `CompleteCheckpointTransfer.swift` |
| Host IO lifetime | Read/decrypt aliases retire before the read charge returns; writers claim host buffers before encoding and release them after the complete write stack drains | `SSDHybridCheckpointStore+ReadAttempt.swift` (`readCheckpoint`), `SSDHybridCheckpointStore+Write.swift` (`write`) |
| Durable ready | Only supplied actual input checkpoint after committed write and engine donor/export retirement; requires request mode echo | `SSDHybridCheckpointStore+Write.swift`, `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCacheEvidenceSequencer.swift` |
| Disk compatibility | Verified model/template, binary, loaded metallib, OS and numerical/MTP settings, plus actual native dtype and storage geometry | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+CheckpointIdentity.swift`, `CompleteCheckpointStorageIdentity.swift` |
| Numerical environment identity | Process and slot values whose keys start with `MLX_`, `DARKBLOOM_CBV2_`, `DARKBLOOM_QWEN_`, `DARKBLOOM_MTP_`, `DARKBLOOM_GPTOSS_` or `DARKBLOOM_GEMMA4_`; native `mimo_v2` additionally binds its `DARKBLOOM_MIMO_` controls. Changing an included optimization or rollback setting selects a different disk namespace | `provider-swift/Sources/ProviderCore/Inference/PrefixCache/PrefixCachePolicy+CheckpointIdentity.swift` (`completeCheckpointIdentity`) |

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

### Bounded shorter complete-checkpoint fallback

These rules apply to complete AR and native-block imports, not attention-block
suffix compaction. They do not raise capture/read caps or infer a shorter
checkpoint from a longer file.

| Contract | Bound / behavior | Code |
|---|---|---|
| Retry authority | At most one strictly shorter indexed endpoint after an authenticated import plan's typed `CBv2KVError.capacityExhausted`, a typed native pre-allocation reservation refusal, or the provider's pre-allocation destination-peak refusal | `SSDHybridCheckpointStore+Read.swift` (`stageTransfer`), `SSDHybridCheckpointStore+ReadAttempt.swift` (`readCheckpoint`) |
| No retry | Initial scratch/host authority refusal, arithmetic overflow, unknown/generic allocation or post-materialization failure, policy, corruption, cancellation, close, epoch drift or same-ID replacement | `SSDHybridCheckpointStore+ReadAttempt.swift` (`ReadControl`, `readAttempt`), `SSDHybridCheckpointStore+Read.swift` (`readIsCurrent`) |
| First attempt | Existing candidate size/estimated-time and per-file plaintext limits remain unchanged; the new meter only records first-attempt reads and elapsed time | `SSDCheckpointReadBudget.swift` (`beforeRead`, `checkTime`) |
| Retry raw-byte ceiling | The original `maxReadBytes`, less the already-spent first manifest probe; the retry's own manifest probe and whole-file read share that remainder. Every header/framing span is charged before allocation/read, plus a conservative one-byte EOF allowance. Partial OS reads do not grant another allowance | `SSDCheckpointReadBudget.swift` (`beginRetry`, `beforeRead`), `SSDBlockStore.swift` (`readExactly`), `SSDBlockStore+Streaming.swift` (`readStreaming`) |
| Retry time checks | The original start plus `maxStageMillis`, including first-attempt work, file waits and refunds. Remaining time must also admit the candidate's existing estimated cost. Checks are cooperative, including awaited file-access/refund/native work: they do not impose a timer on those waits, preempt an OS/native operation, or guarantee return/cancellation at `maxStageMillis`. The original request cancellation remains authoritative; elapsed time is rechecked before further retry work and publication | `SSDCheckpointReadBudget.swift` (`beginRetry`, `checkTime`), `SSDHybridCheckpointStore+ReadAttempt.swift` (`readAttempt`) |
| Retirement and identity | Failed import/plan aliases unwind, scratch/native owners retire and the original host refund completes before another reservation. One continuous logical registration atomically changes file access; lifecycle invalidation cannot resurrect it or erase its replacement | `SSDHybridCheckpointStore+Read.swift` (`stageTransfer`), `SSDCheckpointStageReservation.swift` (`waitForRefund`) |

Typed retry provenance is pinned to the SDK's admission-before-materialization
paths in `CompleteCheckpointImportPlan.swift` (`allocate`) and
`NativeBlockCheckpointImport.swift` (`allocate`), together with the current
concrete provider owners and evaluators. It is not a guarantee for arbitrary
injected callbacks. A future allocator or callback that can throw the same typed
error after materialization must re-establish that boundary;
generic MLX errors are not substitutes for this evidence. The successful shorter
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
| Disk budget | Default `max(1, volumeFree / 2)`, with no fixed ceiling, re-evaluated during enforcement across all models. Unknown free space uses `fallbackSSDDiskBudgetBytes = 20 * 1_073_741_824` (20 GiB); a valid positive environment override wins verbatim. The separate low-disk write stop still applies. | `PrefixCachePolicy.swift` (`ssdDiskBudgetBytes`) |
| Eviction order | LRU by last hit across the whole `kv3/` root; eviction is `unlink` + index removal | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDBlockIndex.swift` |
| Maintenance sweep | `SSDWholeRootMaintainer`, `intervalSeconds = 60`: TTL expiry, budget eviction, crash-temp cleanup. The temp file and the published, not yet indexed file of an in-flight speculative write are not counted toward the budget eviction, are not its victims and are taken out of a half-of-free limit; the pass also publishes the bytes no registered index counts, and after a walk that could not list a directory it may raise that figure and not lower it ([speculative disk admission](#size-and-eviction-rules), below) | `SSDPrefixCacheFactory.swift` (`startWholeRootMaintenance`), `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWholeRootMaintainer.swift` |
| TTL | `defaultTTLSeconds = 1800`, `maxTTLSeconds = 1800`, sliding on hit. Raising either needs the sign-off recorded in `docs/threat-model.yaml` (T-041, SEC-035) | `SSDPrefixCachePolicy.swift` |
| Daily write cap | `defaultMaxWriteBytesPerDay = 750 * 1_000_000_000` | `SSDPrefixCachePolicy.swift` |
| Complete-checkpoint repeat reserve | Demand gate first: each offered checkpoint gets a write class or none (`SSDCheckpointDemand.writeClass`, `SSDHybridCheckpointStore.offeredWriteClass`), tested in this order. `repeated`: the local `SSDCheckpointDemand` history has seen the tag within the cache TTL. `novel`: no hint (older coordinator, standalone/local serving, or a hint evicted from the 1,024-entry `SSDCheckpointDemandHints` map), where the legacy write-every-checkpoint behavior stays; or the coordinator's `cache_repeated_prefix_tokens >= minEffectiveTokens`; or `cache_first_sight_tokens >= minEffectiveTokens` on a request that restored a checkpoint from this store. `speculative`: `cache_first_sight_tokens >= minEffectiveTokens` with the repeat count below the floor and nothing restored from this store. A not-yet-durable checkpoint with no class settles `skipped_novel` with no bytes written and no write budget charged. Admitted novel checkpoint tags use a 90% burst/refill sub-budget; tags observed again within the cache TTL can use the full shared budget. Both debit the original total cap; unlimited mode stays unlimited. The 4,096-entry volatile tag history is an admission input as well as a priority signal. Novel-share exhaustion reports `write_priority_limited`; total-budget exhaustion remains `write_rate_limited`. A speculative write is admitted only while it leaves both buckets within the headroom H of full, only while no other checkpoint write is registered on the store (its `writing` set is empty), and only while its complete stored file fits the free disk budget and no file is already at its path (the speculative disk admission rows below); a write refused on any of these settles `write_speculative_limited` before a byte is written and charges nothing. H is `min(novel share, cap x TTL / 86,400)`, what the total bucket refills in one cache lifetime: 2.08% of the daily cap at the 30-minute TTL. The novel share refills at 90% of that rate and needs `TTL / 0.9` (2,000 s at the default TTL) to refill H. An admitted speculative write can still settle `write_speculative_limited` after its I/O began and its write budget was charged, when the disk room it was granted is needed by a proven write, including one queued in any store on the budget, or is gone (giving way, below). `write_priority_limited`, `write_rate_limited` and `write_queue_full` are never emitted for a speculative offer. Durable duplicates authenticate and bypass both the gate and write consumption, except that a duplicate classed speculative still needs the empty `writing` set: with another write registered it settles `write_speculative_limited`, not `already_durable`, and returns no position for a ready receipt. What H does and does not bound, and the write-queue limits, are in [first sight](../architecture/cache-aware-routing.md#first-sight) (limits 6 and 7). | `SSDCheckpointDemand.swift`, `SSDHybridCheckpointStore+DemandAdmission.swift`, `SSDHybridCheckpointStore+Write.swift`, `SSDWriteRateLimiter.swift` |
| Speculative (first-sight) disk admission: size and ledger | **Size.** A speculative write is held to its complete stored file, not its plaintext: `SSDBlockStore.streamedFileBytes` returns the exact length of the file `writeStreaming` publishes (`streamedFixedBytes`, 92 bytes; the canonical metadata JSON; each chunk's plaintext plus `streamedChunkFramingBytes`, 20 bytes). The daily write cap is still charged in plaintext bytes and the low-disk write stop still tests plaintext bytes. **Ledger.** `SSDDiskBudget` keeps a process-wide ledger. Every fresh write on the budget holds one `SSDDiskReservation` for its complete stored size from before its first byte until its file is indexed or gone: a complete-checkpoint write of any class (`performWrite`), and each block of a block-tier donation. A donation is recorded whole: when its job starts, before it leaves the queue's bound, one record takes the exact stored bytes of all its blocks (`registerProven`). Each block is moved out of that record into one of its own, in one step, after that block's write-cap charge and file lease (`claimBlock`); a block that is skipped is dropped from it (`dropBlock`); a written block's record is released in one step with its index insert (`commitProven`); what is left is released when the job ends (`SSDWriteBehind.consume`). Per whole cache root the ledger also keeps *unowned* bytes, those on disk that no registered store's index counts (files of unloaded or closed models, temp files of no in-flight write, files published and never indexed), as the last whole-root pass published them plus what a deregistering store added | `SSDBlockStore+Streaming.swift` (`streamedFileBytes`), `SSDBlockIndex.swift` (`SSDDiskBudget`, `SSDDiskReservation`, `registerProven`, `claimBlock`, `dropBlock`, `commitProven`, `publishWholeRoot`, `deregister`), `SSDHybridCheckpointStore+Write.swift` (`performWrite`), `SSDWriteBehind.swift` (`consume`) |
| Speculative disk admission: grant | On the writer, after the low-disk check and before the write-cap charge and before a byte is written, a speculative write is first declined if a regular file is already at its path (`indexedBlockFileStatus`). That is a file its store's index does not have, left by a write that was never indexed or indexed by another instance on the same model root; the write would have to replace it and, on losing its room, delete it. A proven write still replaces such a file. The write then asks for a reservation (`reserveSpeculative`), granted only if `indexed + unowned + reserved + queued + own <= budget`: *indexed* is the bytes in the index of every registered store, box-wide; *unowned* is the figure of the write's own whole root; *reserved* is every other reservation, of any class; *queued* is, summed over every registered store, an estimate, meant as an upper bound, of the stored bytes of the proven work that store has accepted and not yet recorded on the ledger (`SSDEvictableStore.queuedWriteBytes`); *budget* is the disk budget as it will be once the reserved and queued bytes and the write's own are on the volume (`SSDDiskBudgetBasis.bytes(afterWriting:)`). A complete-checkpoint store counts each fresh proven write it has accepted at its plaintext plus 1 MiB, until that write records its exact bytes (`provenWriteBytes`); a re-offer of a checkpoint that is already indexed writes nothing and is not counted. A block-tier cache counts each queued donation at its bytes plus 1 MiB per block, until the donation's job records its exact bytes (`queuedStoredBytes`). The code does not check that the header, metadata and chunk framing stay within that 1 MiB; a job whose overhead is larger is under-counted until it records its exact size. The default half-of-free budget falls by half of those bytes (reserved bytes that are already on the volume are subtracted again, which errs toward declining), and a `DARKBLOOM_PREFIX_CACHE_DISK_GB` override or the 20 GiB fallback does not move. A write refused room, or refused by the write budget once it holds room, releases what it held; each of these settles `write_speculative_limited` with nothing written and nothing charged. The offer-time check (`hasDiskRoomForSpeculativeWrite`) is the same sum without a reservation; it is advisory and runs after the offer-time write-budget check | `SSDHybridCheckpointStore+Write.swift` (`prepareWriteJob`, `performWrite`), `SSDHybridCheckpointStore+DemandAdmission.swift` (`hasDiskRoomForSpeculativeWrite`, `diskBudgetBasis`), `SSDBlockIndex.swift` (`reserveSpeculative`, `hasSpeculativeRoom`, `SSDDiskBudgetBasis`, `SSDEvictableStore.queuedWriteBytes`), `SSDHybridCheckpointStore.swift` (`provenWriteBytes`), `SSDWriteBehind.swift` (`queuedStoredBytes`), `SSDBlockPathGuard.swift` (`indexedBlockFileStatus`), `PrefixCachePolicy.swift` (`ssdDiskBudgetBasis`) |
| Speculative disk admission: proven writes | A `repeated` or `novel` checkpoint write is never refused room by the ledger and never waits for room, and neither is a block of a block-tier donation; the low-disk write stop, unchanged, still refuses any fresh write. A checkpoint write records its stored bytes after its write-cap charge (`registerProven`). A block-tier donation's record for all its blocks, made when its job starts, revokes nothing; each block is tested when it takes its own record after its write-cap charge (`claimBlock`). If a speculative write is in flight and the sum, against the budget projected as above, no longer fits, every in-flight speculative reservation is revoked. A speculative write granted between the proven write's look for one in flight and its registration is not revoked then; the record counts against it from then on, and it gives way at its publish or index check if the room no longer holds both. The block tier is given the same basis as the checkpoint stores (`diskBudgetBasis`), so under the default budget it revokes when a checkpoint write of the same size would. For this registration the volume is asked for its free bytes only while a speculative write is in flight (`hasSpeculativeReservations`); the low-disk check before the write reads the volume as before; the pass after the write now reads it inside the pass, and the enforcement after a checkpoint write reads it once, or again (up to three readings) when a speculative write was withdrawn since the reading. A proven file's index insert and the release of its record are one step under the budget lock (`commitProven`); if its store, a complete-checkpoint store or a block-tier cache, deregistered meanwhile, the file's bytes are counted as unowned. **What changed for them.** Their outcomes, order of side effects and charges are as before. These things differ. The enforcement that follows a proven write or a block-tier job no longer evicts on account of another store's in-flight speculative bytes: for the same reading of the volume it evicts the same entries or fewer, never more. The reading itself is now taken inside the pass, and the enforcement after a checkpoint write can repeat its reading up to three times and then evict nothing in that call. A proven write now takes the budget lock before its first byte (`hasSpeculativeReservations`, `registerProven`) and again at its index step, where its file is published and not yet indexed while it waits (`commitProven`); a block-tier job takes it when it starts, for each block and when it ends. An eviction loop, a whole-root retirement or a reconcile in another store can hold that lock. A proven write also computes its stored size, which encodes its metadata once more. `SSDWholeRootMaintainer.Result.filesSeen` and `bytesAfter` leave out in-flight speculative files | `SSDBlockIndex.swift` (`registerProven`, `claimBlock`, `commitProven`, `hasSpeculativeReservations`), `SSDHybridCheckpointStore+Write.swift` (`performWrite`), `SSDWriteBehind.swift` (`consume`, `setOwner`, `Config.diskBudgetBasis`), `SSDPrefixCacheFactory.swift`, `SSDWholeRootMaintainer.swift` (`Result`) |
| Speculative disk admission: giving way | A speculative write gives way instead of causing an eviction, at three points. (a) Revoked: it stops at its next chunk callback (`SSDDiskReservation.isRevoked`; a chunk is at most `CBv2CompleteCheckpointManifest.maximumSegmentBytes`, 4 MiB) and its temp file is removed. (b) Before publish, with the file finished and still a temp file (`checkSpeculativePublish`, `mayPublishSpeculative`): if it is revoked or the sum no longer fits, the temp file is removed and nothing is published. (c) At commit (`commitSpeculative`): the published file is indexed, in one step with the release of its reservation under the budget lock, only if the write is not revoked, the sum still fits and its store is still open on the same epoch; otherwise the write removes its own published file (`abandonPublishedFile`). In (b) and (c) the sum is the grant's, with the write's own bytes taken as already on the volume, so it also counts *queued*: the proven work every registered store has accepted and not yet recorded, which holds no reservation yet, whether a proven checkpoint write registered behind it in its own store or queued in another, or a queued block-tier donation. A queued re-offer of a checkpoint that is already indexed is not counted. (a) to (c) settle `write_speculative_limited` and add one to the store stat `speculativeWritesYielded`. I/O happened and the write cap charged before the first byte is not refunded; the bytes written are removed. If the unlink of a published file fails, the file stays on disk unindexed and its bytes are counted as unowned; the outcome and the stat are the same. Exceptions that keep their existing outcome and do not count in the stat: a store that is closed or has changed epoch at that point settles `cache_closed` or `cache_epoch_changed`, and a published file already gone at the index step settles `cache_entry_evicted`. A speculative file published as its store closes or changes epoch is removed, where a proven one stays on disk and is counted as unowned. `speculativeWritesYielded` is process-local (`SSDHybridCheckpointStore.stats()`); the heartbeat does not carry it (`PrefixCacheTelemetry.init(complete:)`). A write that gave way adds to `writesDropped` and nothing to `bytesWritten`, so `written_bytes_total` does not show the write cap it spent | `SSDHybridCheckpointStore+Write.swift` (`performWrite`, `checkSpeculativePublish`, `abandonPublishedFile`), `SSDBlockIndex.swift` (`mayPublishSpeculative`, `commitSpeculative`, `SSDDiskReservation`), `SSDNoFollowIO.swift` (`writeAtomically`, `beforePublish`), `SSDHybridCheckpointStore+Maintenance.swift` (`queuedWriteBytes`), `SSDHybridCheckpointStats.swift`, `SSDPrefixCacheTelemetry.swift` |
| Speculative disk admission: enforcement | Within the limits of the next row, no enforcement evicts on account of an in-flight speculative write. The whole-root pass keeps the temp file and the published, not yet indexed file of an in-flight speculative write out of its total and never picks them as TTL or budget victims (the one-hour crash-temp cleanup still applies to a temp file); if the rest of what it counts plus those bytes exceeds its limit, it revokes every in-flight speculative write (`revokeSpeculativeWrites`). Under the default half-of-free budget those bytes have also lowered the limit for as long as they are on the volume, so both enforcers take the limit without them (`SSDDiskBudgetBasis.bytes(afterRemoving:)`). The pass resolves its budget inside the pass, once it holds the maintenance lock and has opened the window that records every reservation outstanding while it walks the tree, so a speculative write whose bytes are in that reading of the volume is known to the pass even if it is gone before the walk reaches its directory. The pass adds back the larger of two figures: the speculative bytes the walk found, and the bytes that the speculative writes outstanding in the window reported as landed (`noteLanded`, reported before each chunk and an upper bound from the first chunk on), leaving out the writes indexed in the window. `SSDDiskBudget.enforce(basis:)`, which a checkpoint write calls after its pass, adds back the bytes in-flight speculative writes report as landed. It reads the volume outside the budget lock; if a speculative write ended without an entry between that reading and the lock, the reading still has that write's bytes on the volume and nothing adds them back, so the volume is read again, and after three such readings the call evicts nothing and the next pass enforces. Under an override or the fallback the limit does not move and only the total changes. `maintain` is handed the closure that resolves its budget by the `maintainWholeRoot` closure of both factories (`SSDPrefixCacheFactory.maintainWholeRoot`) and by the 60-second task. **Unchanged.** Eviction order; the disk budget's configured value and formula (only the limit the two enforcers evict to differs while a speculative write is in flight, as above), the daily write cap, H, the TTL and the low-disk floor; the outcome vocabulary and the wire protocol; first sight on by default | `SSDWholeRootMaintainer.swift` (`maintain`), `SSDBlockIndex.swift` (`SSDDiskBudget.enforce`, `revokeSpeculativeWrites`, `SSDDiskBudgetBasis`, `SSDDiskReservation.noteLanded`), `SSDHybridCheckpointStoreFactory.swift`, `SSDPrefixCacheFactory.swift` (`maintainWholeRoot`, `startWholeRootMaintenance`); tests of these rows: `provider-swift/Tests/ProviderCoreTests/KVCacheSSD/SSDSpeculativeDiskAdmissionTests.swift`, `provider-swift/Tests/ProviderCoreTests/KVCacheSSD/SSDDiskBudgetReservationTests.swift`, block-tier cases in `provider-swift/Tests/ProviderCoreTests/KVCacheSSD/SSDPrefixCacheTests.swift`, the basis wiring in `provider-swift/Tests/ProviderCoreTests/KVCacheSSD/SSDPrefixCacheFactoryTests.swift` |
| Speculative disk admission: limits | 1. Once committed, a first-sight file is an ordinary entry: the index does not record the write class, and a proven write that arrives later and needs room evicts the least recently used entry whatever its class (`SSDDiskBudget.enforce`), which can be an older proven checkpoint while the newer first-sight file stays. Only proven work already accepted, in any store on the budget, when the first-sight write reaches publish or commit is counted (giving way, above). 2. While speculative writes are being told to stop, the root can be over the disk budget it would have without their bytes by at most the sum of those bytes on disk. Against a half-of-free budget read while they are on the volume, which is lower by half of them, that is up to one and a half times their bytes. The bytes are at most one file per loaded complete-checkpoint store, since one speculative write runs per store, each at most the stage cap of plaintext (`defaultMaxStageBytes`, 1 GiB by default) plus its header, metadata and chunk framing. It lasts until each writer reaches its next chunk callback or its publish check: the chunk in hand is finished first (one segment read of at most 4 MiB, sealed and written) and, with strict fsync on, the file is synced first; then the unlink. None of these has a time bound. 3. A speculative write that gives way after I/O began was charged to the daily write cap; there is no refund. 4. The ledger is in-process. It does not see another process writing under the same cache root, a temp file whose unlink failed, or a crash leftover (counted as unowned from the next pass until its one-hour temp TTL, `crashTempTTLSeconds`). 5. A budget is a reading of the volume, taken before the work that uses it. A fall in free disk caused by other disk users after a speculative write's commit check and before the enforcement that follows the commit can still evict an older entry while the new first-sight file stays. That span is the wait for the maintenance lock plus a whole-root pass, which walks the cache tree and reads a header per file; it is not microseconds and its length is not measured. The discount of a speculative write's bytes (enforcement, above) can also be larger than what the reading held. A write's landed bytes are not cleared when its temp or published file is unlinked; they stay in the discount until its reservation is released, and the pass also discounts a speculative write that started after its reading. A reading taken without those bytes on the volume then gives a limit too high by half of them, so entries can stay over the budget by that much until the next pass; nothing is evicted on that account. An `enforce` call whose three readings were each overtaken by a withdrawal evicts nothing and leaves the root to the next pass. 6. *unowned* is as fresh as the last whole-root pass (after a checkpoint write that was indexed or was already durable, after a block-tier job, when a complete-checkpoint store is built, when the 60-second task first starts and every 60 seconds after) plus the deregister adjustment and the bytes of a file left on disk unindexed. A pass that walked while bytes changed sides between an index and *unowned* (a store registered or deregistered, a file was committed or left on disk unindexed), or that could not list the root, a model directory or a fan-out directory, may raise the figure and not lower it; the next whole, undisturbed pass sets it. The figure errs high after a store registers or a pass is disturbed, which declines a speculative write that would have fitted. It can also be too low: it is zero for a root no pass has published yet, it misses files that arrived since the last pass, and it never counts a block file whose header cannot be read or a file whose attributes cannot be read. A speculative write admitted against a figure that is too low can be followed by a pass that counts the missing bytes and evicts. 7. The half-of-free arithmetic assumes that the volume's free figure (`volumeFreeBytes`: `volumeAvailableCapacityForImportantUsage`, else `volumeAvailableCapacity`) falls by the bytes written as they are written, and rises again when they are removed. Measured once, on one machine, on its internal volume and one external volume, with a standalone probe that drops the URL's cached values before each reading, which the provider's reader does not do: at the first reading after a 512 MiB write in 4 MiB chunks, before any fsync, both figures were lower by the bytes written plus 16,384 bytes (internal) or 12,288 bytes (external), and deleting the file returned both to within 57,344 bytes of where they started. The figures were not read while the write was in progress. Not measured on any other machine or volume, and not through the provider's own reader. Where the figure lags a write, a first-sight write can be admitted or committed against a budget that is too high by up to half of the bytes not yet reflected, and a later pass can evict when the figure catches up | `SSDBlockIndex.swift` (`SSDDiskBudget.enforce`, `publishWholeRoot`, `deregister`, `SSDDiskBudgetBasis`), `SSDWholeRootMaintainer.swift` (`maintain`, `ownedContents`), `SSDHybridCheckpointStore+Write.swift` (`performWrite`), `SSDBlockStore.swift` (`crashTempTTLSeconds`), `SSDPrefixCachePolicy.swift` (`defaultMaxStageBytes`), `PrefixCachePolicy.swift` (`volumeFreeBytes`) |
| Complete-checkpoint maintenance | Per-file removals run under the store's `removalLock` (`performIndexedRemoval`): unlink plus index and accounting update, serialized with other removals, refused once the store is closed or no longer owns its epoch. Whole-root external deletion reconciles missing index entries before the barrier lifts. Targeted eviction and corrupt-file removal update only their known index entries, avoiding a full filesystem scan per victim. No per-file removal rotates the model epoch; the coordinator learns of a removed checkpoint through the next lookup miss, or a hit at a shorter boundary, on that provider. A reader that finds its file gone reports `miss_absent` without counting corruption. Whole-root maintenance brackets a removal only through a registered store that still owns its root (`ownsEvictionRoot`); if every registered store for the root is closed or disowned it uses the unloaded-root path, so TTL expiry and budget eviction never wait for a disowned store to close. | `SSDHybridCheckpointStore+Maintenance.swift`, `performExternalDestructiveChange`, `reconcileExternalRemovals` |
| Owned retirement coordination | Capacity/TTL and active-owner whole-root retirement acquire the store removal lock, validate the durable epoch/binding and try the shared per-file lease without waiting. A busy renamed-but-not-indexed file is skipped; its writer commits the index or, for a speculative write that lost its room or whose store closed or changed epoch, removes the file, before releasing that lease. Survivor identity and sequence are unchanged. | `SSDOwnedEntryRetirement.swift`, `SSDCacheEpochStore.performOwnedRetirement`, `SSDDiskBudget.retireActiveEntries` |
| Epoch record read failure | Owned retirement and whole-root rotation reread the persisted record first. An open or read that fails (the record was not read: EACCES, EIO, EBUSY and the like) proves nothing about the record: that operation is refused, nothing is written, the first such failure after a successful read is logged, and the store keeps its epoch; the next owned operation rereads and proceeds once the record matches. Sequence issue already refused without disowning on such a failure. A record that is read and is missing (it is replaced by rename, never unlinked), unparseable, oversized, replaced by a symlink, directory or other non-regular entry, or names another schema, epoch or binding disowns the store permanently, as before. | `SSDCacheEpochStore.swift` (`performOwnedRetirement`, `performOwnedDestructiveChange`) |
| Low-disk write stop | `lowDiskFloorBytes = lowDiskAbsoluteFloorBytes = 20 * 1_073_741_824` (20 GiB), independent of total disk capacity; reads continue; ENOSPC starts `enospcCooldownSeconds = 600` | `SSDPrefixCachePolicy.swift` |
| Payload/staging cap | `defaultMaxStageBytes = 1024 * 1_048_576`; `defaultMaxStageMillis = 1000` at `conservativeStageBytesPerSecond = 1_500_000_000` | `SSDPrefixCachePolicy.swift` |
| Attention donation floor | `prefixTokens > adoptionBoundTokens + minEffectiveTokens`, whole blocks only; `defaultMinEffectiveTokens = 1024`, raised to 1_536 for `.frozenFullReplay` with bound ≥ 25_600 | `SSDPrefixCache.swift` (`donate`), `PrefixCachePolicy.swift` |
| Write-behind queue | `writeQueueMaxJobs = 2`, `writeQueueMaxBytes = 512 * 1_048_576`, `writeQueueSlackBytes = 256 * 1_048_576`; overflow drops the donation | `SSDPrefixCachePolicy.swift`, `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDWriteBehind.swift` |
| Staging RAM | Reserved per staged entry in `GlobalKVCacheBudget`; the engine keeps its full slot grant | `provider-swift/Sources/ProviderCore/Inference/Memory/GlobalKVCacheBudget.swift` |

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
remain open; see the [MiMo qualification scope](../../libs/mlx-swift-lm/docs/mimo-v26/qualification.md).

SSD activation and backend selection have separate exact-model defaults; see
the [backend and cache cohorts](../architecture/prefix-cache.md#kv-layouts).
Resident-memory retention defaults off. Runtime identity, disk/key and loaded
capability checks apply independently of family names. A paging fallback may
still use eligible complete recurrent checkpoints on native contiguous storage;
GPT-OSS/Gemma historical complete checkpoints require segmented paging.

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
`provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Factory+ModelAdapter.swift` (`ProductionModelAdapter`). An explicit `paged` selection is refused when the
model lacks the required capability (reason `model_capability`); the kill switch
can separately degrade it to contiguous.
Eligible recurrent targets use segmented paging with a per-layer native type
table measured from the loaded target. Complete restoration supports both
native target storage layouts. Model-scoped automatic selection is defined by
`EngineV2KVBackendPolicy.preferredBackend`; it does not replace the loaded
capability or checkpoint-identity gates.

## Status and outcome vocabularies

Closed enums in `provider-swift/Sources/ProviderCore/Protocol/Messages.swift`;
the coordinator's consumption is in
[`../architecture/cache-aware-routing.md`](../architecture/cache-aware-routing.md).

| Enum | Values |
|---|---|
| `PrefixCacheStatusReason` | `ready`, `config_disabled`, `weight_hash_unavailable`, `runtime_identity_unavailable`, `unsupported_layout`, `unsupported_backend`, `paged_hybrid_unsupported`, `scan_pending`, `scan_failed`, `disk_unavailable`, `cache_init_failed` |
| `PrefixCacheDonationOutcome` | `donated`, `below_effective_token_floor`, `no_complete_block`, `lossy_snapshot`, `incomplete_layer_state`, `stage_size_exceeded`, `write_rate_limited`, `write_priority_limited`, `write_queue_full`, `already_durable`, `already_queued`, `cache_closed`, `disk_unavailable`, `write_failed`, `host_memory_unavailable`, `cache_epoch_changed`, `cache_maintenance_busy`, `disk_space_insufficient`, `unsafe_cache_root`, `write_io_failed`, `existing_cache_unreadable`, `cache_entry_evicted`, `skipped_novel`, `write_speculative_limited` |

`PrefixCacheDonationOutcome` has 24 known buckets.
Outcomes are cumulative process-local counters carrying no identifiers; each
donation call settles exactly one outcome
(`provider-swift/Sources/ProviderCore/KVCacheSSD/PrefixCacheDonationTelemetry.swift`).

`write_speculative_limited` has two meanings that the counter does not
separate. Nothing spent, with no byte written and no write budget charged:
at the offer, the write budget was below the headroom H, the complete stored
file did not fit the free disk budget, or another checkpoint write was
registered on the store; on the writer, before the charge, a regular file was
already at the write's path, the ledger refused the reservation, or the write
budget refused on the recheck. Write cap spent, charged before the first byte
and not refunded, with no entry kept: an admitted write gave way after its I/O
began, at its next chunk once revoked, before publish or at the index step,
because the disk room it was granted was needed by a proven write or was
gone. Only the second kind adds to the store stat `speculativeWritesYielded`,
which is process-local and not on the heartbeat
([speculative disk admission](#size-and-eviction-rules)). The vocabulary is
unchanged: 24 outcomes, no new wire field.

`disk_space_insufficient` includes both failed free-space preflight and typed
`ENOSPC` errors during atomic file creation/rename. When maintenance removes
the donated endpoint before its receipt is published, the donation reports
`cache_entry_evicted`; the epoch is unchanged and no ready endpoint is
published (`SSDHybridCheckpointStore.performWrite`, `SSDNoFollowIO.posixError`).
`cache_epoch_changed` now occurs only across a whole-root rebuild, and
`cache_maintenance_busy` is reported only by providers older than the per-file
eviction change; both values stay in the vocabulary for them.

## Verification

Three observable surfaces exist; there is no dedicated CLI verifier.

| Surface | What to look for | Code |
|---|---|---|
| `darkbloom logs` | `prefix cache stats (engine=v2, tier=ssd, model=…)` line every `DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS` with cache kind, index/disk/staging counts and cumulative writes/drops; complete stores add I/O totals | `provider-swift/Sources/ProviderCore/KVCacheSSD/EngineV2Bridge+SSDPrefixCache.swift` (`startSSDPrefixCacheStatsLogger`) |
| Typed heartbeat | Optional `slots[].prefix_cache` observation with advancing age; cumulative units, freshness and bounded metrics are in [telemetry](../architecture/telemetry.md#durable-prefix-cache-observations) | `provider-swift/Sources/ProviderCore/KVCacheSSD/SSDPrefixCacheTelemetry.swift` (`SSDPrefixCacheTelemetryBox`) |
| Heartbeat → coordinator `GET /v1/cache/status` | `prefix_cache_statuses` per loaded model (`state`, `reason`, `backend`, `replay_strategy`) and aggregated donation outcomes | `Messages.swift` (`prefixCacheStatuses`), `coordinator/api/inference/exact_cache_status.go` (`HandleExactCacheStatus`) |
| `darkbloom benchmark --parity` | Loads the model on both KV backends and reports the prefix-reuse probe as PASS/FAIL/UNAVAILABLE | `provider-swift/Sources/darkbloom/BenchmarkCommand+Parity.swift` |

## Related

- [`../architecture/prefix-cache.md`](../architecture/prefix-cache.md) — layouts, reuse plan, construction gate
- [`../architecture/cache-aware-routing.md`](../architecture/cache-aware-routing.md) — coordinator side
- [`../architecture/security/encryption.md`](../architecture/security/encryption.md) — key hierarchy
- [`../design/ssd-kv-cache.md`](../design/ssd-kv-cache.md), [`../design/ssd-kv-cache-v1-design.md`](../design/ssd-kv-cache-v1-design.md) — superseded design records
- Tests: `provider-swift/Tests/ProviderCoreTests/KVCacheSSD/SSDPrefixCacheTests.swift`
