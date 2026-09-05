# GPT-OSS 20B improvement estimate

> Last updated: 2026-09-05 · commit `4d9811f7c`

The saved evidence supports an estimated **7–12% reduction in 8K prefill TTFT from output-head pruning**. For decode, **5–15% higher throughput is a reasonable first-pass planning target**, while **20–40% is an ambitious combined kernel-work target**. Decode ranges are engineering targets, not measured candidate results or statistically established forecasts. Prefix reuse, MTP, model changes, and quantization-quality changes remain outside this estimate.

## Evidence for the prefill estimate

The four full 2048-row vocabulary GEMMs occupy command buffers lasting 277.379, 279.293, 273.513, and 270.508 ms: **1.100693 s total**. Each buffer also has six non-head kernels, so its duration cannot be assigned exclusively to the GEMM. Four head-only copy buffers add 34.255 ms. Head-containing intervals cover **1.134948 s**, or **13.13% of the 8.643480 s prefill GPU interval union**. About 0.303287 s overlaps other buffers.

This supports a practical head-pruning estimate around 7–12% of TTFT: **8.32 s → roughly 7.3–7.7 s**. Allocating every head-containing mixed-buffer interval to removable work gives an optimistic trace-based Amdahl estimate of about 1.15×. Neither the mixed buffers nor the instrumented trace establishes a positive guaranteed latency saving. The observed 8192-to-1 projected-position ratio is not an end-to-end speedup ratio.

[Exact GEMM-buffer IDs and contained kernels](data/gptoss20b-profile/improvement-head-buffers.json).

## Correction to the original decode interpretation

The earlier **approximately 2450 dispatches per step / 1200 SwiGLU dispatches across three steps** interpretation is withdrawn. Reused compiled primitives retain previous selected-step context. The 1200 SwiGLU dispatches span **50 actual decode steps × 24 layers**, but carry stale labels 16/32/48. These are real dispatches with misleading per-step attribution, not evidence of approximately 400 redundant activation computations per step. A structurally valid trace does not establish correct semantic attribution.

The **1467 BF16-to-FP32 copies are genuine work in the three selected steps**, or 489 per step. The source repeatedly widens immutable affine quantization scales/biases and linear biases after GPT-OSS execution promotes to FP32. Cache widened constants keyed by the required dtype while preserving the original arithmetic; do not substitute BF16 math merely to reduce casts. Copy counts still do not determine their time share.

The generic expert matvec route at K=N=2880 remains verified. A specialized tail-capable MXFP4 kernel is worth investigating, followed by limited fusion and improved weight access. The saved trace does not isolate a reliable per-kernel GPU-time fraction for these changes.

## Practical decode targets

| Short-context workload | Current tok/s | First pass, +5–15% | Ambitious combined work, +20–40% |
|---|---:|---:|---:|
| B1 | 105 | 110–121 | 126–147 |
| B2 aggregate | 158 | 166–182 | 190–221 |
| B4 aggregate | 156 | 164–180 | 187–218 |

The first-pass range covers immutable cast reuse and modest fusion. The ambitious range requires effective expert-kernel/memory-access improvements as well. These changes overlap; their percentages must not be added. The same percentage is not assumed at every context length. Long-context attention/KV becomes more important as context grows.

## Bandwidth sanity check, not a performance forecast

A simple B1 traffic model counts one eighth of the 10.166 GB expert payload plus about 1.295 GB of non-embedding weights per token. Adding a full-attention FP32 KV read gives approximately 2.59 GB/token at context 512, 2.97 GB at 8K, and 4.18 GB at 32K. It assumes the relevant weights/KV are read once, ignores additional traffic and host work, and does not measure DRAM traffic. FP32 full-attention KV is an explicit assumption in this sanity check, not a measured DRAM-traffic result.

Against the chip's advertised [546 GB/s memory bandwidth](https://support.apple.com/en-us/121553), these correspond to idealized traffic-model limits of about 211/184/131 tok/s. Current B1 results are 105/86/63 tok/s. Fitting inverse throughput versus context gives an apparent bandwidth around 260 GB/s; the agreement is consistent with substantial memory-access cost, but does not prove it or guarantee that the advertised peak is attainable. This leaves room for improvement while providing no basis for promising 2× throughput.

## Recommended order

1. Skip intermediate prefill heads; then test final-row-only projection. This has the strongest quantified opportunity.
2. Reuse immutable FP32 constants. Keep dtype and numerical behavior unchanged.
3. Tune the 2880-wide MXFP4 expert matvec, then revisit fusion and batched attention based on actual gains.

For illustration, an 8K prompt followed by 256 output tokens currently takes roughly 8.32 + 256/85.5 = 11.3 s under a constant-rate approximation. A 10% TTFT reduction plus 30% higher decode throughput would give about 9.8 s: approximately 13% lower total latency. Component gains affect different portions of a request.

No new inference runs or optimizations were performed for this analysis. The original workstation variability and limited-repetition caveats still apply. [Measured baseline and published evidence](2026-09-05-gptoss20b-quick-profile.md). The [machine-readable estimate](data/gptoss20b-profile/improvement-estimate.json) and [corrected decode trace excerpt](data/gptoss20b-profile/decode-512-b4-trace-summary.json) are included in the repository; the large raw trace archives remain local.
