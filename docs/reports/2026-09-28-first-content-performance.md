# First-content performance and M5 capacity investigation

> Last updated: 2026-09-28 · commit `ae4925180`

Read-only production analysis found transient Gemma prefill/queue pressure,
deadline-refusal amplification across models and a prefill measurement ceiling
that can discard fast-machine observations. The resulting
[performance plan](../design/first-content-performance.md) is proposed; no
application, provider or production changes were made by this investigation.

## Evidence and definitions

All windows are September 28 UTC (September 27 Pacific). Queries used the Cloud
SQL read replica with read-only transactions, a 15-second statement timeout and
one-second lock timeout. The observed coordinator was `ae4925180`, release
0.9.11, with MLX-LM dependency `9f70e68d`.

[`data/first-content-performance-2026-09-28/summary.json`](data/first-content-performance-2026-09-28/summary.json)
contains the sanitized aggregate projection. Raw SQL, outputs and analysis
scripts remain in the private workspace directory
`reports/gemma-ttft-2026-09-28/`; raw operational identifiers are not included in
the docs projection.

`usage` counts completed public requests. `inference_routes` counts attempts,
whose `request_id` is not a logical HTTP request identifier. First dispatches
use `attempt=0`. HTTP rejection records are counted separately. Profile TTFT
starts at coordinator receipt; route `actual_ttft_ms` starts at the committed
dispatch and excludes earlier attempts. Neither measures upstream ingress to
the coordinator. Prefill phase duration includes scheduling interference.

Six five-minute Gemma windows begin at 01:20, 02:20, 03:50, 04:20, 04:50 and
05:15. Their estimated-prompt 1,024–4,095-token routing cohort has 23,223
attempts. Reconstructing the existing FNV-1a 10% sampling predicate yields
1,897 successful winning profiles with valid provider timing and no anomaly.
Slow/failing/retried retained profiles are not treated as a random sample.
Successful-request latency excludes failures, which remain separate outcomes.

## Release timeline

| Event | UTC time | Source |
|---|---|---|
| New coordinator image started | 02:13:37 | Retained Docker container state |
| Provider 0.9.11 registered | 03:26:45 | Durable release record |
| Provider GitHub release published | 03:27:12 | Release metadata |
| Same coordinator image restarted | 04:34:46 | Current and retained container state |

Cache planner capacity was 40 QPS before the coordinator update, 120 afterward,
then 240 after the later restart. Cache routing stayed active. Incident
configuration had hard predictive TTFT rejection disabled, admission in shadow
mode and a six-second maximum coordinator queue wait. These are historical
observations, not present configuration guarantees.

## Gemma workload and latency

Completed public traffic, all prompt sizes:

| Metric | 03:50–03:55 | 04:20–04:25 | 04:50–04:55 |
|---|---:|---:|---:|
| Completed requests/minute | 520 | 2,353 | 556 |
| Input tokens/minute | 1.46 million | 7.28 million | 1.56 million |
| Output tokens/minute | 101,617 | 332,917 | 165,514 |
| Average output tokens/request | 195 | 141 | 298 |

The burst had 4.52x as many completions and 4.98x input-token work as the earlier
window; mean output length was shorter. Completion and arrival windows differ,
but first-dispatch records independently show the burst. This does not reproduce
the original pasted before/after table, whose query definitions were unavailable.
No downstream OpenRouter client identity was established.

Successful profiles in the estimated 1k–4k band:

| Metric | 03:50–03:55 | 04:20–04:25 | 04:50–04:55 |
|---|---:|---:|---:|
| Profiles | 182 | 880 | 153 |
| TTFT median | 1.218 s | 2.663 s | 1.103 s |
| TTFT p95 | 2.609 s | 6.179 s | 2.649 s |
| Mean TTFT | 1.370 s | 2.972 s | 1.279 s |
| Mean time before dispatch, including earlier attempts | 25 ms | 458 ms | 33 ms |
| Mean engine admission wait | 4 ms | 198 ms | 3 ms |
| Mean prefill phase | 1,092 ms | 1,932 ms | 989 ms |
| Other provider work before content | 55 ms | 204 ms | 73 ms |
| Transport/delivery residual | 194 ms | 181 ms | 181 ms |

Mean components are additive; medians and percentiles are not. All profiles in
these three successful cohorts streamed and had no tools; vision flags occurred
in 4/182, 1/880 and 1/153. Hardware mix, actual prompt lengths, incidental cache
reuse and cross-model work are not controlled. These observations do not prove
complete release independence or a causal effect of choosing another provider.

## Deadline refusals and routing opportunities

The 04:20–04:25 estimated-band records contain 4,286 `deadline_unreachable`
attempts: 3,892 bounded forecasts and 394 unbounded. At the provider's pre-submit
snapshot, 2,855 had same-model running/waiting work and 1,431 had neither.
Model-idle is not whole-Mac-idle, and the engine state can change before its
atomic admission check.

For 1,347 of 1,628 bounded first-attempt refusals, the coordinator's prediction
still fit inside the provider's later remaining budget. One matched first
attempt predicted 2.669 seconds at the coordinator. The provider projected
3,213 prefill tokens plus six decode tokens at conservative rates of 233.249
and 32.646 tokens/s: 13.959 seconds against 9.299 seconds remaining. The new
prompt itself was 1,413 tokens; other work affected its first-token projection.

The provider halves phase-rate point estimates and serially prices the projected
prefill/decode work. A refusal means its conservative forecast did not fit, not
proof that execution would have missed. Removing the haircut would make many
forecasts fit arithmetically but does not prove successful recoveries. See
[`EngineV2Bridge+Admission.swift`](../../provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+Admission.swift)
(`firstTokenDeadlineAdmission`) and
[`FirstTokenDeadlineAdmissionV2.swift`](https://github.com/Layr-Labs/mlx-swift-lm/blob/9f70e68dce563c90ad443fef470a713936bf6a4d/Libraries/MLXLMCommon/ContinuousBatchingV2/FirstTokenDeadlineAdmissionV2.swift)
(`CBv2FirstTokenScheduledWork`).

At 04:50, 73/153 successful sampled requests had a recorded top-four candidate
with no same-model occupancy or whole-provider pending work and a predicted
first-content advantage above 250 ms; median advantage was 826 ms. For 16/153,
the alternative also had no worse predicted decode speed, health/capacity
penalty or cache credit; median advantage was 580 ms. These are forecast
opportunities, not measured speedups on unchosen providers.

## Hardware and measurement bounds

The stricter hardware cohort joins recorded attempts to the existing 10% profile
sample at 03:50, 04:50 and 05:15. It uses successful non-vision 0.9.11 Gemma
requests, actual prompt length 1,024–4,095, no coordinator cache credit, no
same-model work at submit and lifetime maximum engine batch rows equal to one.
It is not an identical-prompt or whole-Mac-isolation benchmark.

| Hardware | Requests | Provider sessions | Median prompt-processing rate |
|---|---:|---:|---:|
| M4 Max | 35 | 22 | 1,638 tokens/s |
| M5 Max | 102 | 47 | 4,551 tokens/s |
| M5 Ultra | 12 | 5 | 7,680 tokens/s |

Only two qualifying M4 Pro requests were available. Distinct sessions are not
necessarily distinct physical machines; a lack of routing cache credit does not
prove absence of incidental cache reuse.

Apple specifies 460/614 GB/s for 32/40-core M5 Max and 1.2 TB/s for 64/80-core
M5 Ultra, with up to 128/512 GB memory respectively. The public relative GPU AI
compute claims do not establish absolute application TFLOPS or concurrency.
[Apple specifications](https://www.apple.com/mac-studio/specs/),
[M5 Ultra announcement](https://www.apple.com/newsroom/2026/08/apple-introduces-m6-and-m5-ultra-for-a-big-leap-in-performance-and-ai-compute/).

The provider accepts cold-prefill samples up to 20,000 tokens/s, while the
coordinator's 5,000 ceiling turns higher observed rates into zero and falls back.
This incompatible bound is verified in source. At 05:17, four of seven
identified M5 Ultra Gemma slots had isolated rates above 5,000; two had zero
observed rate. The EWMAs differ, so this snapshot alone cannot attribute each
zero to sanitization. A bounded Docker log read timed out and Cloud Logging
returned no matching records; no warning count is claimed.
See [`heartbeat.go`](../../coordinator/registry/heartbeat.go) (`maxPrefillTPS`) and
[`EngineV2Bridge+Accounting.swift`](../../provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+Accounting.swift)
(`classifyPrefillSample`, `recordPrefillSample`).

## Cross-model follow-up, 06:00–06:10 UTC

Complete bounded attempt records on M5 Max and M5 Ultra:

| Model | Attempts | First dispatches | Deadline-refused attempts |
|---|---:|---:|---:|
| Gemma 4 26B QAT | 2,354 | 2,337 | 26 |
| GPT-OSS 20B | 1,047 | 430 | 488 |
| Qwen3.8 27B | 1,186 | 437 | 751 |
| Qwen3.5 35B | 376 | 240 | 129 |
| Qwen3.6 35B VL | 428 | 367 | 18 |
| Qwen3.5 9B | 23 | 23 | 0 |
| Bonsai 2 27B | 41 | 30 | 11 |
| Nemotron 3.5 Lightning | 1 | 1 | 0 |

These are not customer-error rates. Retries crossing window boundaries can appear
without their original dispatch. Across all hardware, the same window contains
239 GPT-OSS and 61 Qwen3.8 first-content-timeout HTTP-429 records.

At 06:09, identified Ultra Gemma slots (four) and GPT-OSS slots (three) advertised
and were assigned concurrency four. The provider default is four with a hard
clamp of eight; this is not hardware capacity certification. Qualified M5 B8/B16
performance was not established. See `clampEngineV2Concurrency` in
[`ProviderLoop.swift`](../../provider-swift/Sources/ProviderCore/ProviderLoop.swift)
and `effectiveMaxConcurrencyForModelRateLocked` in
[`concurrency_cap.go`](../../coordinator/registry/concurrency_cap.go).

## Limits and proposed response

The evidence supports improving measurement preservation, first-content ranking
and deadline/refusal alignment. It does not certify the proposed 8/16 concurrency
targets, lower chunk sizes, a guaranteed traffic increase or any deployed
performance improvement. The illustrative 1,470-ms busy-Ultra example in the
design includes an invented 1,200-ms wait and is not part of these measurements.

See the [proposed plan](../design/first-content-performance.md) for the
coordinator-first sequence, explicit qualification criteria and direct activation
without a shadow or sampled production rollout.
