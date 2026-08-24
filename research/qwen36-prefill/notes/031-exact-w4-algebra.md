# 031 — Exact affine-W4 algebra: only zero output rows reduce MMA work

Status: **analysis complete; one exact opt-in roof benchmark added; no serving
integration justified**

Scope: affine W4/group-64 Qwen 3.6 35B-A3B routed MoE on the M3 Max at the
serving prefill geometry. "Exact" below distinguishes:

- **bitwise exact:** the existing BF16 dequantization, FP32 MMA accumulation,
  BF16 result, top-8 identities, and downstream values are unchanged;
- **real-algebra exact:** equal over real numbers, but floating-point rounding
  or reduction order can differ.

Only the first class is eligible for the small implementation in this note.
The second class remains a hypothesis until it passes the existing numerical
contract and greedy checksums.

## Verdict

1. The current kernel computes each affine weight as BF16
   `w = q*s + b`, promotes BF16 `x` and `w` into FP32
   `simdgroup_matrix` fragments, and performs every dense MMA. Separating the
   scale and bias terms does **not** reduce that MMA count.
2. Sharing one input row across its eight selected experts can remove copies
   and repeated input loads, but the eight experts have different weights.
   It cannot remove any dot product. Top-k returns eight distinct experts.
3. Fused gate/up is already active. SiLU makes gate/up followed by down
   nonlinear, so the two matrices cannot be collapsed.
4. The one genuine exact work deletion is a gate or up output row whose affine
   bytes decode entirely to zero. Its post-SiLU hidden channel is then zero and
   need not be projected. Layer 0 has a striking **41.395%** such pattern, but
   it is not model-wide: an all-layer scan gives only a **1.127% optimistic
   scalar-row upper bound**, or **1.010% after BN=32 output-tile padding**.
5. That model-wide sparsity can remove at most about **0.42% of all linear
   MMA work** even if it is also exploited by down projection. Gate/up-only,
   the bitwise-safe first step, removes about **0.28%**. Mapping and scatter
   overhead are not included.
6. Therefore exact algebra cannot turn the measured 12.3 TFLOP/s monolithic
   control into the 2.5x goal. At B=4, P=2,048, the 39.923 TFLOP linear term
   would still exceed **39.7 TFLOP**. At 12.3 TFLOP/s that is **3.23 s**, before
   attention, GDN recurrence, routing, movement, or graph overhead; the target
   is 1.974 s.

The exact small implementation is the opt-in Metal microbenchmark patch
`research/qwen36-prefill/patches/031-affine-zero-row-compaction-benchmark.patch`
for `libs/mlx-swift`. It keeps live packed rows and affine metadata
byte-for-byte, omits proven `q=0,b=+0` rows, restores explicit zeros, and
requires bitwise-equal output. It is deliberately an optimistic
necessary-condition roof, not a serving path.

## 1. Current physical work

The measured E3 geometry is:

```text
source tokens = 2,048
topK         = 8
assignments  = M = 16,384
experts      = 256, uniformly 64 assignments/expert in the microbenchmark
```

`qmm_t_impl` and `qmm_t_expert_impl` use `BM=BN=BK=32`,
`WM=WN=2`. `BlockMMA` subdivides those blocks into 8x8x8
`simdgroup_multiply_accumulate` operations with an FP32 accumulator.

| Projection | K | N | scalar MAC | useful FLOP | 8x8x8 MMA calls |
|---|---:|---:|---:|---:|---:|
| fused gate_up | 2,048 | 1,024 | 34.360 B | 68.719 GF | 67,108,864 |
| down | 512 | 2,048 | 17.180 B | 34.360 GF | 33,554,432 |
| total/layer | | | **51.540 B** | **103.079 GF** | **100,663,296** |

The down projection is half, not equal to, gate_up work. Per source token over
40 layers:

```text
gate_up = 40 * 2 * topK * 2048 * 1024 = 1.3422 GFLOP/token
down    = 40 * 2 * topK *  512 * 2048 = 0.6711 GFLOP/token
routed  =                                      2.0133 GFLOP/token
```

Unique packed-weight footprint per layer:

| Projection | packed q | scale+bias | total |
|---|---:|---:|---:|
| gate_up | 256 MiB | 32 MiB | 288 MiB |
| down | 128 MiB | 16 MiB | 144 MiB |
| total | 384 MiB | 48 MiB | **432 MiB** |

At M=16,384, the sorted BF16 input is 64 MiB, fused gate_up output is
32 MiB, post-SiLU hidden is 16 MiB, and down output is 64 MiB. These are
logical footprints, not measured DRAM traffic.

E3 measured:

| Projection | W4 sorted gather | illegal one-matrix BF16 control |
|---|---:|---:|
| gate_up | 10.89 TFLOP/s | 12.30 TFLOP/s |
| down | 10.22 TFLOP/s | 11.60 TFLOP/s |

The one-matrix result is a measured control, not a universal hardware theorem,
but it shows that dequantization and expert grouping expose only about 13%
at this operation count. To report materially more than 12.3 model-TFLOP/s on
this M3 path, a candidate must execute fewer physical MMAs.

## 2. Affine decomposition does not delete MMAs

For output row `n` and group `g`:

```text
y_n
  = sum_g sum_j x_gj * BF16(q_ngj * s_ng + b_ng)
```

Ignoring the incumbent BF16 dequantization rounding, real algebra gives:

```text
y_n
  = sum_g [
      s_ng * sum_j(x_gj * q_ngj)
      + b_ng * sum_j(x_gj)
    ]
```

This exposes `S_g(x)=sum_j x_gj`, with 32 sums for K=2,048 and eight sums for
K=512. One source token can share its `S_g` across top-8 assignments.

It does not reduce matrix work:

- `sum_j(x*q)` still has K products for every output row and selected expert;
- applying `s` and `b` adds two multiplies and an add per output/group;
- computing and retaining `S_g` adds a small separate reduction;
- M3's current kernel has no affine INT4 dot-product instruction. Packed W4
  saves storage; it is decoded before FP32 matrix arithmetic.

It is also not bitwise exact. The incumbent rounds every `q*s+b` to BF16
before multiplication, then accumulates in the current 8-term FP32 MMA order.
Factoring `s` and `b` moves that rounding and changes association. Even if a
future integer dot path is faster, it is a numerical experiment, not an exact
rewrite.

**Kill criterion:** do not implement unless a primitive reduces the number of
8x8x8 MMA calls while reproducing the incumbent dequantized BF16 bytes and
FP32 result contract. A group-sum kernel that merely moves dequantization is
dead; E3 already shows dequantization removal is flat.

## 3. Precomputed bias terms and common scale/bias values

Precomputing `S_g(x)` turns the affine offset contribution into a small
`[M,G] x [G,N]` matmul, but the quantized-value term remains
`[M,K] x [K,N]`. The extra term is N*G MACs and deletes no q-dot MMA.

Equal scales or biases across output rows are insufficient:

```text
same s,b + different q rows => different dot products
```

Factoring a common scale after a dot product again moves BF16 rounding.
Exact dot reuse requires the complete decoded weight row to be identical.
For layer-0 gate and up tensors, the packed-byte scan found:

- 54,257 zero rows per projection;
- zero masks exactly equal between gate and up;
- **zero duplicate nonzero packed-q rows within any expert**.

Because equality already fails on q bytes, adding scale/bias metadata cannot
create an identical active row.

**Kill criterion:** require a full decoded-row duplicate rate large enough to
remove at least one BN=32 tile after mapping overhead. Metadata repetition by
itself is not a candidate.

## 4. Shared x rows, repeated expert assignments, and layouts

Each token's top-8 indices are distinct. The same hidden row is therefore
multiplied by eight different expert matrices:

```text
[x W_e0, x W_e1, ..., x W_e7]
```

Stacking those matrices changes this into one wider matmul but leaves exactly
`8*K*N` MACs. Across tokens, sorting already groups repeated expert IDs so
each expert's weight tiles are reused over its BM=32 assignment tiles.
Different tokens have different hidden rows, so their outputs cannot be
memoized.

There is still a movement optimization: `gatherSort` materializes an
eight-fold BF16 copy. At 2,048 source tokens this is 64 MiB per layer instead
of the original 8 MiB. An LHS-indexed expert kernel can avoid that copy and
can load one x tile for multiple expert outputs, but it does not remove an
MMA. It cannot cross the 12.3 control by work deletion.

Batched expert weight layouts have the same limitation. E3's illegal
monolithic control already deletes all expert dispatch geometry and gains only
1.13x.

**Kill criterion:** movement/layout work proceeds only if a Metal trace assigns
at least 3% of end-to-end wall time to gather/sort/combine and the candidate
keeps the exact same QMM. Do not count it as an MMA-reduction lever.

## 5. Fused gate_up and why down cannot be collapsed

The serving path already concatenates gate and up rows and calls one
`gatherQuantizedMM` with N=1,024. This shares:

- sorted assignment metadata;
- the input tile load;
- dispatch overhead.

It does not reduce the `2 * 512` output-row dot products.

The next expression is nonlinear:

```text
h = silu(x W_gate^T) * (x W_up^T)
y = h W_down^T
```

There is no static matrix `W_combined` such that
`y = x W_combined^T` for all x. Fusing kernels can keep intermediates on-chip,
but it retains every gate, up, SiLU, product, and down operation. The prior
GateUp+SwiGLU mega-kernel was measured 63–71% slower and is already dead.

## 6. Exact dead hidden channels

If an entire gate row or up row decodes to zero and there is no module bias:

```text
gate_j(x) == 0  => silu(gate_j(x)) * up_j(x) == 0
up_j(x)   == 0  => silu(gate_j(x)) * up_j(x) == 0
```

That hidden channel can be omitted from gate/up. A bitwise-safe first
candidate computes every live row with its original packed bytes and original
K reduction, then inserts explicit +0 rows before the unchanged down QMM.

Compacting down's K dimension is more difficult. Removing individual zero
channels repacks active terms into different 8-wide MMA reductions and changes
FP32 association. A strictly bitwise path can skip only whole original
8-channel reduction fragments. In layer 0:

| contiguous all-zero width | removable channels |
|---:|---:|
| 1 | 41.395% |
| 2 | 19.516% |
| 4 | 5.188% |
| 8 | **0.519%** |
| 16 | 0.024% |
| 32 | **0%** |
| 64 | 0% |

So the current BN/BK layout exposes no whole zero 32-tile. An impactful
candidate needs expert-specific output-row compaction. Gate/up output
compaction preserves each live dot's reduction order; arbitrary down-K
compaction does not.

### 6.1 Snapshot evidence

The layer-0 tensors were read directly from
`model-00001-of-00004.safetensors`:

```text
language_model.model.layers.0.mlp.switch_mlp.gate_proj.{weight,scales,biases}
language_model.model.layers.0.mlp.switch_mlp.up_proj.{weight,scales,biases}
```

Shapes are:

```text
weight  [256,512,256] uint32  # 2048 W4 values/row
scales  [256,512,32]  BF16
biases  [256,512,32]  BF16
```

For both projections, all 54,257 detected rows had:

- every packed q word equal to zero;
- every bias word equal to BF16 `+0` (`0x0000`);
- the same scale word in all groups (`0xb3d7`);
- gate and up masks exactly equal.

Thus the layer-0 decoded rows are exactly +0 under the current
`scale*q+bias` loader. The full packed tensors, not a sample, were checked for
layer 0.

The all-layer pass then scanned zero-bias row masks for both gate and up.
Their masks were exactly equal in all 40 layers. Packed-zero spot checks passed
at sampled early, middle, and final layers. Because every packed row was not
downloaded for all 40 layers, the following is intentionally an **optimistic
upper bound**; a serving transform must verify packed q and decoded zero bits
per layer and fail closed.

| Layers | dead rows / available rows | scalar fraction |
|---|---:|---:|
| 0 | 54,257 / 131,072 | 41.395% |
| 1 | 2,153 / 131,072 | 1.643% |
| 2 | 952 / 131,072 | 0.726% |
| 3 | 370 / 131,072 | 0.282% |
| 4 | 181 / 131,072 | 0.138% |
| 5 | 18 / 131,072 | 0.014% |
| 6–39 combined | 1,162 / 4,456,448 | 0.026% |
| **all 40** | **59,093 / 5,242,880** | **1.127%** |

Rounding each expert's live count up to BN=32 gives:

```text
all-layer gate/up output-tile reduction = 1.0095%
```

Layer 0 alone goes from 4,096 to 2,524 BN=32 tiles per projection, a
38.379% reduction. That attractive local result is diluted by the other 39
layers.

### 6.2 Whole-model ceiling

Routed projections are 41.3% of all linear work, and gate_up is two-thirds of
routed work.

Bitwise-safe gate/up output compaction:

```text
linear work deleted
  <= 41.3% * (2/3) * 1.0095%
   = 0.278%
```

Even granting equally effective down compaction:

```text
linear work deleted
  <= 41.3% * 1.0095%
   = 0.417%
```

Using the more optimistic unpadded 1.127% scalar mask raises the latter only to
0.466%.

At B=4, P=2,048:

```text
original linear work                   = 39.923 TFLOP
after optimistic all-routed deletion   > 39.737 TFLOP
time at measured 12.3 control          >  3.231 s
2.5x target                               1.974 s
```

Even the false extrapolation "every layer is as sparse as layer 0" leaves
about 33.1 TFLOP, or 2.69 s at 12.3, before the non-linear tail. The algebra is
incapable of meeting the goal.

## 7. Router sparsity

The router already computes only the selected eight experts downstream.
Reducing topK below eight, dropping low scores, or imposing capacity changes
the model.

For finite logits, softmax weights are positive. The top-8 selected scores are
not structurally zero, and top-k returns distinct indices. Replacing

```text
softmax(all 256) -> top8 -> renormalize
```

with

```text
top8(raw logits) -> softmax(top8)
```

is equal in real algebra because the global denominator cancels. It is not
universally bitwise exact: exponent rounding, underflow/ties, max selection,
and reduction order can change selected identities or BF16 weights. It also
removes no expert MMA after top-8.

**Kill criterion:** no router rewrite enters this exact-work experiment unless
all top-8 IDs and weights are bitwise equal over adversarial ties, infinities,
and underflow. Even then it is a sub-percent router optimization, not an MMA
lever.

## 8. Implemented exact microbenchmark

The patch adds `QwenAffineZeroRowCompactionPerfTests`, which constructs:

```text
full gate_up:
  [256 live gate; 256 q=0/b=0 gate;
   256 live up;   256 q=0/b=0 up]       N=1024

compact gate_up:
  [256 live gate; 256 live up]          N=512
```

Both paths use the existing sorted E=256 affine-W4/g64 expert kernel at
M=16,384 and K=2,048. The compact path reuses the exact same live q, scale, and
bias arrays. It then restores omitted +0 rows and asserts full output
bitwise equality.

Run:

```bash
cd libs/mlx-swift
git apply ../../research/qwen36-prefill/patches/031-affine-zero-row-compaction-benchmark.patch
MLX_W4_ZERO_ROW_PERF=1 \
MLX_GATHER_QMM_EXPERT_SLICES=trust \
swift test --filter QwenAffineZeroRowCompactionPerfTests
```

It reports:

- full gate_up time;
- compact live-row time;
- compact plus zero-restoration time;
- physical TFLOP/s and expert-tile hit/fallback counters.

This 50%-zero common-suffix setup is intentionally more favorable than the
real checkpoint. It answers only whether output-row omission has a kernel-level
payoff before funding expert-specific maps and ragged widths.

**Kill criteria:**

1. Bitwise equality must pass. Tolerance-only equality is a rejection for this
   candidate.
2. Both N=1,024 and N=512 calls must hit the intended expert-tile route.
3. Compact plus restoration must be at least 1.5x faster in this optimistic
   50%-zero cell. Otherwise mapping real masks cannot pay.
4. A real-mask prototype must include permutation/map construction and show at
   least 1.25x on layer 0's gate_up call.
5. Regardless of the microbenchmark result, do not integrate serving unless a
   full-checkpoint scan exposes at least 5% all-layer BN32 tile deletion. The
   measured upper bound is 1.01%, so this checkpoint already fails that gate.

The benchmark is retained as a precise regression/research tool. Serving
weight rewriting, new protocol fields, and custom Metal kernels are
intentionally absent.

## 9. Candidate ledger

| Candidate | Exactness | MMA reduction | Best plausible scope | Decision |
|---|---|---:|---:|---|
| affine group-sum decomposition | real only | 0% | dequant/post-op | reject |
| precomputed `sum(x)` bias term | real only | 0% | top-8 shared input | reject |
| common scale/bias factoring | real only | 0% without duplicate q | metadata | reject |
| duplicate decoded weight rows | bitwise possible | none found active in L0 | per expert | reject |
| share x load across top-8 | bitwise possible | 0% | movement | trace-gated |
| fused gate_up | already shipped | 0% | dispatch/input load | keep existing |
| fuse gate_up + SiLU + down | model exact, same arithmetic | 0% | intermediate traffic | prior kernel dead |
| batched/monolithic expert layout | model exact | 0% | grouping overhead | roofed at 1.13x |
| gate/up exact-zero row omission | **bitwise candidate** | 1.01% of gate/up tiles model-wide | output rows | benchmark only; serving pre-killed |
| arbitrary down-K compaction | real only under new reduction order | up to zero-channel rate | down MMA | reject for exact path |
| whole original 8-K-fragment skip | bitwise possible | 0.519% in sparse L0, far less model-wide | down MMA | reject |
| fewer router experts | not exact | large | routed work | forbidden |
| top8-before-softmax | real only | 0% expert MMA | router | reject here |

## 10. Final roof statement

The measured 12.3 TFLOP/s monolithic result is beatable in
**original-model-FLOP/s accounting** only if physical work is deleted. The
enumerated affine algebra, shared inputs, layout changes, and router identities
do not delete dot products. Exact zero rows do, but this snapshot supplies only
a 1.127% scalar-row upper bound across all routed layers.

At the actual model mix, that raises the apparent 12.3 control to only about:

```text
12.3 / (1 - 0.413 * 0.01127) = 12.36 TFLOP/s
```

That is the complete exact-algebra headroom found here, before overhead. A
2.5x result still requires a different arithmetic throughput regime, a
different hardware target, or an explicitly changed model-quality contract.

