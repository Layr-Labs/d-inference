# 039 — E9 preregistration: exact BK64 expert tile

Status: **dead — correct but ≤1.008×**

Isolated-agent patches:

- `patches/e9-bk64-mlx-experiment.patch`
- `patches/e9-bk64-mlx-swift-experiment.patch`

## Hypothesis

Raise only expert-kernel K depth from BK32 to BK64. Group size is 64,
so one outer iteration now consumes one complete affine quantization
group. For gate_up K=2,048, full-threadgroup barriers fall 129→65; for
down K=512, 33→17.

Everything else stays fixed: BM32, BN32, sorted descriptors, W4 bytes,
BF16 reconstructed tiles, FP32 accumulation, BF16 output, and the
8-wide K fragment order.

## Resource risk

Threadgroup memory rises:

| Variant | X + W |
|---|---:|
| BK32 | 5,120 B |
| BK64 | 9,216 B |

BK64 fits the M3 32 KiB limit but can halve memory-limited resident
threadgroups. Fewer outer barriers may lose to lower occupancy.

## Selection

Default remains BK32. Only

```
MLX_GATHER_QMM_EXPERT_BK=64
```

selects the new AOT symbol. Missing/incompatible metallib fails the
explicit experiment closed.

## Ratchet

1. Build host + source-matched metallib.
2. Run selector tests and `SortedGatherQuantizedMMTests` under BK64.
3. Run separate-process BK32/BK64 microbench at M=16,384 and 32,768.
4. Kill unless every gate_up/down cell is ≥1.30×, hits 25/25, and has
   zero fallbacks.
5. Only then fund a full CBv2 checksum run.

## Result

`SortedGatherQuantizedMMTests`: 10/10 PASS under BK64.

Both arms used one source-matched metallib and separate processes;
diagnostics reported 25 hits / 0 fallbacks in every cell.

| Cell | BK32 | BK64 | BK32/BK64 |
|---|---:|---:|---:|
| gate_up T2048 | 6.3045 ms | 6.3104 ms | 0.999× |
| down T2048 | 3.3518 | 3.3447 | 1.002× |
| gate_up T4096 | 12.3299 | 12.2278 | **1.008×** |
| down T4096 | 6.3552 | 6.3412 | 1.002× |

Artifacts:

- `artifacts/e9-bk64-correctness.txt`
- `artifacts/e9-bk32-control.txt`
- `artifacts/e9-bk64-candidate.txt`

Halving full-threadgroup outer barriers is immaterial; unchanged
8-wide SIMD MMA issue dominates, while reduced residency offsets the
small barrier saving. This misses the 1.30× bar in every cell, so no
full-model run.

Remote source, metallib, and host were restored to baseline.
