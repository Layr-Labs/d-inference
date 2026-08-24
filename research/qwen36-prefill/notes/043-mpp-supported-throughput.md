# 043 — Supported Metal 4 MPP BF16→FP32 throughput gate

Status: **implemented; M3 measurement pending**

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
