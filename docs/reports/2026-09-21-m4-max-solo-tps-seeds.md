# M4 Max solo-TPS seed calibration

> Last updated: 2026-09-21 · commit `a07a4832e`

Released-v0.9.7 production-engine B=1 sweeps on one 64 GB M4 Max support
class-qualified cold-start seeds of 65 tok/s for three fast catalog models and
24 tok/s for Bonsai 2. The measurement removes retired Qwen3-VL from the
proposal and supports no new unqualified or other-class values.

## Environment

| Item | Value |
|---|---|
| Machine | MacBook Pro `Mac16,6` |
| Chip | Apple M4 Max, 40 GPU cores |
| Memory | 64 GB |
| OS | macOS 26.5.1 (`25F80`) |
| Provider | Signed `darkbloom 0.9.7` |
| Provider SHA-256 | `2b0da05b4f9c2dfe1dd28d142d9002e2aa4335861a6c8c5e4d63c7e23933baf7` |
| Power | AC power, high-power mode |
| Contention | Local direct-mode service stopped; Ollama had no loaded model; no compilation, video or other inference workload |
| Thermal state | Foundation thermal state 0 at campaign start and after every model; no macOS thermal or performance warning |
| Memory pressure | 91–94% free; swap allocation stayed at 936.12 MiB |

`darkbloom models catalog` marked five current catalog models as downloaded and
eligible, and all five were measured. Qwen 3.8 required Apple M5/NAX and was
ineligible. Qwen 3.5 9B and the catalog Gemma artifacts were not downloaded.
Qwen3-VL was listed as retired local-only and was excluded.

## Method

Each downloaded model ran the production `ContinuousBatchingV2` engine with a
warmup followed by three measured B=1 repetitions:

```bash
darkbloom benchmark --sweep \
  --model <model-id> \
  --prefill-lengths 128 \
  --batch-sizes 1 \
  --decode-tokens 256 \
  --decode-iterations 3
```

The sweep reports complete `Duration` values, one sample per repetition, the
resolved KV backend, and requested-versus-measured coverage. Every requested
decode cell completed and every report had an empty `decodeCoverage.unmeasured`
list.

## Results

| Model | B=1 samples (tok/s) | Median | Resolved KV |
|---|---:|---:|---|
| `gpt-oss-20b` | 124.17, 123.65, 123.54 | 123.65 | paged |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | 107.08, 108.71, 106.88 | 107.08 | paged |
| `qwen3.5-35b-a3b` | 105.62, 106.77, 110.05 | 106.77 | paged |
| `nvidia-nemotron-3.5-lightning` | 122.74, 121.13, 121.71 | 121.71 | paged |
| `ternary-bonsai-2-27b` | 39.34, 37.50, 37.77 | 37.77 | paged |

Every requested cell completed, every `decodeCoverage.unmeasured` list was
empty, and every resolved backend was paged. The catalog aggregate hashes were:

| Model | Aggregate SHA-256 |
|---|---|
| `gpt-oss-20b` | `61bfc04e4016a7fa487eb10e29f79360047e302487229f298da3681984aec512` |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | `d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed` |
| `qwen3.5-35b-a3b` | `95811153b3bb2ed78bf44b3248b07b52fce637706107de8b0fddf21796ade01c` |
| `nvidia-nemotron-3.5-lightning` | `be622ff6ae88533eb31ce984ddc95e5edc3bc52de1767536f2058151383d891a` |
| `ternary-bonsai-2-27b` | `ea1e901e4946c0ba9ad70c78517548808b353db6b3a13e87a8fa20468d81244c` |

The coordinator uses a 15 tok/s floor, `effectiveTPSLoadFactor = 0.39`, and
default overcommit 1.2. Darkbloom 0.9.7 defaults to provider max concurrency
4, so the 65 tok/s fast-cohort seed preserves cap 4 in that default
configuration. For providers explicitly configured to report cap 8, the
shared load-factor model requires 61.80 tok/s on strict quality merit. The
fast-cohort minimum, 105.615 tok/s, permits at most 68.650 tok/s after the
declared 35% discount; 70 no longer qualifies. A 65 tok/s seed retains 38.46%
margin and supports that explicit cap-8 configuration.

That cap-8 result is a coordinator model derived from B=1 measurements with
the default 64-token decode prompt and shared `effectiveTPSLoadFactor = 0.39`.
This campaign did not directly measure B=2, B=4, or B=8 decode behavior for
these models.

Bonsai's minimum, 37.502 tok/s, permits at most 24.376 tok/s after the same
discount. A 24 tok/s seed retains 36.00% margin. It yields strict quality batch
1 and effective cap 2 after the reviewed 1.2 overcommit, replacing the unsafe
unseeded path that can retain the provider-reported cap without a trustworthy
per-model rate.

## Decision

Keep the existing Gemma and GPT-OSS entries unchanged. Add class-qualified
`M4|Max=65` entries for:

- `qwen3.6-35b-a3b-vl-mtp-mxfp8`
- `qwen3.5-35b-a3b`
- `nvidia-nemotron-3.5-lightning`

Add `ternary-bonsai-2-27b@M4|Max=24`. Do not add a Qwen3-VL entry because that
artifact is retired from the current catalog.

Do not add unqualified entries. One M4 Max cannot establish a safe cold-start
rate for slower or unknown classes. Do not raise the new 65 tok/s fast-cohort
seeds: they already preserve the released cap 4 and the modeled explicit cap
8, so a higher value changes neither reviewed admission result and removes
safety margin.

The seed remains temporary evidence. Once a chip class accumulates
`EIGENINFERENCE_QUALITY_CAP_SOLO_MIN_SAMPLES` gated samples, its measured
median replaces the configured value
(`coordinator/registry/concurrency_cap.go`
(`resolvedSoloModelTPSLocked`)).

The reusable capture, validation, threshold, safety-margin, and PR procedure is
documented in
[Calibrate cold-start solo-TPS seeds](../provider/solo-tps-calibration.md).

## Limitations

- This is one machine and one measurement session, not a fleet distribution.
- The measured machine was the 40-GPU-core M4 Max configuration. The
  class-qualified value is provisional for lower-core `M4|Max` variants until
  one of those variants repeats the campaign.
- Aggregate hashes came from the live catalog capture; this campaign did not
  independently rehash every local artifact.
- Cumulative system pageouts increased from 2,609 to 3,161 while loading and
  retiring the five models. Swap allocation did not grow, memory pressure
  stayed nominal, and measured decode followed each warmup.
- The values describe each reported resolved KV backend. A backend or engine
  change requires remeasurement.
- The standard table benchmark was not used for seed evidence because its
  current duration conversion discards whole seconds. The production sweep
  has a separate complete-duration conversion.
