# 012 — Synthesizer queue: aggregate Qwen 3.6 prefill

Status: ranked queue (2026-08-24, after first M3 Max baseline)

## Synthesis

The first M3 Max rows change the ranking:

- B=1 median is 1,435 / 1,669 / 1,555 tok/s at 512 / 2,048 / 8,192.
- Four 2,048-token prompts have a 4.955 s median makespan, or
  **1,661 aggregate tok/s**:
  effectively the same as B=1 at 2,048.
- Source and timing agree on the mechanism: Qwen forms packed `[4,512]`
  forwards, but `maxBatchedTokensPerStep=2048` forces four model passes to
  finish each row's 2,048 tokens. Packing shares each pass's weights; the
  scheduler still permits only 2,048 cohort tokens per weight stream.

Therefore the first bet is not "turn packing on" or "raise the chunk." It is to
qualify the existing expert-tile route at M=32,768 and 65,536; only then widen
the memory-safe packed cohort to `[B,C]`. For B=4, `[4,2048]` reduces four
model passes to one per 2,048 row tokens, but it raises routed assignments from
16,384 to 65,536. Raising the scheduler budget first would deliberately fall
back to the known slower expert route.

B=1 remains a no-regression metric, not the credible location of the 2.5x
claim. A guarded one-shot B=1 experiment could disprove that roof later, but
the current mergeable route to `>=2.5x` is B=2/B=4 aggregate. Expected effects
below are multiplicative versus `0.8.10`, not gains that may be multiplied
together in advance.

## Ranked experiment queue

### 1. Qualify expert-tile M=32,768 and M=65,536 before widening cohorts

- **Hypothesis:** The aggregate roof is the CPU-side closed assignment set
  `{4096,8192,16384}`, not an obvious Metal limit. The existing
  `build_sorted_expert_tiles_bm32` kernel accepts runtime M, and its descriptor
  bound `M/32 + E - 1` is only 1,279 entries at M=32,768 and 2,303 at
  M=65,536. Extending the existing independently tiled gather-QMM route should
  preserve its advantage without a fused MoE mega-kernel.
- **Expected B=1 vs B=4:** No end-to-end effect at current scheduler geometry:
  both B=1 stripe and packed B=4 steps remain M=16,384. This unlocks 4,096 and
  8,192 cohort tokens per weight stream for rank 2, corresponding to potential
  `2.0x` and `4.0x` aggregate traffic multipliers.
- **Kill criterion:** Kill M=32K or M=64K independently if tiled QMM is
  `<1.3x` faster than legacy at the exact Qwen gate-up and down geometries,
  any adversarial expert histogram differs numerically, descriptor build
  erases the QMM gain, or the existing metallib has a hidden unsafe cap.
  Do not raise scheduler budget first; that knowingly benchmarks fallback.
- **Files that would change:** CPU gate/descriptor allocation in
  `libs/mlx-swift/Source/Cmlx/include-framework/mlx-backend-common-gemma4_expert_qmm.h`
  and canonical quantized gather-QMM source under
  `libs/mlx-swift/Source/Cmlx/` (then regenerate, never hand-edit only the
  `mlx-generated` copies), plus
  `libs/mlx-swift/Tests/MLXTests/SortedGatherQuantizedMMTests.swift` and
  `QwenExpertTilePerfTests.swift`.
- **Reviewer risk:** Decode: none because M=1 remains ineligible. Numerics:
  medium; sorted/duplicate assignments, empty experts, and BM32 tails need
  parity. `maxBufferLength`: low for descriptors. Coordinator admission:
  none until rank 2 changes serving geometry.
- **Depends on:** Existing M=16,384 control and one-file additive M=32K/64K
  cases in `QwenExpertTilePerfTests.swift`.

### 2. Wide cohort geometry with the newly qualified tile shapes

- **Hypothesis:** The 2,048-token *total* step budget is the measured
  aggregate bottleneck. After rank 1, pure text prefill can use `[4,1024]`
  (M=32,768) and `[4,2048]` (M=65,536), deleting half or three quarters of
  model passes while retaining the fast packed-4-bit expert route. M=65,536
  also permits a guarded one-shot B=1 8K arm, testing rather than assuming the
  B=1 roof. Keep current geometry whenever decode is present.
- **Expected B=1 vs B=4:** B=1 one-shot 8K may reach `1.5–3.0x`, but is not
  required for success. At B=2, `[2,2048]` should give `1.4–2.0x`; at B=4,
  `[4,1024]` `1.5–2.2x` and `[4,2048]` `2.0–3.5x`. The B=4 target is at least
  `4,153 tok/s` for the measured 2K anchor; the 8K target must use its own
  completed baseline rather than extrapolate.
- **Kill criterion:** Dead if `[4,1024]` is `<1.5x` and `[4,2048]` is `<2.0x`
  at B=4 8K, if any geometry exceeds the activation reserve or
  `maxBufferLength`, or if outputs/KV/GDN state differ from `[4,512]`.
  Kill any serving keep that delays an arriving decode row.
- **Files that would change:** Measurement posture in
  `provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Production.swift`; <!-- pragma: allowlist secret -->
  B=2/B=4, aggregate-prefill, activity, and shape evidence in
  `provider-swift/Sources/ProviderBenchmark/ArrivalInvarianceBenchmark.swift`.
  A kept pure-prefill policy would then update
  `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/CBv2Contracts.swift`,
  `SchedulerV2.swift`, and focused scheduler/packed tests.
- **Reviewer risk:** Decode: high unless pure-prefill-only with immediate
  shrink on decode arrival. Numerics: low in principle, high veto bar on
  recurrent/KV parity. `maxBufferLength`: high; dry-budget every shape.
  Coordinator admission: high; provider `freeForLoadGB`, the flat 5.5 GiB
  reserve, and coordinator token-budget estimates must remain conservative.
- **Depends on:** 1, plus the reviewer-required B=2/B=4 harness fields from
  `notes/016-reviewer-merge-gate.md`.

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
- **Depends on:** 2; sweep at the retained cohort geometry.

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
- **Depends on:** 2 and the retained query-block posture from 3.

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
- **Depends on:** 2 and 3.

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
- **Depends on:** 2; run after scheduler/traffic deletion.

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
