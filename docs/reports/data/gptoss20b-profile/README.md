# GPT-OSS 20B quick-profile evidence

> Last updated: 2026-09-05 · commit `4d9811f7c`

Portable evidence for the historical [quick profile](../../2026-09-05-gptoss20b-quick-profile.md) and [improvement estimate](../../2026-09-05-gptoss20b-improvement-estimate.md). These files preserve the initial measurements and estimates; they do not claim results for subsequent optimizations.

| Evidence | Contents |
|---|---|
| [Short-context summary](baseline-short-summary.json), [long-context summary](long-context-summary.json) | Original aggregate/per-row timing summaries, repetition counts, memory measurements, and caveats |
| [Measurement samples](measurement-samples.json) | Compact raw-derived samples, actual generated-token counts, output hashes, first/last event times, and before/after power settings; full token sequences are omitted |
| [Model inventory](model-inventory.json) | Safetensors-header inventory, stored bytes, logical parameter counts, quantization modes, public model ID/revision, and source/header hashes |
| [Build receipt metadata](baseline-build-receipt.json) | Original executable/metallib hashes, build command, toolchain, source commit and library pins; local absolute paths removed |
| [Prefill trace excerpt](prefill-8192-trace-summary.json) | Structural validator result, prefill intervals/chunks, and LM-head kernel/shape records |
| [Decode trace excerpt](decode-512-b4-trace-summary.json) | Selected-step copy/expert-kernel counts and the explicit correction for stale compiled-operation labels |
| [Head-containing buffers](improvement-head-buffers.json), [estimate](improvement-estimate.json) | Mixed-buffer timing evidence and planning ranges, explicitly not measured candidate speedups |
| [ABBA control summary](control-b2-b4-summary.json) | High-variance control results, thermal observations, output parity, and cycle ratios; not the primary performance baseline |
| [Chart PNG](quick-primary-measurements.png), [SVG](quick-primary-measurements.svg), [CSV](quick-primary-measurements.csv) | Actual primary measured points; no invented 32K B2/B4 cells |

[The evidence index](evidence-index.json) records published-file hashes, original local-artifact hashes, and any transformations. Summary and chart values are unchanged; local paths were removed from the receipt/model inventory, and large traces were reduced to relevant excerpts.

The complete raw traces/reductions, executable and Metal-library binaries, source patches, full stdout/stderr, model weights, and complete host/process snapshots remain in the local research archive. They are **not distributed with the repository or PR**. Hashes identify those source artifacts but do not make the omitted artifacts independently available.

The semantic correction is part of the evidence: 1200 compiled SwiGLU dispatches span 50 actual steps, despite retaining selected-step labels 16/32/48. The original approximately 2450-dispatches-per-step interpretation is withdrawn. The retained selected-step counts are 1467 BF16-to-FP32 copies and 216 expert QMV dispatches across three steps; neither count supplies a GPU-time fraction.
