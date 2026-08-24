# 043 — E13 strict MPP arithmetic roof: 13.72 TFLOPS, hard stop

Status: **measured hard stop for same-quality 2.5× on M3**

## Why this probe is decisive

E12 established the supported Metal 4 path that preserves the incumbent
contract:

- BF16 operands;
- `relaxed_precision=false`;
- FP32 destination/accumulation;
- supported cooperative-tensor load/store;
- output bit-identical to the incumbent Steel K8×2 reduction.

E13 times that path against Steel with:

- 8,192 independent M16×N32 tiles;
- 128 K16 contractions/tile (K=2,048 equivalent arithmetic);
- 17.1799 billion useful FLOPs/dispatch;
- operands resident and reused (optimistic arithmetic-only roof);
- three warmups and 15 GPU-complete samples;
- rotating execution order;
- command-buffer GPU timestamps and CPU wall;
- AC, High Power, M3 Max, macOS 26.4.

Source: `probes/mpp-reduction/{perf.metal,perf.swift,run-perf.sh}`.
Artifact: `artifacts/e13-mpp-perf-m3.txt`.

## Correctness

After 128 repeated contractions:

| Candidate | FP32 changed | BF16 changed | Max error |
|---|---:|---:|---:|
| static K16 MPP | 0 / 512 | 0 / 512 | 0 |
| dynamic K8 MPP | 0 / 512 | 0 / 512 | 0 |

## Performance

| Path | GPU median | P10–P90 | Useful TFLOPS |
|---|---:|---:|---:|
| incumbent Steel K8×2 | 1.2562 ms | 1.2560–1.2609 | **13.68** |
| strict MPP static K16 | 1.2519 ms | 1.2516–1.2522 | **13.72** |
| strict MPP dynamic K8 | 5.1277 ms | 5.1193–5.1335 | **3.35** |

Static MPP is **1.003×** Steel. Dynamic K8 is 0.245×. The supported
portable TensorOps fallback uses the same M3 FP32 arithmetic roof; it
does not expose an M5-class accelerator.

## Binding contradiction

Note 026's exact B=4×8K linear work is 159.692 TFLOP. The measured
primary target is 8.4150 s (note 037).

Grant every impossible advantage:

- all operands cache-resident;
- no W4 dequantization;
- no routing/gather;
- no attention;
- no GDN recurrence;
- no cache writes, movement, graph, or launch overhead;
- every projection sustains the best 13.72 TFLOPS.

Then linear work alone is:

```
159.692 TFLOP / 13.72 TFLOP/s = 11.64 s
11.64 s > 8.415 s target
```

The preregistered continue threshold was 22 TFLOPS. E13 misses it by
37.6%. Even the external 14.2 TFLOPS M3 FP32 specification gives
11.25 s, still above the complete target.

## Closed escape hatches

- Wider cohort: +3.4%, checksum mismatch (E2).
- Persistent BF16 cache/dequant deletion: flat or slower (E3).
- FP16 inputs: +3–6%, same FP32 path (E4).
- Half accumulation: 30 correctness failures (E5).
- Existing relaxed/strict NAX mapping: 11 correctness failures (E6/E8).
- Upstream FP32 dequantization: +3.0% (E7).
- BK64: ≤1.008× (E9).
- BM64×BN64: ≤1.079×, smaller-shape regression (E10).
- Native uint4 affine factoring: 512/512 adversarial failures (E11).
- Exact affine zero structure: ≤0.42% all-linear deletion (note 031).

## Verdict

The original 2.5× objective cannot be reached on this M3 Max while
preserving the current Qwen weights, top-8 semantics, BF16 operand
rounding, and FP32 accumulation contract.

A 2.5× path requires one of:

1. Apple10/M5-class accelerated TensorOps;
2. an explicitly different lower-precision/approximate model contract;
3. a lower multiplier.

Do not disguise any of those as a same-quality M3 optimization.
