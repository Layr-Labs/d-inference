# 043 — Dynamic-K=8 MPP misses the all-projection threshold

Status: **complete — numerically rejected and 7.0× below the 22 TFLOP/s gate**

## Question

The fixed reduction-order probe (note 042 on the integration branch; note 041
in this isolated branch's ancestry) found a legal Metal 4 schedule that passed
the existing QMM tolerance at M=16, N=32, K=16:

```text
dynamic K=8 multiply
→ FP32 cooperative destination
→ explicit FP32 addition
→ supported cooperative store
```

This experiment asks whether that exact 16×32 output-tile schedule remains
legal at full reduction lengths and can sustain the **≥22 TFLOP/s weighted
all-projection threshold** on the M3 Max. It is a standalone probe only. No
MLX, provider, scheduler, or serving path changed.

## Implementation

`probes/mpp-reduction/benchmark/` compares three kernels over the same BF16 A
buffer, BF16 B buffer, FP32 destination allocation, dimensions, and dispatch
order:

1. incumbent Steel 8×8 `simdgroup_multiply_accumulate`, reduced in K=8 steps;
2. static-K=16 MPP `multiply`, using supported cooperative BF16 input loads,
   FP32 partials, explicit FP32 accumulation, and cooperative store;
3. dynamic-K=8 MPP `multiply`, using supported tensor inputs, an FP32
   cooperative destination per step, explicit FP32 accumulation, and
   cooperative store.

All MPP descriptors set `relaxed_precision=false`. The SDK explicitly rejects
input cooperative tensors for a dynamic inner dimension, so the dynamic path
uses the same supported tensor-input/cooperative-destination form that passed
the fixed probe; it does not use MLX's invalid manual register mapping.

The timing ledger covers 99.9966% of Qwen's token-linear work for the
threshold-defining `[4,2048]` pass (8,192 dense rows):

| Projection class | M | N | K | model dispatches |
|---|---:|---:|---:|---:|
| GDN/attention input | 8,192 | 8,192 | 2,048 | 40 |
| GDN wide | 8,192 | 4,096 | 2,048 | 30 |
| GDN/attention output | 8,192 | 2,048 | 4,096 | 40 |
| attention K/V + shared gate/up | 8,192 | 512 | 2,048 | 100 |
| routers | 8,192 | 256 | 2,048 | 40 |
| GDN small projections | 8,192 | 32 | 2,048 | 60 |
| shared down | 8,192 | 2,048 | 512 | 40 |
| routed gate-up | 65,536 | 1,024 | 2,048 | 40 |
| routed down | 65,536 | 2,048 | 512 | 40 |

Only the N=1 shared scalar gate is omitted (0.0034% of linear FLOPs). The
routed cells deliberately use one common dense B buffer, making this an
arithmetic-schedule roof rather than a gathered-expert or serving claim.
Effective throughput is `Σ useful FLOPs / Σ median GPU time`, weighted by the
dispatch counts above; it is not an arithmetic mean of cell TFLOP/s.

## Measurement protocol

The final capture ran on `Mac15,9`, Apple M3 Max 40-core GPU, macOS 26.4, Xcode
26.5, and Metal 4:

- AC and High Power (`powermode=2`) verified before and after;
- no thermal or performance warning recorded before or after;
- five warmup command buffers per variant per cell;
- 21 timed samples per variant per cell, with two dispatches per sample;
- balanced rotating variant order to distribute drift;
- command-buffer GPU start/end timestamps and host CPU wall time, each divided
  by the two dispatches;
- source SHA-256 values embedded in the artifact and matched to the committed
  files.

Raw artifact: `artifacts/mpp-dynamic-k8-throughput-m3.txt`.

## Correctness

The adversary matrix is M=64, N=64 at both K=512 and K=2,048, with QMM-scale
pseudorandom, mixed-exponent, and cancellation fixtures. Steel K=8 is the
reference.

At K=512, dynamic K=8 passes unchanged QMM and Qwen tolerances on all fixtures.
At K=2,048, QMM-scale and cancellation also pass, but mixed exponent does not:

```text
dynamic K8:
  fp32_changed = 3900/4096
  bf16_changed = 1/4096
  max_abs       = 0.375
  max_ulp       = 33400
  qmm_1e-3      = fail
  qwen_existing = pass

static K16:
  max_abs       = 0.359375
  qmm_1e-3      = fail
```

All nine full-size QMM-scale cells pass both existing tolerances for both MPP
variants, with no non-finite values. The K=2,048 mixed-exponent failure is
nevertheless an unchanged-gate rejection: the K=16 result in note 042 does not
generalize to long explicit accumulation.

Timing continued only as an explicitly invalid arithmetic upper bound.

## Performance

Dispatch-weighted results over 39.921721016320 TFLOP of modeled projection work:

| Variant | GPU effective TFLOP/s | best-sample effective | CPU-wall effective | vs Steel |
|---|---:|---:|---:|---:|
| Steel K8 | **11.9916** | 12.1227 | 11.7713 | 1.000× |
| static-K16 MPP | **12.0193** | 12.1737 | 11.8047 | 1.002× |
| dynamic-K8 MPP | **3.1579** | 3.1844 | 3.1417 | **0.263×** |

The two requested routed projection shapes show the same result:

| Cell | Steel K8 | static K16 MPP | dynamic K8 MPP |
|---|---:|---:|---:|
| M=65,536, K=2,048, N=1,024 | 11.9092 | 12.0323 | **3.1634** |
| M=65,536, K=512, N=2,048 | 12.0575 | 12.0219 | **3.1847** |

Dynamic K8 reaches only 14.4% of the 22 TFLOP/s threshold. Its weighted median
is **6.97× too slow**, and even the independently best sample from every cell
combines to only 3.1844 TFLOP/s. Static K16 and Steel agree within 0.3% in the
weighted result, so the control does not hide a favorable MPP arithmetic
regime.

The measurement establishes the slowdown, not its microarchitectural cause.
At source level the dynamic path invokes the M3 MPP fallback once per K=8
slice and explicitly adds each FP32 cooperative partial; attributing the
additional loss requires counters beyond the requested timestamp probe.

## Decision

**No: this supported dynamic-K=8 schedule cannot reach the ≥22 TFLOP/s
all-projection threshold on the tested M3 Max.**

It fails for two independent reasons:

1. the long-K mixed-exponent adversary violates the unchanged QMM tolerance;
2. its validly timestamped weighted rate is 3.1579 TFLOP/s, about 3.8× slower
   than both controls and 7.0× below the continuation gate.

Do not integrate this schedule into serving. This closes the qualified
M16×N32 dynamic-K8 fallback, not every possible future MPP tile or Apple10/M5
NAX implementation.
