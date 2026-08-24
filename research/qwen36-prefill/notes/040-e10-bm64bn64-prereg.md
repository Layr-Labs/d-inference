# 040 — E10 preregistration: BM64×BN64 expert tile

Status: **dead — correct, +3–8% at large M, regresses smaller M**

Isolated-agent patches:

- `patches/e10-bm64bn64-mlx-experiment.patch`
- `patches/e10-bm64bn64-mlx-swift-experiment.patch`

## Hypothesis

At the current M=16,384 uniform shape, every expert has exactly 64
rows. BM64 consumes all rows in one descriptor instead of two BM32
descriptors. BN64 consumes two output tiles at once. Together they cut
useful threadgroups by roughly 4× and increase activation/weight reuse.

BK remains 32, preserving affine group handling and the established
8-wide FP32 accumulation order. Default geometry remains BM32×BN32.

Selection:

```
MLX_GATHER_QMM_EXPERT_TILE_GEOMETRY=bm64_bn64
```

## Risks

- larger accumulator/register footprint can reduce residency or spill;
- tail experts waste more work, covered by 1/16/17/63/64/65-row cases;
- diagnostics ABI changes are mirrored across C/Swift in the experiment;
- metallib must contain both builder and tile AOT symbols.

## Ratchet

1. Build source-matched host and metallib.
2. Pass complete sorted/Qwen correctness suite under BM64×BN64.
3. Separate-process BM32×BN32 versus BM64×BN64 at M=16,384/32,768.
4. Require ≥1.30× in every gate_up/down cell, 25/25 hits, zero
   fallbacks.
5. Otherwise delete without a full-model run.

## Result

All 10 sorted/Qwen correctness tests passed. Every timed cell reported
25 hits / 0 fallbacks.

| Cell | BM32×BN32 | BM64×BN64 | Speedup |
|---|---:|---:|---:|
| gate_up T512 | 2.1292 ms | 2.1508 | 0.990× |
| down T512 | 1.2450 | 1.1903 | 1.046× |
| gate_up T1024 | 3.3294 | 5.8230 | **0.572×** |
| down T1024 | 1.8321 | 3.0863 | 0.594× |
| gate_up T2048 | 6.3004 | 6.0037 | 1.049× |
| down T2048 | 3.3495 | 3.2415 | 1.033× |
| gate_up T4096 | 12.3270 | 11.5238 | 1.070× |
| down T4096 | 6.3620 | 6.1147 | 1.040× |
| gate_up T8192 | 24.2983 | 22.6000 | **1.075×** |
| down T8192 | 12.4437 | 11.5308 | **1.079×** |

Artifacts:

- `artifacts/e10-bm64bn64-correctness.txt`
- `artifacts/e10-bm32bn32-control.txt`
- `artifacts/e10-bm64bn64-candidate.txt`

The large geometry recovers only low single digits and wastes nearly
half the arithmetic when rows/expert=32. Per-shape routing could avoid
the regression but still misses 1.30× everywhere. No full-model run.

Remote source, metallib, and host were restored to baseline.
