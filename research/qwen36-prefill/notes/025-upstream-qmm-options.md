# 025 — Upstream quantized-matmul options for M3 Max Qwen prefill

Status: source/history audit complete; one selective upstream port prepared;
no M3 Max performance result is claimed here.

Scope: Apple M3 Max, Qwen E=256/top-8, affine W4 group-64, BF16 activations,
`(K,N)=(2048,1024)` and `(512,2048)`, and 16,384–65,536 sorted expert
assignments. Source snapshot inspected:

- Darkbloom MLX base `0a725e3000edabc4911cde345270ca950bfa152f`
  (the local `qmv_wide` port);
- local expert-tile extension `e3bdc8038826d55b75e797c7f67a97d2f808af79`;
- fetched public MLX `main` at
  `c793734e` and its quantized-kernel history through 2026-08-23.

## Exact conclusion

**There is no existing faster upstream kernel that can simply be routed to
these shapes on an M3 Max.** The target already uses the only applicable
specialized route in this tree: the non-NAX, sorted E=256 expert-tile kernel
backed by Steel `BlockMMA`, with 32×32×32 tiles. Its legacy fallback is the
sorted-RHS gather kernel with 16×32×32 tiles. At 16K–65K assignments the
specialized route has already measured only 1.04–1.07× over the legacy
gate-up route and 0.99–1.06× for down projection (`notes/021`); both sustain
about 10.5–11.2 TFLOP/s (`notes/023`).

NAX is not a candidate on this machine: MLX requires macOS 26.2 and
architecture generation at least 17 (18 for the `p` architecture), while the
M3 Max reports generation 15. `qmv_wide` and split-K QMM target small row
counts, `qmm_n_impl` requires non-transposed weights, and “Steel GEMM” is
already the inner implementation of the current quantized kernels rather than
a second packed-W4 route.

The one direct selective port is upstream commit
[`56e026d8`](https://github.com/ml-explore/mlx/commit/56e026d8a340e1b00a651d385722e11c1fbaa9f1)
([PR #4241](https://github.com/ml-explore/mlx/pull/4241)), which performs
scale/bias arithmetic in FP32 and casts once when storing the dequantized
weight tile. It changes no dispatch, layout, accumulation type, or public API
and reaches ordinary QMM, generic gather-QMM, the sorted expert kernel, and
the forward-compatible NAX variants through their shared loaders. Upstream
reports affine-Qwen prefill gains on M1 Max, but has no M3 Max or Qwen
E=256/top-8 measurement; therefore this note makes **no speedup claim for the
target**.

That port and regressions are prepared as:

- `patches/0003-perf-metal-dequantize-QMM-weights-in-float32.patch`
  — the four MLX kernel headers plus a Python dense/sorted-gather regression;
- `patches/0004-perf-mlx-dequantize-quantized-weights-in-float32.patch`
  — MLX-Swift's eight generated JIT copies plus the equivalent Swift
  regression.

The source patch must also be applied inside
`libs/mlx-swift/Source/Cmlx/mlx` before building `mlx.metallib`; generated JIT
copies alone do not alter Darkbloom's AOT metallib.

## What actually runs at the target shapes

### Dense `quantized_matmul`

`QuantizedMatmul::eval_gpu` computes the flattened row count `M`. For
transposed weights:

1. `M < get_qmv_batch_limit(K,N,device)` uses a vector kernel;
2. `M >= limit` first calls `qmm_splitk`;
3. `qmm_splitk` targets roughly 512 threadgroups and falls straight back to
   `qmm` when its computed split is one;
4. `qmm` dispatches `affine_qmm_t`, which calls `qmm_t_impl`.

For `M=16K–65K`, `N=1024/2048`, the existing `ceil(M/32) × ceil(N/32)` grid is
already far above 512 threadgroups, so split-K computes `split_k=1` and the
32×32×32 `qmm_t_impl` runs. The small-M split-K work from
[`38ad2570`](https://github.com/ml-explore/mlx/commit/38ad257088fb2193ad47e527cf6534a689f30943)
([PR #3120](https://github.com/ml-explore/mlx/pull/3120)) is already present
but has no target-shape route.

### Sorted MoE `gather_qmm`

Qwen supplies `x=[assignments,1,K]`, sorted RHS expert indices, and
`transpose=true`. `GatherQMM::eval_gpu` takes the sorted-RHS route when:

```text
inner M == 1
assignments >= 16
sorted_indices == true
assignments / E >= 4
```

All target cells satisfy that predicate. On M3 Max, NAX loses the outer gate,
so `gather_qmm_rhs` does one of:

- exact opt-in E=256 expert route:
  `affine_gather_qmm_gemma4_expert_tiles` →
  `qmm_t_expert_impl`, 32×32×32 (16-row body for short tails);
- fallback:
  `affine_gather_qmm_rhs`, 16×32×32.

The exact route accepts affine W4/g64 BF16, contiguous E=256 tensors,
`(K,N)=(2048,1024)`, `(2048,512)`, or `(512,2048)`, and the qualified
assignment counts 4K/8K/16K/32K/64K. Thus no missing selector change remains
for the requested 16K–65K cells.

The ordinary indexed `affine_gather_qmm_t` also calls `qmm_t_impl`, but only
the non-sorted outer path reaches it. Replacing the sorted expert route with
it would discard the known contiguous-run reuse; it is a fallback/control,
not an untried faster kernel.

## Kernel comparison

| Candidate | What it is | Target disposition |
|---|---|---|
| `qmm_t_impl` | Transposed packed-weight QMM, 32×32×32, Steel `BlockMMA` | Already used by dense QMM and generic gather. Large target `M` bypasses effective split-K. |
| `qmm_n_impl` | Non-transposed packed-weight QMM, 32×32×32 | Not layout-compatible with Qwen's `transpose=true` `[E,N,Kpacked]` weights. Repacking would be a different experiment. |
| Steel GEMM | `BlockMMA`/loaders and FP32 accumulator fragments | Already inside `qmm_t_impl`, `qmm_n_impl`, sorted-RHS gather, and expert tiles. Dense Steel GEMM cannot consume packed W4 scales/biases or expert indices directly. |
| NAX QMM/gather | 64-base neural-accelerator kernels, including `gather_qmm_rhs_nax` | Unreachable on generation-15 M3 Max. Do not infer M3 results from M5 measurements. |
| `qmv_wide` | Reuses a weight group for `M` in `[2, vector_limit)` | Already ported from [`548dd80e`](https://github.com/ml-explore/mlx/commit/548dd80e87454f6e4c1c7736ce09551d145c11d5) ([PR #3764](https://github.com/ml-explore/mlx/pull/3764)); target `M` is orders of magnitude larger, and sorted gather takes its outer route first. |
| `qmm_t_splitk` | Raises occupancy by splitting K for small dense `M` | Already present; computes split one at target sizes. It is not used by sorted gather. |
| Legacy sorted-RHS gather | 16×32×32 packed-W4 Steel kernel | Available control/fallback. Already A/B'd against expert tiles in `notes/021`. |
| E=256 expert tiles | Descriptor-driven 32×32×32 `qmm_t_expert_impl` | Current applicable route and measured control winner at the large cells. |
| Dense dequantize + GEMM | Materialize BF16 weights, then ordinary GEMM | Not a packed-W4 replacement: it adds a full dequantized-weight intermediate and loses the traffic contract. |

`BlockMMA<T,T,...>` defaults `AccumType=float`; its A, B, and C
`simdgroup_matrix` fragments are therefore FP32. Upstream #4241 changes only
the arithmetic that creates each BF16 weight-tile element. It does not change
the FP32 matrix accumulation contract.

## Post-pin upstream commits

| Commit / PR | Change | Applicable here? |
|---|---|---|
| [`56e026d8`](https://github.com/ml-explore/mlx/commit/56e026d8a340e1b00a651d385722e11c1fbaa9f1) / [#4241](https://github.com/ml-explore/mlx/pull/4241) | Dequantize scale/bias in FP32, cast once to tile dtype | **Yes; direct port prepared.** Upstream measured M1 Max and M5 Pro, not this M3/Qwen workload. |
| [`4947e3b6`](https://github.com/ml-explore/mlx/commit/4947e3b615964bf52d868540b12861f685cbbad5) / [#4251](https://github.com/ml-explore/mlx/pull/4251) | Ceil the output grid in non-transposed `qvm_split_k` | Correctness fix for a different route; target is transposed QMM/sorted gather. |
| [`a076a632`](https://github.com/ml-explore/mlx/commit/a076a632596eb61b1e876c0512b54b781584f756) / [#4023](https://github.com/ml-explore/mlx/pull/4023) | Choose BM=32 for short expert runs in `gather_qmm_rhs_nax` | Geometry matches, hardware gate does not. NAX-only. |
| [`c7ff35d9`](https://github.com/ml-explore/mlx/commit/c7ff35d9714c78bcdf4620deb1d189f7ffb7c3b9) / [#4352](https://github.com/ml-explore/mlx/pull/4352) | Skip discarded simdgroup work in NAX MoE gather | NAX-only; published measurements are M5 Pro/Max. |
| [`a082cb91`](https://github.com/ml-explore/mlx/commit/a082cb91d5908e9d89a61a31ee90ee45875b8a1e) / [#4171](https://github.com/ml-explore/mlx/pull/4171) | BM=32 NAX QMM when one block covers `M<=32` | NAX-only and wrong row/output regime (`M<=32`, typically `N>8192`). |
| [`02adf7b2`](https://github.com/ml-explore/mlx/commit/02adf7b2125f50f6a03295b6481690c5c960569a) / [#4353](https://github.com/ml-explore/mlx/pull/4353) | Round MXFP8 block scales upward | Quantizer correctness/quality for MX modes; checkpoint is affine W4. |
| [`7408e687`](https://github.com/ml-explore/mlx/commit/7408e687afac5c78ffe15d52ffda1d50fb9a97a4) / [#4372](https://github.com/ml-explore/mlx/pull/4372) | Repair JIT QMV template arity and NAX gather names | Build/correctness repair, not a target performance route. Darkbloom's served metallib is AOT. |

No other post-pin quantized commit in the fetched history supplies a
generation-15 large-M affine gather kernel.

## Ranked concrete experiments

### 1. Target A/B for the prepared FP32-dequant port

This is the only experiment backed by a merged upstream implementation.

Run one source-matched binary/metallib pair before and after the two patches.
Measure, separately:

- dense `quantizedMM`, W4/g64/BF16, both `(K,N)` pairs;
- sorted `gatherQuantizedMM`, E=256, both pairs, assignments
  16,384/32,768/65,536;
- expert route `trust` and legacy route off, with diagnostics proving hits;
- full CBv2 B=1/2/4 at 512/2,048/8,192 prompt tokens.

Correctness gates:

- the new exact regression produces `-109.5`; the old BF16-arithmetic kernel
  produces `-110.0`;
- sorted expert output remains within the existing legacy/dequantized
  tolerances;
- greedy tokens, KV/GDN state checks, decode, and memory remain unchanged.

Report measured latency/TFLOP/s and full-model tokens/s; do not transfer
upstream M1/M5 percentages to M3. Keep only on a measured target win with all
gates passing.

### 2. Re-run expert-tile versus legacy routing after experiment 1

`notes/021` is decisive for the old dequant instruction mix. #4241 changes
that mix in both kernels, but not identically: the 16-row/32-row expert bodies
and BM=16 legacy body can expose different occupancy/register effects.

Use the existing environment switch and diagnostics; do not add a kernel.
For each `(K,N,M)` target cell, select the measured faster existing route.
This can simplify the selector if one route wins the entire requested range;
otherwise retain the current per-shape fallback. No improvement is assumed.

### 3. Isolate loader versus gather overhead with existing kernels

Benchmark the same quantized expert matrix and contiguous row slice through:

1. ordinary `quantizedMM`/`qmm_t_impl`;
2. legacy sorted-RHS gather;
3. E=256 expert tiles.

Use the real per-expert row histograms for 16K/32K/64K assignments and sum
work-weighted times. This does not propose 256 serving dispatches; it
answers whether time is in shared dequant/Steel MMA or in gather descriptors
and boundary handling. Stop if ordinary QMM has the same per-useful-FLOP
ceiling, because no routing-only change remains.

### 4. Only if experiment 3 isolates the 32×32×32 core: compile-time tile sweep

Instantiate one additional `qmm_t_impl`/`qmm_t_expert_impl` tile schedule at
a time for the two exact K/N pairs. Compare against the source-matched current
route at all three assignment counts, including partial expert tails. This
reuses the current loader and Steel MMA and preserves operation boundaries; it
is not a GateUp/SwiGLU mega-kernel.

Require correctness, metallib-size accounting, register/threadgroup-memory
occupancy, and a full CBv2 A/B before changing dispatch. Delete every losing
instantiation. There is no source-backed performance number to claim in
advance.

## Explicit non-experiments

- Do not port NAX optimizations for M3; the architecture gate is definitive.
- Do not route large prefill to `qmv_wide` or split-K; their row-count
  mechanisms do not apply.
- Do not transpose/repack the registry weights merely to reach `qmm_n_impl`
  without first proving that repack traffic and storage are acceptable.
- Do not materialize dequantized BF16 expert weights to call dense Steel GEMM.
- Do not revive the fused MoE mega-kernel; paired tests already found it
  63–71% slower.
- Do not upgrade wholesale to public `main` for this experiment. Selective
  #4241 isolates one mechanism; the later public tree mixes NAX, MX formats,
  JIT repairs, and unrelated backend changes.

## Regression fixture

For affine W4/g64 with BF16 scale `0.0185546875`, BF16 bias `-1.9921875`,
packed code 15, and a 64-element dot against ones:

```text
BF16 multiply/add per weight                 -> -110.0
FP32 multiply/add, then one BF16 tile store  -> -109.5
```

The Python and Swift tests assert `-109.5` for ordinary QMM and sorted-RHS
gather-QMM. This fails on the old kernel and covers the exact arithmetic
changed by #4241; the existing Swift suites retain E=256 Qwen
`(2048,1024)/(512,2048)` route and random-tensor equivalence coverage.

## Sources

Repository:

- `libs/mlx/mlx/backend/metal/quantized.cpp`
- `libs/mlx/mlx/backend/metal/device.cpp`
- `libs/mlx/mlx/backend/metal/kernels/{quantized,quantized_nax}.h`
- `libs/mlx/mlx/backend/metal/kernels/{fp_quantized,fp_quantized_nax}.h`
- `libs/mlx/mlx/backend/metal/kernels/steel/gemm/mma.h`
- `libs/mlx/mlx/backend/common/gemma4_expert_qmm.h`
- `libs/mlx-swift/tools/update-mlx.sh`
- `scripts/fetch-metallib.sh`
- `research/qwen36-prefill/notes/{011-explorer-moe-gdn,021-e1-tile-ab-results,023-e1-confirms-alu-bound}.md`

Upstream links are attached to every commit/PR in the history table.
