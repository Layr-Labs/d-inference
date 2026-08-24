# 024 — Gathered affine-W4 QMM kernel plan for M3 Max

Status: **source audit complete; one upstream candidate and benchmark
instrumentation prepared; no new M3 Max timing is claimed**

Scope: Qwen 3.6 35B-A3B text prefill, E=256/top-8, BF16 activations,
affine W4 group-64 weights, `(K,N)=(2048,1024)` gate-up and
`(512,2048)` down, and sorted assignment counts
`M={16384,32768,65536}`.

## Verdict

The present `affine_gather_qmm_gemma4_expert_tiles` path is not missing
threadgroups. It launches tens of thousands of them at the smallest target
shape. Nor is affine dequantization a plausible hidden 2x term: the expert
kernel and legacy kernel execute the same total FP32 SIMD-group MMA work, and
the expert kernel's main saving—reusing one dequantized weight tile across 32
rather than 16 rows—has already measured only **1.04–1.07x** at these M values.

The current kernel is a packed-W4 **storage** path but an FP32 matrix-arithmetic
path. `BlockMMA<T,T,...>` converts the BF16 activation and dequantized-weight
tiles to `float` fragments; A, B, C, and D then use
`simdgroup_matrix<float,8,8>`. The measured 10.5–11.2 TFLOP/s is already a
substantial fraction of the estimated 14.2–16.4 TFLOP/s M3 Max FP32 roof.
Retiling, descriptor cleanup, and loader cleanup can test single-digit or
low-teens losses. They cannot make the same FP32 instructions sustain
23 TFLOP/s.

There is a more important correction to the premise: faster gathered QMM is
necessary but not sufficient for 2.5x end-to-end prefill. At 2,048 tokens the
measured routed gate-up plus down kernels occupy about 0.404 s of a 1.225 s
pass. Dense GDN, attention, and shared-expert projections use the same
quantized-matmul family and contain more linear FLOPs than the routed experts.
Any 2x-class implementation must raise the rate of **both gathered and dense
large projections**. See `notes/026-independent-roof-and-levers.md`.

The only same-quality experiment with a credible path above the homogeneous
FP32 roof is a **new**, exact BF16-input, FP32-accumulate Metal 4 MPP
prototype. It must preserve the incumbent BF16 dequantized tile bytes and FP32
accumulation. E6 already forced MLX's existing NAX/MPP kernels onto this M3:
the optimized-shader fallback executed but failed 11 QMM correctness
assertions, so that shortcut is dead before timing (`notes/034`). A custom
byte-identical loader remains conceptually open, but cannot reuse the existing
NAX implementation as-is.

## 1. Exact path that runs

`GatherQMM::eval_gpu` sees Qwen's `x=[assignments,1,K]`. With sorted RHS
indices, at least 16 assignments, and at least four assignments per expert, it
takes `gather_qmm_rhs` (`libs/mlx/mlx/backend/metal/quantized.cpp:1756-1821`).

On M3 Max:

1. NAX loses the hardware/OS gate. MLX requires macOS 26.2 plus architecture
   generation at least 17 (18 for architecture `p`); the M3 route reports
   generation 15 (`device.cpp:965-983`).
2. The E=256 expert classifier accepts only affine W4/g64 BF16, contiguous
   sorted inputs, the three Qwen projection geometries, and the closed
   assignment set through 65,536
   (`backend/common/gemma4_expert_qmm.h:108-188`).
3. `try_gemma4_expert_qmm` dispatches one E=256 descriptor builder followed by
   the AOT 32x32x32 tile kernel (`quantized.cpp:1311-1418`).
4. If the specialization is disabled or rejected, the legacy sorted-RHS path
   dispatches `affine_gather_qmm_rhs` with
   `BM=16, BN=32, BK=32, WM=1, WN=2`
   (`quantized.cpp:1566-1655`).

The only AOT expert specialization is explicitly named
`...bm_32_bn_32_bk_32` in `quantized.metal:184-207`. There is no dormant M3
BM64/BK64 variant for the host to select.

## 2. Geometry at the target M values

For the benchmark's uniform E=256 histogram, every expert has a multiple of 32
rows. There are no partial expert tiles and no safe output stores.

| M | rows/expert | valid BM32 descriptors | allocated/over-dispatched slots | empty-slot share | expert TGs gate / down | legacy TGs gate / down |
|---:|---:|---:|---:|---:|---:|---:|
| 16,384 | 64 | 512 | 767 | 33.2% | 16,384 / 32,768 | 32,768 / 65,536 |
| 32,768 | 128 | 1,024 | 1,279 | 19.9% | 32,768 / 65,536 | 65,536 / 131,072 |
| 65,536 | 256 | 2,048 | 2,303 | 11.1% | 65,536 / 131,072 | 131,072 / 262,144 |

The host allocates `ceil(M/32)+E-1` slots, while a uniform histogram needs
exactly `M/32`. Thus it always launches 255 empty descriptor rows:
8,160 empty gate threadgroups or 16,320 empty down threadgroups. They return
after reading `count[0]`, before the microkernel
(`quantized.h:2693-2708`). This is real fixed overhead, but it shrinks as M
grows. The measured gate curve 6.541/12.516/24.486 ms and down curve
3.563/6.584/12.610 ms are nearly linear; any fixed descriptor plus empty-grid
term is bounded to roughly the sub-millisecond intercept, not half the call.

The descriptor builder itself is one 256-thread group. Each thread binary
searches its expert boundary, scans a strided share of the M indices to prove
sortedness, participates in an eight-step prefix scan, and emits a strided
share of 16-byte descriptors (`quantized.h:2534-2669`). The valid descriptor
payload is only 8/16/32 KiB at the three M values; the index array is
64/128/256 KiB. Descriptor bytes cannot explain a 6–24 ms matrix kernel.

## 3. What each threadgroup does

### Expert tile

- `BM=BN=BK=32`, `WM=WN=2`
- 4 SIMD groups = 128 threads
- BF16 threadgroup storage:
  - X: `32 x (32+8)` = 2.5 KiB
  - W: `32 x (32+8)` = 2.5 KiB
  - total: **5 KiB**
- one SIMD group computes a 16x16 output quadrant
- each SIMD group retains four 8x8 FP32 accumulator fragments

The kernel chooses a BM16 body only for a descriptor tail of at most 16 rows;
otherwise it calls the BM32 body (`quantized.h:2728-2763`).

### Legacy sorted-RHS tile

- `BM=16, BN=BK=32`, `WM=1, WN=2`
- 2 SIMD groups = 64 threads
- BF16 threadgroup storage:
  - X: `16 x 40` = 1.25 KiB
  - W: `32 x 40` = 2.5 KiB
  - total: **3.75 KiB**
- each threadgroup scans its 16 sorted rows for expert boundaries and can run
  more than one matmul if a boundary crosses the tile
  (`quantized.h:2852-2959`)

For a full uniform 32-row region, one expert threadgroup and two legacy
threadgroups launch the same four SIMD groups. Each SIMD group has the same
16x16 output tile and the same K-depth. Therefore both routes execute the same
number of 8x8x8 FP32 `simdgroup_multiply_accumulate` instructions.

For gate-up, each SIMD group performs 1,024 such instructions; the whole BM32
threadgroup performs 4,096. Down performs one quarter as many per threadgroup
because K is 512. `BlockMMA`'s default accumulator type and inner loop are in
`steel/gemm/mma.h:434-531`.

## 4. Loader and traffic accounting

For W4, `pack_factor=2`: one byte contains two values
(`quantized.h:17-25`). For one full BK32 step:

| work for the same 32 output rows | one expert BM32 TG | two legacy BM16 TGs |
|---|---:|---:|
| useful FLOPs | 65,536 | 65,536 |
| X device-to-threadgroup loads | 2,048 B | 2,048 B |
| packed-W device loads | **512 B** | **1,024 B** |
| scale+bias load instructions | 512 B | 512 B |
| X+W threadgroup writes | 4,096 B | 6,144 B |
| MMA threadgroup reads | 8,192 B | 8,192 B |

This table explains both the expert route's win and its small size. BM32 halves
packed-weight loads, affine unpack/dequant work, and W threadgroup writes
relative to two BM16 tiles. It does not remove activation staging, metadata
loads, FP32 fragment loads, or any MMA.

The metadata pattern is worse than the checkpoint's compact byte count makes
it look. In the expert loader, 128 threads split a 32x32 packed-W tile. Four
threads serve each output row and all four independently load that row's BF16
scale and bias. BK32 is half of g64, so the same pair is loaded again in the
next K iteration: **eight issued scale/bias loads per unique pair**. The legacy
loader has two threads per output row and issues four loads per pair across
the two BK halves. Two BM16 row tiles restore the same total metadata issue
count as BM32. The loader mapping and `group_steps` state are visible at
`quantized.h:580-693`.

For the full expert calls, the source-level requests into threadgroup memory
(before cache coalescing) are approximately:

| M | gate logical request+store | down logical request+store | implied rate from E1 |
|---:|---:|---:|---:|
| 16,384 | 3.03 GiB | 1.56 GiB | 0.47–0.50 TB/s |
| 32,768 | 6.06 GiB | 3.13 GiB | 0.51–0.52 TB/s |
| 65,536 | 12.13 GiB | 6.25 GiB | about 0.53 TB/s |

These are **not DRAM bytes**. The unique W4/g64 expert footprint is only
288 MiB for gate-up and 144 MiB for down; X and W reuse can hit GPU caches.
The table instead shows why reporting the unique weight footprint divided by
time as “memory bandwidth” is misleading. The extended benchmark now labels
that quantity `unique-W GB/s` and separately reports useful TFLOP/s.

Two observations constrain the bottleneck:

- 0.47–0.53 TB/s of logical staging requests makes loader/cache issue a
  plausible secondary limiter.
- Dense BF16 gather, which removes affine unpack/dequant entirely, measured
  10.93 TFLOP/s versus 10.89 for W4 gate-up (`notes/028`). Therefore scalar
  dequantization is not the dominant limiter. FP32 MMA issue, fragment
  load/cast, and staging remain.

BK32 also executes two threadgroup barriers around every load and four
8-wide MMA substeps inside every K tile. BK64 can halve the outer-loop
barriers and metadata reloads, but it does not reduce the number of 8x8 MMA
instructions or their SIMD-group barriers.

## 5. Output layout and occupancy

Output is row-major BF16 `[M,N]`. Both N values are divisible by 32, and the
uniform target row counts are divisible by BM16 and BM32. The hot path uses
`store_result`, not `store_result_safe`/`store_result_slice`; SIMD-group lanes
write contiguous 16x16 quadrants (`qmm_t_expert_impl`,
`quantized.h:1311-1317`; `BlockMMA::store_result`,
`mma.h:534-583`). Output volume is 32/64/128 MiB for gate and
64/128/256 MiB for down as M grows. There is no transpose, scatter, or atomic
in the store. An output-layout rewrite has no first-principles 2x mechanism.

There are two different meanings of occupancy:

1. **Work/tile fill:** 100% for the uniform M targets. Real routing histograms
   can create at most one partial BM32 tile per nonempty expert; the BM16 tail
   body limits the waste.
2. **Hardware residency:** not established by source. The 5 KiB
   threadgroup allocation is small, but FP32 accumulator fragments and
   compiler temporaries can limit resident groups. Only Metal counters or the
   compiler's register/threadgroup report can settle this.

Grid occupancy is not in doubt: even M=16,384 launches 16K–33K useful expert
threadgroups. Increasing M changes the number of identical tiles, not the
kernel shape, and measured TFLOP/s moves only 10.5 to 11.2. Any tile experiment
must report SIMD occupancy/residency rather than using “more threadgroups” as
its mechanism.

## 6. Five smallest decision experiments

Run gate-up and down at all three M values, 5 warmups plus at least 25 timed
iterations, AC/High Power, with route counters proving the intended kernel.
Every candidate must first pass `SortedGatherQuantizedMMTests`, then full-model
greedy/KV/GDN checks before it can be kept.

### P0 — Upstream FP32 affine dequant arithmetic (prepared)

Named candidate: **`fp32-affine-dequant`**.

Upstream MLX
[`56e026d8`](https://github.com/ml-explore/mlx/commit/56e026d8a340e1b00a651d385722e11c1fbaa9f1)
([PR #4241](https://github.com/ml-explore/mlx/pull/4241)) converts BF16
scale/bias to float, performs `scale*q+bias` in float, then casts once when
storing the BF16 weight tile. It changes no dispatch, packing, tile shape,
output layout, or FP32 MMA contract.

Mechanism: isolate whether scalar BF16 affine arithmetic causes avoidable
conversion/instruction pressure in the shared loader. This reaches dense QMM,
legacy gather, and expert tiles, so it is measurable across the real
projection family. E3 says the likely gain is small; no M3 result is assumed.

Prepared artifacts:

- `patches/0003-perf-metal-dequantize-QMM-weights-in-float32.patch`
  — canonical MLX kernels plus Python dense/sorted-gather regression;
- `patches/0004-perf-mlx-dequantize-quantized-weights-in-float32.patch`
  — generated MLX-Swift mirrors plus Swift regression;
- `patches/0005-bench-report-gathered-QMM-delivered-TFLOPS.patch`
  — direct TFLOP/s and 23-TFLOP/s target reporting, while relabeling the old
  weight metric as a unique footprint rather than DRAM bandwidth.

The exact fixture distinguishes the arithmetic: code 15, BF16
scale `0.0185546875`, BF16 bias `-1.9921875`, and a 64-wide dot against ones
produce `-110.0` with BF16 affine arithmetic and `-109.5` with float affine
arithmetic followed by one BF16 store.

Kill:

- any fixture, sorted-gather tolerance, greedy token, KV, GDN, NaN/Inf, or
  decode regression;
- performance geomean below 1.03x or any target cell slower by more than 2%;
- even if it passes, classify it as cleanup—not the 2x lever—unless a target
  M3 measurement says otherwise.

### P1 — Broadcast and retain g64 scale/bias

Have one lane in each four-lane output-row subgroup load scale and bias, use a
SIMD shuffle to broadcast them, and retain the pair across the two BK32 steps
inside one g64 block. Do not change the dequantized BF16 bytes.

Mechanism: reduce eight issued metadata loads per unique pair to one in the
expert loader. Packed-weight loads, nibble unpack, and MMA remain unchanged.

Kill:

- anything other than bit-identical dequantized BF16 tiles;
- less than 1.03x at both projection shapes;
- a register/residency loss that erases the load reduction.

### P2 — One-axis compile-time tile sweep

Add exactly one AOT variant at a time:

1. `BK64` with BM32/BN32: align K tiling to g64, halve outer threadgroup
   barriers and metadata reloads; threadgroup storage rises from 5 to 9 KiB.
2. `BM64` with BN32/BK32: halve packed-W dequant/staging per output row;
   use a BM64 descriptor builder and a BM16/BM32 tail.
3. `BN64` with BM32/BK32: halve X staging per output column; preserve
   row-major stores.

Do not start with BM64xBN64xBK64: that confounds three mechanisms and can hide
an occupancy loss. Keep an axis only before composing it with the next.

Kill each axis:

- less than 1.05x useful-TFLOP/s geomean;
- more than 2% regression in any M/projection cell;
- lower resident SIMD occupancy, excessive register spill, or material
  metallib growth without a measured win.

E1's 4–7% BM32-over-BM16 gain and E3's 1.13x illegal monolithic ceiling make
single-digit/low-teens the honest expected range. This sweep cannot establish
a path to 23 TFLOP/s by itself.

### P3 — Measure descriptor/empty-grid cost without changing serving

In the existing non-`trust` mode, the host already synchronizes and reads
`count[0]`. For a diagnostic build only, dispatch exactly that many descriptor
rows instead of `max_tile_count`. Do not add the synchronization to `trust`.

Mechanism: remove the fixed 255 empty descriptor rows and place a direct upper
bound on descriptor/over-dispatch cost. If it matters, the shipping follow-up
would need a device-side/indirect dispatch; a host drain is not acceptable.

Kill:

- less than 3% at M=16,384 or no fixed-cost signature across M;
- any proposal to keep the readback drain in the serving trust path.

### P4 — Exact Metal 4 MPP BF16xBF16→FP32 roof

Do **not** force-enable the existing NAX route: E6 did that on the generation-15
M3 and found 11 failures, including ordinary QMM error up to 14, Qwen gate-up
error 5.03, Qwen down error 6.75, and sorted-boundary error 3.0–3.5. No timing
was taken under its correctness-first ratchet
(`artifacts/e6-portable-mpp-correctness.txt`).

Instead, build one new fixed-shape isolated kernel first. Dequantize affine
W4/g64 into bytes proven identical to the incumbent non-NAX BF16 tile, feed
BF16 activation and weight tensors to MPP `matmul2d`, set
`relaxed_precision=false`, accumulate/store through float at the incumbent
boundary, and compare against the current kernel.

Mechanism: this is the only candidate that can change the arithmetic execution
rate without lowering the model's input or accumulation precision. It may
still fail because M3/Apple9 can lower portable MPP to ordinary shader code.

After one gathered cell proves a different roof, cover the weighted real mix:
dense GDN `2048→8192`, `2048→4096`, `4096→2048`; shared-expert
`2048↔512`; and both gathered projections at M=8K–65K.

Hard decision:

- **<22 weighted TFLOP/s:** stop the same-quality 2.5x program on M3;
- **22–24:** continue only if the measured non-linear tail fits the full
  latency equation;
- **>=24:** earn full-model integration;
- any BF16/FP16 accumulation, relaxed precision, or requantized weight format:
  reject.

## 7. Changes and test status

Local submodule commits:

- MLX `5b626759` — FP32 dequant candidate and Python regression;
- MLX-Swift `b78dbc0` — generated mirrors and Swift regression;
- MLX-Swift `1d6f4bc` — TFLOP/s microbenchmark reporting.

The bot cannot push the two `Layr-Labs` submodule repositories (GitHub returns
403), so the three patches above are the self-contained handoff.

Static checks completed:

- patch 0003 reverse-applies to the modified canonical MLX tree;
- patch 0003 applies cleanly to the nested AOT source tree;
- patches 0004 and 0005 reverse-apply to the modified MLX-Swift tree;
- canonical and generated `quantized.h` are byte-identical after the prepared
  changes;
- Swift 6.3.2 parses both the new regression and extended benchmark sources.

No Metal runtime result is claimed. This cloud host cannot compile or execute
Metal. A CPU-only `swift test` build was also attempted, but the package fails
before test execution in pre-existing Linux-only `MLXFast` declarations after
Metal sources are excluded; the candidate code is not implicated or exercised
by that failure. The source-matched Mac sequence is:

1. apply E1 patch 0001 then patch 0003 to
   `libs/mlx-swift/Source/Cmlx/mlx`;
2. apply E1 patch 0002 then patches 0004 and 0005 to `libs/mlx-swift`;
3. rebuild the host and `mlx.metallib`;
4. run `FloatDequantizationTests`, `SortedGatherQuantizedMMTests`, then both
   `QwenExpertTilePerfTests` routes;
5. only after those pass, run B=1/B=2/B=4 CBv2 correctness and timing.

This source placement matters: `scripts/fetch-metallib.sh:9-23` builds the AOT
metallib from `libs/mlx-swift/Source/Cmlx/mlx`, not from top-level
`libs/mlx` or only the generated JIT mirrors.

## Sources

Repository primary sources:

- `libs/mlx/mlx/backend/metal/quantized.cpp`
- `libs/mlx/mlx/backend/metal/kernels/{quantized.h,quantized.metal}`
- `libs/mlx/mlx/backend/metal/kernels/steel/gemm/{loader.h,mma.h}`
- `libs/mlx/mlx/backend/common/gemma4_expert_qmm.h`
- `libs/mlx/mlx/backend/metal/device.cpp`
- `libs/mlx-swift/Source/Cmlx/mlx-generated/{quantized.cpp,metal/quantized.h}`
- `libs/mlx-swift/Tests/MLXTests/QwenExpertTilePerfTests.swift`
- `research/qwen36-prefill/notes/{011-explorer-moe-gdn,013-optimizer-metal,021-e1-tile-ab-results,023-e1-confirms-alu-bound,034-e6-portable-mpp-prereg}.md`

External API constraints:

- Apple,
  [Metal Shading Language Specification](https://developer.apple.com/metal/Metal-Shading-Language-Specification.pdf)
- Apple,
  [Metal Performance Primitives Programming Guide](https://developer.apple.com/download/files/Metal-Performance-Primitives-Programming-Guide.pdf)

