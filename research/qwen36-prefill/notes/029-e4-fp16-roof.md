# 029 — E4 FP16 does not expose a 2× M3 arithmetic lane

Status: **measured; dead**

## Hypothesis

M3 might execute FP16 matrix arithmetic at 2× BF16 throughput. If so,
an FP16 prefill-only path could be worth testing end-to-end, subject to
the strict greedy-checksum gate.

## Experiment

Same E=256, M=16,384, top-8 uniform expert geometry and K/N as E3.
Compare BF16 and FP16 inputs/scales through:

- affine W4/g64 gather-QMM;
- dequantized dense gather-MM;
- illegal monolithic dense GEMM roof.

Artifact: `artifacts/e4-fp16-roof.txt`.

## Result

| Projection/path | BF16 | FP16 | FP16/BF16 |
|---|---:|---:|---:|
| gate_up W4 gather | 10.89 TFLOPS | 11.23 | **1.03×** |
| down W4 gather | 10.16 | 10.78 | **1.06×** |
| gate_up dense gather | 10.90 | 10.86 | 1.00× |
| down dense gather | 8.37 | 8.37 | 1.00× |
| gate_up monolithic | 12.30 | 12.29 | 1.00× |
| down monolithic | 11.65 | 11.59 | 1.00× |

## Verdict

There is no hidden 2× FP16 lane available to these Metal/Steel matrix
kernels on this M3 Max. The small W4 gain is at most 6% and changing
the model's activation dtype would additionally face the full-model
checksum/quality gate. Do not build that invasive path.

Combined with E3, precision and dequantization choices cannot provide
the missing 2.5×.
