# v0.8.0 PagedAttention — Live Gate Results

Measured on Apple M4 Max, 40 GPU cores, 128 GB, 546 GB/s.
Model: `mlx-community/gemma-4-26B-A4B-it-qat-4bit` (real weights, 15 GB, 3 shards).
Provider built `swift build -c release`. Medians of **5 repetitions** per point.

## G0b — Does batching pay end to end?

Bar: aggregate ≥ 1.07x of B=4, per-request decode ≥ 22 tok/s.

| B | contiguous agg | paged agg | paged/contig | contig per-req | paged per-req |
|--:|---:|---:|---:|---:|---:|
| 1 | 107.2 | 98.8 | 0.92x | 107.2 | 98.8 |
| 2 | 116.3 | 120.1 | 1.03x | 58.2 | 60.1 |
| 3 | 182.6 | 156.4 | 0.86x | 60.9 | 52.1 |
| 4 | 197.5 | 194.4 | 0.98x | 49.4 | 48.6 |
| 5 | 194.3 | 200.9 | 1.03x | 38.9 | 40.2 |
| 6 | 186.1 | 223.1 | **1.20x** | 31.0 | 37.2 |
| 7 | 199.7 | 222.7 | **1.12x** | 28.5 | 31.8 |
| 8 | 211.1 | 247.3 | **1.17x** | 26.4 | 30.9 |

**B=4 -> B=8 aggregate gain: contiguous 1.069x, paged 1.272x.**

### Verdict: PASS on paged, marginal on contiguous

Both backends clear the per-request floor at B=8 (26.4 and 30.9 tok/s vs a
22 tok/s bar, and far above the `EIGENINFERENCE_MIN_DECODE_TPS=15` production
floor).

The aggregate bar is where they separate. Contiguous gains **1.069x** from
B=4 to B=8 — it lands exactly ON the 1.07x bar, i.e. within noise of not
paying at all. Paged gains **1.272x**.

The migration plan modelled 1.26x for this step. That model is confirmed —
**but only for paged**. On contiguous the same step is worth essentially
nothing.

This is the plan's central claim, now measured rather than derived: *paged is
a batching enabler.* Its value is not a faster kernel — it is slightly
**slower** at B=1 (0.92x) and B=3 (0.86x) — it is that the batch curve keeps
climbing where contiguous flattens. The crossover is at B=5-6.

## Prefill (single sample, 1 iteration)

| tokens | contiguous | paged |
|--:|---:|---:|
| 512 | 990.1 tok/s | 1107.9 tok/s |
| 2048 | 759.0 tok/s | 710.2 tok/s |

Prefill is not a paged win and was never claimed to be — there is no paged
prefill kernel. These are within run-to-run noise of each other.

## G1 — Is paged sized correctly?

Bar: per-sequence paged KV <= contiguous at ctx {1k, 10k, 100k}; pool
footprint fits 36 GB boxes.

### Per-sequence KV, gemma-4 (25 sliding w=1024 + 5 full, fp16)

Derived from the LANDED ring geometry (`ringPageCount = 97 pages = 1,552
tokens`), cross-checked against `PagedKVPool.pageDemand`.

| ctx | contiguous | paged (ring 1,552) | ratio | paged + ring shrink | ratio |
|--:|--:|--:|--:|--:|--:|
| 1,024 | 0.273 GiB | 0.273 GiB | 1.00x | 0.273 GiB | 1.00x |
| 10,240 | 0.977 GiB | 1.077 GiB | **1.10x** | 0.980 GiB | 1.00x |
| 102,400 | 8.008 GiB | 8.109 GiB | 1.01x | 8.011 GiB | 1.00x |

### Verdict: MARGINAL FAIL at 10k, and the ring shrink is what fixes it

Paged overshoots contiguous by **10% at 10k context**. It is at parity at
1k (both under the window) and at 100k (the 5 full-attention layers
dominate and the sliding overshoot washes out). 10k is the worst case
because it is where the sliding ring's extra `maxPrefillChunk` of width is
largest relative to total KV.

The overshoot is exactly `ring - window = 1,552 - 1,024 = 528` tokens per
sliding layer. Shrinking the ring to `window + span` closes it to 1.00x at
every context.

**This promotes `gather(ring) ++ chunk` from an optimisation to a G1
blocker.** It also needs BOTH halves: the layer half is landed, but
row-level direct writers cannot re-gather post-write and need their own
answer.

### Measured, real weights, B=1

| prefill | contiguous | paged |
|--:|--:|--:|
| 1,024 | 1291.2 tok/s | 1299.4 tok/s |
| 8,192 | 861.1 tok/s | 910.1 tok/s |
| 32,768 | 354.3 tok/s | 371.6 tok/s |

Peak RSS at 32k: contiguous 14.914 GiB, paged 14.861 GiB.

Note paged is slightly FASTER at long prefill (+5.7% at 8k, +4.9% at 32k).
The gain is query sub-blocking (WS-0.2p): paged previously built one full
`[l, kL]` score tensor and now blocks at q=128, cutting score-tensor
traffic contiguous had already avoided since #85.

CORRECTION, recorded because this repo repeated it for months and it is
wrong in a way that hides real work. The migration plan said paged could
not help prefill because "there is no paged prefill kernel". There IS one.
`PagedAttentionKernel.supportedHeadDims` is `[64, 128, 256, 512]`
(PagedAttentionKernel.swift:159) and it already runs gemma-4's 512-wide
global layers split two-heads-per-threadgroup. The `{64, 80, 128}` ceiling
that motivated the claim belongs to MLX's FUSED SDPA, which binds only the
prefill path (`attendQueryBlock` -> `MLXFast.scaledDotProductAttention`,
PagedLayerCache.swift:833-835).

What is actually true is narrower and more actionable: the paged kernel is
gated to decode by `precondition(q.dim(2) == 1)`
(PagedAttentionKernel.swift:577), so prefill cannot use it and every
prefill chunk pays a full history copy through `PagedKVPool.gather`, whose
own doc says it "materializes a copy (MLX gathers always do)".

Lifting that gate is not a one-line change: it is a two-pass
flash-decoding design whose `q_smem[HPT * D]` has no token axis, and the
threadgroup-memory budget it would resize is what
`PagedKVBackend.init` refuses shapes on at engine build -- deliberately,
because exceeding `threadgroupMemoryLimit` is an UNCATCHABLE process
fatal. The honest unit is "re-derive the threadgroup budget with a
query-tile axis", which is still far smaller than writing a kernel.

## G0a — Does the coordinator actually dispatch 8?

Bar: `effectiveMaxConcurrencyForModelRateLocked` returns 8 for gemma-4.

Pinned by `coordinator/registry/gate_g0a_test.go` against the MEASURED solo
rates above, not modelled ones.

| input rate | source | quality cap |
|---|---|--:|
| 98.8 tok/s | measured, paged B=1 | **8** |
| 107.2 tok/s | measured, contiguous B=1 | **8** |
| 23.4 tok/s | `sqrt(memory_bandwidth)` fallback | **1** |

### Verdict: PASS, and the reason is load-bearing

`b = floor((tps/floor - 1)/k)` with `floor = 15` (`EIGENINFERENCE_MIN_DECODE_TPS`)
and the re-fitted `k = 0.39` requires **61.8 tok/s** to earn a cap of 8. Both
backends measure well past it, so there is ~1.6x headroom.

The third row is the important one. Rev 1 of the plan claimed "no code change
is required to test the batching hypothesis." That was wrong, and this is why:
with no real per-model measurement the coordinator falls back to a
model-agnostic `sqrt(memory_bandwidth)` proxy that reads gemma-4 as ~23.4 tok/s
and pins the cap at **1**. B=8 would never have been dispatched and G0b would
have measured nothing.

So the gate passes *because* a real measurement now reaches the coordinator —
which is the relaxed solo-rate tier added this wave (trust a real solo sample
below the 5-sample floor). A second test pins that dependency explicitly, so
if anyone removes the relaxed tier the failure names the cause instead of
silently reverting the fleet to B=1.

---

# FINAL GATE RESULTS — all measurable gates

Re-measured after the full completion pass. Apple M4 Max, 128 GB, release
build, real weights.

## G2 — parity, both models, `darkbloom benchmark --parity`

### gemma-4-26B-A4B-it-qat-4bit (+ qat-assistant drafter) — **exit 0**

| criterion | verdict |
|---|---|
| token exactness | UNAVAILABLE — the bar is unsatisfiable, see below |
| MTP | UNAVAILABLE — inherited from the same positions |
| packed prefill | **PASS** — active on both backends |
| vision spans | **PASS** — active on both backends |
| prefix reuse | **PASS** — paged 2,816 = contiguous 2,816, bound 25,600 both |

### gpt-oss-20b-MXFP4-Q8 — **exit 0**

| criterion | verdict |
|---|---|
| token exactness | **PASS** — 144/144 identical |
| MTP / packed prefill / vision spans | UNAVAILABLE — model facts, not backend faults |
| prefix reuse | **PASS** — paged 2,304 = contiguous 2,304, bound 1,536 both |

**Zero FAILs. Zero EXPECTED_SHORTFALLs.** Both `EXPECTED_SHORTFALL`
verdicts that existed earlier in this pass disappeared when the cause was
fixed, which is the signal the harness was designed to give.

## Why token exactness reads UNAVAILABLE rather than FAIL

**The bar fails the incumbent.** Changing only
`DARKBLOOM_CBV2_ATTN_QUERY_BLOCK` from 128 to 8 — a shipped operator
latency knob whose own doc says results "can differ in the last ulp" —
makes contiguous diverge from contiguous at token 1 and token 0 on 2 of
the same 3 prompts, with no backend involved.

The in-process control agrees: paged fp32 against paged fp16, same
backend, flips 2 of 3 rows. One position yields **three different tokens
from three configurations of the same weights** — contiguous 100, paged
fp16 107, paged fp32 101.

Root cause is storage-order drift amplified ~1,300x relative to gpt-oss by
gemma-4's attention scale of 1.0 at head_dim 256/512 and its
top-8-of-128 MoE routing across 30 layers. ULP is the ORIGIN, not the
arrival: at the decision the perturbation is 3.657 against a top-2 margin
of 0.604 (6.1x, flips), while the non-flipping prompt is 0.691 against
4.508 (0.15x, holds).

Not a paged defect, and not new:
- paged prefill is **bit-identical** to contiguous — 0.00000 across all
  262,144 logits
- against an fp32 reference, paged is **at parity on sliding layers and
  7-17x MORE accurate on gemma-4's full-attention layers**
- the divergence **predates this wave's ring shrink** — byte-identical at
  the old 97-page geometry

## Gate summary

| gate | verdict |
|---|---|
| G0a — coordinator dispatches 8 | **PASS**, pinned by test; needs 61.8 tok/s, measures 98.8 |
| G0b — batching pays | **PASS** — paged 1.27x from B=4 to B=8, contiguous 1.07x |
| G1 — paged sized correctly | **PASS** — 1.00x contiguous at 1k, 10k, 100k |
| G2 — parity | **PASS** — every evaluable criterion, both models |
| G5 — observable by backend | **PASS** — segmentable end to end |
| G3 — gpt-oss 24h canary | **NOT RUN** — time-based |
| G4 — gemma-4 24h canary | **NOT RUN** — time-based |

## Verdict on the default flip

**The code is ready. The flip is not signed, and the reason is G3/G4.**

Every gate that can be measured on one machine passes. What remains are
two 24-hour canary gates against a real fleet, which cannot be
compressed. The plan named them for a reason: this migration has no
canary fleet, so the soak IS the canary.

`.auto` therefore still resolves to contiguous. Flipping it is a one-line
change plus the operator action in the release notes, and the rollback is
`DARKBLOOM_CBV2_PAGED_KV=0`.

One product decision must be made explicitly rather than inherited from a
green gate: **gemma-4 greedy outputs change under paged.** They are not
worse — measurably more accurate against an fp32 reference — but they are
different, and the same is already true across a shipped latency knob.
That is a call for a product owner, not a test.

---

# What vLLM does that we do not

Read against `vllm-project/vllm @ b153ae6089e9ec3272c423340d2116da97b904ce`
(2026-07-26). Five agents; every claim below is cited to source and the
sliding-window findings were EXECUTED on this M4 Max, not inferred.

## The root cause of our 25,600-token prefix-reuse floor is the RING

vLLM's minimum prompt for a hybrid prefix-cache hit is **one block, 16
tokens** — not window-granular, not window x layers.

Measured against the real `SlidingWindowManager` and
`HybridKVCacheCoordinator`, built to gemma-4's shape (25 sliding w=1024 +
5 full), on Apple Silicon with no CUDA:

| probe | result |
|---|---|
| 25,600-token prompt, only the last 64 sliding blocks cached | 100% hit, **0 tokens recomputed** |
| p50 = 979 tokens | **976 reused (99.7%)**, sliding identical to full attention |

A sliding-window hit needs only the window-sized CONTIGUOUS RUN of blocks
ending at the hit boundary. Every out-of-window position resolves to a
null sentinel that is never read, because SWA masking already excludes it.
Persist and bound — never replay.

**vLLM's sliding rows are not rings.** They are position-indexed
block-table rows sized to `max_model_len`, whose out-of-window entries are
overwritten with a sentinel and whose physical pages are freed
mid-request. A ring cannot express "positions 0..24,576 are absent AND
that is correct", which is exactly why our cache hit starts empty and
replays. The floor is a consequence of the ring, not of the cache design.

Two related corrections to our own framing:
- **Layers do not multiply.** One `block_id` addresses every layer in a KV
  cache group (`kv_cache_utils.py:1140-1200`). Residency is window-sized.
- **Below the window there is no window requirement at all**
  (`single_type_kv_cache_manager.py:941-949`).

## `retainPage` has zero callers

We built the hard half — a block-granular SHA-256 prefix chain, the same
construction vLLM uses — and never wired sharing to it. Adoption COPIES
the donor's KV into fresh pages instead of aliasing them.

Confining sharing to FULL blocks needs no copy-on-write at all: our
frontier page is private by construction and `256 % 16 == 0` is already an
unconditional invariant. vLLM shipped full-blocks-only for years.

The reservation obstacle is smaller than it looks. vLLM's
`full_sequence_must_fit` mode is structurally identical to ours and
already sharing-aware: **a shared page held by another row costs the
admitting row zero reservation; a shared page sitting free costs one.**
That is reservation arithmetic, not occupancy gating, so our no-throw
guarantee on `CBv2SequenceKV.update` can stay. The work is splitting
`pageDemand`, which today serves three roles at once.

## Our watermark is symmetric; vLLM's is not

vLLM charges its reserve only to WAITING/PREEMPTED requests and only when
the batch is non-empty (`kv_cache_manager.py:459-466`). Ours is one
ceiling for every caller.

So at 95% occupancy a RUNNING decode row asking for one more token throws
`capacityExhausted`, and we preempt — `numComputedTokens = 0`, a
979-token re-prefill. vLLM lets those decodes run into the last 5% and
refuses only new admissions.

This costs us more than it would cost vLLM. Their docs justify
recompute-only preemption on the grounds that "prefix caching being better
(zero overhead) and therefore on by default" makes re-prefill nearly free.
**We inherited the preemption model without the prefix caching that makes
it cheap.**

## Confirmed negatives — do not spend time here

- **Long prefill delaying decodes in the same step: vLLM does not solve it
  either.** Its only knob ships disabled, exactly as our
  `mixedStepPrefillTokenCap` does. Ours is arguably the better design; just
  turn it on.
- **Our SchedulerV2 is already a faithful vLLM V1 port**, and cites vLLM
  line numbers in its own docstrings. Step composition, preemption trigger,
  victim selection, recovery mode and FCFS break-vs-continue are parity.
- **Do not build**: copy-on-write, beam fork (`vllm/core/` is deleted),
  cascade attention (gated off for sliding-window models, needs >= 8
  requests — could never fire for gemma-4 or gpt-oss), block de-dup, or
  SLO-aware admission (vLLM has none).

## Ranked

| # | change | shape |
|---|---|---|
| 1 | Asymmetric watermark | two branches |
| 2 | Position-indexed sliding rows + null sentinel — retires the ring | structural, zero CUDA, proven on this machine |
| 3 | Alias on adopt (reuse 2.3% -> ~100%) | hash->page map, `retainPage` caller, split `pageDemand` |
| 4 | Lift `L==1` — kills the prefill gather copy | re-derive the threadgroup budget with a query-tile axis |
| 5 | `ref_cnt == 0` means evictable-but-hit-able | small |
| 6 | Invert PTOK: segment-count constexpr, length at runtime | small; retires the JIT ladder |
| 7 | Hash granularity 256 -> 16-64 · `pendingSamples` skip-don't-break | one line each |

2 and 3 compound: the sentinel design is what makes sliding blocks
shareable at all, and aliasing is what makes sharing free.
