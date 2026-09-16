# Calibrate cold-start solo-TPS seeds

> Last updated: 2026-09-16 · commit `4c8e33125`

This how-to measures every eligible local catalog model on one Apple Silicon
chip class and turns the B=1 decode results into a conservative
`EIGENINFERENCE_MODEL_SOLO_TPS_SEED` proposal. It reproduces the method used for
the 2026-09-16 M4 Max calibration while making the evidence and rejection rules
explicit.

## Prerequisites

- An Apple Silicon Mac with the released `darkbloom` CLI and enough unified
  memory for the models being measured.
- `jq`, `zsh` or Bash, and several hours during which the Mac can be dedicated
  to benchmarking.
- AC power and the highest macOS performance mode the machine supports. Record
  the mode; do not mix power modes within one campaign.
- No serving provider, local inference process, compilation, video workload, or
  other sustained GPU workload running during the campaign.
- The current coordinator values for the decode quality floor, load factor,
  overcommit, and the model's provider-reported concurrency ceiling. The
  production cap math is in
  `coordinator/registry/warm_pool_target.go` (`qualityConcurrency`) and
  `coordinator/registry/concurrency_cap.go`
  (`effectiveMaxConcurrencyForModelRateLocked`).

Use `darkbloom benchmark --sweep`, not the ordinary benchmark table, for this
calibration. The sweep emits raw B=1 repetitions, requested-versus-measured
coverage, and the resolved production KV backend as JSON. The provider version
used for the M4 Max campaign, `0.9.4`, also had a known whole-second conversion
bug in the ordinary table path; the sweep's duration conversion was separate
and retained complete durations.

## Steps

### 1. Create an evidence directory

Keep the raw reports and host observations together:

```bash
RUN_DIR="solo-tps-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$RUN_DIR/reports" "$RUN_DIR/posture"

darkbloom --version > "$RUN_DIR/darkbloom-version.txt"
system_profiler SPHardwareDataType -json > "$RUN_DIR/hardware.json"
system_profiler SPDisplaysDataType -json > "$RUN_DIR/displays.json"
pmset -g custom > "$RUN_DIR/posture/power-before.txt"
pmset -g batt > "$RUN_DIR/posture/battery-before.txt"
pmset -g therm > "$RUN_DIR/posture/thermal-before.txt"
memory_pressure > "$RUN_DIR/posture/memory-before.txt"
sysctl vm.swapusage > "$RUN_DIR/posture/swap-before.txt"
osascript -l JavaScript \
  -e 'ObjC.import("Foundation"); console.log(Number($.NSProcessInfo.processInfo.thermalState))' \
  > "$RUN_DIR/posture/foundation-thermal-before.txt" 2>&1
```

Record at least the machine model identifier, chip name, GPU-core count, unified
memory, `darkbloom` version, AC power mode, Foundation thermal state, memory
pressure, and swap usage. Foundation thermal state `0` is nominal.

### 2. Select the model set

Capture both the current network catalog and the local model inventory:

```bash
darkbloom models catalog | tee "$RUN_DIR/catalog.txt"
darkbloom models catalog --json > "$RUN_DIR/catalog.json"
darkbloom models list --json > "$RUN_DIR/local-models.json"
```

Benchmark every entry marked `✓` under `Supported models` in the human-readable
catalog. The mark means that the current catalog artifact is downloaded and
eligible on this machine. Do not include:

- an eligible catalog model that has not been downloaded;
- an entry reported as ineligible because the machine lacks a required
  capability;
- a local-only or retired artifact;
- an embedding, transcription, or other non-serving artifact.

Download any missing eligible model that the proposed seed is intended to cover,
then capture the catalog again. If a model remains unavailable, name the
omission in the measurement report; the campaign supports no seed change for
that model.

Place the exact selected build IDs in a shell array:

```bash
MODELS=(
  gpt-oss-20b
  qwen3.6-35b-a3b-vl-mtp-mxfp8
  qwen3-vl-30b-a3b-instruct
  qwen3.5-35b-a3b
  nvidia-nemotron-3.5-lightning
)
```

Those five IDs are the M4 Max campaign's model set, not a permanent catalog
list. Build the array from the catalog on the machine being measured.

### 3. Quiesce the Mac

Stop the provider before measuring if it is running, and close other GPU-heavy
applications. The benchmark must be the only process with a model resident.

```bash
darkbloom status
darkbloom stop
pmset -g batt
pmset -g custom
pmset -g therm
memory_pressure | tail -n 3
sysctl vm.swapusage
```

Proceed only while the Mac is on AC power, has no thermal or performance
warning, and is not paging. If the Mac has just completed another sustained
workload, let it return to nominal thermal state first.

### 4. Run one production-engine B=1 sweep per model

The M4 Max campaign used this exact command for each model:

```bash
darkbloom benchmark --sweep \
  --model <model-id> \
  --prefill-lengths 128 \
  --batch-sizes 1 \
  --decode-tokens 256 \
  --decode-iterations 3
```

The omitted `--decode-prompt-tokens` and `--kv-backend` flags used their
`darkbloom 0.9.4` defaults, `64` and `auto`. Record the CLI version because
defaults can change. `--sweep` builds the same `ContinuousBatchingV2`
production engine used by a serving slot. It warms the requested shape before
recording data, then returns three independent B=1 decode samples.

Run every model in a fresh CLI process and retain stdout and stderr separately.
Progress remains visible while stdout stays parseable JSON:

```bash
set -euo pipefail

for model in "${MODELS[@]}"; do
  slug="$(printf '%s' "$model" | tr '/@|' '___')"
  report="$RUN_DIR/reports/$slug.json"
  progress="$RUN_DIR/reports/$slug.stderr"

  darkbloom benchmark --sweep \
    --model "$model" \
    --prefill-lengths 128 \
    --batch-sizes 1 \
    --decode-tokens 256 \
    --decode-iterations 3 \
    > "$report" \
    2> >(tee "$progress" >&2)

  jq -e --arg model "$model" '
    .modelID == $model
    and .decodeCoverage.requestedBatchSizes == [1]
    and .decodeCoverage.unmeasured == []
    and .decodeConstructionFailure == null
    and ([.decode[] | select(.batchSize == 1)] | length) == 3
    and all(
      .decode[];
      .batchSize == 1
      and .aggregateTokensPerSecond > 0
      and .elapsedMs > 0
      and (.resolvedKVBackend | type) == "string"
    )
  ' "$report" >/dev/null

  pmset -g therm > "$RUN_DIR/posture/$slug-thermal-after.txt"
  memory_pressure > "$RUN_DIR/posture/$slug-memory-after.txt"
  sysctl vm.swapusage > "$RUN_DIR/posture/$slug-swap-after.txt"
done
```

Do not combine models into one resident multi-model process. A fresh process
prevents the preceding model's residency and engine state from contaminating
the next result.

### 5. Verify every run

For each model, require all of the following:

1. `darkbloom benchmark` exits zero and stdout parses as one JSON document.
2. `decodeCoverage.requestedBatchSizes` is exactly `[1]`.
3. `decodeCoverage.unmeasured` is empty and
   `decodeConstructionFailure` is absent or null.
4. There are exactly three positive B=1 `aggregateTokensPerSecond` samples.
5. `resolvedKVBackend` is present on every sample. Record whether it is
   `paged` or `contiguous`; do not combine results from different resolved
   backends as if they measured the same engine.
6. The report's `hardware` block agrees with the captured host facts.
7. Stderr shows one unmeasured warmup and three measured B=1 repetitions.
8. The post-run thermal, memory-pressure, and swap observations remain
   acceptable.

Print a compact review record:

```bash
for report in "$RUN_DIR"/reports/*.json; do
  jq -r '
    [
      .modelID,
      ([.decode[] | select(.batchSize == 1)
        | .aggregateTokensPerSecond | tostring] | join(", ")),
      ([.decode[] | select(.batchSize == 1)
        | .aggregateTokensPerSecond] | sort | .[1]),
      ([.decode[] | select(.batchSize == 1)
        | .aggregateTokensPerSecond] | min),
      (.kvBackend.resolved | join("+"))
    ] | @tsv
  ' "$report"
done | sort
```

The columns are model ID, all B=1 samples, median, minimum, and resolved KV
backend. Use the minimum—not the median—to size a cold-start seed from a
three-sample, one-machine campaign. Calculate each model's bound separately
when proposing different values. If several models will share one value, use
the minimum across every accepted sample for those models; the M4 Max PR used
that common-value rule.

### 6. Calculate the useful seed range

For a desired provider cap `N`, decode floor `F`, measured load factor `k`, and
quality-cap overcommit `O`, calculate two thresholds.

The smallest strict quality batch whose overcommitted cap reaches `N` is:

```text
q = floor((N - 1) / O) + 1
```

The seed that merely grants cap `N` after overcommit is:

```text
grant_threshold = F × (1 + k × q)
```

The seed that supports all `N` requests on strict quality merit, without
depending on overcommit rounding, is:

```text
strict_threshold = F × (1 + k × N)
```

Use `strict_threshold` when proposing a normal production seed. For the M4 Max
campaign:

```text
N = 8
F = 15 tok/s
k = 0.39
O = 1.2

q = floor(7 / 1.2) + 1 = 6
grant_threshold  = 15 × (1 + 0.39 × 6) = 50.10 tok/s
strict_threshold = 15 × (1 + 0.39 × 8) = 61.80 tok/s
```

Discount the slowest accepted observation to account for the narrow evidence.
The M4 Max campaign required at least 35% headroom:

```text
slowest_observation = 108.76 tok/s
maximum_seed_at_35_percent_headroom = 108.76 × 0.65 = 70.694 tok/s
```

The supported interval was therefore:

```text
61.80 <= seed <= 70.694
```

The 35% discount is an engineering margin for one machine and three
repetitions, not a statistical confidence interval. Declare the margin before
choosing the seed. A broader multi-machine campaign can justify a different
reviewed margin; a narrow campaign must not shrink its margin merely to make
the desired cap fit.

The PR chose the clean round value `70`. It:

- supports cap 8 without relying on the overcommit allowance;
- remains 35.64% below the slowest sample;
- matches the existing M4 Max seed used for Gemma and GPT-OSS;
- changes no admission result if raised further because 8 is already the
  provider-reported ceiling.

If no value satisfies both `seed >= strict_threshold` and the chosen discounted
measurement bound, the campaign does not support the desired cap. Reduce `N`,
collect broader evidence, or make no seed change. Do not lower the safety margin
only to force an update.

### 7. Scope the value to measured hardware

The coordinator's seed qualifier is the exact
`ChipFamily|ChipTier` key produced by
`provider-swift/Sources/ProviderCore/Hardware/HardwareDetector.swift`
(`parseChipIdentity`) and consumed by
`coordinator/registry/solo_tps.go` (`chipClassKey`). Examples are `M4|Max`,
`M4|Pro`, and `M3|Base`.

Add a class-qualified entry:

```text
<model-id>@<family>|<tier>=<seed>
```

Do not remove the tier or add an unqualified value based on one chip class.
`@M4` is not a wildcard, and an unqualified entry can reach unrelated,
unmeasured classes through the fleet fallback.

One Mac measures one physical configuration. When a `Family|Tier` class spans
multiple GPU-core, memory-bandwidth, memory, or chassis variants, use the
slowest representative variant before treating the seed as established for the
whole class. Until then, describe the class-wide value as provisional and keep
enough margin for the unmeasured variants. The coordinator cannot express a
GPU-core-specific seed inside one family and tier.

The 2026-09-16 campaign directly measured a 40-GPU-core `Mac16,6`. Its
`M4|Max` proposal is therefore direct evidence for that configuration and
provisional class-wide evidence for lower-core M4 Max variants.

### 8. Prepare the PR evidence

Include:

- host identity, GPU cores, memory, power mode, thermal state, memory pressure,
  swap, CLI version, and benchmark date;
- the catalog and the reason for every omitted model;
- the exact command and all B=1 samples;
- resolved KV backend and complete decode coverage for every model;
- `grant_threshold`, `strict_threshold`, the safety margin, and the supported
  seed interval;
- the exact chip-class qualifier and why broader qualifiers are unsupported;
- engine/backend/version limitations and whether artifact hashes were
  independently verified.

Update both production seed files and keep them identical:

- `deploy/gcp/prod/release-env-defaults`
- `deploy/environments/prod.env`

Add tests that resolve the new value on the measured class, reject it on an
unmeasured class, and prove the resulting admission cap. Follow the repository
PR checklist, including documentation checks and before/after Mermaid diagrams.

## Verify

A seed proposal is ready for review only when:

- every selected model has three accepted B=1 samples;
- the slowest sample still leaves the declared safety margin;
- the proposed seed reaches the desired cap on strict quality merit;
- no unmeasured chip class inherits the value;
- production environment files and tests agree;
- the raw evidence or a complete derived report is retained.

After implementation, run:

```bash
make coordinator-test
make docs-impact-check BASE=origin/master
make docs-check
git diff --check
```

## Troubleshooting

| Symptom | Action |
|---|---|
| Model is not marked `✓` | Download the current catalog artifact, or record it as unmeasured and make no seed claim for it |
| `decodeCoverage.unmeasured` is non-empty | Reject the run; inspect stderr and rerun only after fixing the construction or submission failure |
| Resolved KV backend changes between repetitions or machines | Separate the cohorts; do not combine them into one seed claim |
| Thermal warning, swap growth, or serious memory pressure appears | Reject the affected run, cool or free the machine, and repeat the whole model |
| Samples drift downward across the three repetitions | Treat this as thermal or contention evidence; stabilize the Mac and rerun rather than taking the median |
| Discounted minimum is below `strict_threshold` | The data cannot support the desired cap; lower the cap target or make no update |
| Ordinary benchmark reports implausible multi-second timing on `0.9.4` | Use `--sweep`; do not use the ordinary table as seed evidence |

## Related

- [M4 Max calibration report](../reports/2026-09-16-m4-max-solo-tps-seeds.md)
- [Provider CLI reference](cli-reference.md#darkbloom-benchmark)
- [Coordinator configuration reference](../reference/configuration.md)
- [Scheduling architecture](../architecture/scheduling.md)
