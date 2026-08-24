Status: needs-measure

# 010 — Qwen 3.6 packed-prefill execution path

Code inspected:

- `libs/mlx-swift-lm` at `ab73a827c9dd`
- current `provider-swift` serving and benchmark wiring
- no M3 Max runtime was used for this note

## Bottom line

The current source has a real Qwen35 recurrent packed-prefill path. Under the
normal B=2/B=4 equal-length, text-only burst configuration, the scheduler gives
each row a 512-token chunk and `EngineLoopV2.executeMixed` coalesces the rows
into one `[B, 512]` Qwen forward. The old 2026-08-19 result does not establish
what this source does: that report explicitly said Qwen could not pack until
the recurrent prefill seam existed, and `ab73a827` is the commit that added
that seam.

This is a static conclusion, not runtime proof. The M3 Max benchmark still
needs to difference `packedPrefillActivity()` around the exact B=2/B=4 burst.
Until that counter is captured, the answer to “did the measured 8K burst
pack?” remains `needs-measure`.

The suspected MoE failure mode is not present at the Swift graph level:
Qwen35 does not loop over original request rows inside its MoE. A packed
`[B, L, H]` activation is flattened across `B * L`, all `B * L * topK`
assignments are sorted together, and each expert projection is issued as one
global `gatherQuantizedMM` operation. Attention and KV storage are deliberately
split per request row for isolation; that per-row attention loop does not turn
the surrounding Qwen layer or MoE back into B separate model forwards.

This source-level coalescing does **not** prove that an expert's bytes are
fetched from DRAM exactly once. The expert-tile kernel may have several
32-assignment descriptors for one expert, and physical cache/DRAM traffic is a
Metal measurement. What the source disproves is the narrower hypothesis that
Qwen explicitly re-runs `SwitchGLU` once per original request row.

## Why the 2026-08-19 measurement is not a current-path verdict

`docs/reports/2026-08-19-solo-prefill-stripe-experiment.md` records:

- four 8K rows at about the same aggregate throughput as one row;
- rows executing as separate forwards;
- “Qwen cannot [pack] until the recurrent prefill seam exists.”

At the source revision inspected here:

- `EngineLoopV2.executeMixed` has a recurrent packed branch through
  `targetForward`;
- `Qwen35TextModel` conforms to
  `CBv2RecurrentLanguageModelPrefillForwardable`;
- `Qwen35TextModel.cbv2SupportsPackedPrefill` is `true`;
- `Qwen35Configuration.cbv2Capabilities` sets
  `supportsPackedPrefill = true`.

`git log -L` attributes both the engine branch and the Qwen conformance to
`ab73a827` (`perf(cbv2): ... recurrent prompt narrowing + packed prefill
(Qwen3.6) ...`). The 2026-08-19 number remains valid evidence for the older
path, but it cannot distinguish whether the new path fires.

## End-to-end call graph

The normal text-prefill path is:

```text
EngineV2.submit
  -> EngineLoopV2.enqueue
     -> SchedulerV2.enqueue

EngineLoopV2.engineStep
  -> SchedulerV2.plan
     -> running pass / waiting admission
        -> prefillChunkCap(for:)
        -> CBv2StepPlan.assignments [(request id, token count)]

  -> executeMixed(plan)                         [when this is not an MTP round]
     -> build RowWork for each assignment
     -> packedPrefillSupported
        = cacheProvider.supportsPackedPrefill
       && model.supportsPackedPrefill
     -> group non-decode rows by:
        (row.count, row.samples)
     -> for each eligible group with rows.count > 1:
        -> inputs = [B, L]
        -> eagerCaches(rowStates: B request-owned KV rows)
        -> targetForward(tokens: inputs, ids: B ids, requirement: ...)
                                                        [Qwen is recurrent]
           -> bind one CBv2RecurrentStateEvaluation per request id
           -> CBv2SteppableLanguageModelAdapter.recurrentPrefill
              -> Qwen35Model.cbv2RecurrentPrefill
                 -> Qwen35TextModel.cbv2RecurrentPrefill
                    -> Qwen35TextModelInner.cbv2Forward
                       -> for each Qwen35DecoderLayer:
                          -> Qwen35GatedDeltaNet.cbv2Forward
                             [linear-attention layers; one B-row rectangle]
                          OR
                          -> Qwen35Attention.cbv2Forward
                             -> qProj/kProj/vProj on [B,L,H]
                             -> cache.updateAndAttend
                                -> per-row attention and KV write
                          -> Qwen35SparseMoeBlock.callAsFunction
                             -> gate / softmax / topK on [B,L,*]
                             -> SwitchGLU.callAsFunction
                                -> SwitchGLU.projectExperts
                                   -> gatherSort over every B*L*topK assignment
                                   -> QuantizedSwitchLinear.callAsFunction
                                      -> MLX.gatherQuantizedMM(
                                           sortedIndices: true)
                                      -> sorted expert-tile route if all
                                         Metal classifier gates pass
                                   -> scatterUnsort to [B,L,topK,H]
                             -> weightedExpertSum over topK
                             -> sharedExpert on [B,L,H]
                    -> final intermediate handle or frontier logits
           -> evaluate/stage each request's recurrent state transaction
        -> packedPrefillRowsExecuted += B
        -> packedPrefillGroupsExecuted += 1
        -> skip these ids in the singleton loop

     -> for every non-packed prompt row:
        -> inputs = [1, L]
        -> targetForward(... ids: [one id] ...)
```

Relevant symbols:

- admission and chunking:
  `Libraries/MLXLMCommon/ContinuousBatchingV2/SchedulerV2.swift`,
  `SchedulerV2.plan`, `prefillChunkCap(for:)`;
- step dispatch and grouping:
  `Libraries/MLXLMCommon/ContinuousBatchingV2/EngineLoopV2.swift`,
  `EngineLoopV2.engineStep`, `executeMixed`, `targetForward`;
- adapter gates:
  `Libraries/MLXLMCommon/ContinuousBatchingV2/SteppableAdapterV2.swift`,
  `CBv2SteppableLanguageModelAdapter.supportsPackedPrefill`,
  `recurrentPrefill`;
- Qwen trunk:
  `Libraries/MLXLLM/Models/Qwen35.swift`,
  `Qwen35TextModel.cbv2RecurrentPrefill`,
  `Qwen35TextModelInner.cbv2Forward`,
  `Qwen35DecoderLayer.cbv2Forward`;
- MoE:
  `Qwen35SparseMoeBlock.callAsFunction` and
  `Libraries/MLXLMCommon/SwitchLayers.swift`,
  `SwitchGLU.projectExperts`, `gatherSort`,
  `QuantizedSwitchLinear.callAsFunction`;
- KV terminal:
  `Qwen35Attention.cbv2Forward`,
  `CBv2AttendingLayerCache.updateAndAttend`.

The packed path does not call the ordinary legacy
`Qwen35TextModel.callAsFunction` entry point. It enters through the recurrent
prefill conformance and then runs the same Qwen decoder-layer trunk through
`Qwen35TextModelInner.cbv2Forward`.

## 1. Exact packed-prefill conditions

### Capability gates

`EngineLoopV2.packedPrefillSupported` requires both:

1. `cacheProvider.supportsPackedPrefill == true`;
2. `(model as? CBv2PackedPrefillSteppableModel)?.supportsPackedPrefill == true`.

The adapter's model gate is itself two-stage:

1. `cbv2Capabilities.supportsPackedPrefill` must be true;
2. the wrapped model must make the appropriate prompt-forward claim:
   `cbv2SupportsPackedPrefill`.

Qwen satisfies both:

- `Qwen35Configuration.cbv2Capabilities` sets the capability to true;
- `Qwen35TextModel.cbv2SupportsPackedPrefill` returns true;
- `Qwen35Model.cbv2SupportsPackedPrefill` forwards the text-model claim;
- `Qwen35MoEModel` inherits the `Qwen35Model` conformance.

These are capability claims only. They do not prove that a cohort was present
or that the packed branch ran.

### Per-step cohort gates

Inside `EngineLoopV2.executeMixed`, rows pack only when all of the following
hold:

- at least two prompt rows were assigned in the same scheduler step;
- each row is not classified as decode;
- the rows have the same assigned token count (`row.count`);
- the rows have the same `row.samples` value;
- for Qwen's recurrent path, the row has no span in this chunk and no explicit
  `positionState`;
- the plan takes `executeMixed`, not `executeMTPRound`;
- KV state creation/reservation succeeded for every participating row.

`row.samples` means the chunk computes through the final known prompt token.
Consequently, an intermediate chunk and a final chunk of the same numerical
length do not pack together. Equal total prompt lengths and simultaneous
admission keep both `count` and `samples` aligned, which is why the requested
equal-length burst is the clean probe.

Equal **absolute KV offsets are not required**. The engine may group
same-length chunks at different offsets; each cache row carries its own
offset. `CBv2PackedPrefillTests.testPackedRowsWithDifferentCacheOffsetsStayIndependent`
pins this behavior.

Equal total prompt lengths are sufficient for the target burst, not the
literal implementation predicate. Two unequal prompts can pack during steps
where their assigned chunk count and `samples` flag happen to match.

### Text versus multimodal

For the requested Qwen text burst:

- `multimodalByID[id]` is absent;
- `hasSpan` is false;
- `request.positionState` is nil;
- the rows are eligible for recurrent packing.

The generic engine can pack multimodal rows only behind the stronger model and
cache claims. Qwen's current recurrent packing branch is explicitly text-only:
`executeMixed` excludes recurrent rows with either a span or explicit position
state. Therefore “no multimodal” is a real Qwen v1 condition, not merely a
benchmark simplification.

### Scheduler conditions that can prevent a cohort

Even with all model/cache gates true, these policies can leave fewer than two
same-shape assignments:

- `maxConcurrentRequests < B`;
- `maxConcurrentPartialPrefills == 1` serializes prompt work;
- a smaller `maxBatchedTokensPerStep` exhausts the step before all rows receive
  equal chunks;
- a mixed-step prefill quota truncates or defers prompt rows when decode work
  is present;
- KV reservation/preemption changes the assigned set;
- staggered arrival lets an older row advance before its peers enter
  `SchedulerV2`;
- prefix adoption leaves rows at different remaining lengths;
- cancellation or backpressure pauses a row.

The primary goal's simultaneous text burst, prefix cache off, no decoder
company, and normal B=4 limits remove these confounders.

## Contiguous versus paged KV

At the cache implementation level, both backends affirm packed safety:

- contiguous:
  `LayerCacheBankV2.swift`,
  `CBv2LayerCache.keepsRowsIndependentWhenPacked == true`;
- paged:
  `Paged/PagedLayerCache.swift`,
  `PagedLayerCache.keepsRowsIndependentWhenPackedByConstruction == true`.

`CBv2LayerCacheBank.supportsPackedPrefill` is all-or-nothing:
`caches.allSatisfy` must see an affirmative
`CBv2PackedPrefillCapableCache` claim on every layer cache. One custom or
silent cache disables packing for the entire bank.

The two cache backends have the same batch-axis isolation contract but
different storage bodies:

- contiguous `CBv2LayerCache.updateAndAttend` calls
  `CBv2AttentionV1.updateAndAttend`;
- paged `PagedLayerCache.updateAndAttend` calls the shared
  `CBv2AttentionV1.packedPerRow` decomposition, then runs each row through
  `prefillKVWritingChunk` and `prefillAttend`.

Both deliberately slice `[B,...]` into `[1,...]` attention calls. This is only
the attention/KV terminal. Q/K/V projections, GDN projections, dense
operations, and MoE remain one rectangular model forward.

There is an important provider-level qualification for Qwen:
`Qwen35Configuration.cbv2Capabilities` starts from
`CBv2ModelCapabilities.initialRecurrentTarget`, whose
`supportsPagedKV` is false. In
`provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Production.swift`, <!-- pragma: allowlist secret -->
`makeProductionBuild` resolves a requested paged Qwen engine back to <!-- pragma: allowlist secret -->
contiguous with `fallbackReason = "model_capability"`. Thus:

- the paged cache implementation is packed-capable in the generic CBv2
  library;
- the serving Qwen35 engine inspected here actually uses contiguous KV;
- a Qwen runtime proof should assert the factory's resolved backend and should
  not claim it measured paged Qwen.

## 2. Solo stripe and the B=2/B=4 chunk

Defaults are:

- `CBv2SchedulerConfig.prefillChunkSize = 512`;
- `CBv2SchedulerConfig.maxBatchedTokensPerStep = 2048`;
- ProviderCore sets `soloPrefillStripeTokens = 2048` by default in
  `EngineV2Factory.soloPrefillStripeTokens`.

Under the normal unlimited-partial-prefill policy, a B=2/B=4 burst disarms the
solo stripe because `SchedulerV2.plan` sees more than one live request across
`running + waiting`. `prefillChunkCap(for:)` therefore returns the plain 512
for every row.

Normal pure-prefill plans are:

| Burst | Per-row chunk | Total assigned | Packed input when aligned |
|---|---:|---:|---|
| B=1 | 2048 stripe | 2048 | no cohort |
| B=2 | 512 | 1024 | `[2, 512]` |
| B=4 | 512 | 2048 | `[4, 512]` |

B=2 does not automatically grow to 1024 per row merely because half of the
step budget remains. The plain per-request cap stays 512.

There is one current-code exception to the blanket statement “stripe never
applies when waiters exist.” If
`maxConcurrentPartialPrefills == 1`, `SchedulerV2.plan` treats the single
policy-active prefill as stripe-eligible even with queued waiters, provided no
decode row or deferred multimodal block is present. That mode serializes the
burst by policy: one row may use 2048 while the others wait, and there is no
B=2/B=4 packed cohort. The target packed-prefill experiment must record
`maxConcurrentPartialPrefills` and keep it unset/unlimited.

Other config overrides can change the table. The table is the current
ProviderCore default with a simultaneous pure-prefill burst and enough KV
capacity.

## 3. Does Qwen MoE re-run experts per original row?

### What the Swift graph does

No. `Qwen35SparseMoeBlock.callAsFunction` receives the full activation
`x: [B, L, H]` and performs:

1. `gate(x)` and top-K selection, producing indices shaped `[B, L, K]`;
2. one `switchMLP(x, inds)` call;
3. one `weightedExpertSum` over the K axis;
4. one shared-expert path over `[B, L, H]`.

`SwitchGLU.projectExperts` then:

1. inserts the singleton matrix axes expected by gathered MM;
2. enables sorting when `indices.size >= 64` (always true for these prefills);
3. calls `gatherSort(x:indices:)`.

`gatherSort` flattens the leading token axes before indexing:

```swift
x.flattened(start: 0, end: -3)[order.floorDivide(m)]
```

For `[B, L, H]` with top-K `m`, the gathered projection input contains all
`B * L * m` assignments in one expert-sorted array. Original request identity
is not a partition in the expert projection. `scatterUnsort` restores the
`[B, L, K, ...]` layout only after the projection.

The hypothesized helper `qwen35FlattenMoEInputs` does not exist in the
`ab73a827` tree. The actual flattening seam is the model-generic
`SwitchLayers.gatherSort`.

### Expert-tile call

For a quantized expert projection,
`QuantizedSwitchLinear.callAsFunction` passes the globally sorted assignment
array to:

```text
MLX.gatherQuantizedMM(... rhsIndices: idx, sortedIndices: true)
```

The Metal classifier in
`libs/mlx-swift/Source/Cmlx/include-framework/mlx-backend-common-gemma4_expert_qmm.h`
accepts the Qwen E=256 geometries and assignment counts:

- B=1, L=512, topK=8: 4,096 assignments;
- B=2, L=512, topK=8: 8,192 assignments;
- B=4, L=512, topK=8: 16,384 assignments.

Those are all explicit classifier values. Route engagement additionally
requires the process feature latch, compatible quantization/dtype/layout,
supported projection geometry, source-matched AOT metallib, and no higher
priority NAX route. Therefore the assignment shape makes the tile route
eligible; it does not by itself prove the route hit. The independent runtime
proof is `GPU.gemma4ExpertQMMDiagnostics()` with the route counters armed only
for a benchmark interval.

The kernel's `build_sorted_expert_tiles_bm32<256>` scans one globally sorted
index array, finds each expert's segment, and emits descriptors for up to 32
assignment rows at a time. The descriptor stores `(row, row_count, expert)`;
it does not store an original request-row id.

### What remains unproven without a Metal measurement

A single global expert projection is not synonymous with one physical DRAM
read of each expert:

- an expert with more than 32 assignments has multiple descriptors;
- output and reduction geometry introduces additional tiles;
- cache residency and memory-controller behavior are hardware facts.

Static source can therefore conclude:

- there are not B explicit Qwen/`SwitchGLU` expert forwards;
- assignments from all request rows are globally coalesced by expert;
- physical expert-weight traffic and any throughput consequence still require
  the device benchmark/trace.

This distinction also explains why the per-row `CBv2AttentionV1.packedPerRow`
loop is not evidence of per-row MoE execution. That loop occurs after the
rectangular Q/K/V projections, only at attention/KV storage.

## 4. Can a benchmark surface `packedPrefillActivity()` today?

### Engine API: yes

The public API already exists:

- `CBv2Contracts.swift`: `CBv2PackedPrefillActivity` and
  `CBv2Engine.packedPrefillActivity()`;
- `EngineV2.swift`: republishes the loop snapshot;
- `EngineLoopV2.swift`: synchronizes the read on `engineQueue`.

The fields are:

- `isSupported`: both configuration gates agree; not execution evidence;
- `rowsExecuted`: cumulative rows carried by packed forwards;
- `groupsExecuted`: cumulative packed rectangular forwards;
- `didExecute`: `groupsExecuted > 0`.

The counters increment only at the point where `executeMixed` has built and
issued the rectangular group forward. They remain zero for a capability-only
engine, unequal/singleton rows, and the per-request fallback.

### Existing CLI modes: only partially

`provider-swift/Sources/ProviderBenchmark/BackendParityHarness.swift`,
`probePackedPrefill`, already:

1. runs solo references;
2. snapshots `before = engine.packedPrefillActivity()`;
3. submits distinct equal-length prompts concurrently;
4. snapshots `after`;
5. reports delta groups/rows and checks output identity.

Its source defaults are B=3 and 192 prompt tokens. `darkbloom benchmark
--parity` invokes it, but the CLI exposes neither packed probe row count nor
prompt length.

For Qwen specifically, `--parity` is not a reliable final artifact for this
question: the requested paged arm resolves to contiguous because Qwen declares
`supportsPagedKV = false`, and `BackendParityCriteria.comparisonBlocker`
returns “both arms resolved to contiguous” before attaching the per-arm
packed measurements to the report. The internal probe ran, but the final
criterion does not preserve its counts in this same-backend case.

The two goal harnesses do not currently expose the probe:

- `--scheduler-prefill` constructs `maxConcurrentRequests: 1`, so it cannot
  exercise packed prefill;
- `--arrival-invariance` constructs a burst-capable engine but never reads
  `packedPrefillActivity()` and its JSON has no packed-activity fields.

Thus the engine and parity probe can surface activity today, but the exact
Qwen B=2/B=4 8K benchmark artifact cannot do so without a small harness
change.

## 5. Smallest non-numerical proof

No new engine hot-path log is necessary. The smallest proof for the target
benchmark is to difference the existing counters around each isolated burst:

```swift
let packedBefore = engine.packedPrefillActivity()
// submit and fully drain the B=2 or B=4 equal-length burst
let packedAfter = engine.packedPrefillActivity()

let packedGroups = packedAfter.groupsExecuted - packedBefore.groupsExecuted
let packedRows = packedAfter.rowsExecuted - packedBefore.rowsExecuted
```

Record these two deltas in the `ArrivalInvarianceBenchmark` sample JSON after
the streams have drained. The reads occur outside the model computation,
alter no tensor, sampler, cache, or scheduling decision, and use the existing
synchronized public accessor.

Interpretation for an isolated burst:

- `isSupported == false`: model/cache configuration gate is closed;
- `isSupported == true`, `packedGroups == 0`: capable but no packed group
  fired;
- `packedGroups > 0`: at least one rectangular packed forward fired;
- with no other requests and a maximum cohort B, `packedRows == B *
  packedGroups` proves every counted group had width B. A smaller ratio means
  some counted groups were narrower. Singleton fallback chunks are not counted.

If a one-line temporary diagnostic is preferred, the only authoritative site
is beside:

```swift
packedPrefillRowsExecuted += group.rows.count
packedPrefillGroupsExecuted += 1
```

in `EngineLoopV2.executeMixed`, logging `B=group.rows.count`,
`L=group.count`, and `samples=group.samples`. Such I/O should not remain in a
timed benchmark; the counter delta is the cleaner artifact.

To prove both independent questions in one run:

1. use `packedPrefillActivity()` deltas to prove the CBv2 rectangular Qwen
   forward;
2. separately arm/snapshot `GPU.gemma4ExpertQMMDiagnostics` at engine-idle
   boundaries to prove the sorted expert-tile route hit.

Neither counter alone is a speed claim. Aggregate prefill tok/s and physical
weight traffic remain measurements.

## Runtime measurement required to close this note

On the M3 Max, for B=2 and B=4 equal-length text bursts:

1. record the resolved KV backend;
2. record effective `prefillChunkSize`,
   `soloPrefillStripeTokens`, `maxBatchedTokensPerStep`, and
   `maxConcurrentPartialPrefills`;
3. snapshot packed activity after warm-up and immediately before the measured
   burst;
4. run the fixed burst and drain all streams;
5. record `delta groups`, `delta rows`, and the observed packed width ratio;
6. record expert-QMM route hits/fallback reasons if expert-tile engagement is
   part of the experiment;
7. report the existing B=1/B=2/B=4 timing metrics separately.

Only step 5 answers whether packed prefill actually fired for the measured
burst. Timing alone cannot distinguish “packing was off” from “packing ran but
did not improve the measured bottleneck.”
