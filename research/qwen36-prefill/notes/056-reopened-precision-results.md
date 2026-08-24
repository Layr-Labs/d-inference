# 056 — Reopened precision paths: no M3 speed lane

Status: **measured; three candidates dead on performance**

The owner override permits numerical drift if quality passes. Three
previously correctness-vetoed paths were timed.

## E17 — half accumulator

The E5 half-accumulator metallib was benchmarked despite its adversarial
errors.

| Cell | FP32 baseline | Half accumulator | Speedup |
|---|---:|---:|---:|
| gate_up T2048 | ~6.30 ms | 6.2926 ms | ~1.00× |
| down T2048 | ~3.35 ms | 3.4379 ms | 0.97× |
| gate_up T8192 | ~24.30 ms | 24.4006 ms | 1.00× |
| down T8192 | ~12.44 ms | 12.3940 ms | 1.00× |

No faster half-accumulation lane exists in this Steel path.
Artifact: `artifacts/e17-half-accum-perf.txt`.

## E18 — native uint4 affine factoring

The standalone `bfloat × uint4b_format → float` kernel was allowed to
run despite moving the per-weight BF16 rounding boundary. A parallel
8,192-tile dispatch (536.9 MFLOP useful work) measured:

```
GPU median = 207.46 µs
rate       = 2.5878 TFLOPS
```

It is more than 5× slower than strict BF16 MPP/Steel on M3. Quality
evaluation cannot rescue a performance loss.
Artifact: `artifacts/e18-native-uint4-parallel.txt`.

## E19 — relaxed MPP

Setting `relaxed_precision=true` on static/dynamic MPP produced exactly
the strict rates:

| Path | Relaxed rate |
|---|---:|
| Steel K8×2 control | 13.68 TFLOPS |
| MPP static K16 | 13.72 |
| MPP dynamic K8 | 3.35 |

The M3 shader fallback does not expose a lower-precision accelerator
through this flag. Artifact: `artifacts/e19-mpp-relaxed.txt`.

## Verdict

Precision policy is open, but these implementations do not accelerate.
The next search moves to **work deletion and state construction**:
adaptive experts, layers/tokens, cache/state approximation, reuse, and
speculative correction.
