# 012 — Synthesizer queue: aggregate Qwen 3.6 prefill

Status: ranked queue (2026-08-24, after first M3 Max baseline)

## Synthesis

The first M3 Max rows change the ranking:

- B=1 median is 1,435 / 1,669 / 1,555 tok/s at 512 / 2,048 / 8,192.
- Four 2,048-token prompts finish in 4.926 s, or **1,663 aggregate tok/s**:
  effectively the same as B=1 at 2,048.
- Source and timing agree on the mechanism: Qwen forms packed `[4,512]`
  forwards, but `maxBatchedTokensPerStep=2048` forces four model passes to
  finish each row's 2,048 tokens. Packing shares each pass's weights; the
  scheduler still permits only 2,048 cohort tokens per weight stream.

Therefore the first bet is not "turn packing on." It is to widen the
memory-safe packed cohort to `[B,C]`, starting with C=1,024 and 2,048. For
B=4, `[4,2048]` reduces four model passes to one per 2,048 row tokens. It also
raises routed assignments from 16,384 to 65,536, beyond today's qualified
expert-tile shapes, so scheduler geometry and expert-tile capacity are separate
experiments.

B=1 remains a no-regression metric, not the credible location of the 2.5x
claim. A guarded one-shot B=1 experiment could disprove that roof later, but
the current mergeable route to `>=2.5x` is B=2/B=4 aggregate. Expected effects
below are multiplicative versus `0.8.10`, not gains that may be multiplied
together in advance.

## Ranked experiment queue

### 1. Wide packed-cohort geometry: `[B,512]` → `[B,1024]` → `[B,2048]`

- **Hypothesis:** The 2,048-token *total* step budget, not failure to pack, is
  the measured aggregate bottleneck. During pure text prefill, increasing both
  `prefillChunkSize` and `maxBatchedTokensPerStep` so all B rows receive C
  tokens deletes model passes and amortizes each layer's weight stream over
  `B*C` tokens. Keep current geometry whenever decode work is present.
- **Expected B=1 vs B=4:** A burst-only gate leaves B=1 unchanged. At B=2,
  C=2,048 is expected to give `1.4–2.0x` aggregate; at B=4, C=1,024
  `1.4–2.0x` and C=2,048 `1.8–3.5x`. The B=4 target is at least
  `4,158 tok/s` against the measured 1,663 baseline.
- **Kill criterion:** Dead if the best memory-safe geometry is `<1.5x` at
  B=4 8K, if `[4,2048]` cannot stay below both the activation reserve and
  `maxBufferLength`, or if outputs/KV/GDN state differ from `[4,512]`.
  Kill any serving keep that delays an arriving decode row; this queue is not
  trading ITL for a benchmark.
- **Files that would change:** Measurement posture in
  `provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Serving.swift`;
  formal aggregate/activity/shape evidence in
  `provider-swift/Sources/ProviderBenchmark/ArrivalInvarianceBenchmark.swift`.
  A kept pure-prefill policy would then update
  `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/CBv2Contracts.swift`,
  `SchedulerV2.swift`, and focused scheduler/packed tests.
- **Reviewer risk:** Decode: high unless pure-prefill-only with immediate
  shrink on decode arrival. Numerics: low in principle, high veto bar on
  recurrent/KV parity. `maxBufferLength`: high; dry-budget every shape.
  Coordinator admission: high; provider `freeForLoadGB`, the flat 5.5 GiB
  reserve, and coordinator token-budget estimates must remain conservative.
- **Depends on:** Measured baseline in `notes/009-baseline-b1-curve.md`.

### 2. Extend the existing expert-tile route to 32K/64K assignments

- **Hypothesis:** Rank 1 raises sorted assignments from the currently
  qualified set `{4096,8192,16384}` to 32,768 (`[4,1024]×top-8`) and 65,536
  (`[4,2048]×top-8`). The existing descriptor bound
  `M/32 + E - 1` remains small (2,303 entries at M=65,536). Extending the same
  independently tiled gather-QMM route avoids falling back to the slower
  expert path without introducing a fused MoE mega-kernel.
- **Expected B=1 vs B=4:** B=1 stays on its qualified 2,048-token/16,384-
  assignment stripe and should be unchanged. Incremental B=4 effect after
  rank 1 is `1.1–1.8x` if fallback is the reason a wider cohort underperforms;
  zero if the wider shape already takes the fast route or is compute-bound.
- **Kill criterion:** Dead if diagnostics show no tile fallback at 32K/64K,
  if the extended route is `<10%` faster than fallback end-to-end at B=4,
  if descriptor build becomes material enough to erase QMM gain, or if any
  adversarial expert histogram differs numerically.
- **Files that would change:** Canonical quantized gather-QMM dispatch/kernel
  source under `libs/mlx-swift/Source/Cmlx/` (then regenerate, never hand-edit
  only the `mlx-generated` copies), plus
  `libs/mlx-swift/Tests/MLXTests/SortedGatherQuantizedMMTests.swift` and
  `QwenExpertTilePerfTests.swift`.
- **Reviewer risk:** Decode: none because M=1 is ineligible. Numerics: medium;
  sorted/duplicate assignments and tails need parity. `maxBufferLength`: low
  for descriptors, high for the enclosing `[4,2048]` graph. Coordinator
  admission: inherited from rank 1, not changed by the kernel itself.
- **Depends on:** 1 proving a wider cohort is safe and showing fast-route
  fallback or a route-counter opportunity.

### 3. Query-block width A/B on Qwen D=256 full attention

- **Hypothesis:** The default 128-query block is a general compromise, not a
  result for this 16-head D=256, ten-full-layer M3 Max geometry. A
  64/128/256/512 sweep can delete dispatches or avoid score work after cohort
  widening changes B and C.
- **Expected B=1 vs B=4:** B=1 `0–8%`; B=4 `0–12%`. Larger packed cohorts may
  favor smaller bounded blocks despite their extra launches.
- **Kill criterion:** Dead if the best width is `<5%` faster than 128 at B=4
  8K, regresses B=1 by `>5%`, changes greedy output, or raises peak score
  allocation outside the reserve. Never run an unbudgeted unblocked 32K+
  shape.
- **Files that would change:** None for the experiment; use
  `DARKBLOOM_CBV2_ATTN_QUERY_BLOCK` in
  `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/AttentionV1.swift`.
  Only its default and tests change if a width wins.
- **Reviewer risk:** Decode: none (`L=1` bypasses blocking). Numerics: medium
  because reduction tiling may change last ulps. `maxBufferLength`: medium.
  Coordinator admission: medium if the winning width raises measured peak.
- **Depends on:** 1; sweep at the retained cohort geometry.

### 4. Delete final-layer full-sequence work with Qwen tail narrowing

- **Hypothesis:** After layer 39 there is no downstream trunk consumer for
  discarded prompt positions. Commit all K/V, evaluate only the newest query
  in the final full-attention layer, then run final residual/MoE/norm on that
  row. This deletes one full MoE layer for discarded rows and most of one of
  ten full-attention layers; it is a narrow specialization, not a mega-kernel.
- **Expected B=1 vs B=4:** `1.02–1.08x` at B=1 and a similar relative gain at
  B=4. It cannot supply 2.5x alone.
- **Kill criterion:** Dead if B=1 and B=4 8K are both `<3%` faster, any KV byte
  differs, greedy tokens differ, or frontier-logit error exceeds the existing
  last-query tolerance contract.
- **Files that would change:**
  `libs/mlx-swift-lm/Libraries/MLXLLM/Models/Qwen35.swift` and a focused Qwen
  suite beside
  `libs/mlx-swift-lm/Tests/MLXLMTests/CBv2LastQueryPrefillTests.swift`.
- **Reviewer risk:** Decode: low with a strict `L>1` prompt gate. Numerics:
  medium/high; logits need tolerance and greedy identity while KV stays
  bit-identical. `maxBufferLength`: lower than control. Coordinator admission:
  none.
- **Depends on:** 1 and the retained query-block posture from 3.

### 5. Collapse packed row-local attention calls into one batched SDPA

- **Hypothesis:** Packed Qwen shares projection and expert work, but
  `CBv2AttentionV1.updateAndAttend` loops over B rows. For equal-length,
  equal-history text bursts, stack each row's committed KV and issue one
  batched SDPA with row-local causal masks. This deletes B-1 attention
  dispatch chains per full-attention layer without cross-row visibility.
- **Expected B=1 vs B=4:** B=1 exactly unchanged. B=2 `1.02–1.08x`; B=4
  `1.05–1.15x` if attention dispatch/occupancy is material.
- **Kill criterion:** Dead if B=4 gains `<5%`, the fast path requires padding
  unequal histories, any row can attend another row, output checksums differ,
  or the batched score tensor violates the memory budget.
- **Files that would change:**
  `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/AttentionV1.swift`
  and focused packed-attention parity tests.
- **Reviewer risk:** Decode: none if restricted to `B>1 && L>1`. Numerics:
  medium due batched kernel selection. `maxBufferLength`: high unless query
  blocking remains active. Coordinator admission: medium if peak rises.
- **Depends on:** 1 and 3.

### 6. Reuse one expert-major route plan across routed projections

- **Hypothesis:** `SwitchGLU` sorts the packed cohort once at the Swift level,
  but gate-up and down gather-QMMs can rebuild route descriptors and traverse
  permutation metadata separately. Retain the existing independent quantized
  GEMMs and output-column parallelism, but pass one stable expert-major plan
  through gate-up, activation, and down. This deletes metadata work; it does
  not fuse the arithmetic kernels or retry direct weighted unsort.
- **Expected B=1 vs B=4:** `1.01–1.05x` at B=1; `1.02–1.10x` at B=4, where
  the wider cohort creates more route metadata but fuller expert tiles.
- **Kill criterion:** Do not implement beyond a probe unless route sort/build,
  repeated descriptor work, or partial-tile waste is `>=8%` of MoE prefill
  time. Dead if full-model gain is `<3%` or a projection reads an expert's
  packed weights more often with the retained plan.
- **Files that would change:**
  `libs/mlx-swift-lm/Libraries/MLXLMCommon/SwitchLayers.swift`, quantized
  gather-QMM plan/dispatch code under `libs/mlx-swift/Source/Cmlx/`, and
  focused `SwitchGLUTests.swift` / sorted-QMM tests.
- **Reviewer risk:** Decode: medium unless restricted to large sorted M.
  Numerics: medium/high; duplicate top-k assignments and inverse order must
  remain exact. `maxBufferLength`: low for metadata. Coordinator admission:
  none.
- **Depends on:** 1 and 2; proceed only with phase counters proving the cost.

### 7. GDN prefill via chunkwise WY; decode stays on serial recurrence

- **Hypothesis:** Thirty of forty layers run fp32 recurrent GDN updates.
  Compact-WY chunks of 32/64/128 move sequence dependence into larger matrix
  operations and compose boundary states in order, while T=1 decode remains
  byte-for-byte on the current kernel.
- **Expected B=1 vs B=4:** `1.05–1.10x` at both B=1 and B=4 if the prior 5–7%
  estimate is real. Packing already batches B, so this is not preferentially
  an aggregate lever.
- **Kill criterion:** Stop after the one-layer probe if GDN is not a material
  wall-time share, WY is not `>=1.2x` faster than serial, state/logit error
  exceeds a declared tolerance, greedy tokens change, or scratch grows beyond
  a budgeted `O(B*T*state)` bound. Full-model keep requires `>=5%`.
- **Files that would change:**
  `libs/mlx-swift-lm/Libraries/MLXLLM/Models/GatedDelta.swift` and
  `libs/mlx-swift-lm/Tests/MLXLMTests/GatedDeltaTests.swift`; Qwen wiring only
  if the shared primitive cannot select by T.
- **Reviewer risk:** Decode: low only with an explicit unchanged T=1 test.
  Numerics: high because recurrence order changes. `maxBufferLength`:
  medium/high for scratch. Coordinator admission: medium if scratch exceeds
  the 5.5 GiB reserve.
- **Depends on:** 1; run after scheduler/traffic deletion.

### 8. Adjacent A/B of the existing numerically-correct D=256 Steel path

- **Hypothesis:** Qwen's ten full-attention layers use D=256, outside the
  commonly fused 64/80/128 path. A qualified streaming Steel dispatch can keep
  mask/online-softmax/value reduction on chip and remove score traversals.
  Correctness evidence exists; stable-power full-model speed evidence does not.
- **Expected B=1 vs B=4:** `1.03–1.12x` at B=1 and `1.05–1.15x` at B=4 if
  attention remains visible after wider cohorts.
- **Kill criterion:** Dead if B=4 8K gains `<5%`, B=1 regresses `>5%`, greedy
  tokens change, or any fallback materializes an unbounded score tensor.
  Bounded memory by itself is not a speed result.
- **Files that would change:** Restore/rebase the focused MLX Metal attention
  candidate under `libs/mlx-swift/Source/Cmlx/`, regenerate its embedded
  sources/metallib, and update the corresponding attention dispatch/parity
  tests. No Qwen-specific model fork.
- **Reviewer risk:** Decode: high unless the selector excludes L=1. Numerics:
  high. `maxBufferLength`: medium; every fallback must remain bounded.
  Coordinator admission: low if measured peak does not rise.
- **Depends on:** 3, then 4/5 so the A/B measures the retained attention path.

## Deliberate exclusions

- No packed-enable repair: the M3 baseline already has the packed timing
  signature and source forms `[4,512]`; rank 1 adds the activity/shape counter
  required for a publishable claim.
- No MoE mega-kernel or GateUp+SwiGLU fusion: paired tests are 63–71% slower.
- No unconditional GDN 4-in-1 or direct expert reduction: `0.8.8` traded
  prefill for decode/uptime and was rolled back. A new T>1-only mechanism with
  decode canaries can be proposed later; re-enabling the old default is dead.
- No FCFS/partial-prefill cap as throughput: it changes mean TTFT, not
  aggregate prompt tokens per makespan.
- No sparse attention or prefix cache: 32K+/product bets do not answer the
  fixed 8K B=4 score.
- No general wavefront yet: packed execution already forms one layer-major
  graph and one `asyncEval`; first exhaust wide cohorts and the remaining
  row-local attention loop before adding command-buffer ordering machinery.
