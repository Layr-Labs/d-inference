# 033 — E5 preregistration: half-accumulator expert MMA

Status: **dead — correctness failed before timing**

## Hypothesis

Steel `BlockMMA` defaults `AccumType = float`. E4 showed FP16 inputs
remain at the BF16/FP32-accumulation rate, despite an external M3 Max
specification of ~28.4 FP16 versus ~14.2 FP32 TFLOPS. Changing only the
expert tile's accumulator to `half` may expose that lane.

## Why this is probably illegal

K=2,048 accumulation in half changes rounding on every partial and can
overflow where FP32 does not. The model contract is current BF16 inputs
with FP32 accumulation. A speedup is irrelevant if:

- sorted W4 differs from the dequantized/legacy references beyond the
  existing QMM tolerance;
- any NaN/Inf appears;
- full-model greedy checksums differ at B=1/B=2/B=4.

## Experiment

Named patch: `patches/e5-half-accum-experiment.patch`.

It changes only the experimental AOT expert-tile Metal kernel:

- template `qmm_t_expert_impl` on accumulator type (default remains float);
- instantiate `half` from `affine_gather_qmm_gemma4_expert_tiles`.

Host routing, scheduler, weights, inputs, output dtype, and non-expert
kernels remain unchanged.

## Ratchet

1. Build source-matched metallib.
2. Run `SortedGatherQuantizedMMTests`.
3. **Any correctness failure: dead; stop without timing.**
4. If correct, run `QwenExpertTilePerfTests`; require ≥1.8× to justify
   the full-model checksum matrix (2.5× needs ~27 TFLOPS).
5. Only then run B=1/B=2/B=4 CBv2.

## Result

The source-matched Metal kernel compiled after making the epilogue
accumulator-preserving. `SortedGatherQuantizedMMTests` then failed:

- **30 assertion failures** across Gemma and Qwen shapes;
- gate_up maximum absolute errors up to **2,368** / **1,152**;
- down errors up to **96**;
- failures at M=4,096 through 65,536, aligned, skewed, and fragmented;
- ordinary non-expert QMM and selector/fallback tests remained green.

Artifact: `artifacts/e5-half-accum-correctness.txt`.

The random-tensor tolerance case happened to pass, but deterministic
constant-output fixtures exposed half overflow/rounding at model-scale
dot lengths. This is exactly why correctness precedes timing.

No performance test and no full-model run were performed. The patch was
reversed and the baseline source/metallib restored byte-for-byte.
