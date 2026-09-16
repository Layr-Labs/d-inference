# M4 Max solo-TPS seed calibration

> Last updated: 2026-09-16 · commit `4c8e33125`

Production-engine B=1 sweeps on one 64 GB M4 Max support conservative
`M4|Max=70` cold-start solo-TPS seeds for four current catalog models. The
measurement does not support new unqualified values or values for other chip
classes.

## Environment

| Item | Value |
|---|---|
| Machine | MacBook Pro `Mac16,6` |
| Chip | Apple M4 Max, 40 GPU cores |
| Memory | 64 GB |
| Provider | `darkbloom 0.9.4` |
| Power | AC power, high-power mode |
| Contention | Local direct-mode process idle with no model resident |
| Thermal state | No recorded thermal or performance warning |
| Memory pressure | No swap I/O; 93% free after the campaign |

`darkbloom models` marked five current catalog models as downloaded. Models
without that marker, the ineligible Qwen 3.8 entry, and retired local-only
artifacts were not measured.

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
| `gpt-oss-20b` | 123.89, 123.75, 123.82 | 123.82 | paged |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | 108.76, 110.58, 110.39 | 110.39 | paged |
| `qwen3-vl-30b-a3b-instruct` | 118.47, 119.34, 118.73 | 118.73 | contiguous |
| `qwen3.5-35b-a3b` | 112.45, 112.60, 112.31 | 112.45 | paged |
| `nvidia-nemotron-3.5-lightning` | 122.65, 123.02, 122.71 | 122.71 | paged |

The slowest sample was 108.76 tok/s. The coordinator's production quality
model uses a 15 tok/s floor, `effectiveTPSLoadFactor = 0.39`, and overcommit
1.2; `soloTPSForCap` requires 50.10 tok/s to grant a provider-reported cap of
8. A seed of 70 tok/s clears that threshold and remains more than 35% below
the slowest observation.

## Decision

Keep the existing Gemma and GPT-OSS entries unchanged. Add class-qualified
`M4|Max=70` entries for:

- `qwen3.6-35b-a3b-vl-mtp-mxfp8`
- `qwen3-vl-30b-a3b-instruct`
- `qwen3.5-35b-a3b`
- `nvidia-nemotron-3.5-lightning`

Do not add unqualified entries. One M4 Max cannot establish a safe cold-start
rate for slower or unknown classes. Do not raise the existing GPT-OSS M4 Max
seed toward its measured median: 70 already reaches the maximum supported cap,
so a higher value changes no admission result and removes safety margin.

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
- The artifacts were the downloaded current-catalog entries selected by
  `darkbloom 0.9.4`; their aggregate hashes were not independently recomputed
  during this run.
- The values describe each reported resolved KV backend. A backend or engine
  change requires remeasurement.
- The standard table benchmark was not used for seed evidence because its
  current duration conversion discards whole seconds. The production sweep
  has a separate complete-duration conversion.
