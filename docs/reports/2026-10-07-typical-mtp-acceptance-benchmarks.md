# Typical MTP acceptance: controlled three-model benchmarks

> Last updated: 2026-10-07

The completed M5 Max benchmark measures same-binary median decode gains of **8.02% for Qwen3.8-27B, 11.21% for Qwen3.6-35B, and 4.49% for Gemma4-26B** with opt-in typical MTP acceptance. All 33 processes and 81 sampled measurements pass the recorded execution/integrity gates; all three candidate greedy controls preserve tokens and text. This is performance evidence, not quality qualification: sampled typical acceptance is intentionally lossy, and exact remains the default.

## Results

Each arm has nine sampled measurements per model. TPS and TTFT are medians of those measurements. Percentage changes below are ratios of arm medians, not medians of paired ratios. The primary comparison is typical/exact on one candidate executable; before comparisons also include intervening SDK changes.

| Model | Before TPS | Candidate exact TPS | Candidate typical TPS | Typical/exact | Exact/before | Typical/before |
|---|---:|---:|---:|---:|---:|---:|
| Qwen3.8-27B | 73.2703 | 73.4896 | 79.3815 | +8.0174% | +0.2993% | +8.3407% |
| Qwen3.6-35B | 186.2378 | 187.4686 | 208.4895 | +11.2130% | +0.6609% | +11.9480% |
| Gemma4-26B | 147.0226 | 147.0107 | 153.6171 | +4.4939% | -0.0081% | +4.4854% |

| Model | Before TTFT (ms) | Exact TTFT (ms) | Typical TTFT (ms) | Before weighted acceptance | Exact weighted acceptance | Typical weighted acceptance |
|---|---:|---:|---:|---:|---:|---:|
| Qwen3.8-27B | 243.34 | 240.99 | 242.32 | 62.47% | 62.84% | 71.52% |
| Qwen3.6-35B | 70.31 | 70.30 | 70.30 | 60.01% | 63.58% | 70.94% |
| Gemma4-26B | 76.04 | 71.28 | 71.59 | 77.65% | 77.84% | 86.37% |

Weighted acceptance is `sum(accepted_tokens) / sum(proposed_tokens)` from `arms.mtp_totals`, not the median per-request acceptance. The underlying sampled totals are:

| Model | Before accepted/proposed; rounds | Exact accepted/proposed; rounds | Typical accepted/proposed; rounds |
|---|---|---|---|
| Qwen3.8-27B | 2355/3770; 1076 | 2356/3749; 1076 | 2486/3476; 950 |
| Qwen3.6-35B | 2290/3816; 1142 | 2257/3550; 1176 | 2414/3403; 1021 |
| Gemma4-26B | 1310/1687; 1687 | 1303/1674; 1674 | 1571/1819; 1819 |

### Paired Spread

Every model/comparison has nine matched prompt/repetition pairs. The table gives the minimum and maximum individual paired TPS change, `100 * (typical_tps / exact_tps - 1)`, within each three-repeat prompt class. These are descriptive ranges, not confidence intervals.

| Model | Coding range | Reasoning range | Exposition range |
|---|---:|---:|---:|
| Qwen3.8-27B | -2.01% to +15.51% | +6.04% to +14.00% | +12.82% to +19.83% |
| Qwen3.6-35B | +9.12% to +12.96% | +3.89% to +13.21% | +7.34% to +11.93% |
| Gemma4-26B | +0.60% to +3.44% | +4.49% to +6.85% | +3.89% to +18.08% |

Qwen3.8 has one coding pair that is 2.01% slower with typical acceptance despite the positive aggregate. The observed gains are not uniform across prompts or repetitions.

## Method And Gates

Execution runs from `2026-10-07T00:52:52Z` to `2026-10-07T01:17:14Z` on the owned `dginf-m5max` host. Three arms cover before exact, candidate exact, and candidate typical. Three synthetic prompts (coding, reasoning, exposition) run three times per model/arm, using seeds `341`, `342`, and `343`, temperature `0.6`, `top_p=0.95`, `top_k=0`, and a 384-token output cap. The rendered request date is fixed to `2026-10-06`. Model and arm order rotates across repetitions; the complete schedule is in `provenance.json`.

The workload is B1, cache off, contiguous attention, through the real production factory with `--production-kv-grant` and the production `SingleSlotKV` grant. Memory/activation/KV/admission safeguards are unchanged. Decode TPS excludes the first-token delta. Eight-token warmups and tenant/cancellation/recovery probes are excluded from performance aggregates. Six additional candidate requests provide one exact/typical greedy pair per model; all three token and text hash comparisons match. They are controls, not sampled measurements or quality evaluations.

All 33 processes return code zero and status `completed`. All 81 sampled rows are valid and MTP-active. All 87 requests, including the six greedy controls, produce 384 completion tokens with positive proposals and rounds. No invalid rows, integrity errors, or unsupported fallbacks are recorded. Nonzero adaptive-controller fallback counters such as exploration/goodput decisions are distinct from unsupported-engine fallback; this report does not claim all controller counters are zero.

Every process enters at GPU temperature at or below 42 C and one-minute host load at or below 4, with a bounded 300-second cooldown. Actual maximum entry temperature is 41.86 C; maximum entry load is 2.52. Cooldown samples reach 63.74 C; no continuous runtime thermal maximum is captured. The canonical lock is `/tmp/mtplx-gpu-exclusive.lock`. Read-only checks of `http://127.0.0.1:11434/api/ps` record `models: []` at every entry and exit boundary; the user's Ollama daemon remains running. These are advisory snapshots and cannot rule out unrelated work between checks.

Binary identities are pinned; per-process before/after checks preserve AOT metallib and assistant-file hashes. Actual loaded-model hashes match the three references below. Factory/installed-rule evidence distinguishes the candidate rules and confirms active MTP. Typical uses SDK `defaultTypicalDelta = 0.2`, with no delta override; provenance explicitly states that the runtime does not report the numeric delta separately.

## Frozen Provenance

| Arm | Root source | Engine source |
|---|---|---|
| Before exact | `82968020177d8615abda1e6d2ec07e5d0fc50830` | `e407e899c4e3f9ee4d95f8974ed4f01e7e60e702` |
| Candidate exact and typical | `f59a6a4f0484e65802b8d7279f1f29d70d5593bc` | `7f9c05d7d2e944edac6950a61405406dcde5e5c7` |

Candidate exact and typical share the same frozen executable. Before/candidate also span approximately 70 SDK commits; only the same-binary comparison isolates this acceptance setting. Post-benchmark code-validation revision `65ead7f5816d67e636ed12e17395d1eba7a51e55` rebases onto master `16823b527` with API-test/privacy additions. `git diff --exit-code f59a6a4f0484e65802b8d7279f1f29d70d5593bc 65ead7f5816d67e636ed12e17395d1eba7a51e55 -- provider-swift libs scripts/benchmarks` passes: measured production trees are unchanged.

| Component | Identity |
|---|---|
| Hardware | Apple M5 Max, 128 GiB unified memory, 18 CPU cores |
| Runtime OS | macOS 27, build `26A428` |
| Remote Swift | 6.3.2; not the artifact build compiler |
| Build compiler | Local Xcode Swift 6.3.3, SDK 26.5, `-O` / whole-module optimization |
| Dependency pins | Original `Package.resolved`; external matches include SwiftSyntax 603.0.1, Hugging Face 0.9, Transformers 1.3.3, Jinja 2.3.6 |
| MLX / MLX Swift | `cb77239be` / `6923a80f` |
| Before binary SHA-256 | `8665dd933e40b157a24265043111befa4ded515fbaab7019fb7b30308c5d9ac1` |
| Shared candidate binary SHA-256 | `62d1ccd7813800c226553459fd9113c889c2a8ee1b421c43f927098873858ea1` |
| Shared AOT metallib SHA-256 | `7c28ecf53933836990a9f29f0ec5367c44dae9e0c2f3e875076c3bac3a5adb32` |

| Model ID | Verified model SHA-256 |
|---|---|
| `EigenLabs/Qwen3.8-27B-4bit-mtp` | `bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463` |
| `qwen3.6-35b-a3b-vl-mtp-mxfp8` | `d932e96b00404b0575fff47e2dac8ed113056b3f22d0040c3c8d3f9ef25b09ed` |
| `gemma-4-26b-qat-4bit` | `2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785` |

The Qwen3.6 directory spelling is not quantization evidence: verified headers describe mixed affine four-bit group-64 payloads, not pure MXFP8. Gemma's main snapshot is `0e3cbab38ce568cf6e23543010d08d03b731910c`; its assistant is downloaded only from `models.darkbloom.ai`, revision `bb94eae1b70a80dac16cbf959bb4b7d56bd1fb8c`.

| Gemma assistant component | SHA-256 |
|---|---|
| Config | `0cd54ff36e53a258532c5c1433bc44b88ba758cfe9b59bb4e6eecfd5453fabcf` |
| Weights | `3c4d43863abbbf455ec537c726eff7abeb88bb361e3ab23ff0d2d6006f620f74` |
| Manifest reference | `8b7c00b7f131345156f5f20fa9c94a895c5340f16d9331bafb9e59628bf45bf2` |
| Aggregate reference | `d8c5fae1f4b7a07376c9f0b92f3ec283ba276d57ec3b675d8cf758a79d73bd34` |

## Evidence And Reproduction

Raw per-cell inputs/reports/logs plus `summary.json`, `results.json`, and `provenance.json` remain at host path `/Users/gaj/Builds/typical-mtp-benchmark/results/full-20261007-f59a`. The checksum-verified local copy is `/var/folders/hv/5779vnmn5c564l3tdknlf4x80000gp/T/opencode/full-mtp-20261007-f59a`. These are local retention paths, not a committed evidence archive or a public download.

| Evidence | SHA-256 |
|---|---|
| `summary.json` | `58e68a853acee866bb32837440b0f1ae4292b26bf2e6db1d5b377f9f8fb3ea17` |
| `results.json` | `9564495cecd3a403ea53622360670fb8f9965ef1426ede21e3fd8b5634777313` |
| `provenance.json` | `d0e4d3c3f181ece9759c93fed4433da33d830a2f1e736338fc7509c8c7c19bc2` |
| Runner | `5da8186414a1dcc32c6f4c40b30e394a7755040021ce67a8fa619a0f919d225b` |
| Inputs | `0dff9897ccc36f6154d61dac382617b8fb71e954a6f02f7cfc78c1b46a962cdf` |

The temporary runner is not committed in this PR. To reproduce on the owned host, retain the pinned binaries/metallib/models, use the captured `measurements/actualconfig.json` and `measurements/inputs.json`, and replay the runner arguments in `provenance.json` into a new output directory. `results.json` records every actual binary command, including the production KV grant and cache-off/MTP-on/contiguous settings. Do not rerun into the frozen evidence directory. The host-local command below requires the retained temporary runner and controlled-smoke evidence; `NEW-OUTPUT` must name a fresh directory:

```bash
python3 /Users/gaj/Builds/typical-mtp-benchmark/measurements/runner.py \
  --config /Users/gaj/Builds/typical-mtp-benchmark/measurements/actualconfig.json \
  --inputs /Users/gaj/Builds/typical-mtp-benchmark/measurements/inputs.json \
  --output /Users/gaj/Builds/typical-mtp-benchmark/results/NEW-OUTPUT \
  --process-timeout 300 --run \
  --smoke-evidence /Users/gaj/Builds/typical-mtp-benchmark/results/smoke-controlled-20261006-f59a
```

To independently reduce the acceptance totals from the retained summary:

```bash
jq '.models | to_entries[] | {model: .key, arms: (.value.arms | map_values({tps: .medians.decode_tps, weighted_acceptance: (.mtp_totals.accepted_tokens / .mtp_totals.proposed_tokens)}))}' summary.json
```

## Validation And Limits

Focused validation reports 99 passing engine cases with 18 native-exclusive skips. After adding the divergent-draft regression, the 11-case typical suite also passes; these counts overlap and are not a deduplicated total. Provider DEBUG validation passes 19 tests in three suites, including actual public-SPI installation of exact and typical. Harness validation passes 19 Python tests and three Swift tests. Release artifacts build with the original matched dependency pins. Dedicated engine, provider, harness, and test refactor passes find no warranted changes. A release-mode full-provider test attempt fails in unrelated existing DEBUG-hook tests; the successful focused DEBUG runs are not evidence that the whole provider suite is green.

The controlled 18-request smoke passes active-MTP gates on all three models but is excluded from final numbers. Earlier uncontrolled smoke and the assistant-manifest staging failure are retained and excluded. A local VPN interruption is recovered by the user. The complete measured run passes; not every historical attempt passes.

This single-host B1, cache-off, short synthetic workload does not qualify fleet performance, concurrency, cache behavior, or model quality. Three repetitions per prompt do not establish statistical significance. Typical acceptance can alter sampled output, and no code/reasoning/prose quality evaluation is performed. Greedy equality covers only the three tested control requests. Exact remains the default; no fleet-default change, release, merge, or deployment is authorized by these measurements.
