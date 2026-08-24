# 026 — Independent roof: gathered W4 QMM is necessary, not sufficient

Status: **analysis + experiment plan; no code and no new Mac measurements**

Scope: Qwen 3.6 35B-A3B **text** prefill on the M3 Max through the real
ContinuousBatchingV2 path. I read `GOAL.md`, `program.md`, notes 009–023, the
Qwen/GDN/CBv2 Swift path, and the pinned MLX Metal kernels. Measured inputs are
only those already recorded in notes 009, 019, 021, and 023. Everything else is
marked as a source fact, arithmetic consequence, bound, or hypothesis.

Following `program.md`, “reach 2.5× at B=2/B=4” means the equal-length 8K
aggregate cells; 512 and 2K remain mandatory disclosure and non-regression
cells. I also use the measured B=4 2K cell as a short-prompt bound. A stronger
claim of 2.5× at every length would need explicit R0 baselines and bars for
every cell.

## Verdict

The statement “gathered W4 QMM is the only 2× lever” is too strong in two
different ways:

1. At the measured 2,048-token shape, routed gate-up plus down QMM accounts for
   about **0.404 s of a 1.225 s pass, or 33% of wall time**, not 93%. The
   unmeasured residual is 0.821 s. Making routed QMM free while leaving that
   residual unchanged gives only `1 / (1 - 0.33) = 1.49×`.
2. “W4” describes weight storage, not arithmetic precision. The current
   quantized Metal kernel dequantizes into the activation type, then
   `BlockMMA` promotes both matrix operands and its accumulator to **float**.
   The measured 10.2–11.1 TFLOP/s is therefore an FP32-matrix path with W4
   traffic, not an INT4 or BF16 TensorOp. Dense GDN/attention/shared-expert
   projections use the same quantized-matmul family and contain **more FLOPs
   than the gathered routed experts**.

There is no composition of packing, scan work, exact attention, final-layer
narrowing, or graph-overhead deletion that reaches 2.5× while the current
projection arithmetic remains at this ceiling. The official B=4, L=2,048
target is 1.974 s. In one `[4,2048]` pass, all linear projections require
39.923 TFLOP. Even at the generous 1.6-GHz estimate of **16.4 TFLOP/s** for
homogeneous FP32 SIMD-group matrix arithmetic:

```text
39.923 / 16.4 = 2.434 s > 1.974 s
```

That idealized all-linear term alone misses before GDN recurrence, attention,
sort/combine, elementwise work, cache writes, or evaluation overhead. Keeping
the measured routed kernel and granting only the non-routed work the 16.4
TFLOP/s roof is worse: **2.913 s**.

The only arithmetically plausible same-quality composition is:

1. wider safe cohorts (`[2,2048]` and `[4,2048]`);
2. a **precision-preserving mixed-input/FP32-accumulate path for all large
   quantized projections**, dense and gathered, sustaining roughly
   **24–26 TFLOP/s** on this M3 Max;
3. exact tail deletion: prefill-only GDN projection fusion, Qwen final-layer
   last-query/tail narrowing, and exact D=256 online attention if profiling
   justifies it;
4. current kernels retained for decode and any shape where the candidate is
   slower.

Metal 4 MPP can express `bfloat × bfloat -> float` on macOS 26.1+, so this
composition is semantically legal: it can consume the exact BF16 values the
current dequantizer already produces and retain FP32 accumulation. It is **not
yet a performance claim**. M3 is Apple9 and does not have the Apple10/M5
per-core neural accelerator used by MLX’s NAX path. If an exact MPP prototype
does not cross the rate threshold below, 2.5× should be escalated as a hardware
or target mismatch rather than pursued with lower precision or approximate
model semantics.

## 1. Model and FLOP ledger

### 1.1 Architecture used

Source facts:

- hidden width 2,048; 40 decoder layers;
- 30 Gated DeltaNet layers and 10 full-attention layers;
- full attention: 16 query heads, 2 KV heads, head dimension 256;
- MoE in every layer: 256 experts, top-8, routed width 512, shared width 512;
- activation dtype BF16; recurrent SSM state FP32;
- affine W4 group-64 weights on the measured checkpoint, with 8-bit routers;
- LM-head narrowing is already present: intermediate chunks do not project
  vocabulary logits and the frontier projects one row.

### 1.2 Token-linear work

The following counts one multiply-add as two FLOPs.

| Component | Derivation | GFLOP/token |
|---|---:|---:|
| GDN projections, 30 layers | `30 × 2 × [2048×(8192+4096+32+32) + 4096×2048]` | **2.0211** |
| Full-attention Q/K/V/O projections, 10 layers | `10 × 2 × [2048×(8192+512+512) + 4096×2048]` | **0.5453** |
| Routed experts, 40 layers | `40 × 2 × 8 × (2048×1024 + 512×2048)` | **2.0133** |
| Shared experts + scalar gate, 40 layers | three `2048↔512` projections + gate | **0.2518** |
| Routers, 40 layers | `40 × 2 × 2048 × 256` | **0.0419** |
| **All linear work** | | **4.8734** |
| FP32 GDN recurrence | `30 × 7 × (32×128×128)` | **0.1101** |

The important split is not “MoE versus everything.” It is:

```text
gathered routed linear work     = 2.0133 GFLOP/token  (41.3% of linear)
non-routed linear work          = 2.8602 GFLOP/token  (58.7% of linear)
```

GDN projections alone are as large as the entire routed-expert arithmetic.

### 1.3 Exact full-attention work

For one row of length `P`, causal attention visits `P(P+1)/2` query-key pairs.
Each pair costs QK plus AV:

```text
16 heads × (2×256 + 2×256) = 16,384 FLOP/pair/layer
10 layers × P(P+1)/2       = 81,920 × P(P+1) FLOP/row
```

For batch `B`:

```text
F_attention(B,P) = 81,920 × B × P × (P+1)
```

Chunking changes when those pairs execute, but not their total count.

### 1.4 End-to-end work

Ignoring small elementwise FLOPs but not their eventual wall time:

```text
F_total(B,P)
  = B×P×(4.8734208 + 0.11010048) GFLOP
  + 81,920×B×P×(P+1) FLOP
```

| B | P | Linear TFLOP | Scan TFLOP | Attention TFLOP | Total TFLOP | GFLOP/token |
|---:|---:|---:|---:|---:|---:|---:|
| 1 | 512 | 2.495 | 0.056 | 0.022 | **2.573** | **5.026** |
| 1 | 2,048 | 9.981 | 0.225 | 0.344 | **10.550** | **5.151** |
| 1 | 8,192 | 39.923 | 0.902 | 5.498 | **46.323** | **5.655** |
| 2 | 2,048 | 19.962 | 0.451 | 0.688 | **21.100** | **5.151** |
| 4 | 2,048 | 39.923 | 0.902 | 1.375 | **42.200** | **5.151** |
| 4 | 8,192 | 159.692 | 3.608 | 21.993 | **185.293** | **5.655** |

The table also omits the GDN depthwise convolution’s 0.00197 GFLOP/token
(0.04% at 2K), norms, activations, routing/sort reductions, RoPE, cache copies,
and embeddings. Those remain in the latency model’s measured tail; omitting
their FLOPs makes every compute-only roof slightly optimistic.

This ledger is the invariant. Packing can improve kernel shape, remove
submission boundaries, and avoid partial tiles. It cannot remove any row’s
model FLOPs.

## 2. Latency model and calibration

For per-row chunk width `C`, step `s`, and history before that step `H_s`, let
`N_s = B×C_s` and routed assignment count `M_s = 8N_s`.

```text
T(B,P,C) = Σ_s [
    F_route(N_s) / R_route(M_s)
  + F_dense(N_s) / R_dense(N_s, shapes)
  + T_scan(B,C_s)
  + T_attention(B,C_s,H_s)
  + T_move/sort/combine(N_s)
  + T_graph/eval(B,C_s)
] + T_frontier
```

`R_route` and `R_dense` must be measured separately. A single blended
“delivered TFLOP/s” hides the distinction this investigation needs.

### 2.1 Measured B=1 calibration

From note 009:

| P | measured TTFT | delivered model TFLOP/s |
|---:|---:|---:|
| 512 | 0.3560 s | 7.23 |
| 2,048 | 1.2253 s | 8.61 |
| 8,192 | 5.2637 s | 8.80 |

The two-point `66.2 ms + 0.566 ms/token` fit in note 011 is a useful
phenomenological interpolation, but it does **not** identify 66.2 ms as one
full-model weight read. Tile fill, matrix shape, launch count, cache residency,
and fixed graph work all vary between 512 and 2,048. E1 then showed that the
same routed kernel’s time remains nearly linear as the token axis widens.

### 2.2 Direct routed-QMM calibration

E1 measured one fused gate-up and one down projection at each token count.
Multiplying their sum by 40 layers:

| tokens in pass | gate-up + down per layer | routed time, 40 layers | routed TFLOP/s |
|---:|---:|---:|---:|
| 2,048 | 10.104 ms | **0.4042 s** | **10.20** |
| 4,096 | 19.100 ms | **0.7640 s** | **10.79** |
| 8,192 | 37.096 ms | **1.4838 s** | **11.11** |

At B=1, P=2,048:

```text
full pass                      1.2253 s
measured routed QMM            0.4042 s  (33.0%)
everything else                0.8211 s  (67.0%)
```

The residual represents 6.427 TFLOP of modeled work plus elementwise,
movement, and graph costs. Its effective modeled rate is only 7.83 TFLOP/s.
It is too large to leave aggregated under “QMM overhead.”

### 2.3 What E1 says about packing

The expert kernel dispatches descriptors for each `(expert, row tile)` and
output-column tile. Additional M tiles still reload/dequantize weight tiles
through the cache hierarchy. “One packed pass” is therefore not “one physical
read of every expert weight.” E1’s near-linear time is direct evidence:

```text
tokens: 2,048 -> 8,192 = 4×
route time: 0.404 -> 1.484 s = 3.67×
```

The real routed benefit of widening B=4 from four 2,048-token passes to one
8,192-token pass is `1.617 / 1.484 = 1.09×` for that component, not 4×.
Fewer graph/eval boundaries and better non-routed shapes may add a small
whole-model gain; they do not create a hidden 2×.

## 3. Hard B=4 bound under the current arithmetic path

The official B=4, P=2,048 burst baseline is 1,661 aggregate tok/s, with
4.936 s median TTFT. The 2.5× bar is:

```text
T_target = 4.936 / 2.5 = 1.9744 s
```

One safe wide step has `[B,C] = [4,2048]`, `N=8192`, and 65,536 routed
assignments.

| Term | Work/time |
|---|---:|
| All linear projections | **39.923 TFLOP** |
| All linear work at optimistic 16.4 FP32 TFLOP/s | **2.4343 s** |
| Routed QMM, currently measured at exactly `N=8192` | **1.4838 s** |
| Other linear work | **23.430 TFLOP** |
| Measured route + other linear at 16.4 TFLOP/s | **2.9125 s** |
| Target, including every other term | **1.9744 s** |

The first two rows form the hard contradiction for the current homogeneous
FP32 matrix regime; the measured-route row is an observation, not a lower
bound on a future kernel. Even perfect FP32 projection utilization plus zero
attention, scan, movement, and evaluator time would miss. The observed route
plus an idealized non-routed path misses by more.

The reverse framing is equally useful: keeping routed QMM at its measured
1.484 s leaves only **0.491 s** for 23.43 TFLOP of other linear work plus the
entire non-linear tail. Dense linear work alone would need 47.8 TFLOP/s.

Thus:

- gathered QMM must improve materially;
- gathered QMM improvement is not sufficient;
- dense quantized projections must move to the same higher-throughput
  arithmetic regime.

## 4. Precision semantics and the actual hardware opportunity

### 4.1 Current W4 QMM is FP32 matrix arithmetic

Source chain:

1. Qwen CBv2 activations are BF16 and the affine group-64 loader dequantizes
   weight values into template type `T`.
2. `qmm_t_expert_impl` and ordinary `qmm_t_impl` instantiate
   `BlockMMA<T,T,...>`.
3. `BlockMMA` defaults `AccumType = float`.
4. Its A, B, and C `MMATile`s are all parameterized by `AccumType`, and its
   `load<T>` casts the BF16 threadgroup values into float fragments.
5. `BaseMMAFrag<float>` calls `simdgroup_multiply_accumulate` on float 8×8
   matrices.

W4 therefore reduces storage and dequant traffic. It does not invoke a 4-bit
dot-product unit, and the existing SIMD-group API uses one element type for A,
B, C, and D.

Changing `AccumType` to BF16/FP16 would likely raise throughput, but it would
also change accumulation precision. That is a model-quality change, not a
legal optimization for this goal.

### 4.2 Legal mixed-input alternative

Metal 4 MPP `matmul2d` supports distinct operand/destination types. The Metal
Shading Language table includes:

```text
bfloat × bfloat -> float    (Metal 4, OS 26.1+)
```

The test machine runs macOS 26.4. A legal candidate would:

1. reproduce the current affine dequantizer’s BF16 tile bytes exactly;
2. multiply those BF16 values by the existing BF16 activations;
3. accumulate into float with `relaxed_precision=false`;
4. cast the result to the same output dtype at the same boundary.

BF16 operands have at most eight significant bits each, so finite products in
the model’s normal FP32 range do not need a lower-precision product. The
candidate can still differ through FP32 reduction order, overflow/subnormal
handling, or compiler contraction, so parity must be measured rather than
declared. It must remain inside the incumbent operation tolerance and preserve
all greedy tokens. This does not add weight or activation quantization.

On macOS 26.3+, a custom affine-W4 loader can dequantize into a BF16
cooperative tensor and pass that directly to `matmul2d`, avoiding a
threadgroup-memory round trip. macOS 26.4 also exposes native 4-bit tensor
types, but they are usable here only if their scale/offset semantics encode
the checkpoint’s affine group-64 bytes **exactly**. Any conversion to a
different W4 format is requantization and is rejected.

### 4.3 M3 constraint

Metal API availability is not accelerator availability:

- M3 is Apple GPU family Apple9.
- Apple’s MPP guide identifies per-core neural accelerators on M5/Apple10.
- MLX’s NAX selector additionally checks a new architecture generation and is
  false on the M3 path; current E1 uses the ordinary SIMD-group expert kernel.

TensorOps source is portable from M1 through M5, but Apple states that older
GPUs fall back to optimized shader implementations. An MPP prototype on M3 may
therefore map to the same FP32 execution resources and show no gain. It must be
benchmarked; M5 NAX results cannot be projected onto M3, and MLX’s `NAX`
selector is not evidence that portable MPP itself is unavailable.

MPSGraph/MPS matrix multiplication is not a shortcut for this model. A host
graph would first need to expand affine W4 expert weights or materialize a
dequantized matrix and separately express expert gather. That destroys the W4
traffic advantage and adds intermediates. Only an inline custom dequant +
mixed-input matmul has the right semantics and traffic.

## 5. Non-gathered legal levers

These cannot reach 2.5× alone, but they are real terms in the required
composition.

### 5.1 Prefill-only four-in-one GDN input projection

The four projections `in_proj_qkv`, `in_proj_z`, `in_proj_a`, and `in_proj_b`
all read the same `[B,L,2048]` input. Concatenating output rows preserves each
row’s affine quantization parameters and dot product while replacing four
dispatches and four activation reads with one. It must fail closed if the
checkpoint’s quantization modes differ.

- Work touched: **1.519 GFLOP/token**, 29.5% of total work at P=2,048.
- Free-work upper bound: 1.42× whole model; not attainable because arithmetic
  remains.
- Prior full-prefill evidence from v0.8.8: roughly **1.06–1.10×**.
- Shipping condition: prefill shape only (`L>1`), old path for M=1 decode,
  followed by the complete decode/uptime gate. The unguarded v0.8.8 posture is
  explicitly rejected.

This is a dense-QMM/launch lever, not gathered-QMM efficiency.

### 5.2 Qwen final-layer tail and last-query narrowing

Layer 39 is full attention. Every token from layer 38 is needed to project and
commit layer 39 K/V, so **layer 38 cannot be narrowed**. After those K/V
projections, however, only the frontier row’s query, attention output,
o-projection, residual, MoE, final norm, and logits are observable.

For intermediate chunks, layer 39 needs only full K/V commitment; its query,
attention output, and stateless MoE output are discarded. For the frontier
chunk, those operations need one row. The contiguous-cache primitive already
exists as `CBv2LastQueryPrefillLayerCache` and is wired for Gemma 4, but Qwen’s
current loop does not use it.

Modeled work deletion:

| P | deleted GFLOP/token | share of total work | free-work upper |
|---:|---:|---:|---:|
| 512 | 0.112 | 2.23% | 1.023× |
| 2,048 | 0.125 | 2.42% | 1.025× |
| 8,192 | 0.175 | 3.10% | 1.032× |

It is exact at the model level: full K/V bytes and offsets remain, the newest
causal query sees the same keys, and token-local final-layer rows have no
future consumer. Paged/custom caches retain the old path unless they expose
the same atomic capability.

### 5.3 Exact D=256 online attention

For query length above 8, MLX’s fused full-SDPA allowlist is `{64,80,128}`.
Qwen’s D=256 path therefore composes QK, mask, precise softmax, and AV.
CBv2 query-blocks it at 128, bounding peak allocation but not removing score
traffic or total attention FLOPs.

One correction to note 011: in the pinned MLX fallback, `scores = matmul(q,kT)`
has the promoted Q/K result dtype. For this BF16 model that score array is BF16,
not unconditionally FP32. `precise: true` may use FP32 internal/workspace
arithmetic, which should be measured rather than inferred. The earlier 4-byte
score-traffic estimate is not a source fact.

An exact D=256 online-softmax kernel can remove score round trips while keeping
dense causal attention:

| P | attention share by FLOPs | free-attention upper |
|---:|---:|---:|
| 2,048 | 3.26% | 1.034× |
| 8,192 | 11.87% | 1.135× |

The real wall share may differ. Requalify the existing Steel candidate only
after a trace. Sparse/window attention is not an acceptable substitute.

### 5.4 GDN recurrence

The recurrence is FP32 and serial over `T`, but parallel over
`B × 32 × 128 × 128`. Its arithmetic is only 0.110 GFLOP/token:

- 2.14% of work at P=2,048;
- 1.95% at P=8,192.

The kernel redundantly reads q/k across value-dimension work items and performs
two SIMD reductions per token. Exact threadgroup staging or a better work
mapping can help without changing the recurrence. Chunkwise WY is
mathematically equivalent but changes FP32 operation order and adds temporary
work; it is justified only if a trace shows a much larger wall share than its
FLOP share.

Free-scan upper bound by FLOPs is only about 1.02×. Do not fund a scan rewrite
before measuring its kernel time.

### 5.5 Sort/gather/combine traffic

Qwen currently:

- materializes the top-8 expanded activation in `gatherSort`;
- retains expert order through gate-up, activation, and down;
- scatters to `[tokens,8,hidden]`, then performs weighted reduction.

Using LHS indices in a compatible expert kernel and a Qwen-shaped direct
weighted unsort can remove those copies. This is exact in real arithmetic but
may change BF16 reduction order. The prior Gemma-only direct reduction is not
wired for Qwen, and the v0.8.8 serving regression forbids enabling such a path
for decode without a separate qualification.

Expected whole-model contribution is low single digits; continue only if the
trace attributes at least 3% of wall time to these kernels.

### 5.6 Graph/eval boundaries and overlap

Current B=4, P=8,192 uses 16 `[4,512]` prefill evaluations; `[4,2048]` uses
four. The old two-point fit assigns 66 ms per pass, which would cap the gain
from deleting 12 boundaries at about 0.79 s, under 4% of the modeled current
burst. Because that intercept is confounded, use a Metal System Trace and host
signposts before assigning it.

MLX uses one process-global GPU stream and one process-global eval lock.
Independent request graphs cannot overlap today. Within a packed graph,
several branches are independent—GDN projections, and shared versus routed
expert work—but concurrent encoding helps only if the trace shows idle
resources or command gaps. Two ALU-saturated QMMs do not become faster by
contending concurrently.

CPU/GPU step submission overlap already exists through `asyncEval`.
Multi-stream ragged-request work is not a solution to the equal-shape packed
metric.

### 5.7 Recomputation

There is no training backward pass or activation tape to checkpoint. Forward
recomputation adds FLOPs and cannot raise throughput unless it is the only way
to fit a wider cohort. The relevant `[4,2048]` individual buffers are bounded:

- sorted routed input, `65536 × 2048 × 2` bytes: 256 MiB;
- fused gate-up output, `65536 × 1024 × 2`: 128 MiB;
- D=256 score block per row at BF16, `16 × 128 × kL × 2`: at most 32 MiB
  when `kL=8192`.

These are below the device’s single-buffer limit, but aggregate live bytes must
still be measured under `UnifiedMemoryCap`. If the cohort fits without
recomputation, recomputation is rejected. It also cannot move the narrowing
boundary before layer 39 because layer 39 K/V require every layer-38 row.

## 6. A composition that can meet the arithmetic target

This is a conditional budget, not a claimed result.

### 6.1 B=4, P=2,048

For the official baseline:

```text
baseline                         4.9360 s
2.5× target                      1.9744 s
all linear work                 39.9231 TFLOP
```

Let `T_tail` include the optimized scan, exact attention, movement,
final-layer work, caches, and graph/eval time. Required weighted throughput
over **all** linear projections is:

```text
R_linear_required = 39.9231 / (1.9744 - T_tail)
```

| `T_tail` | required all-linear TFLOP/s |
|---:|---:|
| 0.16 s (near physical minimum) | **22.00** |
| 0.25 s | **23.15** |
| 0.30 s | **23.84** |
| 0.40 s | **25.36** |

The 0.16 s row is intentionally extreme: modeled scan plus attention is 2.277
TFLOP at this cell, which already takes 0.139 s at 16.4 TFLOP/s, leaving only
21 ms for every movement, cache, elementwise, and graph cost. It is a near-
physical lower budget, not a measured tail.

At 24 TFLOP/s and a measured 0.30 s tail:

```text
T_candidate = 39.9231/24 + 0.30 = 1.963 s
speedup     = 4.936/1.963        = 2.51×
```

That is why 24 TFLOP/s is the practical continue threshold. It must be a
weighted result across GDN dense, attention dense, shared expert, router, and
gathered gate-up/down shapes—not one favorable square GEMM.

### 6.2 B=4, P=8,192

There is not yet an official B=4 8K baseline in `results.tsv`. Four times the
measured B=1 TTFT gives a model check, not an acceptance value:

```text
modeled baseline                 4 × 5.2637 = 21.0548 s
modeled 2.5× target              8.4219 s
all linear work               159.6923 TFLOP
scan + attention work          25.6007 TFLOP
```

| optimized non-linear tail | required all-linear TFLOP/s |
|---:|---:|
| 1.25 s | 22.27 |
| 1.50 s | **23.07** |
| 2.00 s | 24.87 |

At 24 TFLOP/s and a 1.50 s measured tail, the model predicts 8.154 s, or
2.58× versus the modeled baseline. Exact D=256 attention matters here because
the attention term is 22.0 TFLOP; it matters much less at 2K.

The actual baseline and tail must replace these values before any claim.

### 6.3 B=2

The required official B=2 baseline is still absent from `results.tsv`; no
derived number can pass the goal. For P=2,048:

```text
all linear work = 19.9615 TFLOP
scan work       =  0.4510 TFLOP
attention work  =  0.6875 TFLOP

R_required = 19.9615 / (T_B2_baseline/2.5 - T_tail)
```

The old step fit predicts about 2.58 s for four `[2,512]` steps. With
24 TFLOP/s linear work and a 0.18 s tail, `[2,2048]` would take about 1.012 s,
barely 2.55×. This is deliberately labeled a prediction: B=2 has the narrowest
margin and can kill the composition once its real baseline is measured.

At 8K, the equally provisional serialized-baseline check is
`2 × 5.2637 = 10.5274 s`. The candidate has 79.846 TFLOP of linear work; at
24 TFLOP/s plus a 0.75 s tail it takes 4.077 s, or 2.58×. This prediction is
valid only if the narrower `N=4096` B=2 projection mix independently sustains
24 TFLOP/s. A favorable B=4 `N=8192` result cannot be extrapolated to it.

## 7. Experiment sequence

### R0 — Establish the missing acceptance cells and component trace

No kernel change.

Run:

- B=1 at 512/2,048/8,192;
- B=2 and B=4 burst at 512/2,048/8,192;
- packed activity and expert-route diagnostics around every burst;
- Metal System Trace for one B=1 2K step, one current `[4,512]` step, and one
  safe `[4,2048]` step.

Trace buckets:

1. dense quantized projections;
2. gathered gate-up/down;
3. GDN recurrence;
4. attention QK/softmax/AV;
5. sort/gather/combine and elementwise;
6. command/eval gaps and host finalization.

Expected: routed QMM near the measured 33% at N=2,048; dense projections are
the largest part of the residual.

Stop/escalate if the control misses baseline by more than 8%, any required row
is absent, or B=2/B=4 shapes do not match the intended cohort.

### R1 — Precision-preserving TensorOp roof

This is the first implementation experiment worth funding. Keep it as an
isolated Metal/MLX test; do not wire serving yet.

Compare current versus MPP BF16-input/FP32-destination kernels with
`relaxed_precision=false`:

| Class | Shapes |
|---|---|
| dense GDN | `M∈{1024,2048,4096,8192}`, `2048→8192`, `2048→4096`, `4096→2048` |
| dense shared expert | `2048→512`, `512→2048` |
| gathered gate-up | E=256, top-8, `K=2048`, `N=1024`, assignments 8K–65K |
| gathered down | E=256, top-8, `K=512`, `N=2048`, assignments 8K–65K |

Required evidence:

- current dequant tile and candidate dequant tile byte-identical in BF16;
- compare cooperative-tensor custom dequant with threadgroup staging; try
  native INT4 only if affine group-64 scale and bias are exactly representable;
- FP32 accumulation, no relaxed precision;
- output errors within the existing QMM contract;
- weighted throughput by real model FLOPs, not average of cell TFLOP/s;
- M3 route proof—do not accidentally report an unavailable NAX/M5 path.

Decision:

- **<22 TFLOP/s weighted:** hard stop for 2.5× on this M3 under current
  quality semantics;
- **22–24:** continue only if R0 proves a tail small enough for the exact
  equation in section 6;
- **≥24:** proceed to full-model integration;
- any need for BF16/FP16 accumulation, extra quantization, or relaxed precision:
  reject and escalate.

### R2 — Cohort geometry

With the already-qualified 32K/65K assignment route, sweep:

```text
B=2: C=512,1024,2048
B=4: C=512,1024,2048
B=1: unchanged 2048 solo stripe control
```

Record full-model makespan, route hits, actual plan shapes, peak active/cache
bytes, every requested buffer size, and attention history.

Expected whole-model upper: **1.05–1.15×** under the current kernel, based on
E1’s 1.09× routed gain plus fewer evals. It is structural support for R1, not
the main multiplier.

Stop if `[B,2048]` is less than 1.03×, exceeds memory policy, or regresses B=1.

### R3 — Exact dense/tail deletions

Run separately, one conceptual change per A/B:

1. prefill-only four-in-one GDN input projection;
2. Qwen layer-39 tail + last-query specialization;
3. indexed routed input and direct weighted combine only if R0 gives those
   kernels at least 3% wall share.

Expected:

- GDN projection fusion: **1.04–1.10×**, informed by prior prefill evidence;
- final-layer narrowing: **1.02–1.03×**;
- MoE movement deletion: **1.00–1.05×**, trace-gated.

Every path retains M=1 decode fallback. Stop any item below 1.02× end-to-end,
on any greedy/KV/GDN mismatch, or on any directional decode loss.

### R4 — Attention and scan, profile-gated

Attention:

- compare current composed D=256 path with the existing exact Steel candidate;
- report output/KV parity, actual score/workspace dtype, allocations, and
  attention-only plus end-to-end time;
- continue if it saves at least 3% end-to-end at 8K without harming 512/2K.

Scan:

- first time the existing GDN kernel in R0;
- try exact q/k staging/work mapping before chunkwise WY;
- fund WY only if scan is at least 8% of wall and exact staging does not close
  the gap.

Reject sparse attention and any lower-precision recurrent state.

### R5 — Compose and run the binding matrix

Only after individual keeps:

- B=1/2/4 prefill at 512/2,048/8,192;
- primary B=4 8K aggregate burst;
- B=1/2/4 decode after 512 and 8K contexts;
- greedy token/checksum, full K/V, top-8, and GDN-state parity;
- B=2/B=4 8K uptime/cancel soak;
- memory/`maxBufferLength`/`UnifiedMemoryCap` checks.

The composition passes only if both B=2 and B=4 8K aggregate cells reach 2.5×,
every other prefill cell is at least 0.98×, and there is no deliberate B=1
loss. Per-shape fallback is part of the implementation, not an afterthought.

## 8. Explicitly rejected “speedups”

These change model quality or the measured task and are not fallback options:

- top-K below 8, expert pruning/skipping, expert capacity drops, or low-rank
  replacement;
- W3/W2, requantizing affine W4 to another format, activation INT8/FP8, or
  BF16/FP16 accumulation;
- `relaxed_precision=true` for float inputs;
- sparse, windowed, landmark, or retrieval attention in place of exact dense
  attention at 512/2K/8K;
- FP16/BF16 GDN state, approximate recurrence, fewer layers, early exit, or
  distillation;
- prefix cache presented as faster execution of the same prefill tokens;
- changing the denominator, dropping failed rows, or calling two provider
  processes a continuous batch;
- M5/Apple10 NAX performance presented as an M3 Max result.

Algebraically equivalent reordering is allowed only under the existing
numeric contract: operation-level tolerance where already permitted, exact
top-8 identities, exact greedy tokens/checksums, correct KV bytes/offsets, and
the existing FP32 GDN state tolerance. A few matching prompts do not authorize
a lower-precision accumulation mode.

## 9. Final stop/escalation rule

The program now has a quantitative kill switch:

1. Measure weighted all-projection throughput for a BF16-input,
   FP32-accumulate candidate.
2. Measure the non-linear tail after exact, individually profitable
   optimizations.
3. Substitute both into section 6—no multiplicative marketing factors.

If the M3 cannot sustain at least 22 TFLOP/s across the real projection mix,
2.5× is physically outside the same-quality roof. If it sustains 22–24, the
measured tail decides. At 24+ with the stated tail budgets, the composition has
an arithmetic path to 2.5× and earns full CBv2 implementation.

If the threshold fails, escalate one of:

- move the target to Apple10/M5-class NAX hardware;
- lower the required multiplier;
- explicitly open a separate product-quality experiment with its own model ID
  and evaluation.

Do **not** silently spend precision, sparsity, recurrence, or attention quality
to preserve the 2.5× headline.

## Sources checked

Repository:

- `research/qwen36-prefill/{GOAL.md,program.md,results.tsv}`
- `research/qwen36-prefill/notes/009-023`
- `libs/mlx-swift-lm/Libraries/MLXLLM/Models/{Qwen35.swift,GatedDelta.swift}`
- `libs/mlx-swift-lm/Libraries/MLXLMCommon/SwitchLayers.swift`
- `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/{AttentionV1,LastQueryPrefillV2,LayerCacheV2,EngineLoopV2}.swift`
- `libs/mlx-swift/Source/Cmlx/mlx-generated/metal/quantized.h`
- `libs/mlx-swift/Source/Cmlx/mlx-generated/metal/steel/gemm/mma.h`
- `libs/mlx-swift/Source/Cmlx/mlx/mlx/{fast.cpp,backend/metal/scaled_dot_product_attention.cpp,backend/metal/device.cpp,backend/metal/quantized.cpp}`

External API constraints:

- Apple, [Metal Shading Language Specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)
- Apple, [Metal Feature Set Tables](https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf)
- Apple, [Metal Performance Primitives Programming Guide](https://developer.apple.com/download/files/Metal-Performance-Primitives-Programming-Guide.pdf)
- Apple, [Accelerate your machine learning workloads with the M5 and A19 GPUs](https://developer.apple.com/videos/play/tech-talks/111432/)
- Apple, [Optimize custom machine learning operations with Metal tensors](https://developer.apple.com/videos/play/wwdc2026/330/)
