# Darkbloom v0.8.0 post-release engine benchmark sweep

**Purpose.** v0.8.0 flipped the fleet default KV backend to PagedAttention. Every report in
`libs/mlx-swift-lm/benchmarks/reports/` predates the release range (newest: 2026-07-09/10) — before the
ring shrink (97→65 pages), sub-blocked prefill, and first-admission slab commitment. This sweep is the
first post-release in-engine measurement, the first post-release gpt-oss throughput measurement of any
kind, and a targeted attempt to localize the unexplained ~1 ms/step paged-only B=1 cost seen on gemma
provider-side (98.8 vs 107.2 tok/s solo).

## Provenance

| | |
|---|---|
| Engine tree | `/Users/gaj/Documents/Builds/mlx-swift-lm-simplify` (worktree, branch `cbv2/simplify`) |
| Commit | worktree HEAD `120d1c0`; **content-identical to `origin/main` @ `edc6036`** (`git diff origin/main` empty, verified 2026-07-27) |
| Build | `swift build -c release --product BenchCBv2` (bench binary self-stamps `120d1c0`) |
| metallib | copied from `/Users/gaj/Documents/Builds/d-inference-v080/provider-swift/.build/arm64-apple-macosx/debug/mlx.metallib` into `.build/arm64-apple-macosx/release/` |
| Machine | Apple M4 Max, 16 CPU cores, 128 GB unified |
| macOS | 26.5.2 (build 25F84) — note 07-09 baselines were taken on 26.5 (25F71) |
| Thermal | `pmset -g therm`: no thermal/performance warning levels recorded before or after the sweep |
| Models | `mlx-community/gpt-oss-20b-MXFP4-Q8` @ snapshot `773a7da` (24 layers, vocab 201088); `mlx-community/gemma-4-26B-A4B-it-qat-4bit` @ snapshot `0e3cbab` (30 layers, vocab 262144). Local HF cache; nothing downloaded. |
| Date | 2026-07-27, 13:12–13:31 PDT (runs), PTOK 13:12–13:15 |
| Harness | `BenchCBv2` (`--mode all` = correctness + perf; perf cells: maxTokens 128, prefillChunkSize 512, maxBatchedTokensPerStep 2048, kv 16 GiB; `--prompt-lengths` replaces the default mix and auto-sizes the paged pool nominal max seq len to longest prompt + steps) |
| Host policy | one bench process at a time, models sequential, GPU exclusively mine. Host CPU was shared with other agents' Swift builds/tests arriving in bursts; every run's 1m load is stamped in its header and recorded below. Two runs that landed on bursts (self-flagged `HOST CONTENDED`) were **discarded and re-run**, and are listed in the contention log. |

Flag note vs the task brief: the prompt-length axis flag is `--prompt-lengths` (comma list, cycled to
batch width), not `--prompt-tokens`. Engines are `v2` (contiguous) and `v2-paged`; `legacy` and
`v2-compiled` are refused by the harness in v0.8.0 (both removed).

### Exact commands

```bash
# build (once)
cd /Users/gaj/Documents/Builds/mlx-swift-lm-simplify
swift build -c release --product BenchCBv2
cp /Users/gaj/Documents/Builds/d-inference-v080/provider-swift/.build/arm64-apple-macosx/debug/mlx.metallib \
   .build/arm64-apple-macosx/release/mlx.metallib

# PTOK microbench (per process, per target; 5 passes each)
DARKBLOOM_CBV2_PAGED_PTOK_BENCH=1 DARKBLOOM_CBV2_PAGED_PTOK_TARGET={0|128|512} \
  swift test --skip-build --filter partitionSizingBenchmark

B=./.build/arm64-apple-macosx/release/BenchCBv2
OSS=~/.cache/huggingface/hub/models--mlx-community--gpt-oss-20b-MXFP4-Q8/snapshots/773a7da77e569019bb0fd17a554b263738d669a3
GEM=~/.cache/huggingface/hub/models--mlx-community--gemma-4-26B-A4B-it-qat-4bit/snapshots/0e3cbab38ce568cf6e23543010d08d03b731910c

$B --model $OSS --mode all  --engines v2,v2-paged --batches 1,4,8 --steps 128 --kv-gb 16 --label v0.8.0-postrelease --out /tmp/bench-gptoss-main.md
$B --model $OSS --mode perf --engines v2,v2-paged --batches 1 --prompt-lengths 512  --steps 128 --kv-gb 16 --out /tmp/bench-gptoss-b1-p512.md
$B --model $OSS --mode perf --engines v2,v2-paged --batches 1 --prompt-lengths 8192 --steps 128 --kv-gb 16 --out /tmp/bench-gptoss-b1-p8192.md
$B --model $OSS --mode perf --engines v2,v2-paged --batches 1,4,8 --steps 128 --kv-gb 16 --out /tmp/bench-gptoss-perfrepeat.md
$B --model $OSS --mode perf --engines v2-paged,v2 --batches 1,4,8 --steps 128 --kv-gb 16 --out /tmp/bench-gptoss-reversed.md   # order control
$B --model $GEM --mode all  --engines v2,v2-paged --batches 1,8 --steps 128 --kv-gb 16 --out /tmp/bench-gemma-main.md
$B --model $GEM --mode perf --engines v2-paged,v2 --batches 1,8 --steps 128 --kv-gb 16 --out /tmp/bench-gemma-reversed.md      # order control
$B --model $GEM --mode perf --engines v2,v2-paged --batches 1 --prompt-lengths 512  --steps 128 --kv-gb 16 --out /tmp/bench-gemma-b1-p512.md
$B --model $GEM --mode perf --engines v2,v2-paged --batches 1 --prompt-lengths 8192 --steps 128 --kv-gb 16 --out /tmp/bench-gemma-b1-p8192.md
```

Per-run reports with full per-request detail: `/tmp/bench-*.md`.

---

## Executive verdicts

1. **Both engines got faster since 07-09 on both models.** gpt-oss: contiguous B=1 101.8→107.9 (+6%),
   B=8 aggregate 108.5→122.8/129.6 (+13–19%); paged B=1 88.5→94.6/96.9 (+7–9%), B=8 aggregate
   110.8→118.1/127.8 (+7–15%). gemma: contiguous B=1 101.8→107.4, B=8 aggregate 122.0→138.6 (+14%);
   paged B=1 99.5→107.0 (+7.5%), B=8 aggregate 115.6→136.2/138.3 (+18–20%), B=8 ITL 35.9→30.4 ms.
2. **The gemma B=1 paged deficit does NOT reproduce in-engine at tip.** 107.0 vs 107.4 tok/s, identical
   9.3 ms ITL, in both engine orders. The provider-side −7.8% (98.8 vs 107.2) therefore does not live in
   the paged decode kernel; see localization section.
3. **gpt-oss does show an in-engine B=1 paged deficit, but it is ~3–8%, not the ~12–13% the fixed-order
   tables suggest.** Roughly half of the apparent deficit in this harness's fixed engine order (and in the
   07-09 reports) is a within-process position bias — the engine measured later in a process scores
   ~3–6% lower. Measured both orders to control for it. The residual paged-only cost is ~0.2–0.7 ms/step
   at ctx≈0.5–0.6k and **inverts at 8k context** (paged decode 98.6 vs 93.7, +5.2%).
4. **Paged batching advantage reproduces directionally in-engine on gpt-oss:** B=4→8 aggregate scaling
   1.20–1.23x (paged) vs 1.11–1.17x (contiguous). Narrower than the provider-side gemma gate (1.272x vs
   1.069x) but the same shape. At B=8 gpt-oss the backends converge (paged 127.8 first-position vs
   contiguous 122.8–129.6 first-position); on gemma B=8 paged wins per-request (27.6–27.9 vs 26.1–26.8)
   and ITL (30.4 vs 32.0–32.8) in both orders.
5. **Long-prompt prefill:** paged pays +9.9% TTFT at 8192 tokens on gpt-oss (8203 vs 7466 ms ≈ 999 vs
   1097 tok/s prefill) — the prefill gather copy showing where 12 of 24 layers are full-attention. On
   gemma (5 of 30 full) it is at parity (7518 vs 7506 ms). No refusals anywhere: the 8192-token cells
   auto-sized the paged pool (nominalMaxSeqLen 8320) and ran.
6. **New correctness delta on gpt-oss:** the contiguous chunked-vs-unchunked prefill check FAILS
   token-exactness at token 5 — an argmax near-tie flip (logprob gap 0.026), the documented ulp class
   from the sub-blocked prefill, on the model family (gpt-oss) whose 07-09 report PASSed it. gemma still
   PASSes token-exact. Not a paged defect (paged is not involved in that check).
7. **PTOK sizer on gpt-oss geometry: keep disabled.** Min-of-5 microbench shows the adaptive targets beat
   the fixed 256-token partition only at B=1 mid-context shapes (~13% at ctx 1024, where both targets
   agree), inside or barely above a ±7% same-geometry noise floor everywhere else, and **no benefit at
   any B≥4 shape**. At the largest shape (B=8, ctx 4096) the sizer doesn't even change geometry. Verdict
   below.

---

## 1. PTOK partition-sizing microbench (gpt-oss geometry, no model load)

Per `Tests/MLXLMTests/CBv2PagedPoolGuardTests.swift` (`partitionSizingBenchmark`): kvHeads 8, queryHeads
64, headDim 64, pageSize 16, fp16 — gpt-oss decode shapes. One `DARKBLOOM_CBV2_PAGED_PTOK_TARGET` value
per process; `TARGET=0` is the kill switch (shipping default) reproducing the fixed 256-token partition.
200 timed iterations per shape after 8 warmups; µs per dispatch (includes per-eval submission overhead,
so read relative deltas, not absolutes).

**Noise handling.** 5 passes per target. Passes 3–4 coincided with a host load burst (1m load up to 27
from other agents' builds); contention only adds time, so the estimator is **min over 5 passes**. The
same-geometry control cells (where the sizer picks PTOK=256 = baseline, so any delta is pure noise) put
the residual noise floor at ~±7%.

### Min-of-5 per dispatch (µs), and chosen PTOK

| shape | target=0 (PTOK) | target=128 (PTOK) | Δ vs 0 | target=512 (PTOK) | Δ vs 0 |
|---|---:|---:|---:|---:|---:|
| B=1 ctx=256  | 350.5 (256) | 299.7 (64)  | −14.5% | 342.7 (64)  | −2.2% |
| B=1 ctx=512  | 282.9 (256) | 260.4 (64)  | −8.0%  | 272.6 (64)  | −3.6% |
| B=1 ctx=1024 | 326.4 (256) | 285.6 (64)  | **−12.5%** | 282.3 (64) | **−13.5%** |
| B=1 ctx=4096 | 323.4 (256) | 301.5 (256†) | −6.8%† | 314.5 (64) | −2.8% |
| B=2 ctx=512  | 294.3 (256) | 268.2 (64)  | −8.9%  | 275.4 (64)  | −6.4% |
| B=4 ctx=1024 | 321.9 (256) | 307.4 (256†) | −4.5%† | 298.3 (64) | −7.3% |
| B=8 ctx=1024 | 349.6 (256) | 347.7 (256†) | −0.5%† | 331.3 (128) | −5.2% |
| B=8 ctx=4096 | 539.1 (256) | 547.8 (256†) | +1.6%† | 536.7 (256†) | −0.4%† |

† identical dispatch geometry to baseline (sizer chose 256): these deltas are pure between-process noise
and define the ±7% floor.

Cross-target consistency check: at B=1 ctx=256 both targets choose PTOK=64 yet measure −14.5% vs −2.2% —
identical configurations disagreeing by 12 points confirms cells must clear ~±7% *and* agree across
targets to count. Only **B=1 ctx=1024 (−12.5%/−13.5%, both targets, PTOK=64)** and weakly B=2 ctx=512
(−8.9%/−6.4%) qualify.

### Raw passes (µs), for the record

```
                     pass:      1       2       3*      4*      5      (* = load burst, 1m load 10–27)
target=0    B1/256          354.6   350.5   571.2   528.4   429.6
            B1/512          302.0   282.9   651.9   512.7   369.1
            B1/1024         326.4   389.9   646.3   477.9   373.1
            B1/4096         323.4   510.2   695.6   712.4   499.7
            B2/512          294.3   399.3   612.9   506.3   384.9
            B4/1024         321.9   495.0  1003.4   551.3   516.6
            B8/1024         349.6   633.8  1392.8   647.2   641.7
            B8/4096         539.1  1537.5  2393.6  1812.5  1481.7
target=128  B1/256          299.7   367.3  2597.1   372.2   353.5
            B1/512          260.4   341.5  1354.0   320.8   272.6
            B1/1024         312.6   370.2   603.3   362.4   285.6
            B1/4096         301.5   530.9  1138.1   595.2   317.3
            B2/512          268.2   350.3  1268.6   768.1   282.4
            B4/1024         307.4   500.8  1663.7   794.1   311.3
            B8/1024         361.3   646.6  2036.3   634.3   347.7
            B8/4096         589.4  1494.0  2604.4  1486.9   547.8
target=512  B1/256          350.3   382.9   587.5   379.1   342.7
            B1/512          311.7   351.3   534.3   332.0   272.6
            B1/1024         347.2   362.5   500.8   365.9   282.3
            B1/4096         531.6   522.9   605.6   529.7   314.5
            B2/512          357.7   364.5  1198.1   344.4   275.4
            B4/1024         522.5   486.2   989.6   466.2   298.3
            B8/1024         638.2   627.1  1349.9   623.7   331.3
            B8/4096        1561.6  1649.1  1802.5  1765.0   536.7
```

### PTOK verdict

**Keep the sizer disabled.** The original claim's home turf (gpt-oss shapes) shows a real win only at
B=1 mid-context (~13% per-dispatch at ctx 1024), nothing beyond noise at any batched shape, and no
geometry change at all at the largest shape — while re-enabling it would reintroduce the
batch-composition nondeterminism `partitionTargetDefault = 0` was landed to remove, and the gemma paired
A/B was already null (≤3.6%). If anyone wants the B=1 win, re-open it as the per-row/"segment-count
constexpr" inversion (rank 6 in the 07-25 gate doc), not by flipping the env knob.

---

## 2. gpt-oss-20b-MXFP4-Q8 — engines × batch

All cells: 128 decode steps, kv 16 GiB, greedy. `agg TPS` counts total tokens over the cell's wall time
including prefill. gpuPeak for paged sits at ~28.5–29.7 GiB in every cell because `--kv-gb 16`
preallocates the pool slabs (11.25 GiB weights + 16 GiB pool + transient); contiguous peaks at
12.4–13.9 GiB. Same as 07-09 by construction — the ring shrink shows up in per-row page demand, not in
the pool footprint at fixed `--kv-gb`.

### Run A — canonical fixed order (v2 first), `--mode all` [load 6.7, clean]

| engine | B | prompts (tok) | decode TPS/req | agg TPS | TTFT p50 (ms) | ITL p50 (ms) | gpuPeak GiB |
|---|---|---|---|---|---|---|---|
| v2 | 1 | 500 | 107.9 | 80.4 | 414 | 9.2 | 12.37 |
| v2 | 4 | 100/500/1500/500 | 42.6 | 110.7 | 1342 | 18.9 | 13.47 |
| v2 | 8 | 500×8 | 24.2 | 122.8 | 2927 | 36.0 | 13.88 |
| v2-paged | 1 | 500 | 94.6 | 68.5 | 526 | 10.5 | 28.49 |
| v2-paged | 4 | 100/500/1500/500 | 38.8 | 95.9 | 1599 | 19.1 | 28.85 |
| v2-paged | 8 | 500×8 | 24.2 | 118.1 | 3207 | 34.6 | 29.65 |

### Run B — perf-only repeat, same order [load 7.3, clean]

| engine | B | decode TPS/req | agg TPS | TTFT p50 | ITL p50 |
|---|---|---|---|---|---|
| v2 | 1 | 108.9 | 81.2 | 410 | 9.2 |
| v2 | 4 | 42.9 | 111.9 | 1334 | 18.7 |
| v2 | 8 | 25.2 | 129.6 | 2721 | 33.7 |
| v2-paged | 1 | 96.9 | 72.3 | 461 | 10.2 |
| v2-paged | 4 | 41.5 | 104.2 | 1467 | 18.3 |
| v2-paged | 8 | 25.8 | 125.0 | 3064 | 32.6 |

### Run C — order control: paged FIRST [load 6.5, clean]

| engine | B | decode TPS/req | agg TPS | TTFT p50 | ITL p50 |
|---|---|---|---|---|---|
| v2-paged | 1 | 99.6 | 73.3 | 471 | 9.9 |
| v2-paged | 4 | 42.1 | 106.1 | 1452 | 18.3 |
| v2-paged | 8 | 24.9 | 127.8 | 2744 | 34.3 |
| v2 | 1 | 102.2 | 73.2 | 506 | 9.6 |
| v2 | 4 | 41.5 | 104.6 | 1521 | 19.2 |
| v2 | 8 | 24.6 | 122.3 | 3046 | 34.7 |

### Methodology finding: within-process engine order is worth ~3–6%

Whichever engine runs later in a process measures lower: v2 B=1 first 107.9/108.9 vs later 102.2;
paged B=1 first 99.6 vs later 94.6/96.9. The B=1 minimal pairs (one cell per engine, least accumulated
prior work) show the smallest gaps: v2 108.4 vs paged 105.4 (−2.8%, clean); the full matrices the
largest (−12%). **The 07-09 fixed-order reports carry the same bias** (paged additionally ran after the
since-removed v2-compiled ladder there), so their −13.1% gpt-oss B=1 paged deficit was also inflated.
Same-position comparisons:

| pairing | v2 | v2-paged | paged delta |
|---|---:|---:|---:|
| both first-in-process (A/B vs C) | 107.9–108.9 | 99.6 | **−7.7 … −8.5%** |
| both later-in-process (C vs A/B) | 102.2 | 94.6–96.9 | −5.2 … −7.4% |
| minimal pair, adjacent cells (p512 run) | 108.4 | 105.4 | −2.8% |
| B=8 aggregate, first-in-process | 122.8–129.6 | 127.8 | ≈ parity |

**Corrected gpt-oss B=1 paged deficit: ~3–8% (ITL +0.2…+0.7 ms/step), not 12–13%.**

### B=4→8 aggregate scaling (the provider G0b axis)

| backend | run A | run B | run C | 07-09 (fixed order) | provider gemma gate 07-25 |
|---|---:|---:|---:|---:|---:|
| contiguous | 1.109x | 1.158x | 1.169x | 1.167x | 1.069x |
| paged | 1.231x | 1.200x | 1.204x | 1.182x | 1.272x |

Paged consistently out-scales contiguous into B=8 in-engine on gpt-oss (1.20–1.23x vs 1.11–1.17x). The
provider-side spread (1.27 vs 1.07) is directionally confirmed, narrower in-engine.

### vs 2026-07-09 report (`gptoss-20b-mxfp4q8-paged-gate-2026-07-09.md`, same fixed order)

| cell | 07-09 | now (A/B) | delta |
|---|---:|---:|---:|
| v2 B=1 TPS | 101.8 | 107.9 / 108.9 | **+6.0…+7.0%** |
| v2 B=4 agg | 93.0 | 110.7 / 111.9 | **+19…+20%** |
| v2 B=8 agg | 108.5 | 122.8 / 129.6 | **+13…+19%** |
| v2-paged B=1 TPS | 88.5 | 94.6 / 96.9 | **+6.9…+9.5%** |
| v2-paged B=4 agg | 93.7 | 95.9 / 104.2 | +2.3…+11.2% |
| v2-paged B=8 agg | 110.8 | 118.1 / 125.0 | **+6.6…+12.8%** |
| v2-paged B=8 ITL p50 | 38.6 ms | 34.6 / 32.6 ms | improved |
| v2-paged B=1 gpuPeak | 28.21 GiB | 28.49 GiB | unchanged (pool pinned by --kv-gb) |

Improved: everything, on both backends (kernel-opt work in the release range). Regressed: nothing.
Unchanged: paged pool footprint at fixed kv-gb; the relative paged-vs-contiguous picture at B=8 (parity
then, parity now).

---

## 3. gemma-4-26B-A4B-it-qat-4bit — engines × batch

### Run D — canonical fixed order, `--mode all` [load 6.4, clean]

| engine | B | decode TPS/req | agg TPS | TTFT p50 | ITL p50 | gpuPeak GiB |
|---|---|---|---|---|---|---|
| v2 | 1 | 107.4 | 80.4 | 409 | 9.3 | 14.78 |
| v2 | 8 | 26.8 | 138.6 | 2508 | 32.0 | 18.53 |
| v2-paged | 1 | 107.0 | 78.0 | 454 | 9.3 | 30.68 |
| v2-paged | 8 | 27.6 | 136.2 | 2729 | 30.4 | 32.81 |

### Run E — order control: paged FIRST [load 5.0, clean]

| engine | B | decode TPS/req | agg TPS | TTFT p50 | ITL p50 |
|---|---|---|---|---|---|
| v2-paged | 1 | 106.9 | 77.8 | 457 | 9.3 |
| v2-paged | 8 | 27.9 | 138.3 | 2675 | 30.4 |
| v2 | 1 | 107.5 | 80.5 | 407 | 9.3 |
| v2 | 8 | 26.1 | 135.2 | 2555 | 32.8 |

gemma shows **no order sensitivity** (unlike gpt-oss) and **no B=1 paged deficit**: 106.9–107.0 vs
107.4–107.5, ITL 9.3 ms on both backends in both orders. At B=8 paged wins per-request decode
(27.6–27.9 vs 26.1–26.8) and ITL (30.4 vs 32.0–32.8) in both orders; aggregate is within ±2% (paged
pays ~200 ms more TTFT at B=8, prefill gathers).

One caveat: the gemma B=1 p512 cell in the prompt-length runs (below) measured paged 100.5 vs v2 106.2
(−5.4%) minutes later on the same host — so gemma B=1 paged has a run-to-run band of ~100.5–107.0
(v2: 106.2–107.5). The two full-matrix runs both landing at 107 in both orders makes ≈parity the
central estimate, band −5%…0%.

### vs 2026-07-09 (`gemma4-26b-qat4bit-paged-gate-2026-07-09.md`) and provider gate (07-25)

| cell | 07-09 in-engine | provider 07-25 | now in-engine | notes |
|---|---:|---:|---:|---|
| v2 B=1 | 101.8 | 107.2 | 107.4 / 107.5 | +5.5% vs 07-09; matches provider |
| v2-paged B=1 | 99.5 (−2.3%) | 98.8 (**−7.8%**) | 107.0 / 106.9 (**−0.4%**) | deficit gone in-engine |
| v2 B=8 agg | 122.0 | 211.1† | 138.6 / 135.2 | +13.6% vs 07-09 |
| v2-paged B=8 agg | 115.6 | 247.3† | 136.2 / 138.3 | **+17.8…+19.6%** vs 07-09 |
| v2-paged B=8 ITL | 35.9 | — | 30.4 | improved |
| paged/contig B=8 agg ratio | 0.95x | 1.17x† | 0.98–1.02x | in-engine: parity + per-req/ITL edge |

† provider bench is a different harness/workload (5-rep medians, production stack, different prompt
shapes) — compare ratios, not absolutes. The provider's B=8 paged/contig ratio (1.17x) does not
reproduce in-engine at this workload (0.98–1.02x agg, but paged +3…+7% per-request decode and −2.4 ms
ITL); its B=1 ratio (0.92x) does not reproduce either (1.00x in-engine).

---

## 4. Prompt-length axis, B=1 × {512, 8192} × both engines

`--prompt-lengths` resizes the paged pool nominal max seq len (8320 for the 8192 cells). No cell
refused. Prefill tok/s below ≈ prompt / TTFT (both engines carry the same small scheduling overhead in
TTFT, so the comparison is fair; gpt-oss prefill numbers are not comparable to gemma's because vocab and
layer geometry differ).

| model | prompt | v2 decode / ITL / TTFT | v2-paged decode / ITL / TTFT | paged decode Δ | paged prefill Δ |
|---|---:|---|---|---:|---:|
| gpt-oss | 512 | 108.4 / 9.2 / 415 | 105.4 / 9.4 / 467 | −2.8% | −11% (467 vs 415 ms, incl. warm sched) |
| gpt-oss | 8192 | 93.7 / 10.6 / 7466 | 98.6 / 10.1 / 8203 | **+5.2%** | **−9.9%** (999 vs 1097 tok/s) |
| gemma | 512 | 106.2 / 9.4 / 420 | 100.5 / 9.9 / 468 | −5.4% | −10% (TTFT) |
| gemma | 8192 | 87.5 / 11.4 / 7506 | 89.2 / 10.8 / 7518 | **+1.9%** | −0.2% (1090 vs 1091 tok/s) |

Reading:

- **Decode:** the paged B=1 decode gap *closes and inverts* with context on both models (gpt-oss −2.8% →
  +5.2%; gemma −5.4% → +1.9%). The paged decode kernel scales better with attend length than contiguous
  SDPA; the per-step paged cost is fixed-overhead-shaped, not proportional to context.
- **Prefill:** the long-prompt prefill gather cost is real on gpt-oss (+9.9% TTFT at 8k; 12 of 24 layers
  are full-attention, every 512-token chunk re-gathers the growing history) and **washes out on gemma**
  (5 of 30 full-attention: parity at 8k). Consistent with the provider gate doc's 8k measurement
  (gemma 861 vs 910 tok/s, paged not slower). Post-ring-shrink there is no sign of a new prefill
  regression on gemma; gpt-oss long-prompt TTFT is the one place paged visibly pays.

---

## 5. Correctness (mode all, v2 contiguous, greedy)

| check | gpt-oss | gemma | 07-09 gpt-oss | 07-09 gemma |
|---|---|---|---|---|
| b1-sanity | PASS (191 tok, stop, no loop) | PASS (46 tok, stop) | PASS (195 tok) | PASS |
| invariance (solo/repeat/burst/mid-join) | PASS | PASS | PASS | PASS |
| chunked-prefill token-exact | **FAIL — diverges at token 5** | PASS (32 tok exact) | PASS | PASS |

The gpt-oss chunked-prefill failure detail: chunked (512-token chunks) chose token 10648 (logprob
−1.0989, top-2 gap **0.0263**), unchunked chose 31064 (logprob −1.0644, gap 0.0843); both continuations
are coherent. This is the argmax near-tie ulp class the v0.8.0 gate analysis documented (different
prefill tiling ⇒ last-ulp drift ⇒ tie flip), now visible on gpt-oss chunked-vs-unchunked where 07-09
was token-exact — the sub-blocked prefill landed in exactly this range. It is a contiguous-only check
(no paged involvement), a **new post-release delta vs 07-09** that should be tracked, and by the
release's own token-exactness argument (the bar fails the incumbent under a shipped latency knob) it is
not a blocker. Note the greedy b1-sanity text also changed wording vs 07-09 (same class).

---

## 6. Localizing the B=1 paged-only per-step cost

The question this sweep was asked to inform: gemma provider-side measured 98.8 vs 107.2 solo (−7.8%,
≈+0.8 ms/step; brief cites ~1.25 ms/step).

| evidence | paged-only B=1 step cost |
|---|---|
| gemma in-engine @ tip, both orders | **0.0 ms** (9.3 vs 9.3 ITL; 107.0 vs 107.4) |
| gemma in-engine 07-09 | ~0.2 ms (−2.3%) |
| gemma provider-side 07-25 (release stack) | ~0.8 ms (−7.8%) |
| gpt-oss in-engine @ tip, position-corrected | ~0.2–0.7 ms (−3…−8%) |
| gpt-oss in-engine @ 8k ctx | **negative** (paged faster) |

Conclusions:

1. The gemma B=1 deficit **is not a paged decode-kernel property** — in-engine plain decode never showed
   more than −2.3% even pre-release, and shows ≈0% at tip. The provider-observed −7.8% must come from
   the production stack around plain decode — the prime suspect per the 07-25 MTP analysis is the
   speculative-verify path (per-column paged dispatch pairs: +1.48 ms/col marginal, k≥1), which
   BenchCBv2 never engages (no drafter), plus bridge/step overheads. The engine tip also landed the MTP
   capture-fence probe fix (`a162016`) after the provider measurement, which would shave that stack cost
   further. Re-measuring provider-side G0b at B=1 on the current tip is the cheap follow-up that would
   close this.
2. gpt-oss's smaller (~0.5 ms) in-engine deficit at short context is kernel-level (two dispatches per
   layer vs one fused SDPA — fixed overhead, consistent with it vanishing as context grows and the
   per-token work dominates).
3. Fixed-order harness tables overstate the deficit by roughly 2x on gpt-oss (position bias, section 2);
   treat any single-order in-process A/B at B=1 with suspicion, including the 07-09 tables.

---

## 7. Host contention log

Other agents ran Swift builds/tests in bursts on this box throughout. Policy: own parallelism 1, GPU
exclusive, load stamped per run, contended runs discarded and repeated.

| time (PDT) | event |
|---|---|
| 13:08 | 1m load 14.5 at start (compile bursts); waited before first model run |
| 13:12–13:15 | PTOK passes 1–5; passes 3–4 under a burst peaking at load 27 (min-of-5 estimator used) |
| 13:18–13:21 | gpt-oss runs A, p512, p8192, B — loads 6.7–7.9, all clean, no CONTENDED flags |
| 13:22 | gpt-oss reversed run **DISCARDED** — burst to load 30.7 mid-run, harness self-flagged HOST CONTENDED (v2 B=1 collapsed to 24 TPS — the documented busy-host artifact) |
| 13:27 | gpt-oss reversed re-run clean (load 6.5) — reported as Run C |
| 13:29–13:31 | gemma D, E, p512, p8192 — loads 4.8–6.4, all clean |
| 13:31 | two extra gpt-oss B=1 pairs attempted; first at load 8.0 (v2 itself depressed to 97.3), second self-flagged CONTENDED at 9.0 — **both excluded** from the corrected-deficit estimate (their paired deltas, −2.5% and −9.8%, bracket the clean estimate anyway) |
| 13:31–13:52 | four further alternating-order B=1 pairs queued behind a load<6.5 gate; host stayed at load 15–19 (other agents' builds) for 20+ min, so the queue was cancelled — the existing clean pairs already bound the estimate |
| after | thermal: `pmset -g therm` still reports no thermal/performance warning levels |

GPU was never shared during a measured cell (no darkbloom process; other agents ran CPU test suites at
most — the harness's `no darkbloom process` stamp confirms per run).

## 8. What was NOT run / deviations from the brief

- `--prompt-tokens` does not exist; the axis is `--prompt-lengths` (used as such).
- PTOK target set {0,128,512} as briefed (doc's example also lists 256; skipped — 128 and 512 already
  bracket the geometry choices at these shapes).
- No cell refused, so no refusal rows to record. The only FAIL of any kind is the gpt-oss
  chunked-prefill exactness delta (section 5).
- Extra runs beyond the brief: gpt-oss perf-repeat + both models' reversed-order controls (needed to
  de-bias the headline B=1 comparison), and 5 PTOK passes instead of 1 (host noise).
- gemma B=1 prompt-length cells were kept (time permitted: total sweep wall time ≈ 26 min including
  contention waits, well under the 90-minute budget).
