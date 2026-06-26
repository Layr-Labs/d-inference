# Implementation Plan — Continuous Batching on the Pipeline-Parallel Cluster

**Goal:** serve B concurrent decode requests as batched `[B, hidden]` forward
passes across the ring (each node owns a layer slice), with mid-flight
admission/eviction of requests at different sequence positions — so aggregate
throughput scales toward ~B× and the cluster becomes competitive with a single
large machine.

**Why this is the path** (measured, see
[cluster-benchmark.md](../cluster-benchmark.md)): at batch=1, pipeline
parallelism runs the two GPUs sequentially — clustering is *slower* than a single
machine for a model that fits. Decode is memory-bandwidth-bound: the head streams
its layer weights once per step regardless of B, so batching B requests yields
~B× aggregate throughput with the same per-step weight traffic. This is the only
lever that makes pipeline clustering win on throughput. (Tensor parallelism is
the latency lever, but `comms-bench` measured an 83 ms/token / ~12 tok/s floor on
the CPU-stream collectives — TP also needs batching to be viable.)

## Ground truth (read from the code)

- **The fork already has all batched machinery.** `BatchKVCache` /
  `BatchRotatingKVCache` / `BatchedCache` (`libs/mlx-swift-lm/Libraries/MLXLMCommon/BatchKVCache.swift`)
  with `filterBatched`, `extendBatched`, `prepareBatched`, `finalizeBatched`,
  `extractBatched`, per-row `batchOffset`/`leftPadding`, and `makeMask`.
  `BatchGenerator.swift` is the single-node reference scheduler (queue/admit/filter).
- **Layer modules are already batch-generic.** `LlamaAttention.callAsFunction`
  reads `B = x.dim(0)`; RoPE dispatches per-row when the cache is
  `BatchPositionedKVCache` (`RoPEApplication.swift:38-42`). The sharded
  `runOwnedLayers` calls these same modules — no B=1 assumption in the math.
- **One fork correctness gap:** `LlamaPipelineShard.runOwnedLayers` builds the
  mask with `createAttentionMask(h:cache:)` (plain causal, ignores leftPadding).
  Must use `makeAttentionMask(n:cache:)` → `cache.makeMask` so `BatchKVCache`
  supplies the per-row left-padding mask. **GPT-OSS already does this** — no
  change to `GPTOSSPipelineShard`.
- **Crypto:** one seal/open per ring hop per step holds for any B (the
  `[B,width,hidden]` tensor is one blob). The per-step `seq` counter must stay
  independent of B — B must NOT enter the AAD or nonce.
- **sealedLen** becomes `14 + B*width*hiddenSize*2 + 28`.

## Phasing (each ends at a compiling, testable checkpoint)

Build a **new `ClusterBatchPipeline` alongside `ClusterPipeline`**, not a mutation
— the B=1 loop is the verified regression oracle and stays the default until
Phase 3 validates.

### Phase 1 — Static equal-length batching
B prompts of identical length, all admitted at step 0, all run to maxTokens, no
mid-flight churn. Exercises the entire batched data plane (shapes, sealedLen,
transport payload, per-row sampling, `[B]` allGather) while avoiding ragged masks
and the composition control protocol. **Validates the ~B× throughput thesis.**
- Widen `PipelineModelShard` to a batch dim.
- Adapters: `embed` builds `[B, maxLen]`; `caches()` allocates
  `BatchKVCache(leftPadding: [0…])`.
- New `ClusterBatchPipeline.generate(batch:)`; `sealedLen` gains B; tail samples
  `[B,vocab]→argMax→[B]`; allGather broadcasts `[B]`.
- **Test:** worldSize=1, B identical prompts → each row matches the B=1
  `ClusterPipeline` stream token-for-token (greedy). Then 2-Mac aggregate tok/s
  vs B=1.

### Phase 2 — Ragged positions
B requests of different prompt lengths admitted together (B still fixed).
`leftPadding[b] = maxPromptLen - promptLen[b]`, per-row `batchOffset`, per-row mask.
- Adapters build the left-padded matrix; allocate caches with real leftPadding.
- **Fork fix:** `LlamaPipelineShard.runOwnedLayers` mask → `makeAttentionMask`.
- **Test:** worldSize=1, B different-length prompts → each row matches its B=1
  stream. Isolates mask/RoPE/offset correctness.

### Phase 3 — Continuous admission/eviction
Head-side scheduler (mirror `BatchGenerator`) + per-step batch-composition control
round so all ranks apply identical filter/extend.
- New `ClusterBatchScheduler` drives the ring primitives instead of
  `model.callAsFunction`.
- Per-step composition control round (below).
- `cluster-provider` intake feeds a shared queue the scheduler drains.
- **Test:** 2-Mac, staggered arrivals + varied lengths; each request completes
  with the same greedy output it would get alone; sustained aggregate tok/s → B×.

## Batch-composition control protocol (riskiest part)

**Invariant:** every rank calls the same collectives in the same order every step.
The control round moves *inside* the per-step loop: **one composition all_gather +
one token all_gather per step.**

Wire format — a single fixed-width int32 vector, all_gathered from the head
(rank 0's slot is the first `CTRL_WIDTH` entries; peers contribute zeros and read
the head's slot, exactly as `headRankSlot` does today):

```
[0] schema/version tag
[1] command: 0=step, 1=shutdown, 2=idle-keepalive
[2] B_next    — active batch size after this step's admit/evict
[3] nEvict
[4] nAdmit
[5] prefillWidth — width admitted rows are prefilled at (0 if none)
[6 ..< 6+B_prev]  keepIndices into PREVIOUS batch (ascending)
[..]              per-admitted-row metadata: {promptLen, leftPadding, maxTokens,
                  eos ids…, prompt ids…}, packed back-to-back
```

Fixed width sized to an admit cap (reuse `CONTROL_MAX_PROMPT=8192` budget). If an
admit payload would exceed the cap, the scheduler admits fewer rows (back-pressure).

**The head computes the entire next composition before the step and broadcasts
it; peers replay it** (same trust model as today's `exchangeRequest`, extended to
per-step). Each rank, identically, every step:
1. all_gather composition vector.
2. shutdown→return; idle-keepalive→loop (keeps the collective alive when the
   queue is dry, mirroring the current idle round).
3. **Evict:** `cache.filterBatched(batchIndices: keepIndices)` on every owned-layer
   cache.
4. **Admit:** if nAdmit>0, build a fresh `BatchKVCache(leftPadding:)`, prefill the
   admitted rows (ring carries `[nAdmit, prefillWidth, hidden]`), then
   `existing.extendBatched(admitted)`.
5. **Decode:** one `[B_next,1,hidden]` forward; tail samples `[B_next]`; token
   all_gather broadcasts `[B_next]`.

Two collectives per step, fixed order on every rank.

## KV cache lifecycle across the ring

Each rank holds `[any BatchedCache]` — one batched cache per *owned* layer; axis 0
is the batch dim. **Row order must be identical on every rank.** The composition
vector imposes the canonical order: `[surviving rows ascending] ++ [admitted rows
in admit order]`. Because `filter`/`extend` are pure functions of
`(keepIndices, admittedLeftPadding, admittedPrompts)` — all delivered identically
by the composition all_gather — every rank's cache stays in lockstep with no extra
synchronization. The head never ships KV; each rank keeps its own layers' KV local.

## Per-file change list

**Fork (one change):** `LlamaPipelineShard.runOwnedLayers` mask →
`makeAttentionMask(n:cache:)`. GPT-OSS unchanged.

**ProviderCore:**
- `PipelineModelShard.swift` — widen `embed` to `(batchTokens:[[Int]], leftPadding:[Int])`
  with a B=1 default-impl shim; add cache filter/extend hooks.
- `LlamaShardAdapter.swift` — `embed` builds `[B,maxLen]`; `caches()` allocates
  `BatchKVCache` per layer; add filter/extend fan-out.
- `GPTOSSShardAdapter.swift` — same + per-layer dispatch (full→`BatchKVCache`,
  sliding→`BatchRotatingKVCache`), driven by the fork shard's `ownedLayerTypes`.
- `ClusterPipeline.swift` — leave as-is (B=1 oracle).
- `ClusterBatchPipeline.swift` (NEW) — batched ring loop; `sealedLen(B:width:)`;
  `[B,width,hidden]` activation; `[B]` token broadcast; exposes step primitives
  (`prefillStep`, `decodeStep`) so admit/evict can interleave.
- `ClusterServer.swift` — add `ClusterBatchComposition` + `exchangeComposition`
  + `runBatchedPeerLoop`.
- `ClusterBatchScheduler.swift` (NEW) — head-side mirror of `BatchGenerator`
  driving ring primitives.
- `cluster-provider/main.swift` — intake feeds shared queue; control thread runs
  the scheduler loop; per-row token routing keyed by uid→senderKey; per-row
  `inferenceComplete`. Config flag `[cluster].batched` (default off).

**Tests:** `batch-shard-smoke` (single-node B-prompt equality oracle);
`ClusterBatchCompositionTests` (vector round-trip); worldSize=1 batched-vs-serial
equality.

## Risks / unknowns

- **Dynamic-B sealedLen:** derive on every rank purely from the composition
  vector's B/width, never local state, or `recvLike` template mismatches wedge the
  ring.
- **Nonce sequence when B changes:** keep `seq` = per-step counter, B out of AAD.
  Run admission-prefill on its own `requestId` namespace + fresh channels so the
  steady-state decode counter stays one-per-step.
- **GPU watchdog with bigger buffers:** keep `evalEvery` low; bound
  `prefillBatchSize`; consider chunked prefill via `prepareBatched`. Validate on
  the 24 GB node.
- **24 GB tail KV budget:** compute a concrete `maxB` from model config
  (kvHeads, headDim, owned layers) × per-node budget; scheduler respects it
  (admission back-pressure). GPT-OSS sliding-window caps KV per sliding layer —
  helps.
- **Control-round latency:** ~1 ms/all_gather extra per step (~2% at 50 ms/step,
  amortized across B). Keep `CTRL_WIDTH` tight — only ship prompts on admit steps.
- **Large-B ring payload:** B× the `[1,width,hidden]` frame may stress the
  transport (a 64 KB all_gather tripped it during bringup). Validate frame sizes
  at target B early.
- **`extend` cost mid-stream:** batch admissions (admit several at once) to
  amortize the concat/realloc, as `BatchGenerator` does.

## Validation summary

All single-node tests run via the worldSize=1 ring (head==tail) or the no-ring
`shard-smoke` forward; only transport timing needs 2 Macs. Per-phase greedy
token-for-token equality against the B=1 path is the correctness oracle
throughout.
