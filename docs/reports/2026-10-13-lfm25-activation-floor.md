# LFM2.5-24B-A2B activation floor measurement (2026-10-13)

> Last updated: 2026-10-13

**Result:** `LiquidAI/LFM2.5-24B-A2B-MLX-4bit` and its catalog alias
`lfm2.5-24b-a2b` get a measured activation floor of **2.0 GiB**, replacing
the 5.5 GiB default. The worst measured non-KV peak was 1.28 GiB. The floor
adds 0.30 GiB of slack, the same slack gpt-oss-20b uses (3.20 + 0.30 = 3.5),
and rounds up to the 0.5 GiB grid that both existing constants use.

The provider table is `UnifiedMemoryCap.measuredActivationFloorsBytes`. The
coordinator mirror is `servabilityModelActivationFloorsGB` in
`darkbloom-platform`; both tables carry the same value. Constants and formulas
are in [`../architecture/hardware-support.md`](../architecture/hardware-support.md#constants).

## Why the model qualifies

- **Text only.** The artifact has no `vision_config`, and the provider does not
  advertise media for it (`ModelMediaPolicy`). The vision-tower caveat that
  keeps the Qwen and Gemma VLM builds on the default does not apply.
- **Exact ids.** Both keys match `EngineV2SupportedModels.isLFM25ListingModelID`.
  Other `lfm2_moe` checkpoints and look-alike ids stay on the default.

## Environment

| | |
|---|---|
| Machine | Apple M4 Max, 36 GB unified memory, macOS 27.2 |
| Artifact | `LiquidAI/LFM2.5-24B-A2B-MLX-4bit` @ `667408d494bde191c2cb9dd4f4549827816b9275` (sha256-verified); resident weights 13,567,192,544 B (12.64 GiB) |
| Release harness | `darkbloom benchmark --sweep` (`ProviderBenchmark/ThroughputSweep.swift`), release build of d-inference `7218aa791` with `libs/mlx-swift-lm` `6bdfdb2c`. It builds every cell with `EngineV2Factory.makeProductionBuild`, the construction a serving slot uses, and resets `Memory.peakMemory` after engine construction. |
| Production-slot harness | Gated live test `LFM25MemoryQualificationLiveTests` (debug build of `7218aa791`): the production bundle with the default-on SSD complete checkpoints and the provider's single-slot KV grant |
| Prompts | Tiled in-vocabulary tokens; 64 greedy decode tokens per row (65 emitted). Prefix caching is not attached by the sweep. |

## Convention

This follows [`2026-08-30-activation-floor-measurements.md`](2026-08-30-activation-floor-measurements.md):
peak MLX memory minus resident weights per measured cell (warm-up cells
excluded), a B=1/2/4/8 matrix at 500-token prompts, and B=8 cells at 4k, 8k
and 16k prompts so the prefill working set saturates. B=1 cells at 32k, 64k
and 131,000 tokens were added because the long-context single request is
where this model's transient peaks.

The "non-KV" column subtracts the analytic attention KV:
`rows × (prompt + 65) × 20,480 B` (10 attention layers × K+V × 8 KV heads ×
64 × fp16). Short-conv state is a separate per-request engine charge. In the
long B=8 cells, early rows finish before late rows end prefill. Their non-KV
figure counts only the rows still decoding when the last prefill ends.

## Results — release sweep, paged KV (the production default for these ids)

| Cell | Raw peak − resident (GiB) | Non-KV (GiB) |
|---|---|---|
| B=1 @ 500 | 0.41 | 0.40 |
| B=2 @ 500 | 0.48 | 0.46 |
| B=4 @ 500 | 0.63 | 0.58 |
| B=8 @ 500 | 0.67 | 0.59 |
| B=8 @ 4,000 (8 rows overlap) | 1.07 | 0.45 |
| B=8 @ 8,000 (5 rows overlap) | 1.36 | 0.59 |
| B=8 @ 16,000 (3 rows overlap) | 1.63 | 0.71 |
| B=1 @ 32,768 | 1.61 | 0.98 |
| B=1 @ 65,536 | 2.26 | 1.01 |
| B=1 @ 131,000 | 3.76 | **1.26** |

The contiguous backend (the convention's backend, supplementary here) measured
0.53 GiB raw at B=8 @ 500, 1.63 GiB raw at B=8 @ 16,000, and a flat 0.95 GiB
non-KV at B=1 from 32k to 131k.

## Results — production slot with SSD complete checkpoints (debug build)

| Cell | Raw peak − resident (GiB) | Non-KV (GiB) |
|---|---|---|
| B=1 @ 4,096 / 16,384 / 32,768 | 1.06 / 1.30 / 1.61 | 0.98 / 0.98 / 0.98 |
| B=1 @ 65,536 | 2.26 | 1.01 |
| B=1 @ 131,000 | 3.78 | **1.28** (worst measured) |
| B=8 @ 8,192 / 16,384 | 1.80 / 3.08 | 0.55 / 0.58 |

The B=1 non-KV figures match the release sweep within 0.02 GiB. MLX buffer
sizes do not depend on the Swift build configuration.

## Decision

`floor = 1.28 + 0.30 = 1.58`, rounded up to **2.0 GiB**. The floor also covers
every raw B=8 cell including its KV (at most 1.63 GiB). Long-context KV is
charged by the KV budget, not the activation reserve, as for every other
measured model.

## Effect

A provider whose serving set holds only these ids needs
`15.16 + 2.0 + 1.0 = 18.2 GiB` free to cold-load the model, down from
`15.16 + 6.5 = 21.7 GiB` (scanner load estimate 15.16 GiB). On a 36 GB Mac
with the default `memory_reserve_gb`, the KV grant grows by 3.5 GiB, from
14.89 GB to 18.65 GB. Mixed serving sets still take the maximum floor of
their members. The environment override still raises the floor and never
lowers it.

## Limits

- One machine class (M4 Max). The B=1 non-KV figure was stable across build
  configurations and KV backends (0.95–1.28 GiB).
- Only text was measured; the model has no other modality.
- Re-measure if the LFM2-MoE forward, the prefill chunking or the
  checkpoint capture path changes.
