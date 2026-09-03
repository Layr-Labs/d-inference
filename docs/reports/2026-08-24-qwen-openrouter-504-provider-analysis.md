# Qwen 3.6 OpenRouter 504 and Provider Performance Analysis

> Last updated: 2026-08-24 · commit `5d400cf75`

**Date:** 2026-08-24  
**Model:** `qwen3.6-35b-a3b-vl-mtp-mxfp8`  
**OpenRouter identity:** `qwen/qwen3.6-35b-a3b`  
**Related proposal:** [PR #681 — stop slow Qwen prefill from being counted as OpenRouter downtime](https://github.com/Layr-Labs/d-inference/pull/681)

## Executive summary

OpenRouter reported 27,220 Qwen HTTP 504 responses alongside 206,175 successes. The matching Darkbloom routing window contains 27,221 `client_gone` cancellations and only 116 coordinator-generated first-chunk 504s.

The `dev@openrouter.ai` service key accounts for 27,219 of the 27,221 `client_gone` rows. The near-exact count match means the dominant OpenRouter 504 is not a provider returning HTTP 504 to Darkbloom. OpenRouter is timing out or cancelling a request that has not produced first content, then representing that upstream failure as 504 in its dashboard.

The issue is systemic but hardware-sensitive:

- 24-hour OpenRouter-like timeout rate: **11.65%**.
- Latest-hour timeout rate: **13.70%**.
- Best high-volume tier over 24 hours: M5 Pro at 7.85%, followed by M5 Max at 8.95%.
- Worst tier: M4 Pro at 19.80% over 24 hours and 29.88% in the latest hour.
- M2 Max and M2 Ultra are also consistently poor.
- Provider variance inside one family is large: current M5 Max providers range from 2.13% to 46.56% in the latest hour.

The operator's isolated benchmark—4,096 warm tokens at 1,766.6 tok/s and 2.318 s TTFT—is credible and does not contradict production. It excludes queueing, concurrent partial prefills, active decode rows, routing, dispatch, and burst contention. Production successful Qwen requests averaged about 5.0 s of queue wait plus 7.2 s actual TTFT over the 24-hour window. In the latest hour, successful TTFT rose to 8.7–10.0 s and decode fell to 24–29 tok/s across tiers.

Lack of prefill serialization/FCFS is therefore a real contributor under bursts, but FCFS alone is not sufficient. PR #681's three-part design matches the evidence better:

1. Rank providers using observed prefill performance.
2. Serialize partial prefills so a burst does not make every row finish at the makespan.
3. Refuse rows that still cannot land before the upstream deadline, allowing coordinator re-dispatch instead of an OpenRouter-visible timeout.

## Scope and methodology

### Fixed analysis window

The database window was fixed before querying:

```text
UTC: 2026-08-23 19:45:31 → 2026-08-24 19:45:31
PDT: 2026-08-23 12:45:31 → 2026-08-24 12:45:31
```

This aligns closely with the OpenRouter screenshot beginning around noon on August 23 and ending around noon on August 24.

A separate latest-hour slice used:

```text
UTC: 2026-08-24 18:45:31 → 2026-08-24 19:45:31
```

### Data sources

- Current fleet inventory: live `GET /v1/stats`.
- Current scheduler capacity: live `GET /v1/models/capacity`.
- Request outcomes and hardware snapshots: `inference_routes`.
- OpenRouter account attribution: `api_keys` joined to `users`.
- Operator-supplied benchmark: production `mlx-swift-lm` ContinuousBatchingV2 path through `SchedulerPrefillBenchmark`.
- Proposed remediation design: PR #681.

### Safety

All database queries were executed against Cloud SQL read replica `d-inference-prod-pg17-ro` with:

```text
default_transaction_read_only = on
statement_timeout              = 30s or lower
lock_timeout                   = 1s
```

No provider, request, routing, database, model, traffic, or infrastructure state was changed.

## OpenRouter dashboard reconciliation

### OpenRouter screenshot

```text
success-200: 206,175
error-504:    27,220
error-429:       481
error-413:        26
error-522:         7
error-400:        11
error-422:        27
error-0:           6
error-503:         1
```

### Darkbloom route outcomes in the matching window

| Final status | Error code | Error class / reason | Requests |
|---|---:|---|---:|
| success | 0 | — | 206,354 |
| cancelled | 0 | `client_gone` / `cancelled` | **27,221** |
| cancelled | 0 | `speculative_loser` | 1,720 |
| unset | 0 | — | 1,002 |
| error | 503 | `provider_error` / `capacity_busy` | 265 |
| error | 502 | `provider_disconnect_pre_commit` | 236 |
| partial success | 0 | client gone, provider later completed | 144 |
| partial success | 500 | provider error after commit | 121 |
| timeout | 504 | `first_chunk_timeout` | **116** |
| error | 502 | provider error | 115 |
| error | 503 | request exceeds node budget | 100 |
| partial success | 502 | provider disconnect after commit | 79 |
| other | mixed | all remaining classes | low volume |

The OpenRouter service key owns:

```text
Success rows:      204,232
client_gone rows:   27,219 of 27,221
```

The key resolves to `dev@openrouter.ai` with role `service`.

### Interpretation

**Inference:** OpenRouter cancels requests that remain silent beyond its upstream deadline and records those as HTTP 504. Darkbloom sees the connection disappear, so its durable outcome is `client_gone`, code 0, rather than a locally emitted 504.

Evidence:

- OpenRouter 504 count: 27,220.
- Darkbloom client-gone count: 27,221.
- OpenRouter service-key client-gone count: 27,219.
- Actual Darkbloom `first_chunk_timeout` 504 count: only 116.
- Client-gone rows have no recorded first-content TTFT.

The small success-count mismatch (179 rows, 0.09%) is consistent with slight chart-window, bucket, or refresh-boundary differences.

## Current Qwen fleet

### Scheduler capacity

```text
Ready:                 true
Can accept:            true
Routable providers:    469
Warm providers:        256
Running providers:      29
Cold providers:        216
Active requests:        62
Queued requests:         0
Queue limit:             8
Aggregate TPS:      14,282.7
```

Aggregate capacity is available and the central request queue is empty. The 504s are not explained by complete fleet exhaustion.

### Advertised providers

```text
Providers advertising Qwen: 654
Hardware-attested:           582
Self-signed:                  67
No trust:                      5

Online:                      507
Serving:                     107
Untrusted:                    40
```

`BackendCapacity.Slots` is authoritative for scheduler warmth. The 256 warm-provider count should be used instead of `current_model`, because a provider can hold multiple loaded model slots.

### Current advertised fleet by chip family

| Chip family | Providers |
|---|---:|
| M4 | 165 |
| M1 | 159 |
| M5 | 133 |
| M3 | 119 |
| M2 | 78 |

### Current advertised fleet by family and tier

| Family / tier | Providers | Current Qwen model | Hardware-attested |
|---|---:|---:|---:|
| M1 Max | 117 | 39 | 96 |
| M4 Max | 83 | 22 | 71 |
| M5 Max | 82 | 31 | 72 |
| M4 Pro | 67 | 14 | 62 |
| M3 Ultra | 64 | 28 | 63 |
| M3 Max | 49 | 15 | 44 |
| M2 Max | 48 | 12 | 41 |
| M5 Pro | 38 | 8 | 35 |
| M1 Pro | 31 | 0 | 27 |
| M2 Ultra | 25 | 7 | 24 |
| M4 Base | 15 | 0 | 15 |
| M5 Base | 13 | 0 | 13 |
| M1 Ultra | 11 | 5 | 11 |
| M3 Pro | 6 | 0 | 5 |
| M2 Pro | 5 | 0 | 3 |

## Outcomes by chip family and performance tier

### Twenty-four-hour window

| Hardware | Success | OpenRouter-like timeout | Timeout rate | Providers routed |
|---|---:|---:|---:|---:|
| M5 Pro | 4,920 | 419 | **7.85%** | 30 |
| M5 Max | 39,329 | 3,868 | **8.95%** | 156 |
| M3 Ultra | 69,604 | 7,806 | **10.08%** | 155 |
| M1 Max | 507 | 61 | 10.74% | 10 |
| M3 Max | 20,744 | 2,870 | 12.15% | 56 |
| M4 Max | 47,301 | 7,308 | 13.38% | 88 |
| M2 Ultra | 10,142 | 1,811 | 15.15% | 143 |
| M2 Max | 7,323 | 1,477 | 16.78% | 91 |
| M4 Pro | 6,484 | 1,601 | **19.80%** | 35 |

Overall success/timeout cohort:

```text
Successes:    206,354
Timeout-like:  27,221
Timeout rate:   11.65%
```

### Latest hour

| Hardware | Success | OpenRouter-like timeout | Timeout rate |
|---|---:|---:|---:|
| M5 Max | 3,742 | 370 | **9.00%** |
| M5 Pro | 292 | 38 | 11.52% |
| M3 Ultra | 4,601 | 644 | 12.28% |
| M3 Max | 901 | 153 | 14.52% |
| M4 Max | 2,484 | 447 | 15.25% |
| M1 Max | 62 | 12 | 16.22% |
| M2 Ultra | 636 | 138 | 17.83% |
| M2 Max | 517 | 142 | 21.55% |
| M4 Pro | 589 | 251 | **29.88%** |

```text
Latest-hour successes:    13,824
Latest-hour timeouts:      2,195
Latest-hour timeout rate:  13.70%
```

The problem was still active and worse than the 24-hour average at investigation time.

## Prompt-size sensitivity

Timeout rate by estimated prompt length:

| Hardware | <2K | 2–4K | 4–8K | 8–16K | 16K+ |
|---|---:|---:|---:|---:|---:|
| M5 Max | 6.71% | 13.79% | 11.71% | 5.61% | 5.03% |
| M5 Pro | 5.14% | 12.59% | 9.74% | 5.89% | 11.48% |
| M3 Ultra | 6.67% | 18.67% | 13.32% | 5.74% | 7.69% |
| M4 Max | 8.30% | 17.89% | 16.49% | 11.09% | 15.30% |
| M3 Max | 5.83% | 17.36% | 15.55% | 12.39% | 20.38% |
| M2 Ultra | 7.16% | 27.72% | 17.53% | 13.05% | 19.41% |
| M2 Max | 8.15% | 27.47% | 24.14% | 35.42% | insufficient sample |
| M4 Pro | 6.94% | 27.04% | 25.10% | 27.66% | **61.31%** |
| M1 Max | 3.37% | 32.50% | insufficient sample | insufficient sample | insufficient sample |

The lower tiers become unsafe for latency-sensitive OpenRouter traffic as prompts grow. M4 Pro and M2 Max are the clearest examples.

## Provider-level attribution

### Concentration

The timeout problem is not one bad provider:

```text
Largest provider contribution:  614 timeouts, 2.26% of all timeouts
Top 5 providers:              2,640 timeouts, 9.70%
Top 10 providers:             4,504 timeouts, 16.55%
Top 20 providers:             7,614 timeouts, 27.97%
```

There were 764 routed provider IDs in the 24-hour window. Provider reconnects can fragment one physical machine across identifiers, so route hardware snapshots are more stable for tier conclusions than provider-ID counts.

### Worst current high-volume providers over 24 hours

Minimum 500 requests; provider IDs shown in full for operational lookup.

| Provider | Hardware | Memory | Success / timeout | Rate | Qwen loaded now |
|---|---|---:|---:|---:|---:|
| `c6c8a318-8fd4-4693-aa41-6121c6f4ea69` | M3 Max | 128 GB | 500 / 195 | **28.06%** | no |
| `3f559581-0b3c-4e10-904c-e5ca3a9f1cf2` | M4 Max | 128 GB | 1,523 / 440 | **22.41%** | yes |
| `ec515e03-25cb-4bba-bd32-876e23cc5ac1` | M4 Pro | 64 GB | 874 / 251 | **22.31%** | yes |
| `fe25ac1e-d31e-49de-9875-e44c1671c0f0` | M4 Max | 128 GB | 648 / 155 | 19.30% | yes |
| `ddf6a7a4-48ef-4fb0-a3a4-461e2ac71d1b` | M4 Max | 128 GB | 2,609 / 614 | 19.05% | yes |
| `f2c4c88c-f015-4a6d-8815-59f42cb0080f` | M5 Max | 128 GB | 830 / 183 | 18.07% | yes |
| `d914acb4-1b08-44d1-9f81-914005baa02a` | M3 Max | 128 GB | 696 / 150 | 17.73% | yes |
| `22fff9d5-155d-4766-a3d9-702d845f690f` | M4 Pro | 64 GB | 944 / 203 | 17.70% | yes |
| `f93d7ab3-6166-4b1d-ae0b-9d8e6da50743` | M4 Pro | 64 GB | 693 / 147 | 17.50% | yes |
| `262f100d-376f-48c7-9f6c-55d7031f7f18` | M4 Max | 128 GB | 534 / 113 | 17.47% | yes |

### Best current high-volume providers over 24 hours

| Provider | Hardware | Memory | Success / timeout | Rate | Qwen loaded now |
|---|---|---:|---:|---:|---:|
| `87b83111-eb46-466a-bc26-ae32e911a7b0` | M3 Ultra | 96 GB | 488 / 31 | **5.97%** | yes |
| `11e03964-c617-4565-a5eb-3f74789265b4` | M3 Ultra | 256 GB | 634 / 46 | **6.76%** | yes |
| `3e05b9f2-23c9-4266-82ec-b5534c7cbdce` | M5 Max | 128 GB | 641 / 48 | **6.97%** | yes |
| `6d746807-6d20-4fde-9265-346c77121429` | M5 Pro | 64 GB | 1,678 / 127 | **7.04%** | yes |
| `49522151-2ec5-43e3-bed2-14901bb96493` | M5 Max | 128 GB | 836 / 64 | **7.11%** | yes |
| `ac74f30b-a0c8-47da-9a6b-959ccb90bf70` | M3 Ultra | 512 GB | 3,212 / 248 | 7.17% | yes |
| `dd66eede-12cb-4219-aa5e-4a372c835fbb` | M5 Max | 128 GB | 642 / 50 | 7.23% | yes |
| `29ba18c4-acfe-46be-97d9-e221eace2fb2` | M4 Max | 128 GB | 629 / 50 | 7.36% | no |
| `f5c1c495-d3fa-4313-80b9-bef4937cffcf` | M3 Ultra | 96 GB | 734 / 60 | 7.56% | yes |
| `27db039f-5873-45c6-8108-cd32af126669` | M3 Ultra | 512 GB | 3,054 / 258 | 7.79% | yes |

No high-volume provider had zero timeouts. There were 134 zero-timeout provider IDs, but the largest handled only 38 successful requests.

### Acute current outliers in the latest hour

Minimum 100 requests; all listed providers currently advertise Qwen and have Qwen loaded.

| Provider | Hardware | Success / timeout | Rate | Success TTFT | Decode TPS |
|---|---|---:|---:|---:|---:|
| `f17ca6f2-7e4f-4204-93df-11c82dcb51f3` | M5 Max 128 GB | 70 / 61 | **46.56%** | 9.77 s | 29.01 |
| `6b234ee9-1a44-465c-931c-de2ca45c9eed` | M4 Pro 64 GB | 69 / 40 | **36.70%** | 9.27 s | 25.20 |
| `fe25ac1e-d31e-49de-9875-e44c1671c0f0` | M4 Max 128 GB | 108 / 51 | **32.08%** | 9.17 s | 23.60 |
| `ec515e03-25cb-4bba-bd32-876e23cc5ac1` | M4 Pro 64 GB | 74 / 34 | **31.48%** | 11.41 s | 23.15 |
| `f93d7ab3-6166-4b1d-ae0b-9d8e6da50743` | M4 Pro 64 GB | 80 / 31 | **27.93%** | 9.50 s | 26.44 |
| `054c6e34-9c23-4a51-8a60-e6413bd13fd0` | M2 Max 64 GB | 128 / 45 | 26.01% | 7.45 s | 30.42 |
| `262f100d-376f-48c7-9f6c-55d7031f7f18` | M4 Max 128 GB | 104 / 31 | 22.96% | 9.66 s | 24.48 |
| `e6b4f6a6-44b0-4186-9a21-f3703555b3dc` | M2 Ultra 192 GB | 109 / 28 | 20.44% | 10.26 s | 24.02 |
| `942856f0-6ee1-4651-addd-87e791090ab9` | M3 Max 128 GB | 115 / 29 | 20.14% | 10.18 s | 26.02 |
| `f2c4c88c-f015-4a6d-8815-59f42cb0080f` | M5 Max 128 GB | 108 / 27 | 20.00% | 11.03 s | 25.17 |

### Healthiest current providers in the latest hour

Minimum 100 requests; all listed providers currently advertise Qwen and have Qwen loaded.

| Provider | Hardware | Success / timeout | Rate | Success TTFT | Decode TPS |
|---|---|---:|---:|---:|---:|
| `baf8269e-f7e6-4562-a34e-348426e56ee8` | M5 Max 48 GB | 230 / 5 | **2.13%** | 8.06 s | 28.93 |
| `dd66eede-12cb-4219-aa5e-4a372c835fbb` | M5 Max 128 GB | 123 / 3 | **2.38%** | 8.30 s | 29.34 |
| `3e05b9f2-23c9-4266-82ec-b5534c7cbdce` | M5 Max 128 GB | 195 / 6 | **2.99%** | 8.48 s | 28.04 |
| `0f572d1b-4149-414c-bcc6-5ba16fc4ec56` | M5 Max 128 GB | 273 / 9 | **3.19%** | 7.32 s | 29.94 |
| `bc71dd39-ba67-4e0f-bd02-ac98aa6f40a0` | M5 Max 128 GB | 137 / 5 | **3.52%** | 8.49 s | 27.40 |

## Timing signature

### Client-gone duration distribution

```text
p10: 11.640 s
p50: 13.812 s
p90: 24.653 s
p95: 27.592 s
p99: 37.695 s
```

Stage percentiles for the cancelled cohort:

```text
Parse:    p50 3 ms,   p95 965 ms
Route:    p50 13 ms,  p95 185 ms
Dispatch: p50 280 ms, p95 5,009 ms
```

The durable total includes cancellation detection and cleanup, so it should not be treated as the exact OpenRouter gateway deadline. The lower edge and dispatch tail are nevertheless consistent with a silent-upstream deadline around the known OpenRouter range.

### Twenty-four-hour success versus timeout cohort

| Metric | Success | OpenRouter-like timeout |
|---|---:|---:|
| Requests | 206,354 | 27,221 |
| Total duration | 15.63 s | 16.21 s |
| Parse | 17.5 ms | 127.5 ms |
| Balance reservation | 8.3 ms | 27.9 ms |
| Routing | 26.8 ms | 109.0 ms |
| Encryption | 3.9 ms | 6.8 ms |
| Queue wait | 5.05 s | not finalized |
| Dispatch | 427.5 ms | 920.1 ms |
| Actual TTFT | 7.22 s | no first content recorded |
| Prompt estimate | 5,826 tokens | 5,821 tokens |
| Requested max tokens | 9,976 | 8,250 |
| Candidates | 126.7 | 131.5 |
| Projected TPS | 81.23 | 82.38 |

The overall prompt mix is nearly identical. The timeout cohort did not ask for more output on average. This argues against request shape alone as the explanation.

### Latest-hour tier performance

| Tier | Successful TTFT | Selected TTFT projection | Actual decode TPS | Timeout rate |
|---|---:|---:|---:|---:|
| M5 Max | 8.81 s | 8.79 s | 27.32 | 9.00% |
| M3 Ultra | 9.96 s | 9.61 s | 25.51 | 12.28% |
| M4 Max | 8.67 s | 8.82 s | 26.57 | 15.25% |
| M4 Pro | 9.42 s | 8.29 s | 24.29 | 29.88% |
| M3 Max | 8.88 s | 8.98 s | 24.75 | 14.52% |
| M2 Max | 7.42 s | 7.29 s | 29.35 | 21.55% |
| M2 Ultra | 9.86 s | 10.06 s | 24.31 | 17.83% |
| M5 Pro | 9.45 s | 8.73 s | 23.46 | 11.52% |
| M1 Max | 7.27 s | 8.30 s | 29.29 | 16.22% |

The selected-provider TTFT model is reasonably close for successful requests. The underlying service is simply operating close to the upstream deadline, leaving little variance budget.

## Why the isolated 4K benchmark does not contradict production

Operator-supplied benchmark:

```text
Model: EigenLabs/Qwen3.6-35B-A3B-MLX-VL-4bit-g64-router8-mtp
Prompt: 4,096 tokens
Engine: production mlx-swift-lm ContinuousBatchingV2
KV: contiguous
Prefix cache: off
Production prefill stripe: 2,048 tokens
Iterations: 3
Median prefill throughput: 1,766.6 tok/s
Median TTFT: 2.318 s
```

This establishes that the Swift kernels and isolated production engine can prefill 4K quickly. It does not measure the production queueing problem because each measurement uses:

- One request.
- A fresh single-row engine.
- No concurrent partial prefills.
- No active decode rows competing for scheduler steps.
- No provider backlog.
- No coordinator routing or dispatch.
- No burst arrival schedule.

A simple reconciliation is:

```text
Isolated 4K prefill:          ~2.3 s
Observed average queue wait:  ~5.0 s
Expected production TTFT:     ~7.3 s
Observed production TTFT:     ~7.2 s over 24 h
```

The benchmark proves raw throughput is sufficient. Production telemetry shows that shared-engine scheduling and waiting consume the deadline margin.


## Direct evidence of concurrent/batched prefill

The route snapshot does not expose the CBv2 partial-prefill queue directly, but
three independent production signatures show that requests are sharing a busy
engine rather than receiving isolated single-row prefill.

### Reported backend depth

When the provider snapshot explicitly reported any running or waiting row, the
timeout rate quadrupled:

| Snapshot state | Success | Timeout | Rate |
|---|---:|---:|---:|
| `backend_running = 0`, `backend_waiting = 0` | 205,410 | 26,441 | 11.40% |
| Either field non-zero | 944 | 780 | **45.24%** |

Reported depth is sparse and should not be treated as complete truth:

- 99% of route rows report zero depth.
- `EngineV2Bridge+Capacity.swift` maps a momentary engine snapshot to
  `num_running`/`num_waiting`.
- `queued_token_budget` is hardcoded to zero in the current bridge.
- The snapshot can be stale by the time the selected request reaches prefill.

The non-zero sample nevertheless shows that known contention is strongly
associated with timeout.

Detailed rate by reported depth:

| Running | Waiting | Requests | Timeout rate |
|---:|---:|---:|---:|
| 0 | 0 | 231,851 | 11.40% |
| 0 | 1 | 206 | 51.46% |
| 0 | 2 | 69 | 68.12% |
| 1 | 0 | 877 | 30.22% |
| 1 | 1 | 116 | 68.97% |
| 2 | 0 | 141 | 54.61% |
| 3 | 0 | 110 | 78.18% |
| 4 | 0 | 8 | 87.50% |

### Same-provider arrival spacing

Requests arriving shortly after another Qwen request on the same provider time
out much more often:

| Gap from previous Qwen request on provider | Requests | Timeout rate |
|---|---:|---:|
| First observed request | 764 | 8.38% |
| ≤100 ms | 12,157 | 16.15% |
| 100–250 ms | 11,905 | 15.70% |
| 250–500 ms | 14,130 | 16.35% |
| 500 ms–1 s | 18,187 | 15.33% |
| 1–5 s | 44,934 | 12.65% |
| >5 s | 131,498 | **9.54%** |

The request shape is therefore materially worse when arrivals overlap the
roughly 7–10 second production prefill/TTFT interval.

### Burst size

Requests were clustered per provider when adjacent arrivals were no more than
one second apart:

| Burst size | Bursts | Requests | Timeout rate | All-timeout bursts |
|---|---:|---:|---:|---:|
| 1 | 140,612 | 140,612 | **8.34%** | 11,729 |
| 2 | 22,943 | 45,886 | 16.33% | 1,469 |
| 3 | 8,047 | 24,141 | **18.10%** | 367 |
| 4 | 5,229 | 20,916 | 15.24% | 128 |
| 5–7 | 354 | 1,921 | **22.54%** | 9 |
| 8+ | 11 | 99 | 10.10% | 0 |

The 8+ bucket is too small for conclusions. Across the meaningful buckets,
two or more near-simultaneous rows approximately double the singleton timeout
rate.

### Production 4K comparison

For production prompts between 3,500 and 4,500 estimated tokens:

| Burst size | Success | Timeout | Rate | Success TTFT p50 | Success TTFT p90 |
|---|---:|---:|---:|---:|---:|
| 1 | 6,515 | 1,026 | 13.61% | 5.55 s | 10.37 s |
| 2 | 2,530 | 574 | 18.49% | 6.60 s | 11.50 s |
| 3 | 1,534 | 353 | 18.71% | 6.94 s | 11.33 s |
| 4 | 1,503 | 272 | 15.32% | 6.56 s | 11.30 s |
| 5+ | 82 | 27 | **24.77%** | 8.22 s | 12.31 s |

Even the singleton production bucket has 5.55 s median TTFT rather than the
isolated benchmark's 2.318 s. “Singleton” here means no adjacent Qwen arrival;
the engine can still contain active decode rows or requests for other work, and
the route can still wait before prefill.

### Lockstep first-token signature

For successful same-provider request pairs that:

- arrived within 250 ms, and
- differed by no more than 256 estimated prompt tokens,

the first-token completion times were:

```text
Pairs:                  2,957
Within 100 ms:          1,049  (35.5%)
Within 250 ms:          1,240  (41.9%)
Within 500 ms:          1,500  (50.7%)
Within 1 second:        2,016  (68.2%)
Completion-gap median:    475 ms
Completion-gap p90:      2.86 s
```

If those rows were strict serial FCFS, the second row would normally finish
roughly one isolated prefill later, not within a few hundred milliseconds.
The clustering is consistent with concurrent partial prefills advancing
together. It is not absolute proof for every request because telemetry lacks
stripe-level events.

### Live scheduler configuration

Every route in the window reported provider version `0.8.10`. In that provider
code, `maxConcurrentPartialPrefills` is populated only from
`DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS`; otherwise it remains `nil`. PR #681
documents that production provider configuration does not set this key.

The current behavior is therefore the unlimited/fair partial-prefill interleave
described in PR #681 unless an individual provider operator added a private
environment override.

### Telemetry still missing

To prove exact scheduler behavior per request, provider heartbeats or terminal
telemetry need to add:

- Active partial-prefill row count.
- Configured `maxConcurrentPartialPrefills`.
- Per-row prefill queue position.
- Queued prefill tokens ahead.
- Stripe number, stripe start, and stripe completion timestamps.
- Time admitted, time prefill first scheduled, and time prefill completed.
- Isolated/queue-excluded prefill EWMA.
- Load-inclusive prefill EWMA.
- Active decode-row count while each stripe runs.
- Deadline projection and refusal reason.

Current `backend_running`/`backend_waiting` is too sparse, and
`queued_token_budget` is always zero, so neither can reconstruct the exact CBv2
plan after the fact.

## Is the missing FCFS behavior the cause?

**Partly, yes. Not by itself.**

PR #681 documents the current CBv2 behavior under concurrent partial prefills:

```text
maxConcurrentPartialPrefills = nil
512-token fair interleave
all burst rows advance together
all finish near the burst makespan
```

For four concurrent 8K prompts at the measured rate used by the PR:

```text
Unlimited interleave:
  all rows finish at ~21.4 s
  budget ~18.2 s
  0/4 land

FCFS / maxConcurrentPartialPrefills = 1:
  row 0 ~5.35 s
  row 1 ~10.70 s
  row 2 ~16.05 s
  row 3 ~21.40 s
```

FCFS changes the outcome from four simultaneous misses to three successes plus one unavoidable miss. It does not save the fourth row. The admission/refusal component is required to reject that row before work begins so the coordinator can re-dispatch it to idle fleet capacity.

Strict FCFS also introduces head-of-line blocking. The useful policy is not arbitrary global FCFS; it is:

- One concurrent partial prefill per serving engine.
- Preserve decode progress.
- Project queued prefill work against the request deadline.
- Refuse work that cannot land.
- Re-dispatch refused work elsewhere.

## How PR #681 maps to observed production failures

### 1. Use measured prefill in provider selection

PR #681 changes the coordinator's dominant prefill cost term from static `snap.prefillTPS` to `resolvePrefillTPS(snap)`.

This matters because production currently routes across machines whose actual behavior differs materially despite similar advertised class. Family-only performance is insufficient; provider-specific performance ranges from 2% to more than 40% timeout in the latest hour.

Relevant files:

- `coordinator/registry/scheduler.go`
- `provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge.swift`

### 2. Serialize partial prefills

The proposed default:

```text
DARKBLOOM_CBV2_MAX_PARTIAL_PREFILLS=1
```

prevents every row in a burst from being delayed to the same makespan and re-arms the 2,048-token solo-prefill stripe.

Relevant file:

- `provider-swift/Sources/ProviderCore/Inference/EngineV2Factory+Production.swift`

### 3. Refuse rows that cannot meet the deadline

The provider projects TTFT from:

- Queue-excluded isolated prefill EWMA.
- Queued prefill tokens ahead.
- Elapsed work discount.
- Prompt tokens.
- Deadline base.

A row that cannot fit returns the existing queue-full/token-budget contract, producing a retryable 429 and coordinator re-dispatch instead of a silent timeout.

This is important for OpenRouter uptime accounting: 429 is failover-neutral; error-0/504 contributes to downtime.

### PR #681 limitation

The PR's real-model concurrent benchmark has not been run. Its scheduler simulation uses real planner code and measured arithmetic, but downstream kernels, paused-row accounting, and hardware behavior still need an end-to-end burst test on a Qwen-capable machine.

The operator's isolated 4K benchmark validates the single-row rate, not the 4×8K concurrency claim.

## Root-cause ranking

1. **Concurrent partial-prefill interleave under burst load.** Strong mechanistic fit; supported by PR #681's real-scheduler simulation.
2. **Admission too permissive for the upstream deadline.** Requests with selected projected TTFT around 8–11 s have almost no margin.
3. **Provider-specific degradation under load.** Same-family machines differ by more than 20 percentage points of timeout rate.
4. **Hardware-tier mismatch for long prompts.** M4 Pro and M2 tiers are consistently unsafe for larger prompts.
5. **Recent fleet-wide performance degradation.** Latest-hour decode is 24–29 tok/s versus roughly 30–45 tok/s over the full day.
6. **Coordinator route/dispatch tail.** Cancelled rows have higher parse/reserve/route/dispatch latency, with dispatch p95 around 5 s.
7. **Raw isolated prefill throughput.** Not the primary problem; the 4K benchmark is healthy.

## Recommended next steps

### Immediate routing mitigation

1. Keep OpenRouter Qwen long-prompt traffic off M4 Pro, M2 Max, and M2 Ultra.
2. Prefer M5 Max, M5 Pro, and selected M3 Ultra providers.
3. Do not apply family-only trust: retain provider-level model-specific timeout history.
4. Use fast 429 rejection when the selected provider's projected first-token latency is near the OpenRouter deadline.

### Validate PR #681 before merge

Run on a Qwen-capable provider under release build:

```text
1 x 4K
4 x 4K simultaneous
1 x 8K
4 x 8K simultaneous
mixed 1K / 4K / 8K burst
active decode rows + new 8K prefill burst
```

For each arm capture:

- Arrival order.
- Per-row first-token time.
- Prefill stripe schedule.
- Decode progress while prefill runs.
- Refusal decision and projection.
- Actual provider queue depth.
- Aggregate prefill throughput.
- Output checksum.

Compare:

```text
maxConcurrentPartialPrefills = 0 / unlimited
maxConcurrentPartialPrefills = 1
admission gate off
admission gate on
```

Acceptance criteria:

- No aggregate throughput regression beyond an agreed tolerance.
- Earlier rows land inside deadline.
- Rows projected to miss are refused before reservation/work.
- Decode rows do not starve.
- Short prompts are not trapped behind long-prefill head-of-line blocking.
- Coordinator re-dispatch converts refusals to success while fleet capacity is available.

### Medium-term routing controls

- Maintain EWMA of Qwen `client_gone` rate per provider with prompt-size buckets.
- Require a minimum sample before ejection.
- Decay old failures so recovered providers return.
- Feed timeout reputation into selection rather than using permanent hard bans.
- Expose provider-level observed prefill and actual TTFT divergence in admin telemetry.
- Separate OpenRouter deadline-aware admission from ordinary direct-consumer policy.

## Key caveats

- `client_gone` proves the caller disconnected before a terminal result; it does not expose OpenRouter's internal timeout implementation directly. The OpenRouter attribution is an inference supported by key ownership and the near-exact count match.
- Provider IDs can change across reconnects. Hardware snapshots are reliable per attempt; long-term physical-machine attribution should use serial/provider-key lineage.
- Hardware-tier rates include different prompt mixes. Prompt-bucket analysis reduces but does not eliminate that confounding.
- `actual_ttft_ms` is absent on the cancelled cohort because no first content was recorded.
- The current capacity snapshot is healthy in aggregate; per-provider burst contention remains possible.

## Short handoff

For another agent, the core facts are:

```text
OpenRouter 504 count                 27,220
Darkbloom client_gone count         27,221
OpenRouter-key client_gone count    27,219
Darkbloom first_chunk_timeout 504      116
24h timeout rate                    11.65%
latest-hour timeout rate            13.70%
current Qwen routable/warm          469 / 256
current Qwen queue                  0
best large tier                     M5 Max ~9%
worst tier                          M4 Pro 19.8% / 29.9% recent
isolated 4K TTFT                     2.318 s
production success TTFT              7.2 s 24h; 8.7–10.0 s recent
```

The isolated benchmark and production failures are compatible. Raw prefill is fast; burst scheduling, waiting, deadline admission, and provider variance consume the remaining margin. PR #681 directly targets those mechanisms, but its concurrent real-model benchmark still needs to be run before relying on the simulation alone.
