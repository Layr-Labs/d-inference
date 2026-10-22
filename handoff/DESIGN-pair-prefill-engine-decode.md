# Design: pair prefill, then the product engine decodes (G1, G4)

> Last updated: 2026-10-09

Status: **plan only, nothing implemented and nothing run.** Written from a read
of the code on 2026-10-09. It answers one question: can two Macs make a single
request faster end to end than the faster Mac alone, by using both only for
prefill and handing the result to the product's serving engine for decode.
Short answer: yes through a seam that already exists, but for the 9B the gain
at the one measured pair configuration is a few percent at 8,192 tokens and a
loss at 4,096 and below; the case rests on an unmeasured better cut, or on the
27B. Every timing not marked measured is arithmetic. Decisions in section 8
are the owner's.

Paths: `$SRC` is the repository root (read at `332b4a1a7`); `$PHASE` is the phase-split branch (`work/phase-split`, read at `1ae3d9e94`). `$CB` = `$SRC/libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2`, `$RT` = `$SRC/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime`, `$PV` = `$SRC/provider-swift/Sources/ProviderCore`, `$WK` = `$SRC/libs/darkbloom-cluster-worker`. Nothing was run or changed; every timing not marked "measured" is my arithmetic.

**Recommendation.** Build variant (b), but through a seam that already exists: the engine's public complete-checkpoint import (`EngineV2.planCompleteCheckpointImport` → `CBv2CompleteCheckpointImportPlan.allocate` → `CBv2CompleteCheckpointImport.appendSegment` / `finish` → `CBv2CompletePrefixCache.takeStaged`). The pair prefills to M, the largest 256-multiple below the prompt length; the provider stages the exported state in memory, and the engine adopts it exactly as it adopts an SSD hit, then prefills the ≤256-token tail and decodes with paged KV and MTP. No new engine adoption API is needed. It cannot work without four things:
- **X1.** The HTTP provider must sit on the Mac holding the upper stage. Today the leader is always rank 0 (`ClusterConfiguration.localRank`), which in the measured cut-4 pair is the slower Mac.
- **X2.** The pair must emit the normalized final hidden row for every prompt token. With MTP configured, the engine refuses a checkpoint without assistant history, and no public forward returns hidden for an embedding-input stage.
- **X3.** The owner must accept that pair state is asserted under the engine's cache identity. By that identity's own fields (binary, OS, backend) it is not the same.
- **X4.** At cut 4 the state transfer must be streamed or zero-copy. A post-hoc checked copy costs about 38 µs per token, which equals the whole prefill gain.

The benefit is thinner than the motivating arithmetic. At the only measured operating point (cut 4), the 9B gains about 1–4% at 8k/128 and loses at 4k and below. It is worth building only if the unrun cut sweep confirms about 3,400+ tok/s, or for the 27B. Reject (d), defer (c), and use (a) only as a write-behind donation. Run slice 1 first.

## 1. State equivalence

Both runtimes hold the same mathematical objects, built by the same classes from the same pinned library (`libs/mlx-swift-lm` at `3fd4944c`). The cluster runtime's request state is `CBv2OwnedRequestState` (`$RT/State/CBv2OwnedRequestState.swift`), which wraps the product's `CBv2ContiguousKVBackend`, `CBv2LayerCacheBank` and `CBv2RecurrentRequestState`. Its geometry comes from the product model (`CBv2RequestGeometry`: `model.cbv2LayerKinds`, `cbv2RecurrentStateSpec`, `newCacheV2`). Both run `Qwen35TextModelInner.cbv2Forward` (`$SRC/libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift`).

| Component (9B: 32 layers, 8 attention, 24 linear) | Product engine after prefill of T tokens | Cluster runtime at the same point |
|---|---|---|
| Attention K and V, model layers 3, 7, …, 31 | `[1, 4, T, 256]` bfloat16, native precision; `PagedKVPool` pages of 16 tokens (`PagedKVPool.pageSize = 16`), K then V at `valueOffset` in segmented buffers | Same shape and dtype; contiguous `CBv2FullSequenceKV` rows; snapshot entries `kv.keys`, `kv.values` |
| Linear-attention state, 24 layers | conv `[1, 3, 8192]` bfloat16, ssm `[1, 32, 128, 128]` float32, in `CBv2RecurrentRequestState` | Same class, same spec; entries `conv`, `ssm` |
| Position | Row `absoluteOffset` = T; cache `positionOffsets` int32 `[1]` | Same; `kv.position_offsets` (derived, not sent) |
| Sampler | Nothing before the first token | Greedy argmax only (`QwenLayerStageGenerationSelection`) |
| MTP history (`Qwen35InlineMTPAssistant.RequestState`) | `backlogHidden` `[1, T−1, 4096]` bfloat16 (final-norm applied once), `backlogTokens` `[1, T−1]` int32, `targetHiddenFrontier` `[1, 1, 4096]`; head KV empty | **Absent.** Stages are loaded without `mtp.*` (`QwenLayerStageSession.init` refuses a model containing it) |

Sizes, checked against the journal's byte counts:
- Attention: 4,096 B per token per layer, so 32,768 B/token.
- Recurrent: 51.5 MB fixed.
- MTP hidden: 8,196 B/token.
- A complete 9B checkpoint is 67 tensors, 51.5 MB + 40,964 B/token, or 376.6 MB at M = 7,936.
- 27B (16 attention, 48 linear, hidden 5,120): 153.9 MB + 75,780 B/token, or 755 MB at 7,936.

The snapshot's row-major logical bytes (`CBv2OwnedStateSnapshot.capture`) are already the packed `[1, H, M, D]` format `appendSegment` consumes. The mapping is `kv.keys`→`.keys`, `kv.values`→`.values`, `conv`→`.convolution`, `ssm`→`.recurrent`, in the order of `CBv2CompleteCheckpointCodec.tensorDescriptors(position:)`.

Every mismatch:
1. **Container.** Contiguous versus paged; the import already writes packed bytes into pages (`CBv2PagedCheckpointStorage.append`).
2. **MTP history missing.** `CBv2CompleteCheckpointCodec.plan` requires `manifest.assistantCodecID == assistant?.prefixCheckpointCodecID`, and `EngineLoopV2.adoptRecurrentCheckpoint` throws "assistant checkpoint cannot be restored".
3. **Prefill attention path.** Contiguous uses the symbolic mask of `CBv2AttentionV1`; paged uses SDPA over gathered pages with a materialized mask (`$CB/Paged/PagedLayerCache.swift` header). Low-bit differences above the first attention layer are possible. Not found: any evidence the two backends give bit-identical K/V on dense Qwen; the product keeps them in separate namespaces (`CompleteCheckpointStorageIdentity`, `storage.backend`).
4. **Chunking.** 512-token chunks versus a 4,096 stripe. Not an issue on the dense 9B: `docs/reports/2026-09-27-qwen-chunk-partition-parity.md` found the state bit-identical under every partition.
5. **Precision and dtype.** No mismatch: both convert to bfloat16 (`DARKBLOOM_BF16_WEIGHTS=1`; `Load.swift`; profile `requiredBF16ConversionPolicy = true`), and both use query block 128.
6. **Chips.** Layers below the cut are computed on the other Mac; tokens equal, logits differ.
7. **Identity.** `PrefixCachePolicy.completeCheckpointIdentity` binds provider binary hash, loaded metallib, OS version, MTP settings, storage layout and `MLX_*`/`DARKBLOOM_*` environment. The worker is a different binary (`$WK/Package.swift`, macOS 26.2 target), and the two Macs run different OS versions.
8. **Position.** `manifest.position < promptTokens.count`, and `validateStructure` requires 256-alignment or a chunk multiple.
9. **Limits.** The cluster profile admits at most 8,192 prompt tokens, 512-token chunks and 128 outputs (`QwenResidentAdapterDefinition.profile`, `QwenResidentResourceCeilings.maximumContextTokens = 8320`).

## 2. Numerical validity

The engine's bar is exact identity for state it restores from disk. Pair state cannot meet it by construction (mismatches 3, 6, 7). The realistic bar has three tiers:
- **Same chip.** Cluster state at M compared byte-for-byte with the engine's own checkpoint at M. Expect bit-equality on the contiguous backend; measure the paged difference.
- **Mixed chips.** Greedy tokens equal across a prompt set, with bounded logit drift, calibrated against drift the fleet already accepts between an M3 and an M5 provider and between the two backends (`darkbloom benchmark --parity`).
- **Enforcement.** Adoption allowed only for qualified tuples of model aggregate, cut, worker build, provider build and chip pair.

Tools that exist: the cluster comparator's verdicts (`QualificationVerdict`: `exact`, `tokensEqualLogitsDiffer`, `divergedAtNearTie`, `diverged`; `$WK/Sources/DarkbloomClusterQualification/QualificationComparator.swift`) and the engine's teacher-forced scorer (`$CB/CBv2TeacherForcedScores.swift`).

Exact-token tests must pin MTP off or to `DARKBLOOM_QWEN_MTP_SERIAL=1`. The parity report records a cold-run difference at token 124 from timing-adaptive draft depth, so default MTP is not deterministic even without adoption.

MTP-specific hazard: committed tokens are always target-authoritative, so a foreign history cannot corrupt output. It can silently lower acceptance. Three ways that happens:
- hidden shipped un-normalized or normalized twice (the codec stores `finalNorm(hidden)`; ID `qwen-trusted-normalized-history-v1:<verification>`);
- hidden paired off by one (`decodePrefixCheckpoint` checks tokens only);
- a verification mode that differs from the engine's.

Each shows up only as decode slowing toward the MTP-off rate. Qualification needs an acceptance-rate comparison against cold, not just token equality.

## 3. Adoption mechanism

| | (a) via SSD format | (b) in-memory import (recommended) | (c) split the engine's prefill | (d) MTP and decode into the cluster runtime |
|---|---|---|---|---|
| Build | Provider-side DBK3 writer fed from host bytes (`CBv2CompleteCheckpointExport` has no public init), plus all of (b)'s export | Export mode in the runtime; X2 seam; a stager in the bridge; `installExternalStage` on `SSDHybridCheckpointStore` | Partial-depth forward in `Qwen35.swift`; externally fed prefill rows in `SchedulerV2`/`EngineLoopV2` (6,413 lines); per-layer deferred adoption in the paged pool; a transport inside or beside the provider | Paged backend, the engine's decode loop, about 4,000 lines of `$CB/MTP`, sampler, prefix cache |
| Reuses | `SSDHybridCheckpointStore.stage`, DBK3, engine adoption | Engine import and `adoptPagedCompleteCheckpoint` unchanged; phase-split `handoffComponents`, `QwenPhaseSplitHandoffSender/Receiver`, lookahead | Engine kernels for the upper layers; no duplicate weights | Phase split |
| Request-time cost at 8k (9B) | (b) plus encrypt, write, read and decrypt of 377 MB: about +0.3–0.5 s. Not found: a measured write rate; policy constant is `conservativeStageBytesPerSecond = 1_500_000_000` | Link 39 MB (cut 4) or 78 MB (cut 8); worker→provider about 300–340 MB same-host; one copy into pages. Streamed about 0.17 s plus 0.09 s tail; post-hoc about 0.37 s plus tail | Only the low stage's 39–78 MB crosses; no rank-1 transfer | None for adoption; decode stays 73–81 tok/s against 98–131 |
| Runs in | Worker → provider → disk → provider | Worker (upper stage) → provider, both on the serving Mac | Provider process | Workers only |
| Breaks | Pair bytes become durable under the single-Mac identity for the 1,800 s TTL and are advertised to the coordinator through ready receipts; charges the write budget. The worker must never write `kv3/` itself (epoch seam, single writer) | Identity is asserted in memory only. Paged accounting is preserved by the existing stage lease (`reserveCheckpointStage` → `transferCheckpointStage`). Adoption is reported as an SSD hit: `EngineV2RequestUsageSignal.record(usage:)` would publish `cached_tokens = M` | Every-layer-per-step invariants (`CBv2RecurrentStateEvaluation.evaluate`, row offsets in lockstep), the 30 s step watchdog, the provider's isolation from JACCL | None of the engine's, because it bypasses the engine: greedy only, no batching, no prefix cache |

The hand-off baseline is measured: 25–27 ms for 21.3 MB and 71–77 ms for 80 MB on the serving path, about 0.78 ms per MB marginal. Applied post-hoc to the whole 9B state that is about 0.3 s at 8k, which is why X4 matters. Attention rows are append-only, so each chunk's rows can be shipped while the next chunk computes; only the 51.5 MB recurrent state must wait for the end. Streaming into the import needs one small SDK change: `appendSegment` enforces a single global cursor, while the paged sink underneath is already random-access.

The ticket must be installed in the store itself, because the engine holds exactly one `completePrefixCache` and `completeCheckpointLookup` calls its `takeStaged`. Adoption therefore requires the slot's complete store to be `ready`.

Simpler variant: "the pair only warms the SSD cache" is (a) on the critical path. It keeps roughly half or more of the 27B benefit and none of the 9B benefit.

## 4. Process and memory model

- **Three processes on the serving Mac (realistic).** Provider (whole model, ordinary `EngineV2`), owner, and a worker holding only the upper stage. Upper-stage weights for the 9B are 3.49 GB at cut 8 and 3.98 GB at cut 4 (`handoff/DESIGN-stage-transfer.md`). For the 27B at cut 16 they are about 11.0 GB (journal: 15.13 GB for both stages minus 4.14 GB). Totals on the 128 GB Mac: about 11–13 GB for the 9B and about 33–36 GB for the 27B, including the provider's measured 18–21 GiB footprint. Both fit physically.
- **Gates are the obstacle, not RAM.**
  - `DistributedInstalledProviderExclusion` passes because the provider is the owner's parent, but its purpose (no second model on the GPU) is now deliberately violated.
  - The provider's ledger (`UnifiedMemoryCap`, `GlobalKVCacheBudget`) does not see the worker; it needs an explicit reservation from the worker's `ready`.
  - The cluster load gate (`QwenDenseStageLoadPolicy`, v3 under review) refused 27B loads on this Mac under the older rule.
- **One process (link the runtime into the provider).** Not realistic now: the provider deliberately does not link `DarkbloomClusterRuntime` (`provider-swift/Package.swift`), real JACCL needs the 26.2 build, and a stuck collective would block inside the serving process.
- **(c).** The only option on a Mac that cannot hold the model plus a duplicate upper stage, such as a 36–48 GB Mac with the 27B. Not needed for this pair.
- **X1 topology.** `localRank` is `role == .leader ? 0 : 1`. Either let the leader be rank 1 (touches `ClusterConfiguration`, `ClusterStatusCodec`, `ClusterWorkerRequest.run`), or mirror the plan with the fast Mac as rank 0 at cut 24. Mirroring needs new 9B cuts (`supportedCuts = [4, 8, 12, 16]`) and sends the MTP hidden rows over the link (+65 MB at 8k).

## 5. Request flow and serving contract

- **Entry.** The ordinary provider API and `EngineV2Bridge.submitTokenized` (`$PV/Inference/Engine/Bridge/EngineV2Bridge+Submission.swift`), right after `store.stage(...)` near line 365. Token IDs come from the provider's tokenizer, so there is no tokenization mismatch.
- **Decision.** Use the pair when all of these hold: the SSD stage missed; the request is text-only with caching enabled (`permitsHybridCheckpoint`); the uncached remainder is at least a threshold (start at 4,096 for the 9B, about 1,024 for the 27B; configurable until slice 0); the pair lease is free and ready; the engine has no active decode rows; and the first-content deadline covers it.
- **First token and stream.** The engine prefills [M, P), samples with the request's real sampler, and streams normally. Sampling, logprobs, constraints and stop handling are restored; the pair path is greedy-only today.
- **Cancellation.** Cancel the stage and release the lease. No cancel reaches the peer (gap B1), so the pair is unusable until both ranks retire, up to the 60 s progress limit; requests go local meanwhile.
- **Peer death.** All-or-nothing in v1. A provider watchdog on chunk cadence (about 170 ms per chunk) abandons the pair after about 1.5 s and the same receipt continues cold, as `abandonPrefixStaging` does today. Worst case is the watchdog plus a full local prefill.
- **Concurrency.** The pair is single-flight; other requests take the ordinary path. The stage must hold `WholeMacUnboundedActivity`, as `stageTransfer` does, so deadline forecasts do not see an idle GPU.
- **Session envelope.** 16 requests and 300 s (`QwenResidentAdapterDefinition`); "not ready" means go local.
- **Coordinator.** The serving Mac stays an ordinary provider, which sidesteps parts 3 and 4 of gap C10.

## 6. Expected benefit

Model: pair time to M = 0.065 s + M/R. R = 3,068 tok/s is measured at cut 4 with a rested Mac B. Predicted rates are 3,580 (cut 8 rested), 2,456 and 2,865 (cut 4 and 8, settled). Adoption overhead with streamed transfers, including a worst-case 256-token tail, is estimated at 0.18 / 0.21 / 0.26 / 0.36 s for 2k / 4k / 8k / 16k. The measured 0.10 s cache-hit first token at 4k bounds import-plus-tail from above. The 16k row is extrapolation; the runtime cannot run it today (mismatch 9).

9B time to first token, seconds:

| Prompt | Mac B alone, rested / settled | Pair + adopt, cut 4, rested / settled | Pair + adopt, cut 8 (predicted), rested / settled |
|---:|---:|---:|---:|
| 2k | 0.75 / 0.80 (interpolated) | 0.83 / 0.99 | 0.75 / 0.89 |
| 4k | 1.47 / 1.80 (measured) | 1.53 / 1.86 | 1.35 / 1.64 |
| 8k | 2.97 / 3.78 (measured) | 2.91 / 3.58 | 2.54 / 3.12 |
| 16k | 5.96 / 7.57 (extrapolated) | 5.68 / 7.01 | 4.93 / 6.07 |

Decode is identical in both arms (same engine, same Mac), so the totals differ by the same seconds.

9B totals at 8k:

| | 128 outputs | 512 outputs |
|---|---:|---:|
| Mac B alone, rested / settled | 4.33 / 5.15 (measured) | 8.13 / 9.08 |
| Cut 4, rested / settled | 4.27 / 4.95 (−1% / −4%) | 8.07 / 8.88 (−1% / −2%) |
| Cut 8 (predicted), rested / settled | 3.90 / 4.49 (−10% / −13%) | 7.70 / 8.42 (−5% / −7%) |

At 16k and 128 outputs the gain is −4% (cut 4) and −14% (cut 8); at 4k it is +2% and −5%.

The task's "3.7–4.0 s against 4.3–5.2 s" compares a rested pair with a settled Mac B and omits tail and adoption. Like for like it is 4.27 against 4.33, or 4.95 against 5.15. Against phase split (cluster decode at about 73 tok/s) adoption saves about 0.1 s at 128 outputs and about 1.6 s at 512.

9B break-even prompt length:
- about 5,600 tokens at the measured cut-4 rate with streamed transfers;
- never at cut 4 with a post-hoc checked copy;
- about 2,100 (rested) or 1,700 (settled) tokens at predicted cut 8, streamed;
- about 4,000 tokens at cut 8 post-hoc.

27B, all predicted (no pair run exists). Single-Mac inputs: Mac A about 300 tok/s; Mac B 590–880 tok/s in the cluster runtime depending on thermal state; product path on Mac B 578 tok/s at 4k (measured late in a long session). The pipeline formula gives about 840 tok/s settled (cut 20) and about 1,075 rested (cut 16).

| Prompt | Mac B alone, settled | Pair + adopt, settled |
|---:|---:|---:|
| 2k | 3.5 s | 2.9 s |
| 4k | 7.1 s (measured) | 5.4 s |
| 8k | 14.2 s | 10.3 s |
| 16k | 28.3 s | 20.3 s |

Decode at 37–39 tok/s adds 3.3 s (128 outputs) or 13.4 s (512) to both arms. At 8k the totals are 17.5 → 13.7 s (−22%) and 27.6 → 23.8 s (−14%). Break-even is about 1,000 tokens. It needs decision D4, because Mac A is not an M5.

## 7. Recommendation and slices

Variant (b), for these reasons: the adoption side is already built and tested for dense Qwen on paged storage; it restores the full serving contract; and it keeps JACCL out of the provider.

| # | Slice | Files | Macs |
|---|---|---|---|
| 0 | Run the cut and schedule sweep, and phase split across the link. Gate: best 9B cut at or above about 3,400 tok/s at 8k, otherwise target the 27B only | `$SRC/scripts/benchmarks/cluster/pair_sweep.py` (written, never run) | **Two** |
| 1 | **Kill experiment, MTP off.** Dump the staged reference's state bytes at M (prompt = first M tokens, 1 output). Import through an in-memory store and compare: (i) each tensor against the engine's own checkpoint at M, (ii) 128 greedy tokens and teacher-forced scores against cold, (iii) time for allocate + append + finish + adopt. Contiguous first, then paged | `$RT/Models/Qwen/Reference/QwenStagedGenerationReference.swift` (`includeBytes: true`), `$WK/Sources/ReferenceCheck/ReferenceCheck.swift`; new live test modelled on `CompleteCheckpointFixtureStore` in `$SRC/libs/mlx-swift-lm/Tests/MLXLMTests/CBv2CompleteCheckpointEngineTests.swift`; paged arm beside `$SRC/provider-swift/Tests/ProviderCoreTests/Inference/Live/BonsaiEncryptedCheckpointLiveTests.swift` | One (each Mac; then dump on A, import on B) |
| 2 | X2: embedding-input prefill that returns hidden; the upper stage accumulates normalized hidden, tokens and frontier. Test with MTP on (serial oracle for tokens, default for acceptance) | `Qwen35.swift`, `$CB/MTP/MTPContractsV2.swift`, `$RT/Models/Qwen/Generation/QwenLayerStageSession.swift`, `$RT/State/CBv2OwnedStateSnapshot.swift` | One |
| 2′ | Independent of the cluster: conform `Qwen35TextModel` to `CBv2RecurrentPrefillHiddenForwardable` | `Qwen35.swift` | One |
| 3 | `prefill_export_v1` mode: lookahead prefill to M, producer hand-off, export over a same-host data channel (the JSONL event limit is 16 KiB) | `$PHASE/.../Generation/QwenPhaseSplit*.swift` as the base; `ClusterGenerationMode.swift`; `DarkbloomClusterProtocol/ClusterWorker{Messages,Codec,Session}.swift`; `$WK/Sources/DarkbloomClusterWorker/**` | One (two processes, local socket) |
| 4 | Slice 3 across the link; export imported on the serving Mac with slice 1's harness. First end-to-end timing and mixed-chip verdict | Qualification flags only | **Two** |
| 5 | Provider seam: stager, `installExternalStage`, bridge hook, memory reservation, usage label, watchdog | `EngineV2Bridge+Submission.swift`, `$PV/KVCacheSSD/SSDHybridCheckpointStore.swift`, `$PV/Inference/Distributed/**`, `EngineV2RequestUsageSignal.swift` | One with a fake pair, then **two** |
| 6 | X1 topology change | `$PV/Config/ClusterConfiguration.swift`, `ClusterWorkerRequest.swift` | **Two** |
| 7 | Streamed transfer (per-tensor cursors in `appendSegment`) | `$CB/Prefix/CompleteCheckpointTransfer.swift` | One, then **two** |
| 8 | Write-behind donation under a cluster namespace | `$PV/KVCacheSSD/ClusterCacheOwnership.swift`, `SSDHybridCheckpointStore+Write.swift` | One |

Slice 2′ rests on a reading of the code, not a measurement. `Qwen35TextModel` lacks `CBv2RecurrentPrefillHiddenForwardable` (only Qwen4Exp and Nemotron have it), so with MTP on every prompt chunk projects all positions to the 248,320-token vocabulary before `narrowPrefillOutput` slices. That is consistent with Mac A's 952–993 against 1,069–1,115 tok/s with MTP on and off.

Slice 1 kills the idea if either of these happens:
- same-chip state differs by more than low bits, or tokens diverge away from a near tie;
- the in-memory adoption time is far above the estimate.

## 8. Risks and decisions for the owner

Decisions:
1. **Correctness bar (X3).** Is "tokens equal, bounded logit drift, qualified tuples only" acceptable for state asserted under the engine's identity? The codec has a single identity, so the alternative is an SDK change.
2. **Topology (X1).** Leader on rank 1, or mirrored cuts.
3. **Mac A's role.** As a dedicated helper it stops serving. Two independent providers measured about 184 output tok/s at four clients each; this feature buys single-request latency on long novel prompts only.
4. **27B on a non-M5 rank (D4).** Here in the weaker form of low-layer prefill only.
5. **Donation.** Without slice 8, a pair-prefilled conversation seeds no checkpoint, so the next turn is cold. With it, the checkpoint at M is deeper than a solo stripe's.
6. **Usage reporting.** A pair prefix must not appear as `cached_tokens` or as holder evidence. `PrefixCacheTier` is a closed enum mirrored by the coordinator.
7. **Alignment.** Keep 256, or relax to the 128-token query block or to P−1. That saves up to about 0.09 s on the 9B and 0.3–0.4 s on the 27B per request, outside the engine's qualified boundary set.
8. **Same-host transfer.** Keep SHA-256 per tensor on the worker→provider hop, or drop it.
9. **Ordering.** Whether to do slice 2′ first; it helps every provider.

Risks:
- The 9B case rests on a predicted cut-8 rate, with only one pair measurement behind it.
- Mac B's thermal drift (2.97 → 3.85 s over seven requests) is larger than the cut-4 gain.
- The engine and the worker contend for one GPU under concurrency.
- The link address is not persistent (A2/A7).
- No peer cancel (B1) and the session envelope (D3) make the accelerator intermittently unavailable.
- MTP acceptance can regress silently.
- The cluster profile caps prompts at 8,192 tokens.

Not found: any pair measurement of phase split, of a cut other than 4, or of the 27B.

### Critical Files for Implementation
- `$SRC/libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/Prefix/CompleteCheckpointTransfer.swift`
- `$SRC/libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift`
- `$SRC/provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+Submission.swift`
- `$SRC/provider-swift/Sources/ProviderCore/KVCacheSSD/SSDHybridCheckpointStore.swift`
- `$SRC/libs/darkbloom-cluster/Sources/DarkbloomClusterRuntime/Models/Qwen/Generation/QwenLayerStageSession.swift` (with `$PHASE`'s `QwenPhaseSplitHandoff.swift` as the export base)
