# 048 — Cold strict prefill is command-feed saturated, not a physical theorem

Status: **measured on M3 Max — no material command-overlap lane; B4 has an
unresolved Medium-performance-state anomaly**

## Question and scope

Notes 043–046 found a fastest valid bounded MPP implementation, but correctly
stopped short of calling it a hardware roof. This measurement asks a narrower
serving-path question:

> Under the current cache-free strict Qwen posture at B=1/2/4 and 8,192 prompt
> tokens per request, is the GPU being starved between command buffers, does
> sustained throughput fade thermally, and which physical counters are actually
> available without privilege on this M3 Max?

This is not a rerun of the standalone MPP tile winner. It measures the current
end-to-end strict prefill posture and determines whether host submission or
inter-command overlap is a plausible remaining optimization lane.

## Captured posture

All cells used the same content-pinned artifacts:

```text
host             Mac15,9, Apple M3 Max 40-core GPU
OS               macOS 26.4 (25E246)
Xcode            26.5 (17F42)
power            AC, High Power (powermode=2)
darkbloom        0.8.10
binary SHA-256   0fded5e1ddb1ac0f3c10382ff446990763081621a01500e37dc4e672213fdfdb
metallib SHA-256 08c48889aee7a8d126e47b12528e8f3e2c43f45866de938be11a8777a952b033
model            qwen3.6-35b-a3b-vl-mtp-mxfp8
KV               contiguous
prefix cache     off
numerics         strict default top-8
prompt           8,192 tokens/request
iterations       3
```

Every Qwen prefill experiment override and exact-prefix benchmark cache override
was unset. AC/High Power and the absence of `darkbloom`, Swift build, and
`xctrace` competitors were gated before each cell. `pmset -g therm` reported no
thermal or performance warning before and after every completed cell.

Profiler overhead is deliberately excluded from throughput:

1. an untraced process records the decision throughput report;
2. a second process with the identical binary, model, and strict environment
   receives a bounded five-second Metal System Trace;
3. `ioreg` AGX utilization is sampled around that trace;
4. trace XML is exported and summarized after the target exits.

The cells were resumed separately after unrelated host work appeared between
attempts. They share content hashes and posture, but are not an ABBA
cross-batch experiment.

## Unprivileged counter boundary

The exact access results are:

| Mechanism | Result |
|---|---|
| `powermetrics --samplers gpu_power` | exit 1: `powermetrics must be invoked as the superuser` |
| Instruments Power Profiler | exit 2: `The Power Profiler instrument is not supported on macOS` |
| `MTLCounterSampleBuffer` | stage-boundary sampling supported; only `timestamp:GPUTimestamp` is exposed |
| Dispatch-boundary Metal sampling | unsupported |
| Metal System Trace counter info | only `RT Unit Active`, irrelevant to this compute workload |
| AGX `ioreg` | device utilization and static performance-state tables available |
| Live GPU clock/power | unavailable without privilege |

The static AGX table advertises 1.38 GHz as its highest frequency, but the
Metal-trace `Minimum`/`Medium`/`Maximum` enums do not map to those table indices.
They are retained only as qualitative performance levels. No valid live
frequency, watts, shader-issue, occupancy, cache, or memory-bandwidth sample was
available.

## Throughput and sustained stability

Burst is the binding simultaneous-arrival comparison:

| Batch | Aggregate prefill tok/s | Prefill ms | Best short sample | vs note 038 baseline |
|---:|---:|---:|---:|---:|
| B=1 | **1,555.798** | 5,264.823 | 1,557.406 | +0.582% |
| B=2 | **1,497.324** | 10,940.849 | 1,499.567 | -0.225% |
| B=4 | **1,547.649** | 21,170.169 | 1,560.431 | -0.626% |

The current posture therefore reproduces the binding baseline within 0.7% and
shows no hidden batch-throughput multiplier.

This is a heterogeneous end-to-end model path, so tok/s is the valid aggregate
metric. Assigning it one TFLOP/s number would mix projections with attention,
GDN, routing, cache writes, and launch work without per-kernel operation
counts. The standalone MPP TFLOP/s result remains separate.

B=4 supplied 12 untraced prefill samples across the four arrival patterns,
totaling 256.727 seconds of measured prefill. Its three burst samples were:

```text
iteration 1  1547.649 tok/s
iteration 2  1560.431 tok/s
iteration 3  1547.322 tok/s
first→last  -0.021%
```

The best short sample is only 0.826% above the three-run burst median. B=2
supplied 131.959 seconds of measured prefill and its burst first-to-last change
was -0.189%. B=1 changed -0.372% over 15.803 seconds. All three bounded traces
reported `Thermal State: Nominal` for 100% of the window. There is no measured
thermal fade large enough to explain the missing 2.5×. The harness does not
repeat burst after the final arrival pattern, so this is not a direct
cold-versus-post-soak burst pair; it combines stable within-pattern samples,
the bounded thermal trace, and the no-warning post-run power capture.

## Command-feed and overlap evidence

Top-level active Compute intervals from Metal System Trace are:

| Batch | GPU intervals | Busy duty | Idle time / span | >1 ms gaps | Median start latency | Max-performance level |
|---:|---:|---:|---:|---:|---:|---:|
| B=1 | 1,731 | 98.533% | 80.449 / 5,483.747 ms | 21, 76.740 ms | 36.156 ms | 98.761% |
| B=2 | 1,663 | 99.265% | 39.395 / 5,359.463 ms | 7, 36.310 ms | 32.126 ms | 98.783% |
| B=4 | 1,426 | 98.693% | 69.984 / 5,354.506 ms | 4, 65.437 ms | 40.113 ms | 38.843% |

Active-only AGX utilization has a 99% median in every cell. The Metal GPU-state
table independently reports 98.5–99.3% Active duty.

Even granting the impossible assumption that every idle microsecond can be
deleted with no new work, the whole-window throughput ceilings are only:

```text
B=1  +1.489%
B=2  +0.741%
B=4  +1.324%
```

The 32–40 ms median start latency is queueing lead time, not an idle bubble:
command buffers are submitted tens of milliseconds before the GPU starts them
while the compute channel remains busy. The trace contains one active
`Compute` channel and no evidence that CPU submission is starving it.

Therefore there is **no material host-submission or command-overlap lane**.
Layer pipelining may move the isolated >1 ms gaps, but deleting all of them
cannot produce more than the low-single-digit bound above.

## Remaining anomaly and next mechanism

B=4 is the one unresolved physical signal. It remains 98.693% busy and 99%
active-utilized under nominal thermals, yet its five-second trace spends:

```text
Maximum performance level  38.843%
Medium performance level   61.149%
Minimum performance level   0.007%
```

B=1 and B=2 spend about 98.8% at `Maximum`. Because live frequency is
unobservable and the available enums are qualitative, this does **not** prove
that B=4 is downclocked. It does rule out command starvation as the direct
explanation for the Medium interval. The remaining lane is kernel-internal:
occupancy, dependency stalls, arithmetic issue, cache behavior, or memory
bandwidth.

The next decision-grade mechanism is a device-scope Metal GPU capture around one
strict B=4 prefill, with MLX primitive/layer command-buffer labels, analyzed in
Xcode's GPU Shader Profiler. It must report per-kernel occupancy, ALU issue,
bandwidth/cache pressure, and limiter reason. In parallel, a human with
privilege can run `powermetrics --samplers gpu_power` to correlate actual
frequency and watts with the same bounded window. The outcomes select the next
implementation:

- high bandwidth with low ALU issue: reduce or fuse packed-W4
  dequant/gather/movement;
- low occupancy: retile the dominant projection and reduce register/threadgroup
  pressure;
- low occupancy and bandwidth around dependencies: target graph/layer
  serialization;
- high issue at verified maximum clock: the tested path is physically
  saturated, subject to the broader proof requirements in note 032.

Do not spend another optimization cycle on generic CPU/GPU overlap before this
capture; its measured upper bound is at most 1.324% for B=4.

## Decision

The current cold strict prefill path is command-feed saturated and thermally
stable on this host. Its throughput is flat across B=1/2/4 at roughly
1.50–1.56K tok/s. The remaining unknown is inside GPU kernels, especially the
B=4 Medium-performance-state interval.

This evidence does **not** close the physical roof:

- no live clock or power was available;
- no shader, occupancy, cache, or bandwidth counter was exposed;
- the trace window is a separate representative run;
- the standalone fastest MPP tile schedule was not the target of this serving
  capture.

Accordingly, the 13.4182 TFLOP/s implementation in note 046 remains the fastest
valid measured implementation, not a theorem about M3 hardware.

## Artifacts and rerun

Committed artifacts:

- `artifacts/cold-strict-prefill-physical-m3.provenance.json`;
- `artifacts/cold-strict-prefill-b{1,2,4}-8192-m3.json`;
- `artifacts/cold-strict-prefill-b{1,2,4}-physical-m3.txt`;
- `artifacts/cold-strict-prefill-b{1,2,4}-trace-sha256-m3.txt`;
- `artifacts/cold-strict-prefill-agx-inventory-m3.txt`;
- `artifacts/cold-strict-prefill-metal-counter-access-m3.txt`;
- `artifacts/cold-strict-prefill-powermetrics-access-m3.txt`;
- `artifacts/cold-strict-prefill-power-profiler-access-m3.txt`.

Rerun on the profiled Mac:

```bash
research/qwen36-prefill/probes/prefill-physical/run.sh \
  /path/to/new-profile-output
```

`DARKBLOOM_BENCH_BINARY` may pin a different executable. The script refuses an
existing output directory, non-`Mac15,9` hardware, non-AC/High-Power posture,
or a competing benchmark/build/tracer process.
