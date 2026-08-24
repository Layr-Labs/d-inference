# 046 — Bounded strict MPP tile and execution-scope sweep

Status: **queued on the M3 Max; no serving integration**

## Question

E13–E15 measured only the supported strict M16×N32×K16
`execution_simdgroup` route. This experiment asks:

> Among a bounded Metal 4 matrix around that schedule, what is the fastest
> numerically valid BF16×BF16→FP32 rate on complete Qwen projection shapes,
> and does it reach the 22 TFLOP/s continuation threshold?

This is a finite implementation sweep, not a proof of a physical hardware
limit. A miss closes only the enumerated descriptors, scopes, and shapes.

## Compile matrix

`probes/mpp-throughput/candidates.tsv` independently compiles 60 candidates:

- output tiles M16×N16, M16×N32, M16×N64, M32×N32, and M64×N32;
- static reduction tiles K16 and K32;
- `execution_simdgroup`, `execution_simdgroups<2>`, and
  `execution_simdgroups<4>` for every tile;
- cooperative-input and direct-tensor-input forms for every descriptor/scope.

Every descriptor is strict (`relaxed_precision=false`) and uses
`multiply_accumulate`, supported cooperative BF16 input loads, one cooperative
FP32 accumulator across the logical K loop, and a supported cooperative FP32
store. Each candidate is compiled and linked separately so one rejected
descriptor or scope cannot suppress another. The artifact records Metal
compile, metallib link, pipeline creation, first execution, and numerical-gate
status independently. The SDK permits input cooperative tensors only at
single-SIMD-group scope, so the compile matrix retains the expected 2/4-group
cooperative-input rejections while the paired tensor-input candidates test
those scopes legally. Both forms retain a cooperative FP32 destination and
supported cooperative store.

Single-SIMD-group candidates pack four independent output tiles per
threadgroup. Multi-SIMD-group candidates launch exactly two or four SIMD groups
cooperatively for one output tile, matching the Metal execution-scope contract.

## Correctness and shapes

The Steel reference is the incumbent FP32 8×8×8
`simdgroup_multiply_accumulate` schedule. It completes first for every matrix.
Every pipeline-executable MPP candidate must then pass the unchanged ordinary
QMM `atol=1e-3, rtol=1e-3` gate, BF16-rounded output equality, and the
non-finite gate on all three deterministic full matrices:

| Shape | M | K | N | Role |
|---|---:|---:|---:|---|
| wide | 2,048 | 2,048 | 8,192 | GDN/attention wide projection |
| primary | 2,048 | 2,048 | 1,024 | routed fused gate/up |
| down | 2,048 | 512 | 2,048 | shared/routed down |

Any compiler, linker, pipeline, command-buffer, or numerical rejection is
recorded and excluded from the valid timing set.

## Measurement and decision

On the exact `Mac15,9` M3 Max, AC and High Power are required before
compilation, before timing, and after timing. Darkbloom must be stopped. Every
valid candidate and Steel receive:

- three complete warmup rounds per shape;
- 16 measured command buffers per shape in balanced rotating order;
- command-buffer GPU, kernel, and CPU-wall timestamps for every sample;
- median, p10/p90, minimum/maximum, and useful `2*M*N*K` TFLOP/s.

The decision uses the fastest valid candidate/shape GPU median:

- `>=22 TFLOP/s`: continue to a serving-integration correctness ratchet;
- `<22 TFLOP/s`: stop this enumerated same-quality M3 matrix.

The fastest individual sample is also reported but does not replace the median
decision metric. Regardless of the result, this probe changes no shipping code
and must report `hardware_theorem=false`.

Expected raw artifacts:

- `artifacts/mpp-tile-scope-sweep-m3.txt`;
- `artifacts/mpp-tile-scope-compile-matrix-m3.tsv`.
