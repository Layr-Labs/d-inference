# 035 — E7 preregistration: upstream FP32 affine dequantization

Status: **dead — 2.97% routed gain misses 5% continuation bar**

## Hypothesis

Upstream MLX PR #4241 (`56e026d8`) converts affine scale/bias arithmetic
to FP32 and casts each reconstructed weight once into the tile dtype.
It removes repeated BF16 conversions in the shared QMM loaders while
retaining W4 storage and FP32 matrix accumulation.

Prepared patches:

- `patches/0003-perf-metal-dequantize-QMM-weights-in-float32.patch`
- `patches/0004-perf-mlx-dequantize-quantized-weights-in-float32.patch`

No upstream M3/Qwen E=256 result exists. This run measures it.

## Numerical warning

The change deliberately moves a rounding boundary. Its regression
distinguishes old `-110.0` from new `-109.5`. It is not the current
Darkbloom arithmetic by declaration. It survives only if:

1. upstream adversarial regression passes;
2. all existing sorted/Qwen QMM tolerances pass unchanged;
3. real-model B=1/B=2/B=4 greedy checksums remain identical.

## Ratchet

1. Build a source-matched metallib and host test binary.
2. Run focused dequant regression + `SortedGatherQuantizedMMTests`.
3. If green, run exact Qwen microbench; require ≥1.05× to fund a full
   model run (anything smaller cannot matter).
4. If ≥1.05×, run adjacent B=4 control/candidate with default geometry
   and exact checksum comparison.
5. Any checksum mismatch or decode loss: dead.

This is a selective upstream port, not a wholesale MLX update.

## Result

On the M3 Max, AC / High Power:

- upstream adversarial `-109.5` regression: PASS;
- all 10 `SortedGatherQuantizedMMTests`: PASS;
- route diagnostics: tile hits 25/25, NAX false.

At the exact serving M=16,384 cell:

| Projection | Source-matched baseline | FP32 dequant | Speedup |
|---|---:|---:|---:|
| gate_up | 6.3125 ms | 6.1445 ms | **1.027×** |
| down | 3.3834 ms | 3.2718 ms | **1.034×** |
| combined | 9.6959 ms | 9.4163 ms | **1.030×** |

Artifacts:

- `artifacts/e7-fp32-dequant-regression.txt`
- `artifacts/e7-fp32-dequant-correctness.txt`
- `artifacts/e7-fp32-dequant-perf.txt`

This misses the preregistered 1.05× bar, so no full-model run was
funded. The candidate also changes the incumbent rounding point and
would still owe exact greedy parity for a 3% microkernel gain.

Both patches were reversed. The Cmlx source tree compared byte-for-byte
with baseline, the cached baseline metallib SHA
`08c48889aee7a8d126e47b12528e8f3e2c43f45866de938be11a8777a952b033`
was restored, and the test host rebuilt.
