# 034 — E6: force portable MPP/NAX fallback on M3

Status: **dead — M3 fallback runs but fails correctness**

## Hypothesis

The M3 (generation 15) fails MLX's shipping NAX gate (`gen >= 17`),
but macOS 26.4 and the built metallib expose Metal Performance
Primitives TensorOps. Apple's portability contract says older GPUs use
an optimized shader fallback.

MLX's NAX quantized kernels already implement the legal mixed path:

- affine W4/g64 dequantization into BF16 tiles;
- `mpp::tensor_ops::matmul2d`;
- BF16 operands and FP32 destination/accumulator;
- no activation requantization or half accumulation.

E6 asks whether that fallback is correct and faster on this exact M3.

## Patch

`patches/e6-force-portable-nax-experiment.patch` adds one opt-in process
override:

```
MLX_FORCE_NAX_EXPERIMENT=1
```

Defaults and shipping generation gates remain unchanged.

## Ratchet

1. Rebuild the host test binary against the override; use the existing
   source-matched NAX-complete metallib.
2. Run `SortedGatherQuantizedMMTests`.
3. Any crash, command-buffer error, mismatch, or unsupported kernel:
   dead; restore source; no timing.
4. If correct, run exact Qwen QMM/gather microbench cells. Continue only
   at ≥22 weighted TFLOPS (note 026 threshold).
5. Only a ≥22 TFLOPS legal result earns dense-shape census and full CBv2.

The M5 NAX headline is not evidence. Only this M3 result counts.

## Result

The opt-in host selected NAX/MPP on generation-15 M3 and executed the
existing NAX-complete metallib. It did not crash, proving API
availability. It failed `SortedGatherQuantizedMMTests`:

- **11 assertion failures**;
- ordinary QMM row-count 33 error up to 14;
- Qwen gate_up random-tensor error 5.03;
- Qwen down random-tensor error 6.75;
- sorted boundary fixtures error 3.0–3.5;
- the non-NAX sortedness retraction case became unavailable by design.

Artifact: `artifacts/e6-portable-mpp-correctness.txt`.

The deterministic constant-output expert fixtures happened to pass, so
an availability smoke test alone would have produced a false green.
Random/full-shape and boundary tests exposed the M3 optimized-shader
fallback's different output.

Per preregistration: no timing and no full-model run. The host override
was reversed, source trees compared equal, and the baseline test host
rebuilt.

This closes “force MLX's existing NAX kernels on M3.” It does not by
itself close a new custom MPP kernel with byte-identical incumbent
dequantized operands, but such a kernel cannot reuse the existing NAX
implementation as-is.
