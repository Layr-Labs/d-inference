# 043 — Supported Metal 4 MPP BF16→FP32 throughput gate

Status: **complete — correct, but 12.65 weighted TFLOP/s misses the 22
continuation gate**

## Question

Note 042 established that the supported Metal 4 cooperative-tensor
`load`/`store` route can preserve the incumbent reduction contract on the M3
fallback. This experiment asks the next, narrower question:

> Does static-K16 MPP BF16×BF16→FP32 sustain at least 22 useful TFLOP/s over a
> Qwen-relevant dense K/N mix on the M3 Max?

This is an isolated arithmetic probe. It does not dequantize packed weights,
gather experts, call MLX, or change serving.

## Candidate and control

`probes/mpp-throughput/` builds two Metal kernels with the same buffers,
logical matrices, dispatch tile, and FP32 output boundary.

Candidate:

- Metal 4 `matmul2d_descriptor(16, 32, 16, ..., relaxed_precision=false,
  multiply_accumulate)`;
- one SIMD group owns one M16×N32 output tile;
- each K16 input tile enters only through supported cooperative-tensor
  `load`;
- one FP32 cooperative destination is initialized once, retained across the
  complete logical K loop, and stored once.

Control:

- actual `metal::simdgroup_matrix<float,8,8>` and
  `simdgroup_multiply_accumulate`;
- BF16 A/B bytes are promoted into FP32 Steel fragments exactly as
  `BaseMMAFrag<float>` does;
- eight FP32 8×8 accumulators cover the same M16×N32 tile and remain live
  across K8 steps;
- the same FP32 output buffer shape is stored once.

Four independent SIMD groups run per threadgroup. There is no threadgroup
staging or cross-SIMD communication in either arm.

## Shape and weight ledger

Every cell uses `M=2048`. This includes the requested primary
`M=2048,K=2048,N=1024` cell and the real dense K/N variants from note 026.
The weight is useful model GFLOP per source token represented by the cell:

| Cell | K | N | GFLOP/token weight |
|---|---:|---:|---:|
| GDN + attention wide input | 2,048 | 8,192 | 1.34217728 |
| GDN z input | 2,048 | 4,096 | 0.50331648 |
| GDN a/b | 2,048 | 32 | 0.00786432 |
| GDN + attention output | 4,096 | 2,048 | 0.67108864 |
| attention KV + shared gate/up | 2,048 | 512 | 0.20971520 |
| shared + routed down | 512 | 2,048 | 0.75497472 |
| router | 2,048 | 256 | 0.04194304 |
| routed fused gate/up primary | 2,048 | 1,024 | 1.34217728 |
| **Represented** | | | **4.87325696** |

The only omitted linear work is the scalar shared-expert gate:
`0.00016384 GFLOP/token`, so coverage is 99.99664% of the
`4.8734208 GFLOP/token` ledger. Weighted throughput is:

```text
R_weighted = sum(weight_i) / sum(weight_i / R_i)
```

This dispatch/work-weighted harmonic result is the useful model work divided
by predicted time. An arithmetic average of cell TFLOP/s is not used.

## Correctness gate

The harness allocates one deterministic BF16 A buffer and one deterministic
BF16 B buffer per full measured shape. Both arms consume those exact buffers.
Before any warmup or timing dispatch, every output element of every shape is
compared against Steel:

- FP32 changed count and maximum absolute/relative error;
- existing ordinary-QMM `atol=1e-3, rtol=1e-3`;
- BF16-rounded output equality;
- non-finite count and FP32 output hashes.

Any shape failure exits before the first timing command buffer.

## Measurement protocol

- exact host gate: `Mac15,9`, Apple M3 Max;
- AC and High Power (`powermode=2`) before compilation, before timing, and
  after timing;
- provider process absent; before/after process and thermal snapshots;
- one complete dense matrix per dispatch and one dispatch per command buffer;
- three ABBA warmup blocks, giving six GPU-complete warmups per arm;
- eight measured ABBA blocks (`MPP, Steel, Steel, MPP`), giving **16**
  GPU-complete samples per arm and shape;
- command-buffer `gpuStartTime`/`gpuEndTime`, kernel timestamps, and CPU wall
  are recorded for every sample;
- useful work is exactly `2*M*K*N`, with median, p10/p90, min/max, and useful
  TFLOP/s reported.

The artifact-producing command is:

```bash
cd research/qwen36-prefill/probes/mpp-throughput
./run.sh /tmp/mpp-throughput-result
```

`result.txt` includes source SHA-256 hashes, toolchain and machine identity,
power/process evidence, compiler status, all raw samples, summaries, weighted
rates, and the final decision.

## Preregistered decision

- any correctness failure: reject before timing;
- `<22` weighted useful GPU TFLOP/s: stop the same-quality M3 path;
- `22–24`: continue only if the measured non-linear tail fits the exact
  full-model latency equation;
- `>=24`: earn the next integration/correctness ratchet;
- CPU wall is a required cross-check, but the threshold is applied to
  command-buffer GPU time;
- no serving integration is part of this experiment regardless of result.

## M3 result

The probe compiled and completed on the preregistered host:

```text
Apple M3 Max, Mac15,9
macOS 26.4 (25E246)
Xcode 26.5 (17F42), Apple metal 32023.883
AC Power, powermode=2 before and after
no thermal or performance warning
```

All eight full shapes were FP32 bit-identical to Steel. Across 37,289,984
output elements:

```text
fp32_changed=0
bf16_changed=0
max_abs=0
qmm_1e-3=pass
nonfinite=0
```

Correctness finished before the first warmup. Every cell then recorded six
GPU-complete warmups per arm and 16 GPU-complete measured samples per arm in
ABBA order.

Command-buffer GPU medians:

| Shape (M=2048) | MPP ms | MPP TFLOP/s | Steel ms | Steel TFLOP/s | MPP/Steel |
|---|---:|---:|---:|---:|---:|
| K2048 N8192 | 5.375229 | 12.7845 | 7.088813 | 9.6941 | 1.3188× |
| K2048 N4096 | 2.630396 | 13.0626 | 2.891187 | 11.8843 | 1.0991× |
| K2048 N32 | 0.068708 | 3.9069 | 0.110354 | 2.4325 | 1.6061× |
| K4096 N2048 | 2.676583 | 12.8372 | 2.880667 | 11.9277 | 1.0762× |
| K2048 N512 | 0.352812 | 12.1735 | 0.382354 | 11.2330 | 1.0837× |
| K512 N2048 | 0.339375 | 12.6555 | 0.362375 | 11.8523 | 1.0678× |
| K2048 N256 | 0.200458 | 10.7129 | 0.215479 | 9.9661 | 1.0749× |
| **K2048 N1024 primary** | **0.682875** | **12.5791** | **0.733042** | **11.7182** | **1.0735×** |

The real-model-work harmonic result is:

| Arm | GPU TFLOP/s | CPU-wall TFLOP/s |
|---|---:|---:|
| supported MPP K16 | **12.6478** | 9.8720 |
| Steel FP32 | **11.0401** | 8.8513 |

MPP is 1.1456× Steel by the weighted GPU metric. The favorable N8192 cell is
not representative of the narrower mix, and even it reaches only 12.78
TFLOP/s. The complete artifact, including all 256 measured samples and raw
command-buffer timestamps, is
`artifacts/mpp-supported-throughput-m3.txt`.

Captured source hashes:

```text
kernel.metal       6abeb91ef028e078f28a41693bb53eef115127f7dd098193688cdfc4e86c68dc
ProbeTypes.swift   636a598b5ba06ff8019885e5bd0ac0193efa5468d32f778d36e183f139052253
MetalRunner.swift  6135bafe0badbb3d8eed7b227e144caee15eb14021e208dab823646f5bd1e9a7
main.swift         88fa2db7b0c6091ad1589eeccd4c3bdd45c79c2e4a927c20a5d30ea96bb1f128
run.sh             ce1119dc38f897b0ac128a59919a5842416b5fc4108b4311c62ac3eb49f44c0f
```

## Decision

Candidate A is numerically legal through supported cooperative-tensor
load/store, but it misses the preregistered continuation threshold by 9.35
TFLOP/s (42.5%). Stop this same-quality MPP line on M3. Do not build the
dequant/gather path or wire serving from this result.

This is a measured implementation ceiling for the tested M16×N32 static-K16
schedule, not a theorem about every possible MPP tile or a future Apple
generation. It is nevertheless the requested ratchet: this schedule cannot
provide the arithmetic rate required by the current 2.5× program.
