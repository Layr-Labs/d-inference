# 046 — Bounded strict MPP tile and execution-scope sweep

Status: **complete — bounded maximum 13.4182 TFLOP/s misses 22; no serving
integration**

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
`multiply_accumulate`, either supported cooperative BF16 input loads or direct
BF16 tensor inputs, one cooperative FP32 accumulator across the logical K loop,
and a supported cooperative FP32 store. Each candidate is compiled and linked
separately so one rejected
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
Every Steel and MPP destination is poisoned with an all-ones NaN bit pattern
immediately before its correctness dispatch, so a partial or no-op kernel
cannot inherit valid output from a previous candidate.
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

## M3 result

The final source-matched capture completed on:

```text
Apple M3 Max, Mac15,9
macOS 26.4 (25E246)
Xcode 26.5 (17F42), Apple metal 32023.883
AC Power, powermode=2 before and after
no thermal or performance warning before or after
```

### Compile and execution matrix

Of the 60 independently compiled candidates:

- 35 compiled and linked;
- all 35 created pipelines and executed on all three full shapes;
- 25 were compiler-rejected and never linked;
- no linked candidate was rejected at pipeline or command-buffer execution.

The 25 compiler rejections are informative API boundaries:

- all 20 cooperative-input candidates at
  `execution_simdgroups<2/4>` failed because input cooperative tensors require
  one SIMD group;
- cooperative M16×N16×K16 failed because at least one descriptor dimension
  must be 32;
- cooperative M16×N64 at K16/K32 failed because cooperative-input N must be 16
  or 32;
- cooperative M64×N32 at K16/K32 failed because cooperative-input M must be 16
  or 32.

Every paired direct-tensor-input descriptor/scope compiled, including the
requested M32×N32 and M64×N32 2/4-SIMD-group candidates.

### Correctness

Steel completed first and every destination was NaN-poisoned immediately before
its candidate dispatch. All 35 executable candidates passed all three matrices:

```text
comparisons=105
candidate output elements checked=807,403,520
fp32_changed=0
bf16_changed=0
qmm_1e-3=pass
nonfinite=0
```

Correctness therefore completed before the first warmup or timing command.

### Throughput

All 35 valid candidates and Steel recorded 16 GPU-complete samples on each
shape: 1,728 measured command buffers in total. The fastest valid median for
each full shape was:

| Shape | Fastest candidate | GPU TFLOP/s |
|---|---|---:|
| M2048 K2048 N8192 | M32×N32×K32, one SIMD group, cooperative inputs | **13.4182** |
| M2048 K2048 N1024 | M16×N64×K32, two SIMD groups, tensor inputs | **12.8865** |
| M2048 K512 N2048 | M16×N64×K32, two SIMD groups, tensor inputs | **13.0299** |

The global maximum is:

```text
fastest valid median       13.4182 TFLOP/s
fastest valid sample       13.4236 TFLOP/s
continuation threshold     22.0000 TFLOP/s
median shortfall            8.5818 TFLOP/s (39.0%)
fraction of threshold       0.6099
```

The best schedule improves the same wide shape only 1.048× over the current
M16×N32×K16 cooperative schedule's 12.8060 TFLOP/s. Neither tile width,
K32, nor 2/4-group cooperation exposes the missing near-2× arithmetic lane.

## Decision and scope

Stop this enumerated same-quality M3 MPP matrix: every executable candidate
misses 22 TFLOP/s, including the fastest individual sample. Do not integrate
any candidate into serving from this result.

This is a **bounded measured maximum, not a hardware theorem**. It closes the
five output tiles, K16/K32, three execution scopes, two supported input forms,
three measured Qwen shapes, and this SDK/M3 runtime. It does not prove a bound
over unenumerated tiles, other operation decompositions, future SDK lowering,
or future Apple GPU generations. Counter saturation and the other independent
structure/routing requirements from note 032 also remain outside this probe.

Raw artifacts:

- `artifacts/mpp-tile-scope-sweep-m3.txt`;
- `artifacts/mpp-tile-scope-compile-matrix-m3.tsv`.
