# Autopilot capacity and 429 evidence

> Last updated: 2026-09-11 · commit `7c394fa2b`

This frozen measurement supports opt-in model loading and unloading. Most recent
429s were exhausted first-content deadlines on already resident models; the
controller therefore needs useful service capacity, request shape and hardware
eligibility, rather than machine counts or retry volume alone. No production
configuration, provider state or traffic was changed during this investigation.

## Window and provenance

| Evidence | Scope and provenance |
|---|---|
| Datadog | **2026-09-09 23:00:00Z ≤ t < 2026-09-11 23:00:00Z**, all 48 hourly buckets; `env:production,service:d-inference-coordinator` |
| Rejection ledger | Same 48 hours, eight six-hour aggregate queries; primary database through the existing coordinator connection |
| Fleet history | First fleet snapshot of each hour, all 48 hours; point samples, not hourly occupancy averages |
| Current inventory | 2026-09-11 23:33Z; snapshot time **23:33:04.907774Z** |
| Routing samples | Sep 10 **16:00–16:05Z**, the peak 429 hour, and Sep 11 **22:00–22:05Z** |
| Provider profiles | Sep 11 **22:00–22:01Z**; the attempted five-minute query exceeded its deadline and was narrowed |
| Billed token shapes | Sep 10 **16:00–17:00Z** and Sep 11 **22:00–23:00Z** |
| Live coordinator | Separately fetched health: version **0.9.2**, commit `ef7b5a9aa69e62374c83d8f2baddb2957e38c9a8`, 1,159 providers |
| Retained context | Previous **336h**, Aug26 23:00Z–Sep 9 23:00Z, 55,175,428 billed records; detailed historical fleet only 146h |

Database queries used `BEGIN READ ONLY`, `default_transaction_read_only=on`,
a 15-second statement timeout, one-second lock timeout and no parallel query
workers. Schema inspection confirmed `replica:false`; these were bounded reads
on the primary, not a replica. A first query's SQL alias syntax error was
corrected before collection. The successful routing aggregate preceding the
profile timeout was retained separately.

Raw aggregate JSON, exact SQL and Datadog query strings, collection scripts,
`evidence-summary.json` and file hashes are retained outside the PR at
`reports/2026-09-11-autopilot-evidence` in the operator checkout. They contain no prompt content,
provider/account/request identifiers, key hashes or credentials. Source semantics
were checked against the stamp commit; this is distinct from the live commit.

## Logical 429s and repeated attempts

Datadog recorded **10,655,401 logical request outcome events**, including
**748,867 rate_limited events (7.03%)**. The independent asynchronous rejection
ledger recorded **749,762 HTTP 429 rows**. These best-effort sources differ in
terminal timing, sink/delivery behavior and window boundaries; their denominators
must not be silently forced to match.

| Persisted reason | 429 rows | Share |
|---|---:|---:|
| `first_chunk_timeout` | 662,170 | 88.32% |
| `deadline_unreachable` | 51,717 | 6.90% |
| `oversized_request` | 18,598 | 2.48% |
| `queue_full` | 13,290 | 1.77% |
| `context_exceeded` | 2,712 | 0.36% |
| `queue_timeout` | 602 | 0.08% |
| `routing_saturated` | 457 | 0.06% |
| `unservable_token_budget` | 149 | 0.02% |
| `no_provider` | 67 | 0.01% |

**733,091 (97.78%)** were recorded at dispatch stage, 13,892 at queue stage and
2,779 at preflight. Dispatch does not establish useful engine execution: a
provider may refuse the remaining deadline without generating.

| Model | Logical outcomes | Rate limited | Rate |
|---|---:|---:|---:|
| Gemma QAT | 6,959,797 | 279,897 | 4.02% |
| GPT-OSS 20B | 2,694,644 | 315,564 | 11.71% |
| Qwen3.5 35B | 445,559 | 90,786 | 20.38% |
| Qwen3.6 35B VL MTP | 338,443 | 29,227 | 8.64% |
| Qwen3.8 27B MTP | 133,496 | 26,049 | 19.51% |
| Qwen3.5 9B | 79,274 | 5,457 | 6.88% |
| Nemotron 3.5 Lightning | 3,617 | 1,886 | 52.14% |

Nemotron's small, recently observed cohort is not a stable long-run estimate.
Qwen3.6 had **18,094 oversized-request 429s**, exceeding its 11,058 first-content
timeouts. Additional copies cannot fix a model-context overflow or a request
that cannot fit any eligible node; larger compatible nodes may help only the
latter when such nodes exist.

Attempt counters were much larger: Qwen3.5 35B had **4,501,368 deadline refusals**
and 354,574 success attempts; Gemma 14,446,290 and 6,674,322; GPT 6,760,793 and
2,377,861. Peak five-minute Gemma routing contained **133,736 rows**, only
**22,668 attempt-0 rows**, and 111,044 deadline refusals. These are not independent
arrivals. An attempt-fed capacity target would amplify retries into new demand.

`coordinator/api/attempt_outcome_metrics.go` (`emitAttemptOutcomeMetric`,
`recordRequestOutcomeORView`) separates dispatched attempts, undispatched queue
exits and logical outcomes. Legacy `request_outcome.success` records response
commitment, not complete streams; the separate final-stream view includes timeout
and mid-stream failures. `ratelimit.rejections` recorded another 29,512 events
without useful reason labels; it must not be added to the logical 429 count.

## Timeout shape and what remains unknown

| Model | First-content timeouts | Estimated prompt >4,096 | Mean estimated prompt | Mean requested max output |
|---|---:|---:|---:|---:|
| GPT-OSS | 281,362 | 79.53% | 12,954 | 25,910 |
| Gemma QAT | 260,353 | 71.48% | 9,114 | 6,533 |
| Qwen3.5 35B | 81,464 | 33.13% | 5,480 | 15,749 |
| Qwen3.8 27B | 23,497 | 77.81% | 12,169 | 16,780 |
| Qwen3.6 35B | 11,058 | 45.62% | 11,567 | 16,927 |

Requested maximum output is a reservation input, **not measured output work**.
Successful completion lengths inform service demand, while output limits still
constrain KV admission separately. Failed calls have no observed counterfactual
completion length.

At the peak, **133,637/133,736 Gemma attempts (99.93%) selected resident
idle/running model slots**. In the recent five-minute sample, GPT's 682
first-content timeout attempts selected 506 idle resident slots, 142 running
resident slots and 34 unknown states. Gemma's 89 selected 80 idle and 9 running
resident slots. Missing weights alone do not explain these failures.

An idle model slot is not an idle GPU: another model, pending reservations,
subsequent arrivals or stale heartbeats may consume resources. The one-minute
profile sample contained 21,443 rows and 11,566 valid provider profiles, but
**none of its 170 first-content timeout rows had engine segments**. A precise
causal split between intrinsic prefill, engine queueing, batch contention and
co-resident GPU work is therefore unavailable.

Observable late-attempt GPT timeout cohorts averaged roughly **10–27 total
attempts**, **1.7–8.1s remaining dispatch budget**, and **26–47s predicted TTFT**.
[INFERENCE] Remaining-deadline fit and repeated refusal are material planning and
routing diagnostics; loading more copies alone cannot be assumed to recover
these requests. The prediction is not ground truth, and this observational
sample does not measure the gain from changing it.

`coordinator/api/rejection_telemetry.go` (`recordRejection`) computes
`could_have_served` from an asynchronous candidate count, not a completed-request
counterfactual or remaining-deadline guarantee. `warm_provider_existed` is not
populated by that path. Engine profile stamps are offsets from enqueue, not
additive durations (`coordinator/protocol/profile.go`, `EngineProfile`). Success
profiles are sampled while failures bypass sampling
(`coordinator/api/profiler.go`, `sampled`); profile proportions are not request
success rates.

## Short-input traffic

Only **1,471** persisted 429s had a positive estimated prompt ≤32 tokens and
**7** had exactly 27. Most 429s were not themselves short-input requests; indirect
contention from short traffic remains possible but is not causally identified.

In the peak billed Gemma hour, 52,725/209,421 records (25.18%) had ≤32 input
tokens: 50,527 had exactly 25, only 53 exactly 27, and 52,272 had ≤32 input and ≤8
output. In the later hour, only 678/120,565 (0.56%) were ≤32; exactly 25 fell to 20
and exactly 27 to zero. Short-shape traffic subsided while 429s persisted.

The retained Sep 9 export had 8,326,514 Gemma records with 25 billed input tokens,
commonly estimated 18–20 at routing. Token length is not proof of abuse; literal 27
filtering misses that cohort. Preserve raw and filtered analysis, and estimate
work rather than treating a tiny completion like a long generation. All current
traffic is OpenRouter according to the operator; historical caller attribution
was not independently complete in these records.

## Eligible cached machines and useful capacity

The current inventory had **1,159 machines, 952 broadly eligible, 721 broadly
eligible idle, 359 with multiple resident models**, and 100 advertising at least
five catalog builds. Broad eligibility means at least one snapshot row was
`eligible`, `no_headroom` or `free_memory`; it does not establish target-model
load admission, opt-in or dedication compatibility.

| Model | Advertised local inventory | Broad eligible idle, cached but nonresident | Public cold count |
|---|---:|---:|---:|
| GPT-OSS | 538 | 147 | 148 |
| Gemma QAT | 528 | 71 | 108 |
| Qwen3.5 35B | 263 | 60 | 116 |
| Qwen3.6 35B | 671 | 181 | 218 |
| Qwen3.8 27B | 80 | **5** | 9 |
| Qwen3.5 9B | 89 | 13 | 14 |
| Nemotron | 44 | **1** | 3 |

These are different predicates at separate instants, not additive capacity.
`coordinator/registry/model_capacity.go` counts warm/cold before immediate
concurrency/token-headroom accounting; its generic 500-token TTFT estimate is not
a promise for a long actual request. Cold counts may contain non-idle nodes.

There were 180 M5 machines, 107 broadly eligible idle, but only 80 advertisements
of `EigenLabs/Qwen3.8-27B-4bit-mtp`. Its exact catalog rule was still **RAM ≥36 GiB
plus both `apple_m5` and `mlx_nax`**, with 71 broadly eligible advertisements and
only 5 idle cached/nonresident candidates. An M5 label alone is insufficient.
[INFERENCE] Compatible hardware has opportunity cost when assigned a general
model; already-advertised inventory must not be treated as permission for new
autopilot control.

Hourly samples contained 717–972 entirely idle machines. At peak 16:00Z, Gemma had
378 resident copies,313 eligibility=`eligible` slots and158 running/75 waiting
requests. At recent 22:00Z, Qwen3.6 had341 resident copies but only 107
eligibility=`eligible` slots. Resident copies, model queues and independent GPU
service are distinct measures.

## Conditional machine quality and loading uncertainty

`warm-quality.json` contains 71 model/chip/prompt-bin cohorts and 8,259 successes:
Sep 11 22:00–22:05Z, successful attempt 0, idle selected model slot, no running work
on that slot, text-only, billed prompt>32 and output≥32. These are selected live
successes, not isolated benchmarks; shape mix, co-resident activity, network time
and survivor bias remain. Small cohorts require conservative priors.

Examples for estimated prompts 513–4096:

| Model/chip | n | TTFT p90 | Service p90 | Recorded decode p10 / median |
|---|---:|---:|---:|---:|
| Gemma/M1 | 386 | 5.46s | 6.77s | 6 / 9 TPS |
| Gemma/M3 | 763 | 3.70s | 7.03s | 6 / 16 TPS |
| Gemma/M4 | 1,298 | 4.92s | 7.89s | 6 / 12 TPS |
| Gemma/M5 | 691 | 2.85s | 6.41s | 9 / 22 TPS |
| GPT/M3 | 447 | 4.53s | 20.22s | 20 / 45 TPS |
| GPT/M4 | 674 | 5.23s | 18.75s | 18 / 39.5 TPS |
| GPT/M5 | 29 | 4.50s | 29.44s | 11.8 / 24 TPS |
| Qwen3.8/M5 | 33 | 3.43s | 27.42s | 20 / 33 TPS |
| Qwen3.6/M5 | 81 | 2.74s | 22.00s | 39 / 71 TPS |

These observations do not support a universal chip-generation ranking. Use exact
model, chip class/GPU cores, fresh per-slot and validated solo observations,
current contention, memory, thermal state and reliability. Do not install these
five-minute success quantiles as permanent model constants.

The profile sample had only two reported cold loads: one successful GPT/M3 load
wait of 2.411s and one failed Qwen3.6/M5 wait of 0.170s. It cannot establish a p90
load-time distribution. Unknown load cost remains a configurable conservative
prior until completed-load telemetry supports a per-model estimate.

The earlier website's coarse 14-day replay estimated 96.04% capacity coverage for
pressure-only allocation versus 94.80% with proactive surplus release. It used
hourly workloads, synthetic opt-in, current inventory for historical replay and
assumed loading/service behavior. It was not an event replay, production success
measurement or validated causal uplift. It supports cautious unloading as an
initial hypothesis, not an optimal dwell constant.

## Requirements supported by this evidence

1. **Unique workload demand:** record validated public logical arrivals once;
   separate attempts, retries and account/invalid-request failures. Keep arrival
   time distinct from terminal time. Use actual completed output/service data
   with explicit missing-data priors; keep requested output limits for admission.
2. **Useful hardware capacity:** reuse exact catalog, capability, attestation,
   dedicated-family, request-trait and memory gates. Account for all models'
   GPU/KV work and pending reservations; preserve scarce compatibility. A large
   free-memory number or model-slot count is not a service guarantee.
3. **Bounded opt-in placement:** explicit provider consent, no implicit eviction,
   cache-aware choices and a shared operation/memory reservation mechanism.
   Keep manual providers and pinned residency outside controller ownership;
   reconcile actual state on completion, failure and reconnect; a timeout must
   not silently restore capacity while an operation may still be running.
4. **Measured quality and deadline fit:** prefer recent per-model/per-machine
   service observations with conservative fallback and freshness checks. Track
   future load readiness separately from immediate request admission. Repeated
   deadline refusal must not multiply the placement target.
5. **Conservative unloading:** drain first; initially require no active, queued
   or pending device work, sustained surplus, dwell and retained per-model
   useful-capacity floors. An eviction must have a feasible replacement and
   enough expected benefit to cover switching cost. Retain disk bytes and
   explicitly account for every victim of a multi-model change.
6. **Observable validation:** compare per-model completion/TTFT/decode quality,
   deadlines, candidate gate reasons, pending loads and predicted benefit with
   load/unload outcomes, bytes downloaded and churn. Shadow results, passing
   tests, opt-in activation and production gains are separate evidence gates.

## OpenRouter traffic-growth interpretation

The retained 14-day exploratory analysis used network logical-outcome volume as
an offered-traffic proxy; current OpenRouter attribution was operator-confirmed,
not independently complete across history. For GPT-OSS, rejection share had an
adjusted correlation of **−0.257** with next-hour log-volume growth (334 hourly
transitions; day-block interval **[−0.342, −0.130]**), controlling for current/prior
volume, time of day and trend. Adding that feature reduced final-four-day
absolute log-growth prediction error by about **24%** against the specified
baseline (239 training / 95 later observations). This was one of 144 explored
associations, not prospective validation or evidence that OpenRouter explicitly
rewards a particular capacity change. Offered traffic can change because of
upstream demand, request mix, provider selection or our observed service quality;
these data do not identify those causes separately. Neither that association
nor the new 48-hour rejection analysis establishes that an autopilot placement
will cause OpenRouter to send more traffic. The frozen network-lab
`signals.py` and `network.json` association record retain the calculation.
