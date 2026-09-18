# Gemma 4 26B-A4B Inference Optimization — Plan, 2026-08-03

> Last updated: 2026-09-03 · commit `5d400cf75`

Status: **Proposed** — 2026-08-03 — none of §7's ten decode items or §8's prefill items is in the engine: decode still runs the 2-slice `temporalOrder` concat (`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/SequenceKV/WindowedSequenceKV.swift`), `SwitchLayers.swift` passes no `lhsIndices`, and `prefillChunkSize` keeps its pre-plan default ([`../architecture/inference.md`](../architecture/inference.md#scheduler-and-loop-configuration)); the Gemma work that shipped in v0.8.2 (`[gemma_optimizations]`, `CHANGELOG.md`) is a different item set.

Plan derived from a full op-level profile of the MLX decode and prefill paths for
`gemma-4-26b-a4b`, measured on an M4 Max (`applegpu_g16s`, GPU gen 16, 128 GB
unified, ~546 GB/s).

Method: a faithful 30-layer MLX replica using **real shapes and real quantized
weight tensors** (15.1 GB resident, distinct weights per layer), min-of-N-reps
timing, plus ten parallel investigations that prototyped and benchmarked real
Metal kernels via `mx.fast.metal_kernel`.

Everything here is either measured or arithmetic on measured numbers. Inferred
values say so. **Seven analytic predictions were falsified by measurement during
this work, five of them our own** — they are listed in §7 because re-deriving
them is expensive.

Baseline: replica B=1 decode = **11.54 ms = 87 tok/s** (4-bit). The shipping
Swift engine on the 8-bit checkpoint measures 67 tok/s at B=1 and 86 aggregate
tok/s at B=4 (decode-only), which is consistent: the CBv2 engine adds only
**0.43 ms (3%)** over raw MLX at B=1.

---

## 1. Summary

| | today | after this plan | physics floor |
|---|---:|---:|---:|
| B=1 | 11.54 ms / 87 tok/s | **7.70 ms / 131 tok/s (1.50x)** | 4.66 ms / 215 tok/s (2.48x) |
| B=4 | 20.91 ms / 191 agg | **6.90 ms / 579 agg (3.03x)** | ~6.9 ms (floor-limited) |
| real engine, 8-bit | 67 / 86 agg | **~100 / ~262 agg** | |
| prefill TTFT | 2048-tok prompt | **-17.5%** | ~1.6x cap |

B=4 is **floor-limited**: the naive sum of wins (3.84 ms) falls below what weight
traffic permits, so the floor is reported instead. B=1 lands at 7.70 ms, above
its 4.66 ms floor, so that win list is internally consistent.

---

## 2. The physics — three measured laws

Every item in this plan derives from these. Anything violating them was cut.

### Law 1 — Weight traffic sets the floor

Decode is weight-stationary. 2.42 GB/token at 4-bit against 546 GB/s gives a
**hard floor of 4.66 ms** at B=1. Measured 11.54 ms, so 6.88 ms is recoverable.

| | 4-bit ckpt | 8-bit ckpt |
|---|---:|---:|
| attention | 624.5 MB (26%) | 1179.6 MB (29%) |
| dense MLP | 568.7 MB (23%) | 568.7 MB (14%) |
| MoE top-8 | 802.9 MB (33%) | 1516.6 MB (37%) |
| router | 11.5 MB (0.5%) | 11.5 MB |
| LM head | 415.2 MB (17%) | 784.3 MB (19%) |
| **total** | **2.42 GB/tok** | **4.06 GB/tok** |

**Corollary: reducing bytes-per-token beats reducing overhead, because it moves
the floor itself.**

### Law 2 — Serial dispatches cost 3x independent ones

Measured with **distinct** input buffers (ruling out read-read barrier elision at
declared-buffer granularity):

| pattern | marginal us/op |
|---|---:|
| `rms_norm`, serially dependent | **3.01** |
| `rms_norm`, independent, same buffer | 1.048 |
| `rms_norm`, independent, distinct buffers | **1.040** |
| `multiply`, serially dependent | 1.985 |
| `multiply`, independent | 1.534 |

MLX issues independent work concurrently into one command buffer. Triangulated
three ways: the direct probe above; the router block in production (0.80 ms of
pure launch / 240 strictly-serial dispatches = **3.33 us**); and 25 SDPA calls
timed as independent (379 us) versus the same 25 layers inside the real forward
(**2.2x** more).

**Corollary: fuse chains, never fan-outs.** Q/K/V projections, dense gate+up, MoE
gate+up and the h1/h2 branches are mutually independent and already free. Fusing
them measured *negative*.

### Law 3 — `affine_qmv` replicates the weight read across the batch

`libs/mlx/mlx/backend/metal/quantized.cpp:251-254`:

```cpp
int bn = 8;  int bk = 32;
MTL::Size group_dims(bk, 2, 1);
MTL::Size grid_dims(M, (N + bn - 1) / bn, B);   // <- M is grid dimension x
```

`quantized.h:786-806` offsets `x` and `y` by `tid.x` but the weight pointer `ws`
has **no `tid.x` term**, and the only loop is over K. So M threadgroups each
stream the entire weight. There is no M loop in the kernel.

Measured per-row cost as a percentage of M=1, four shapes:

| shape | MB | M=1 | M=2 | M=4 | M=8 |
|---|---:|---:|---:|---:|---:|
| lm_head 262144x2816 4b | 415.2 | 100% | 68% | 59% | 55% |
| q_proj 4096x2816 4b | 6.5 | 100% | 67% | 57% | 56% |
| mlp_gate 2112x2816 8b | 6.3 | 100% | 72% | 56% | 52% |
| mlp_down 2816x4096 4b | 6.5 | 100% | 76% | 61% | 58% |

True weight-stationarity would be 12.5% at M=8. The plateau at 52-59% is
**accidental L2/SLC reuse between launch-adjacent threadgroups**, and it
saturates at M=2. It is uniform across shapes, so it is structural, not a
cache-size effect.

**Corollary: B>1 currently pays ~4.4x more weight traffic than physics requires.**
This is why B=4 yields only 11% more aggregate throughput than B=1.

### The resulting cost model

```
t = 4.66 ms (bandwidth)  +  2.0-2.5 ms (launch)  +  4.4 ms (kernel quality)  =  11.54 ms
```

---

## 3. Measured operation inventory

### Decode, B=1, ctx=512 — 1510 dispatches/token

Census verified two ways: code-derived from `Gemma4Text.swift`, and counted from
`mx.export_to_dot` on a faithful replica with view-primitives classified out.
The two agree exactly.

| component | ms | % step | roofline ms | efficiency | dispatches |
|---|---:|---:|---:|---:|---:|
| attention (30L, incl. SDPA) | 3.35 | 29.1% | 1.35 | 40% | ~600 |
| — SDPA only | 1.15 | 10.0% | 0.21 | **18%** | 85 |
| — **ring KV plumbing** | **1.55-1.64** | **13.4%** | 0 | — | 100 |
| dense MLP (30L, 8-bit) | 2.06 | 17.9% | 1.04 | 51% | 210 |
| router (30L, 8-bit) | 0.82 | 7.1% | 0.02 | **3%** | 240 |
| **MoE experts (30L, 4-bit)** | **3.92** | **34.0%** | 1.47 | 38% | 180 |
| LM head + sampling tail | 1.38 | 12.0% | 0.76 | 55% | 3-70 |
| **TOTAL** | **11.54** | 100% | **4.66** | **40%** | **1510** |

Per sliding layer (25 of 30): **50 dispatching nodes** — 11 RMSNorm, 8
QuantizedMatmul, 3 GatherQMM, 4 Add, 4 Multiply, 3 Arange, 2 RoPE, 2 SliceUpdate,
2 AsType, 4 Compiled, and one each of SDPA / ArgPartition / GatherAxis / Softmax
/ Gather / Sum. Full layers (5 of 30): **52** — no `v_proj` (`attention_k_eq_v`),
and a composed 12-op SDPA replaces the single fused one.

### Attention fusion matrix (verified by graph dump)

MLX gates fused SDPA on head dim
(`mlx/backend/metal/scaled_dot_product_attention.cpp:621-626`): `sdpa_vector`
(L<=8) supports {64, 96, 128, 256}; `sdpa_full` (L>8) supports {64, 80, 128}.
Gemma 4 uses 256 (25 sliding layers) and 512 (5 full layers).

| path | head dim | result |
|---|---:|---|
| decode, sliding | 256 | **FUSED** — 1 primitive |
| decode, full | 512 | **COMPOSED** — 12 ops |
| prefill, sliding | 256 | **COMPOSED** — 22 ops |
| prefill, full | 512 | **COMPOSED** — 22 ops |

Isolated cost, ctx=512, B=1: 25 sliding layers = 379 us (51% of KV roofline,
15.2 us/layer); 5 full layers = 141 us (**14%**, 28.2 us/layer). A full layer
costs 1.86x a sliding layer while moving 0.10x the KV bytes.

### Prefill, 512-token chunk — the inversion

Prefill is **compute**-bound and already at 62% of the real GEMM roofline.
Measured M4 Max peak is **14.6 TFLOP/s** at 8192^3 bf16 — not the 34 TFLOP/s
commonly assumed. That caps the total prefill win at ~1.6x.

| component | ms | ms/token | % chunk | TFLOP/s | vs decode % |
|---|---:|---:|---:|---:|---|
| **MoE experts** | 189.3 | 0.370 | **53.1%** | 7.7 (52%) | 34% -> **53%** |
| attention | 110.9 | 0.217 | 31.1% | 11.1 (75%) | 29% -> 31% |
| dense MLP | 48.5 | 0.095 | 13.6% | 11.3 (76%) | 18% -> 14% |
| router | 6.6 | 0.013 | 1.9% | 1.7 (11%) | 7.1% -> **1.9%** |
| LM head (1 row) | 1.0 | 0.002 | 0.3% | — | 12% -> **0.3%** |
| **TOTAL** | **356.3** | **0.696** | 100% | **9.13 (62%)** | |

0.696 ms/token prefill vs 11.54 ms/token decode = **16.6x cheaper per token**.
Router and LM head were pure overhead and amortize away; MoE becomes dominant.

---

## 4. Tier 1 — free wins: no new kernels, no numerics risk

Combined: **1.59 ms at B=1 (13.8%), 5.52 ms at B=4 (26.4%)**.

### 1.1 Remove the decode ring rotation — 0.94 ms / 3.60 ms

**Mechanism.** Softmax attention over an unmasked key set is invariant under a
joint permutation of (K, V): `softmax(qK^T)V == softmax(qK^T P^T)PV`. At decode
`L == 1` the mask is `.none` (`AttentionV1.swift:68`), and MLX independently
forces `do_causal &= q.shape(2) > 1`
(`scaled_dot_product_attention.cpp:746`). RoPE is applied **before** `update()`,
so ring slot order carries no positional meaning. The rotation therefore computes
nothing.

It costs a full 16.8 MB copy (K + V) per layer per step, on 1023 of every 1024
steps once the sequence exceeds the window. Measured **0.94 ms/token at 82% of
peak bandwidth** — i.e. genuinely a full copy. Permutation error measured
**exactly 0.0** at rotations 1, 383 and 1023.

**Change** — `WindowedSequenceKV.swift:147-150`, decode `n == 1` path only:

```swift
// Attention at L == 1 is unmasked (AttentionV1.maskMode -> .none), so softmax
// over the retained window is invariant to key order. Skip the 2-slice concat
// of both K and V.
//
// GATE: only legal once the ring is FULL. Pre-wrap the buffer still holds
// zero-initialised slots (allocateIfNeeded, :518-521) which, under mask .none,
// receive softmax weight e^0 and dilute the output. Pre-wrap temporalOrder
// already returns a single view (ringSlices case 1), so nothing is lost there.
if absoluteOffset - oldestValidPosition == window {
    return (keys!, values!)
}
return (temporalOrder(keys!,   from: oldestValidPosition, to: absoluteOffset),
        temporalOrder(values!, from: oldestValidPosition, to: absoluteOffset))
```

**Why the gate is mandatory.** `allocateIfNeeded` zero-fills the full
`[1, kvHeads, window, D]` ring. An ungated raw return hands SDPA those zero slots.
Measured dilution:

| retained | zero-key softmax mass | max rel err |
|---:|---:|---:|
| 16 | **97.7%** | 0.99 |
| 64 | 90.6% | 0.92 |
| 256 | 64.9% | 0.68 |
| 512 | 37.7% | 0.40 |
| 1023 | 0.1% | 0.15 |
| **1024** | **0.0%** | **0.000** |

A short prompt would be near-total garbage, and the symptom **vanishes past 1024
tokens** — a failure mode that survives a smoke test. The gate must be strict
equality; even one empty slot (retained = 1023) is not exact.

`snapshot()` (`:330-331`) must keep rotating — prefix-cache export needs true
temporal order. The prefill branch (`:153-178`) must keep its concat — there
`L > 1` and the mask is causal, so order matters.

**Tests.** Assert bit-identity against the rotated path at retained == window,
and assert the gated (rotating) path is taken for every retained < window.

### 1.2 Pass `lhsIndices` to `gatherQuantizedMM` — ~0 / 0.56 ms

When `lhs_indices` is nil MLX synthesises `Arange + Reshape + Broadcast`. At M=1
every row reads `x[0]`, so a cached `zeros([B,K], .uint32)` is semantically
identical — verified bit-identical output. Removes **90 dispatches/token** of
pure artifact. Worth ~0 at B=1 (independent ops, Law 2) but 0.56 ms at B=4.
Three lines in `SwitchLayers.swift:356-377`.

### 1.3 Dense MLP uses the fused GeGLU — 0.16 ms

The expert path already fuses `gelu(gate) * up` via `compiledGeGLU`
(`SwitchLayers.swift:83`); the dense path at `Gemma4Text.swift:898` does not,
spending two serial dispatches where one suffices. `gelu -> multiply` is a real
dependency chain, so by Law 2 it pays full latency.

### 1.4 Precompute `scale * rootSize`; hoist the position-offset snapshot

`Gemma4Router` recomputes `scale * hiddenSize^-0.5` on a `[2816]` constant every
layer every step — 30 wasted dispatches/token; move to `init`. At decode every
layer advances by exactly 1 from the same absolute positions, so 30 identical
`positionOffsets + 0` copies collapse to one per step. **Guard: decode-only.**
Prefill, KV-shared source layers and last-query prefill must keep per-layer
snapshots (`forwardV2:749-753`).

Below noise at B=1; 0.22 ms at B=4.

---

## 5. Tier 2 — move the floor: fewer bytes per token

### 2.1 Requantize the dense MLP 8-bit -> 4-bit — 0.49 ms / 1.20 ms

The dense MLP is `3 x 2112 x 2816 x 30 = 535M` params. At MLX affine 8-bit gs=64
that is 8.5 bpw = **568 MB/token**; at 4.5 bpw it is 301 MB.
**-267 MB/token = -11.0% of all decode traffic.**

This is pure accounting — no kernel, no cache behaviour, no traffic model. It is
the most reliable number in this document.

The packager chose 8-bit for the dense MLP and router on a **PTQ** checkpoint.
`mlx-community/gemma-4-26B-A4B-it-qat-4bit` exists, where 4-bit weights are what
the model was trained against. Evaluate there.

**Do not requantize the router.** It is 10.8M params (11.5 MB), saving ~5 MB
which is ~0 ms, and top-8-of-128 routing flips on small perturbations. Its 0.82 ms
is 100% dispatch latency (3% of roofline); §6.4 addresses it instead.

**Gate on** perplexity **and** MoE routing-agreement rate versus the 8-bit build,
not perplexity alone.

### Format accounting, for reference

MLX affine 4-bit gs=64 is **exactly 4.500 bpw — byte-identical to ggml Q4_K and
Q4_0** and to TRT-LLM groupwise g64. K-quants spend the same 0.5 bits on
hierarchical 6-bit scales to buy a finer group, not fewer bytes. Layout and
interleaving work therefore moves **zero bytes**. Only genuine format changes cut
traffic:

| change | bpw | traffic delta |
|---|---:|---:|
| dense MLP 8b -> affine 4b gs64 | 8.5 -> 4.5 | **-11.0%** |
| all 4-bit affine -> `Mxfp4` (kernels already in MLX) | 4.5 -> 4.25 | -4.2% |
| all 4-bit -> gs128 symmetric (Marlin-style) | 4.5 -> 4.125 | -6.3% |

---

## 6. Tier 3 — kernel work: close the 4.4 ms quality gap

### 3.1 Batched-M quantized GEMV — highest-value kernel, 4.20 ms at B=4

**Mechanism.** Law 3. Delete M from the grid:
`grid = (32, NSG * ceil(N / (R * NSG)), 1)`, one threadgroup per output-row tile
serving **all** M rows, with M a compile-time template arg and an in-register
loop. Weight DRAM traffic drops M-fold.

**The subtlety that decides success.** At M=4, hoisting only the *load* leaves
the kernel at **144% of the ALU issue budget** (12 ops/weight x 970 G weights/s =
11.6 T instr/s against ~8.1 T/s available) — zero relief, and it will read as a
failed experiment. The **dequant** must be hoisted out of the M loop as well:

| design | ops/weight | instr rate | % of budget |
|---|---:|---:|---:|
| today, nothing hoisted | 12 | 11.6 T/s | 144% |
| hoist LOAD only | 12 | 11.6 T/s | **144%** |
| hoist LOAD + DEQUANT, scalar | 6 | 5.8 T/s | 72% |
| hoist LOAD + DEQUANT, `half2` | 3.5 | 3.4 T/s | **42%** |

Two-wide unpack in MSL, no `lop3` needed (Marlin's mantissa trick):

```metal
as_type<half2>((q & 0x000F000Fu) | 0x64006400u) - half2(1024.0h)
```

The weight must land in a `uint2`/`uint4` **register** before the M loop. Keeping
`qdot`'s `const device uint8_t* w` signature re-issues the load per row and
reproduces current behaviour exactly — a register-operand overload is mandatory.

Measured prototype: **1.78x at M=4** (load-hoist alone gave 1.63x). Implement
`half2` from the start.

This single kernel multiplies attention projections, dense MLP, router **and**
the LM head — ~1.6 GB of the 2.42 GB/token.

Instantiate `CtaM` in {1,2,3,4} only; the engine caps concurrency at 4 and
activation registers grow linearly.

### 3.2 In-place ring slot write — 0.83 ms / 3.30 ms

`buffer[range] = tokens` is an MLX slice-update whose buffer donation fails
because `gpu::eval` retains input handles until the command buffer completes — so
it copies the whole 4.19 MB ring instead of writing 2 KB. Measured overhead is
almost exactly one full K+V copy at 90-100% of peak.

Fix with a small Metal kernel writing in place through a `const_cast device`
pointer. **The pattern already ships in this repo** —
`pagedattention.metal:87-114`, including its single-writer-per-byte safety
argument. Medium implementation risk, existing precedent.

### 3.3 MoE 2-kernel fusion — 0.76 ms / 1.81 ms

The expert path is a 4-stage serial chain per layer (gate||up -> GeGLU -> down ->
weighted-sum) across 6 dispatches / 20 graph nodes. Collapse to two kernels:

- **K1** = gather(gate, up) + GeGLU -> `a[T, K, 704]`
- **K2** = gather(down) + router-weighted sum -> `out[T, H]`

Measured **1.20-1.29x** for T = 1..64. Bit-layout-identical 4-bit affine dequant,
rel err 1.0e-3..1.5e-3 (fp16 eps).

Attribution matters: only ~7.6 us of the 21 us/layer saving is dispatch
reduction. The other ~13 us is **kernel quality** — the measured +31-37% gather
tax (dense 25.7 us / gather-adjacent 29.4 / gather-random 34.5 at identical bytes
and threadgroup count) plus the two elementwise passes K1/K2 absorb.

**Gate off above T ~= 100.** It measures 0.39x at T=512 where `gather_qmm_rhs`
amortises. That is prefill's regime.

### 3.4 Fused router top-k — 0.25 ms / 1.17 ms

The router is a **strictly serial 8-dispatch chain** (rmsNorm -> proj ->
argPartition -> slice -> takeAlong -> softmax -> gather -> multiply) moving
11.5 MB. 0.02 ms of bandwidth costing 0.82 ms: by Law 2 that is 240 serial
dispatches at ~3.3 us. The purest launch-latency victim in the model.

Design: one simdgroup per token, `grid = (T*32, 1, 1)`, **zero threadgroup
memory**, ~24 registers. Each lane holds `128/32 = 4` scores at coalesced
`ix = lane + j*32`; 8 rounds of `simd_max(best)` then
`simd_min(best == gmax ? bi : 0xffffffff)` for tie-broken argmax; the owning lane
masks its slot to `-INF`. Descending order means `selv[0]` is the softmax max for
free. 16 simd reductions, no barriers.

Measured **14.30 -> 3.16 us/layer**. Index sets bit-identical to
`argPartition + slice + takeAlong`; max weight delta 6.1e-5. Bonus: output order
becomes deterministic descending, strictly better than `argPartition`'s
unspecified intra-partition order (the expert sum is order-independent).

Requires `numExperts % 32 == 0` and `topK <= 32`; gate at construction with an
eager fallback.

### 3.5 Fused radix-select sampler — 0.26 ms / 0.70 ms

The projection is **irreducible**: 824 us at 92% of peak. A hand-written fused
projection+argmax kernel measured *negative* across 24 configurations. The win is
the tail.

Measured tail breakdown at B=1 (in-graph us, 415 MB weight resident):

| stage | us | nodes |
|---|---:|---:|
| projection qmv 415 MB M=1 | 808.9 | 1 |
| softcap `tanh(x/30)*30` -> fp32 | 9.8 | 1 |
| repetition penalty | 19.4 | 10 |
| frequency + presence | 18.9 | 9 |
| **argSort(262144) alone** | **114.1** | 2 |
| `applyTopKTopPMinP` total | 330.9 | 23 |
| SamplerV2 mixed (gumbel) | 47.1 | 24 |
| **reference top-p tail** | **390.6** | **50** |
| **fused replacement** | **130.5** | **6** |

Top-p needs only the top k (typically <= 64), not a total order over 262144.
Replace the argsort pipeline with a fused radix-select. Measured
**361.7 -> 103.7 us at B=1 (3.49x)** and **897.8 -> 197.3 us at B=4 (4.55x)**.
Roughly two-thirds of the saving is dispatch collapse (a ~50-node strictly serial
chain), one third is removed work.

Greedy decoding needs only `argmax`, and `tanh(x/30)*30` is monotonic, so the
softcap can be **skipped entirely** for greedy.

Contract change: any code reading full logits (top-k/top-p, logprobs,
speculative verification) needs an explicit fallback path.

### 3.6 Fused FFN combine and D=512 split-K decode — 0.15 ms / 0.37 ms

The layer tail (`h1 + h2 -> norm -> + residual -> * layer_scalar`) is 6 serial
ops -> 1 kernel; measured 10.37 -> 4.85 us/layer. Numerics measured *better* than
the eager fp16 path against an fp32 reference (2.83e-3 vs 3.86e-3 at T=1).

The D=512 split-K decode kernel is worth ~1.2x on 5 layers: 0.3-1.0% of the step
at short context, growing to ~11% at 32k. Use HPT=2 / NSG=4 / PTOK=256 with
**q_smem in bf16** (18496 B of the 32768 B cap) — that single dtype choice moved
the same configuration from 0.93x to 1.25x, the largest tuning effect found.

Note the D=512 exclusion is **purely a missing template instantiation** —
threadgroup memory in `sdpa_vector` is D-independent at 4352 B — but shipping the
one-line instantiation alone measures **0.79-0.87x**. See §7.

---

## 7. Cumulative effect

| stage | B=1 | B=4 |
|---|---|---|
| baseline | 11.54 ms / 87 tok/s | 20.91 ms / 191 agg |
| + Tier 1 (free) | 9.95 ms / 100 tok/s — **1.16x** | 15.39 ms / 260 agg — **1.36x** |
| + Tier 2 (bytes) | 9.46 ms / 106 tok/s — **1.22x** | 14.19 ms / 282 agg — **1.47x** |
| + Tier 3 (kernels) | **7.70 ms / 131 tok/s — 1.50x** | **6.90 ms / 579 agg — 3.03x** |
| physics floor | 4.66 ms / 215 tok/s — 2.48x | ~6.9 ms |

Per-item, de-duplicated:

| # | win | B=1 ms | B=4 ms | evidence |
|---|---|---:|---:|---|
| 1.1 | Remove decode ring rotation | 0.94 | 3.60 | measured twice, independently |
| 3.2 | In-place ring slot write | 0.83 | 3.30 | measured |
| 3.1 | Batched-M quantized GEMV | — | 4.20 | measured prototype |
| 3.3 | MoE 2-kernel fusion | 0.76 | 1.81 | measured prototype |
| 2.1 | Dense MLP 8 -> 4 bit | 0.49 | 1.20 | accounting; QAT ckpt exists |
| 3.4 | Fused router top-k | 0.25 | 1.17 | measured prototype |
| 3.5 | Fused radix-select sampler | 0.26 | 0.70 | measured prototype |
| 1.3 | Dense GeGLU single kernel | 0.16 | 0.16 | measured |
| 3.6 | FFN combine + hoists + D=512 | 0.15 | 0.37 | measured |
| 1.2 | `lhsIndices` on gatherQMM | ~0 | 0.56 | measured |

---

## 8. Prefill

Prefill is compute-bound at 62% of the real 14.6 TFLOP/s roofline, so the total
available win is ~1.6x. Three measured items, **-17.5% TTFT** on a 2048-token
prompt:

| change | TTFT delta | effort |
|---|---:|---|
| chunk size 512 -> 1024 | **-10.1%** | config one-liner |
| per-expert segmented MoE tile scheduler | -7.1% | real kernel work |
| query block 128 -> 256 | -1.0% | one-liner |

**Chunk size** interacts with decode ITL for co-scheduled requests — that is what
`mixedStepPrefillTokenCap` (`DARKBLOOM_CBV2_MIXED_PREFILL_CAP`) exists for. Larger
chunks improve MoE and matmul efficiency but lengthen the mixed forward that a
decoding request waits behind.

**Segmented MoE scheduler**: `gather_qmm_rhs`'s 16-row tile issues a full matmul
per *distinct expert present in that tile*
(`libs/mlx/mlx/backend/metal/kernels/quantized.h:2329-2360`), a padding inflation
of roughly `1 + 16E/R`. Grouping rows so each tile holds one expert removes it.

---

## 9. Rejected — measured negatives

Building any of these would waste effort. All measured on this hardware.

| rejected | measured result |
|---|---|
| Flash prefill kernel | **0.22-0.37x**, two independent lines. Break-even needs BQ* = 47-171; Apple's 32 KB caps BQ at 24-32 |
| D=512 `sdpa_vector` one-line instantiation | 0.79-0.87x — it *is* only a missing template, and it loses (16 threadgroups at B=1) |
| HPT=8 token-partitioned attention | 0.29-0.50x — `acc[8][16]` = 128 f32/lane spills |
| Split-K for starved GEMVs | 0.29-0.67x — makes calls smaller and more numerous |
| `mx.compile` for dispatch reduction | 53 -> 47 nodes, **1.02x**. Fuses only pure-elementwise runs; Gemma 4 has none between fast primitives |
| Fusing Q/K/V, dense gate+up, tri-RMSNorm | Law 2 — independent, already overlapping. Measured **losses** (tri-RMSNorm +2.4 us) |
| `postAttentionLayernorm + residual` fusion | neutral (4.27 -> 4.33) — only 2 ops, custom kernel fixed cost eats it |
| Padding K to 512 multiples | zero separation (2.02/2.00/1.79/1.90 us/MB fast/slow/fast/slow) |
| Fused LM-head projection + argmax | negative across 24 configurations |
| Vocabulary pruning | negative |
| Single-dispatch full MoE fusion | 1.6-2.4x slower — grid collapses to T*K = 8 threadgroups |
| Removing the MoE sort / 8x replication | slower at every T. The `indices.size >= 64` threshold is correct |
| Steel BD=256/512 prefill instantiation | projected 1.03x, 2.3 us/token |
| Router split-K | budget closes to within noise with the correct serial dispatch rate; nothing to recover |
| Requantizing the router | 5.4 MB saved ~= 0 ms, and routing is precision-sensitive |
| 8-bit `qdot` byte-load fix | large-call 8-bit measures 91% of peak vs 4-bit's 95% — the byte-load path is fine |

### Falsified analytic predictions

Recorded because re-deriving them is expensive. **Five of seven were our own.**

| prediction | reality |
|---|---|
| 3.9 us/dispatch | 2x too high — was timing host graph construction, not GPU launch |
| 8x GQA redundancy in composed SDPA | **zero**. MLX broadcasts K/V (`fast.cpp:728-731`) — it already does the FA2 group-swap trick. Confirmed: pre-expanded KV is 3.5x *slower* |
| SDPA layout-copy penalty from transposed Q / strided ring KV | zero. `q_copy_unless`'s `shape[0]==1` escape covers B=1 |
| `K % 512` fast-path gate costs performance | zero. Source fact is true; performance inference false |
| ">= 1400 threadgroups" as root cause | not causal. At fixed bytes, 8x more threadgroups is slightly *worse* |
| Additive fixed cost per call | falsified 3.7x. 17.3 us is a low-bandwidth *ramp*; eight concurrent 4.46 MB calls reach 360 GB/s jointly |
| Paged kernel's 4x KV over-read | real instruction duplication, but ~2.3x realised — largely SLC-served |

**Pattern: every analytic *traffic* model over-predicted.** Instruction counts,
threadgroup-memory budgets and resident-byte capacity claims did not. Phrase
claims as "issues N instructions" or "occupies N bytes" where possible.

---

## 10. Verification protocol

1. **Measure ratios against a same-session baseline.** Absolutes drift 10-20%
   under GPU contention; a ratio measured back-to-back does not.
2. **Anchor every run** to a known idle reference (LM-head qmv M=1 = 824 us) and
   state the anchor ratio in the result.
3. **A non-monotonic curve means contention, not a discovery.** Discard and re-run.
4. **Bound every projected win by the physics floor** before reporting it. The
   B=4 win list sums below its floor, which is how the over-count was caught.
5. **Distinguish "moves N MB" from "occupies N bytes" / "issues N instructions."**
   The first class over-predicted every time on unified memory with a large SLC.
6. **Do not infer kernel inefficiency by subtracting a launch estimate** from a
   measured block without first establishing the chain's serial depth. Two
   separate wrong conclusions in this investigation came from exactly that move.

---

## 11. Reference — verified model configuration

From `mlx-community/gemma-4-26b-a4b-it-4bit`, cross-checked against the
safetensors index. Two fields differ from the code defaults and disable large
parts of `Gemma4Text.swift`:

```
30 layers = 25 sliding + 5 full (5 sliding : 1 full, repeated)
hidden 2816, 16 query heads
  sliding: head_dim 256, 8 KV heads (GQA 2:1), window 1024, RoPE theta 1e4, has v_proj
  full:    head_dim 512, 2 KV heads (GQA 8:1), unbounded KV, RoPE theta 1e6,
           partial_rotary_factor 0.25 (128 of 512 dims rotated, single fused
           MLXFast.RoPE with +inf frequency padding)
           attention_k_eq_v = true -> NO v_proj; V is the raw pre-norm K projection
EVERY layer runs a dense MLP (inter 2112) AND a 128-expert top-8 MoE (inter 704),
  summed into one residual -- not either/or
vocab 262144, tied embeddings, final softcap tanh(x/30)*30

hidden_size_per_layer_input = 0   -> PLE path DEAD on this checkpoint
num_kv_shared_layers        = 0   -> KV sharing DEAD on this checkpoint
use_double_wide_mlp         = false

quantization: affine 4-bit gs=64, EXCEPT dense mlp {gate,up,down}_proj and
              router.proj at 8-bit gs=64
25.2B params, 3.81B active/token, 14.5 GB resident at 4-bit
```

The PLE and KV-sharing machinery in `Gemma4Text.swift` is fully inert for this
checkpoint. Do not reason about it when profiling 26B-A4B.

Serving path: CBv2 is the only engine; `case .auto: resolvedKind = .contiguous`
(`EngineV2Factory+Production.swift:346`), so production uses
`CBv2ContiguousKVBackend` and attention goes through
`MLXFast.scaledDotProductAttention`. The paged D=512 Metal kernel exists and is
correct but is an explicit experimental opt-in.
