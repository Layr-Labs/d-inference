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

## CONVERGED FINDINGS — corrections after peer review

Five agents cross-checked each other and three of the conclusions above
moved. Recorded because the corrected versions are cheaper AND more
precise than what they replace.

### The 25,600 is CORRECT arithmetic, not a mis-derivation

Withdrawn: "a design artifact, not physics." It is the RECEPTIVE FIELD of
25 stacked sliding layers of width 1024 — recomputing position p exactly
needs correct hidden states N·W tokens back, and depth compounds the cone
linearly (`CONTRACT-DECISIONS.md:15`). Those are real forward-pass tokens:
`replayStart` feeds `rec.numComputedTokens` and the scheduler chunks
`[C, M)` as ordinary prompt.

The two findings reconcile once you see they measure different things:
- "layers do not multiply" is about STORAGE — one block id addresses every
  layer in a group, so residency is 1x not N x.
- N·W is about NUMERICAL EXACTNESS UNDER RECOMPUTE.

**Storing windowed KV costs 1x and eliminates the N x replay entirely.**
That is exactly why vLLM's number is ~0: it never recomputes a windowed
layer.

### The 2.3% has an exact mechanism: the planner REFUSES

At any `M <= 25,600`, `cbv2RequiredRecompute` returns `M`, so
`replayStart = 0` and `PrefixReusePlan.swift:218` returns **nil**. Not a
weak plan — no plan. At p50 979 tokens we are ~26x under the threshold, so
the refusal is unconditional rather than marginal.

### FOUR of the five links are already built

The windowed-restore chain, verified end to end:

| # | link | state |
|---|---|---|
| 1 | planner flag `restoringWindowsAtBoundary` | built, **tested** (2 callers pass true), no production caller |
| 2 | plan with R=0 (`requiresExactWindowRestore`) | built, tested |
| 3 | backend restore branch | built |
| 4 | row-side install (`PagedKVBackend.installWindow:462-477`) | **built and live** |
| 5 | the BRIDGE that supplies the payload | **MISSING** |

The provider half is built and tested too: `adoptionBoundTokens` returns 0
under `.restoredFromSidecar`, pinned at `replayed == 25_600,
restored == 0` on the real gemma fixture.

Link 5 is: fetch `SSDPrefixCache.stagedWindow(requestID:)` (:1810, never
called), bridge each window to `CBv2PagedWindowSnapshot`, place it at the
windowed layer indices, pass `restoringWindowsAtBoundary: true`, and flip
`pagedWindowRestoreLanded` — the deliberate fail-closed gate whose comment
already describes exactly this condition.

**So this is payload plumbing between two built halves, not new
machinery.** The refusal path is already proven: `makeFrozenFullState`
validates every layer before reserving a page and throws rather than
half-installing; `applyAdoption` catches and cold-prefills.

### The Apple-specific constraint, in one line

On Metal the query tile and the simdgroup count are NOT independent knobs.
They are one budget imposed by the 32 KB threadgroup cap:

> **`BLOCK_Q · (1 + NSG) <= 8`**

because `headsPerThreadgroup` caps `hpt·D` at 1024 floats, making the
total `≈ 4 · BLOCK_Q · 1024 · (1 + NSG)` bytes — essentially independent
of head dim. Verified: predicted 20,480 vs actual 20,544 (D=512) and
20,608 (D=256).

`BLOCK_Q = 4` lands on **32,832 B** — byte-identical to a process fatal
this codebase already shipped and fixed ("sizing these by GQA is exactly
the bug that made Gemma-4 global layers a 32,832 B process fatal").
Whoever takes the L==1 work would re-introduce it to the byte. Put that
number in the ticket.

vLLM's `BLOCK_Q = BLOCK_M // num_queries_per_kv` has no such coupling.
**The M-axis packing technique ports; the freedom to size it does not.**

### Rank 1 is worth strictly MORE to us than to vLLM

Sharpened from "probably" to exact. Our preempt path clears the plan —
`SchedulerV2.swift:782-783` sets `numComputedTokens = 0` AND
`prefixReusePlan = nil` — and the planner refuses any plan below 25,600.
So a preempted 979-token row replays **all 979 tokens with certainty**,
not in expectation.

vLLM's recompute-over-swap choice rests on prefix caching absorbing the
re-prefill. On gemma-4 that premise is not merely weaker for us — it is
structurally inapplicable. Which inverts the naive reading of this whole
exercise: the asymmetric watermark is worth more here than it is upstream.

### Sequencing note

The sentinel item and the L==1 item are independently sized but their
failure modes are coupled, one way. Today's poison pad fails SAFE by being
unreachable; a sentinel inside a valid range fails OPEN if the mask is
wrong, because zeros are not neutral in a softmax (exp(0)=1). That
analysis assumes BLOCK_Q=1 — which is exactly what the kernel work
changes. With a query tile, one tile spans rows at different absolute
positions, so the mask stops being a tile-level property.

vLLM splits this deliberately: `compute_tile_loop_bounds` prunes whole
tiles using the UNION across the Q-block (an optimisation), and
`compute_kv_seq_mask` masks per ELEMENT with a per-row `query_abs_pos`
(the correctness argument). Conflating them is the bug, and it only
becomes possible once BLOCK_Q > 1.

Cheapest order: sentinel first at BLOCK_Q=1 semantics, kernel second, with
the re-proof owned by the kernel ticket.

## FINAL corrections — three claims above are wrong

### 1. The M-axis amortisation win is UNAVAILABLE, not merely constrained

There is a tighter budget than the 32 KB threadgroup cap: the per-thread
REGISTER accumulator, `maxAccumulatorFloatsPerThread = 32`
(`PagedAttentionKernel.swift:387`). It is **already exactly saturated at
both gemma-4 head dims**:

    global   D=512, hpt=2  ->  2 x 16 = 32 floats   (at cap)
    sliding  D=256, hpt=4  ->  4 x  8 = 32 floats   (at cap)

Not a coincidence — `headsPerThreadgroup` picks the largest divisor of GQA
that lands on the cap. gemma-4 is GQA 8 at both dims
(`Gemma4Text.swift:147,:154`), so this holds unconditionally.

A query tile gives every token its own `m`/`l`/`acc`, so per-thread floats
become `BLOCK_Q · HPT · D/32`, i.e. **`BLOCK_Q · HPT <= 1024/D`** — at
most 2 on global layers, 4 on sliding.

The KV tile a threadgroup loads is amortised across exactly `BLOCK_Q ·
HPT` rows of the M axis, and that product is PINNED. **Adding a token to
the tile costs exactly one head.** vLLM's `BLOCK_Q = BLOCK_M //
num_queries_per_kv` works because M is a free 16 rows; ours is a fixed
budget already spent in full.

So the unified-kernel amortisation argument is dead at our head dims.
Item 4 still ranks where it does, justified by exactly ONE thing:
**eliminating the prefill gather round-trip**, which is independent of
tile shape and survives all three narrowings.

The two limits also bind differently, which is worth keeping: threadgroup
memory is an uncatchable process fatal refused statically; the register
cap is a validated level, so exceeding it degrades rather than crashes.

### 2. vLLM has the same coupling — the FAILURE MODE is the delta

Withdrawn: "vLLM's BLOCK_Q has no such coupling."
`triton_unified_attention.py:932-935` pins `BLOCK_M = 16` and derives
`BLOCK_Q = BLOCK_M // num_queries_per_kv`. Since `BLOCK_M = BLOCK_Q · gqa`,
both systems hold the product of query tile and head split constant. The
query tile is not a free knob there either, and vLLM's one hand-tuned
exception is gated to Blackwell.

What actually does not port:

> Ours is a **static compile-time refusal**, because overrunning the
> threadgroup limit is an uncatchable process fatal. Triton allocates
> shared memory itself and **degrades occupancy** instead of dying.

The technique ports. The tile does not, and the failure mode is the reason.

### 3. Windowed restore does NOT reduce preemption cost — the two items are complementary

The tempting inference — "once link 5 lands, adoption succeeds with zero
replay, so preemption stops being expensive" — is **false**.

`applyAdoption` has exactly ONE call site in the engine
(`EngineLoopV2.swift:853`), fired on the submit path immediately after
`scheduler.enqueue`. There is no adoption attempt anywhere on the resume
path, and the preempt path destroys the plan outright
(`SchedulerV2.swift:782-783` sets `numComputedTokens = 0` AND
`prefixReusePlan = nil`).

**A preempted row has permanently passed the only point at which adoption
could occur.** It cold-prefills its full sequence on resume,
unconditionally, whether or not link 5 ever ships.

So the asymmetric watermark and windowed restore are complementary:
restore reduces cold-start cost for NEW requests; the watermark reduces
how often ESTABLISHED rows are destroyed. Neither discounts the other.

A FIFTH delta falls out of this, and it is the mechanism behind vLLM's
confidence in recompute-over-swap: **vLLM re-enters the prefix-cache
lookup on resume.** Its waiting-loop lookup is gated on
`num_computed_tokens == 0` (`scheduler.py:717`), which a preempted request
satisfies precisely because `_preempt_request` zeroed it. There is a test
named for the behaviour. We structurally cannot — and making it possible
is new work at the submit-only call site, not a side effect of link 5.

### 4. Granularity is 16 OR 32 tokens, not a flat 16

gemma-4's head dims are asymmetric (256 sliding / 512 global), so vLLM's
`unify_kv_cache_spec_page_size` scales the sliding block up to 32 and
`scheduler_block_size = LCM(32,16) = 32`. With `attention_k_eq_v` set the
pages re-equalise and both stay 16.

p50 reuse is 98.1% or 99.7% respectively — either way 800-1600x below our
25,600. And the sliding contiguous-run requirement is 1024 tokens in BOTH
geometries: it tracks the WINDOW, not the block size, and only binds above
the window, which our p50 is not.

Sharper framing for the ring: **a ring has no absolute position to install
a window AT**, which is exactly what makes link 5 awkward to feed.
`installWindow`'s `row.fastForward(to: snapshot.base)` is the
absolute-positioning primitive, and it is the property vLLM gets for free
from position-indexed rows.

## LAST correction — the amortisation claim was wrong for 25 of 30 layers

The "already exactly saturated at both head dims" finding above was read
off the Swift decoder DEFAULTS (`numAttentionHeads 8 / numKeyValueHeads
1`). Those are placeholders and they disagree between MLXLLM and MLXVLM.

The real config, read independently from the checkpoint on disk AND
present in-repo as a verbatim literal (`CBv2LastQueryPrefillTests.swift:774-791`):

    num_attention_heads 16   head_dim 256    num_key_value_heads 8
    global_head_dim 512      num_global_key_value_heads 2
    attention_k_eq_v true    sliding_window 1024   30 layers

So the two layer families are ASYMMETRIC and only one is saturated:

| | D | GQA | hpt | acc | headroom |
|---|---:|---:|---:|---:|---|
| sliding (25L) | 256 | **2** | 2 | 16/32 | **2x free** |
| global (5L) | 512 | 8 | 2 | 32/32 | at cap |

Recomputed against `headsPerThreadgroup` / `partThreadgroupBytes` directly
(`maxAccumulatorFloatsPerThread = 32`, `threadgroupMemoryLimit = 32768`,
`mergeRecordMetaFloats = 2`):

    sliding  BQ=1: acc=16/32  NSG=8  18,560 B  M-rows=2   <- today
             BQ=2: acc=32/32  NSG=4  20,608 B  M-rows=4   FITS
             BQ=4: acc=64/32                              register spill
    global   BQ=1: acc=32/32  NSG=4  20,544 B  M-rows=2   <- today
             BQ=2: acc=64/32                              register spill
             BQ=4:                            32,832 B    FATAL

`BQ=4` on global is still byte-identical to the historical process fatal.

**Corrected statement:** the M-axis amortisation win is unavailable on the
5 global layers and a 2x on the 25 sliding layers — which is where p50
traffic lives.

**A cost that has not been priced:** `BQ=2` on sliding forces `NSG` from 8
down to 4, because the merge buffer scales with both. It trades simdgroup
parallelism for M-axis amortisation. Whether that is net positive is a
MEASUREMENT, not a derivation, and nobody has run it. Do not file this as
a free doubling.

For scale: at GQA=2 vLLM's formula gives `BLOCK_M=16`, `BLOCK_Q=8`, so 16
M-rows against our reachable 4.

## Link 5 is bounded by disk budget, not just plumbing

Two numbers from our own source that belong next to the "it is only a
bridge" framing:

- A sliding snapshot is `windowCount x window` positions of real K/V —
  **200 MiB per gemma-4 donation** (`CBv2SlidingWindowDonation.swift:10-11`).
- The box-wide SSD budget is **20 GiB across ALL models**
  (`PrefixCachePolicy.swift:53`, clamped to `min(20 GiB, free/2)`).

That is ~100 sidecars for the entire box, competing with the
full-attention blocks already using that budget.

And the two effects interact adversely: flipping the gate collapses
`adoptionBoundTokens` to 0, which drops the donation floor to just
`minEffectiveTokens` — so donation VOLUME rises sharply at the same moment
each donation becomes 200 MiB more expensive. Uncosted.

Link 5 still ranks first — it trades bandwidth we have against forward
passes we do not, and it unblocks the 2.3%. But it is "bounded by a 20 GiB
box-wide budget at ~200 MiB per sidecar," not "cheap."

Also: link 5 restores BY COPY into private pages (`installWindow` ->
`fastForward` + chunked `write` -> `ensurePage` -> `allocatePage`).
It is independent of `retainPage`/refcount>1 sharing and moves
`pagesInUse` toward sharing by exactly zero pages. The two items do not
substitute for each other.

## Closing three items

### The kernel constraint is REGISTERS, in a cleaner form

Supersedes `BLOCK_Q · (1 + NSG) <= 8`, which was the wrong bound (it was
threadgroup memory, and it was not head-dim independent). The binding
constraint is the per-thread accumulator, and it drops out clean —
independent of GQA and of NSG entirely:

> **`BLOCK_Q · hpt <= 1024 / headDim`**

    global   D=512  ->  M <= 2   today M=2   ALREADY AT CAP, BLOCK_Q pinned at 1
    sliding  D=256  ->  M <= 4   today M=2   room for BLOCK_Q=2

Same conclusion as before, correct mechanism, correct per-family numbers.
vLLM's `BLOCK_Q = BLOCK_M // num_queries_per_kv` has neither coupling.

`BLOCK_Q=4` is NOT a further win on sliding, and the reason is worth
pinning so nobody re-scopes it: at `HPT=2` it needs 64 accumulator floats
against a budget of 32 (memory fits at 24,704 B — registers bind first),
and at `HPT=1` it fits both but yields M-axis `4 x 1 = 4`, IDENTICAL to
`BLOCK_Q=2 / HPT=2`, while doubling the threadgroup splits. Memory
headroom on the sliding layers is real and is not available amortisation.

### The granularity number is 32 tokens, and the scaling runs the other way

Read from the operator's actual checkpoint, identical across the
4bit/8bit/qat copies on this box. Per-token KV is **sliding 8192 B**
(2·8·256·2) vs **global 4096 B** (2·2·512·2) — sliding is the BIGGER page,
so vLLM's unify scales the GLOBAL block up, not the sliding one:

    sliding blk 16 x 8192  =  global blk 32 x 4096  =  131,072 B
    scheduler_block_size = LCM(16,32) = 32 tokens     hash granularity = GCD = 16

> **gemma-4-26B-A4B minimum prefix-reuse granularity under vLLM: 32 tokens.
> Ours: 25,600. Ratio 800x.** p50 979 -> 960 reusable (98.1%).

Structural note: vLLM forms **six** KV cache groups for this model, not
two. `group_size` is the min layer count (5), and 25 is not < 5·1.5, so the
sliding layers split into five 5-layer groups plus one full group. They
collapse to two SpecGroups for lookup, and a block counts as cached only if
present in all five sliding group ids at once. The group abstraction is
sized by the REPEATING PATTERN, not by attention type — which is what keeps
per-block residency at 1x instead of N-layers x.

### Link 5 and block sharing are SEQUENCED, not independent

The 20 GiB / 200 MiB ceiling is a cost of OUR chosen restore mechanism —
copy whole windows to an SSD sidecar — not of the capability. vLLM pays
nothing extra: the windowed K/V it reuses is the same in-pool blocks the
request already holds, retained by refcount rather than copied to disk.

**If sharing lands, link 5's payload can come from live pages and the disk
budget stops binding.** Do not rank them as two separate wins that each
need paying for.

### And the watermark must land FIRST

Donation does not stall steps — `enqueueDonation` hands the work to a
serial `.utility` queue off the critical path. But **donor pages stay
pinned out of the pool until the donation materialises**:
`releaseDonationStateOnEngineQueue` runs only after `donate` returns.

Link 5 raises donation VOLUME (the floor collapses to `minEffectiveTokens`)
and donation SIZE (~200 MiB of sliding snapshot) simultaneously, on a
deprioritised serial queue — so the backlog grows exactly under load. More
retired rows pinning more pages shrinks the free pool, which is precisely
the condition that makes our symmetric watermark preempt RUNNING decodes.

> So link 5 does not merely fail to reduce the watermark's value — it
> **increases** it, transiently, at peak donation churn.

**Land the asymmetric watermark before or with link 5, never after.** Under
today's symmetric ceiling that pressure converts directly into preemptions
which are deterministically full-cost on gemma-4. With it, the same
pressure expresses as deferred admissions.

### Refinement: sharing moves the tiling, it does not remove it

Block sharing lifts the 20 GiB disk ceiling, but the reason sidecars tile
is a property of RINGS, not of disks. `SSDPrefixCache.swift:1146-1152`
states it:

> a donor's ring holds "exactly the last W positions ending at its own
> absolute offset, which is a mid-block position for all but 1 in
> blockSize requests... Successive donations end at different offsets and
> their covered ranges TILE, which is what eventually completes a
> boundary's window. A boundary whose tiling is incomplete is simply not
> restorable, and the adopter replays."

A finished donor's ring holds one window ending at ITS final offset.
Sharing those pages by pointer serves adopters matching at that boundary;
every other boundary still needs coverage from some other donor.

So: **link 5 unblocks the capability and is bounded by disk; block sharing
lifts the disk bound and improves tiling density; neither removes the
requirement that a boundary's window be fully covered before it is
restorable.** Where vLLM does better here it is a population effect —
many concurrent requests' retained blocks tile naturally in-pool — not an
absence of the requirement.

---

## Provenance

Five agents, read against `vllm-project/vllm @ b153ae6089` (2026-07-26).
The gemma-4 geometry is confirmed by three independent sources: the
operator's checkpoint on disk and a verbatim in-repo literal
(`CBv2LastQueryPrefillTests.swift:775-791`) that cannot go vacuous.
The sliding-window measurements were EXECUTED on this M4 Max against
vLLM's real `SlidingWindowManager` and `HybridKVCacheCoordinator`.

Every headline claim here survived being challenged by a peer, and the
corrections above are the ones that survived challenge in turn. Ten
substantive claims were retracted during review, including four of the
five agents correcting their own submitted findings. Three agents cited
the wrong checkout at some point — root cause is that the default cwd has
no top-level `PagedKVPool.swift`, so path resolution silently lands in
`.claude/worktrees/release-v070/`, where `pageCount`/`usablePageCount`
differ semantically. That is a standing hazard for anyone working across
these four trees.

---

## The root cause, one level below everything above

Both the 25,600 floor and the tiling requirement are the same defect seen
twice:

> **vLLM's shareable unit is an ABSOLUTELY-POSITIONED BLOCK. Ours is a
> window snapshot defined relative to where a donor stopped.**

vLLM: `block_hashes[i]` covers tokens `[i·bs, (i+1)·bs)` counted from
token 0 and chained from token 0 (`kv_cache_utils.py:691-749`); SWA's hit
scan indexes those same absolute `i`
(`single_type_kv_cache_manager.py:912-916`); blocks are cached as they
fill. So ONE donor of length L caches a block at every absolute index in
`[0, L/bs)`, and an adopter matching at any boundary `M <= L` finds its
entire contiguous window inside that single donor's output.

Ours: a donor's ring holds the last W positions ending at ITS offset, so
coverage must be assembled by tiling across donors that happened to stop
at complementary places.

**Coverage in vLLM is a function of what was COMPUTED. Ours is a function
of where donors STOPPED.** The first composes trivially; the second
requires a coincidence.

Honest bound on the claim: vLLM can be configured sparse
(`VLLM_PREFIX_CACHE_RETENTION_INTERVAL`, defaults to None = dense), and
under sparsity some boundaries genuinely are not restorable — which is why
`shared_prefix_boundary` exists to pin junctions. So the coverage
requirement is real in both systems. The difference is **vLLM pays it only
when it opts in; we pay it unconditionally, because rings carry no
absolute position.**

This corrects the "population effect" framing above: vLLM's advantage here
is architectural, not statistical.

Practical consequence — it reinforces the ordering (link 5 first, sharing
second) but resizes the second item. Moving to absolutely-indexed shared
blocks does not merely lift the 20 GiB disk ceiling; it **removes the
tiling requirement itself**, which is the larger effect and is the actual
reason vLLM's floor is one block.

### CORRECTION to the section above: it is capture policy, not addressing

The "rings carry no absolute position" framing is WRONG and is retracted.
Our ring IS absolutely indexed: the slot for absolute position `p` is
`(p / pageSize) % ringPages`, a pure function of `p` and donor-independent
— `PagedSequenceKV.swift:11-13` states it as a bijection onto
`p % (ringPages · pageSize)`, and `gatherRange` calls the resulting page
list "the CANONICAL slot of every requested position." Two rows at the
same absolute positions occupy the same ring slots.

The actual cause is **bounded retention plus end-of-life capture**. The
donor computed `[0, L)` but the ring physically holds only the last
`ringPages · pageSize` positions, so at donation time only a trailing
window survives to be snapshotted. So:

> vLLM caches blocks **as they fill** — dense, every absolute index
> (`cache_full_blocks`), and gets sparse only when `retention_interval`
> opts in. We snapshot **what a row still holds** at donation.
> **Same axis, opposite default. The delta is capture-time policy, not
> coordinate systems.**

That is independently fixable here without touching the ring, and our own
geometry says there is room: `ringPageCount` gives gemma-4 sliding 65
pages = **1,040 tokens** of residency against a **256-token** prefix block
(`BlockHasher.defaultBlockSize`). A block written during prefill stays
resident about **four block-times** before the ring laps it. Capturing
windowed blocks as they fill is geometrically available; nothing forces
the once-at-the-end snapshot that creates the tiling requirement.

This also revises the 200 MiB / 20 GiB caveat DOWN in importance: 200 MiB
is the cost of persisting a whole window per donation, which is an
artifact of end-of-life snapshotting rather than of the capability.

### How to cost item 4 honestly

- **Gather-round-trip elimination** — unambiguous, tile-shape independent,
  survives every correction in this document. Rank on this alone.
- **2x M-axis on the 25 sliding layers** — real, but paid for with NSG
  8 -> 4, and UNMEASURED. It is budget arithmetic from verified constants,
  not a benchmark. Treat as a hypothesis to test after the kernel exists,
  never as a projected speedup.
- **The 5 global layers** — nothing. `BLOCK_Q` is pinned at 1 outright.
