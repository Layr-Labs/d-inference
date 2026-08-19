# Solo-Prefill Stripe Experiment — 2026-08-19

Feature branch: `perf/cbv2-stripe-major-prefill` (superproject) + `perf/cbv2-solo-prefill-stripe`
(mlx-swift-lm). Opt-in scheduler feature + decision-grade A/B on the 2026-08-18 trace-report
machine (M4 Max, Qwen3.6 35B-A3B, `--scheduler-prefill`, contiguous KV, cold prefills).

## Feature

`CBv2SchedulerConfig.soloPrefillStripeTokens` (env `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE`,
default off): when exactly ONE live text request holds the scheduler's entire schedulable
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
