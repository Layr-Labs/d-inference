# Solo-Prefill Stripe Experiment — 2026-08-19

Feature branch: `perf/cbv2-stripe-major-prefill` (superproject) + `perf/cbv2-solo-prefill-stripe`
(mlx-swift-lm). Opt-in scheduler feature + decision-grade A/B on the 2026-08-18 trace-report
machine (M4 Max, Qwen3.6 35B-A3B, `--scheduler-prefill`, contiguous KV, cold prefills).

## Feature

Canonical implementation: `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/`
`SchedulerV2.swift` (`plan()` solo gate, chunk caps, capacity shrink-retry),
`CBv2Contracts.swift` (`CBv2SchedulerConfig`), and
`provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Production.swift`
(env resolution, defaults, paged-pool lockstep). Later addenda:
`PrefillOutputV2.swift`/`SteppableAdapterV2.swift`/`EngineLoopV2.swift`
(narrowing seam + packed executor), `Qwen35.swift` (conformances).

`CBv2SchedulerConfig.soloPrefillStripeTokens` (env `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE`;
**default ON at 2,048 since PR #646** — `EngineV2Factory.defaultSoloPrefillStripeTokens`,
`EngineV2Factory+Production.swift`; an explicit non-qualifying value such as `0` disarms,
which throttled/Low-Power-Mode machines should export given the ~12% LPM regression
below): when exactly ONE live text request holds the scheduler's entire schedulable
population (no decode-ready row, no other live running row, no waiter, no multimodal
blocks), its prefill chunk — and when needed the step budget — extends from 512 to the
stripe. KV-capacity failure on a striped chunk shrinks once to the plain chunk (running and
admission paths); never preempts, never drops a step. Paged pool sizes
`maxPrefillChunk = max(prefillChunkSize, stripe)` (lockstep). Benchmark JSON echoes the
effective stripe. Tests: 10/10 new (`CBv2SoloStripeTests`, `CBv2SoloStripeEngineTests` —
striped forward shapes, token-identical output), 153/153 pre-existing scheduler/parity/
packed/prefix suites green.

## Measurement rounds (all preserved under /tmp/stripe-major/results/)

| Round | Posture | Status |
|---|---|---|
| 1 | battery LPM + concurrent compiles | **VOID** (compile contention, 3.4x slow controls) |
| 2 "clean" | battery, Low Power Mode (`powermode 1`), quiet | valid **as LPM posture only** |
| 3 "clean-ac" | battery, **High Power Mode** (`powermode 2`), quiet | **decision-grade** (anchor PASS) |

Validity anchor: round-3 control 8K median **6330.3 ms** vs the 2026-08-18 plugged-in
baseline **6406.8 ms** = −1.2% → posture parity proven. (Round-2 control was 13,136.7 ms =
2.05x baseline: Low Power Mode halves effective GPU throughput on this workload.)

## Results (medians of 3 cold iterations)

| Posture | 8K stripe2048 vs control | 16K stripe2048 vs control |
|---|---|---|
| Low Power Mode | **+11.8% (regression)** | −2.3% (wash) |
| High Power Mode | **−1.5% (wash;** spreads 2.2/3.3%) | **−3.9%** (suggestive; control spread 7.9%) |

The LPM-only stripe first-iteration penalty (+23%/+14%) did not replicate under HPM
(it1 fastest in 3/4 cells) — an LPM clock-ramp/JIT artifact, not an intrinsic stripe cost.

## Why the predicted −10-15% did not appear (falsified assumption)

The stripe estimate priced two effects as time: expert-tile occupancy (measured 57.6% at
512-token chunks → ~100% at 2048) and 4x fewer full weight reads. Both are real as
*counters* but nearly free as *time* on this workload: every layer touches ~all 256
experts at either chunk size, so expert weight traffic per layer per token is unchanged,
and the routed GEMMs are weight-bandwidth-bound — half-empty 32-row tiles idle ALUs the
memory system was never feeding anyway, and "weight re-reads" are the GEMM operand
streaming that already overlaps compute. What the stripe actually harvests is per-chunk
fixed cost (80 expert-descriptor drains, routing sort chain, dispatch/launch, graph
build): a few percent, matching observation. Tile occupancy is a compute-utilization
metric; converting it to time requires the kernel to be ALU-bound, which this one is not.

## Operational finding (fleet-relevant)

Stripe benefit is **power-posture-dependent with opposite signs**: LPM machines regress
~12% at 8K under striping while HPM machines see a wash-to-small-win. Any future
enablement must not reach throttled/battery-saver providers. More broadly: **TTFT
benchmarks on this class of hardware are invalid without recording power posture**
(`pmset -g batt`, `powermode`) and reproducing a known anchor; Low Power Mode alone
recreates a silent, stable 2x.

## Recommendation

Merge as default-off scheduler infrastructure (safe, gated, tested); do not auto-enable.
The measured prefill levers of consequence remain LM-head narrowing (removes the
[1,chunk,248320] logits transient — which striping *quadruples* to 970 MiB/chunk) and the
attention L² term. Revisit striping after LM-head narrowing lands: the stripe's residual
overhead-amortization win is additive and its main memory cost disappears.

## Addendum (same day, later): verdict change — trust x stripe interaction

The standalone-wash verdict above is superseded by a 2x2 at 8K (3 iters/cell, HPM):

| cell | median TTFT | vs base |
|---|---:|---:|
| base (`=1`, 512) | 6208.7 ms | — |
| stripe alone (`=1`) | 6639.4 ms | +6.9%* |
| trust alone (512) | 6265.6 ms | +0.9%* |
| **trust + stripe** | **5350.2 ms (~1,531 tok/s)** | **-13.8%** |

*single-iteration battery-droop-affected cells (trust-512 climbed +11.7% within one
invocation; stripe-alone ran last at 43% battery). The trust+stripe cell ran second,
against the drift, with 2.8% spread — the robust result. Replicate plugged-in before PR.

Mechanism — serial-bubble unmasking: per chunk, the 80 expert-descriptor drains and the
chunk boundary (eval/submit) are bubbles in series. With drains on, boundaries are masked
(stripe alone ≈ wash). Trust removes drains; the boundary cost is unmasked; the stripe
removes 3/4 of the boundaries. Since #638 (trust default) merged upstream, THE fleet
config is the right-hand column: solo stripe is worth ~-9% on top of trust, not the
standalone ~0%.

## Addendum: engagement verification

- Production path proven striped: with a temporary env-gated plan log, a 4096-token
  benchmark planned `[128]` (warm-up), then `[2048], [2048]` — admission AND running
  paths striped. Debug print reverted before commit.
- Expert-tile route statically verified at stripe width: the classifier explicitly
  qualifies 16,384 assignments, and `max_tile_count = M/32 + E - 1` sizes descriptors
  dynamically (767 at M=16,384) — no capacity cliff.
- Both env echoes present in every arm JSON (`soloPrefillStripeTokens`, `SLICES`).

## Addendum: multi-request prefill baseline (arrival-invariance, 4 x 8K, HPM)

| arm | burst row-TTFTs (s) | aggregate prefill tok/s |
|---|---|---:|
| base (`=1`) | 24.98 / 24.98 / 24.98 / 24.98 | 1,312 |
| trust | 24.12 / 24.12 / 24.12 / 24.12 | 1,359 |
| solo reference | 6.2 (one request) | 1,319 (base) / 1,531 (trust+stripe) |

Two structural findings (single iteration; charger attached mid-second-run):
1. **4 concurrent prefills ≈ 1x aggregate throughput** (1,312 vs solo 1,319): rows run as
   separate forwards, so weights re-stream per row per chunk. This is the quantified case
   for packed prefill (`CBv2PackedPrefillSteppableModel` — Gemma conforms, Qwen cannot
   until the recurrent prefill seam exists).
2. **Every burst row's TTFT equals the makespan** (all finish at 24.98 s): the 512
   interleave is fair and mean-TTFT-pessimal. FCFS run-to-completion would deliver
   ~6.2/12.5/18.7/25.0 s at identical throughput — mean TTFT halved by policy alone.

## Prefill roadmap (consolidated, dependency-ordered)

1. **Rebase onto #638 (trust default — merged upstream)** and replicate trust x stripe
   plugged-in; if -13.8% holds, promote `soloPrefillStripeTokens=2048` as the serving
   default. Admission note: a request arriving mid-stripe waits one striped step
   (~1.3-1.4 s worst case at 8K rates, vs ~0.4 s today) before normal interleaving
   resumes — no queueing-policy change, no serialized prefill; Phase-2 yields shrink it.
2. **Recurrent prefill seam in EngineLoopV2** — one refactor, three payoffs:
   (a) **LM-head narrowing** (Qwen `.evaluationOnly`/`.lastPositionLogits`): ~-14% at 8K,
   removes the 970 MiB/chunk logits transient striping amplifies;
   (b) **packed prefill for Qwen**: closes the measured 4x-requests = 1x-throughput gap
   (experts are weight-bandwidth-bound, so cohort weight sharing is the real lever);
   (c) clean seam for stripe yield points.
3. **Mean-TTFT scheduling policy**: cap concurrent partial prefills (FCFS-lean) — mean
   TTFT ~halves at identical throughput per the measured all-rows-finish-together burst.
4. **qL512 (#640)**: repair 4 review findings; measured +2.4% (8K) / +3.7% (32K).
5. **Prefill-only stripe relaxation**: stripe when no decode row exists (multi-prefill).
6. **Layer-quantum preemption (stripe-major Phase 2)**: yield to decode at layer-group
   boundaries inside stripes; extends trust x stripe to busy providers (ITL bound
   ~35-100 ms); the Gemma `PREFILL_CHUNK_EVAL` mechanism is the seam embryo.
7. **Tiny-GEMM fusion**: GDN 4-into-1 input projection; router+shared-gate fusion
   (35.8% of dense QMM dispatches carry 1.29% of the FLOPs).
8. **GDN chunkwise-parallel scan** (~5-7%; requires tolerance-based parity, not bitwise).
9. **Mask+softmax fused into the QK epilogue** (removes 2 of 6 score traversals;
   641 GiB per 64K prefill).
10. **Wavefront/concurrent dispatch**: GPU busy union == sum (zero overlap ever) at 24%
    of peak — the structural 2x lever; needs MLX concurrent-encoding work.
11. **Sparse prefill attention** for >=32K (probe-gated); tracer measures per-head mass
    first. The only lever that beats the L^2 term at 64K+.
12. **Prefix cache enablement** (product decision): hybrid GDN state makes cached
    prefixes 3.8x smaller than an all-attention peer; off by default today.
