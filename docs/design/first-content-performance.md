# First-content routing and provider performance plan

> Last updated: 2026-09-28 · commit `4ea5c4e49`

Status: **In progress** — 2026-09-28 — Delivery A is merged in [PR #1230](https://github.com/Layr-Labs/d-inference/pull/1230). Delivery B/C is prepared for review against `master` with the merged [MLX dependency #170](https://github.com/Layr-Labs/mlx-swift-lm/pull/170). Hardware profile promotion remains qualification-gated; no M5 B8/B16 profile is certified. See [coordinator first-content routing](../architecture/first-content-routing.md) and [serving qualification](../developer/serving-performance-qualification.md).

Apply one first-content-oriented routing policy across the model catalog, then
improve provider measurements, chunk scheduling and qualified concurrency.
Ship the qualified behavior as the default for all applicable requests, without
a shadow phase, percentage rollout or randomized production treatment. The
[dated investigation](../reports/2026-09-28-first-content-performance.md) records
the production evidence separately from the decisions below.

## Decision and delivery order

| Delivery | Changes | Dependency |
|---|---|---|
| A: coordinator only | Preserve fast prefill signals; rank deadline-feasible providers by first content; refresh retries and reserve atomically | Existing provider telemetry; no provider upgrade required |
| B: provider and compatible coordinator support | Earlier measurements, model/hardware performance profiles, mixed-prefill sizing and qualified higher concurrency | A remains compatible with older providers; new fields remain optional |
| C: fleet placement follow-up | Warm capacity based on measured prompt/decode work and qualified batch curves | Qualified provider capacity from B |

Deterministic correctness tests and controlled hardware load benchmarks precede
release. Normal production monitoring and rollback follow direct activation.
This plan authorizes no production operation; deployment follows the existing
[coordinator runbook](../operations/coordinator-deploy.md) and
[provider release runbook](../operations/provider-release.md).

## Objective and separate quantities

Minimize time to first **delivered content** while maintaining useful generation
speed, timely successful throughput, correctness and memory safety. Internal GPU
first token, role-only SSE preamble, keepalive and delivered content are distinct.
Keep legitimate empty-completion behavior and terminal arbitration intact.

| Quantity | Purpose | Proposed treatment |
|---|---|---|
| Worst-case byte/token commitment | Physical admission and OOM prevention | Preserve prompt plus maximum-output reservations, activation/KV allowances and whole-serving-set accounting |
| Expected first-content time | Provider ranking | Predict real work and delivery latency, including valid cache reuse |
| Conservative first-content time | Deadline feasibility | Use provider-compatible assumptions and explicit confidence; provider admission remains authoritative |
| Expected generation demand | Capacity planning and close-choice selection | Estimate likely work separately; requested maximum output no longer dominates first-content ranking |

The current `backlog_ms` score converts memory commitments into decode-time
units. It is not measured queue delay. Do not use it as the elapsed waiting term
in the new predictor. See `buildCandidateInto` and `ttftMsFromSnapshot` in
[`coordinator/registry/scheduler.go`](../../coordinator/registry/scheduler.go).

## Coordinator algorithm

### 1. Establish the request scope and original clock

Resolve the model, request traits, ownership policy, prompt-work estimate and
existing request-absolute first-content deadline. Every retry, quote, queue wait
and hedge spends this same clock. Preserve intentionally deadline-exempt routes,
explicit self-route/prefer-owner behavior and existing structural-error semantics.

### 2. Build the eligible candidate set

Reuse current trust, authorization, model/capability, connection, health,
physical-memory and provider/whole-Mac concurrency gates. A cold provider must
include model-load work in its prediction. `max_tokens` continues to protect
memory and enforce completion limits.

Read accepted capacity sequence/age, per-model rates, other-model activity and
coordinator-owned pending reservations consistently. A new heartbeat does not
prove that the underlying performance measurement is recent.

### 3. Forecast first content, including cache work

```text
expected first-content time =
    transport and handoff
  + model load, when needed
  + waiting / competing work before this request can prefill
  + cache restoration
  + uncached prompt work / effective prefill rate
  + first decode and delivery
```

Use exact planned token counts when already available; otherwise account for
per-model/template estimated-to-actual prompt-token error. Count only validated,
unexpired cache evidence, bound reusable work by the request's real prompt work,
and charge restoration once. Apply cache work **before** deadline classification.
Revalidate proof and capacity when committing the reservation.

Reconcile reported queued prefill and local reservations without double-counting
the same request. Existing output reservations do not form a serial queue that
must completely drain. The coordinator-only release cannot reconstruct the
provider's exact mutable GPU schedule: stale, incomplete or poorly matched busy
forecasts carry uncertainty rather than fabricated precision.

### 4. Classify feasibility

| Class | Meaning | Selection behavior |
|---|---|---|
| Feasible | A credible conservative forecast fits the remaining deadline | Preferred pool |
| Unknown | Missing, stale or insufficient evidence | Bounded refresh/quote or fallback; neither zero latency nor automatic impossibility |
| Predicted late | A credible forecast exceeds the remaining deadline | Avoid while a feasible alternative exists; reassess when relevant state changes |

Keep expected and conservative predictions separate. Do not treat a learned mean
or the provider's fixed rate haircut as a mathematical guarantee. Preserve the
provider's atomic final admission decision and avoid tightening all rejection
gates solely on an unqualified estimator.

### 5. Select within a fast group

1. Prefer credible deadline-feasible candidates within the allowed owner scope.
2. Preserve the existing decode-quality preference. The 30-TPS qualification bar
   below applies to expanded concurrency, not blanket rejection of every model.
3. Find the minimum expected first-content time in that pool.
4. Keep candidates no more than **100 ms** above that minimum.
5. Choose the least committed whole-Mac service work within that band; use valid
   prefix affinity to break close choices and spread equivalent choices.

Apply the same ordering to retained plans, refreshed retries, quotes and backup
selection. Preserve health derating and explicit owner semantics when narrowing
the pool. A fast chip name alone does not outrank a provider with a better
cache-adjusted delivery forecast.

### 6. Revalidate and reserve atomically

Immediately before dispatch, recheck remaining time, accepted capacity, model
state and cache proof. Reserve physical memory/concurrency and record pending
prefill work before transmission, making that work visible to the next routing
decision. On a race, perform a bounded rescan instead of overbooking stale state.

Clear or transfer every reservation correctly on refusal, timeout, cancellation,
disconnect and terminal completion. Preserve request identity ownership and
exactly-once accounting across primary and backup attempts.

### 7. Use new evidence on retries

A predictive refusal excludes that provider for this logical request, refreshes
candidate state and spends the original remaining deadline. After **two
predictive refusals**, require fresh feasible evidence before another dispatch;
bound concurrent quote fanout to two. A quote is evidence, not an irrevocable
reservation. Keep genuine transport/provider faults on their existing distinct
recovery path, and avoid permanent health penalties for request-clock-specific
refusals.

A short wait is useful only when a credible near-term capacity release still
allows completion of first-content work within the deadline. Otherwise return
the appropriate early overload response. A six-second configured queue maximum
is not a target waiting time. Keep at most one hedge, require a distinct feasible
provider with spare service allowance, and cancel/retire the loser promptly.

### Control-flow sketch

This is conceptual orchestration, not replacement code for protocol, cancellation
or terminal ownership. All scan/refresh attempts remain bounded.

```python
def route(request):
    while request.permits_another_attempt():
        candidates = eligible_providers(request)
        forecasts = predict_first_content(candidates, request)
        pool = prefer_feasible_then_bounded_unknown_fallback(forecasts, request)
        if not pool:
            return wait_for_known_capacity_or_return_existing_error(request)

        pool = prefer_existing_decode_quality(pool, request)
        fastest = min(p.expected_ttft_ms for p in pool)
        band = [p for p in pool if p.expected_ttft_ms <= fastest + 100]
        chosen = least_committed_work_then_affinity(band)
        if not atomically_revalidate_and_reserve(chosen, request):
            continue

        outcome = dispatch_with_original_remaining_deadline(chosen, request)
        if outcome.committed_success:
            return forward_stream_or_valid_terminal(outcome)
        update_fault_or_predictive_refusal_state(request, chosen, outcome)
    return existing_deadline_or_terminal_result(request)
```

## Worked example: assumptions, not production measurements

For an illustrative 3,000-token prompt, assume 120 ms transport/handoff, 30 ms
first-decode/delivery overhead and 80 ms restoration for the two cached options.
The cached options reuse 2,700 tokens. The only waiting assumption is **1,200 ms
on the busy M5 Ultra**. Use the incident's observed rate proxies: M4 Max 1,638,
M5 Max 4,551 and M5 Ultra 7,680 prompt tokens/s.

| Candidate | Assumed state | Expected first content |
|---|---|---:|
| M5 Ultra | Idle, no reuse | 541 ms |
| M5 Max | Idle, no reuse | 809 ms |
| M4 Max | Idle, 2,700 tokens reusable | 413 ms |
| M5 Ultra | Same reuse, 1,200 ms waiting | 1,469 ms |

The M4 Max wins this example. Without the assumed waiting time, the cached Ultra
would take **269 ms** and win. The previously discussed “1,470 ms” is rounded
arithmetic for a hypothetical busy provider, not an observed Ultra measurement:
`1200 + 80 + 120 + (300 / 7680 * 1000) + 30 = 1469.06 ms`.
Actual routing needs telemetry for each term; memory-reservation backlog cannot
establish the waiting assumption. Request-level rates also do not prove exact
per-chunk timings.

## Delivery A: coordinator-only implementation

- Align observed-prefill validation and the resolver ceiling to the provider's
  existing **20,000 tokens/s** envelope. Preserve invalid-value checks,
  cold/reuse sample validation and explicit diagnostics. Test that plausible
  rates above the current **5,000** ceiling survive ingestion and affect ranking.
- Implement expected/conservative forecasts, feasibility classes and the 100-ms
  selection band using existing wire telemetry and local pending state.
- Wire identical policy into preflight, initial selection, atomic commit,
  retained plans, retry and hedge paths. Do not reset deadlines or erase cache
  proof/restore costs in a later preference stage.
- Make the policy active by default for applicable public routes. Reuse relevant
  work from [PR #1001](https://github.com/Layr-Labs/d-inference/pull/1001) without
  adopting its shadow rollout. Evaluate
  [PR #1134](https://github.com/Layr-Labs/d-inference/pull/1134) against the new
  first-content band rather than simply widening the old generation-cost band.

## Delivery B: provider measurements, concurrency and chunks

### Measurement and performance profiles

Publish eligible prefill observations when prompt computation completes, once
actual cold/reuse work is established, instead of waiting for the whole answer
to finish successfully. Keep terminal success/accounting separate. Add sample
age/count and workload buckets; preserve isolated and contended rates and
identify other-model activity.

Qualify profiles by model artifact, provider/runtime version, KV backend, GPU
bin and context range. Replace the single M4-derived batch-degradation curve
with the qualified profile. Use engine timings for decode capacity; preserve
delivered streaming and end-to-end throughput as separate metrics.

### Concurrency targets and admission

**8 active requests on M5 Max and 16 on M5 Ultra** are capability and qualification
targets. They are not verified fast-serving limits for every model. The active
limit is bounded by the qualified model/hardware/context profile, physical
memory fit, explicit operator settings and a shared whole-Mac service allowance.
Three resident models do not receive three independent allowances of sixteen.

Qualify widths **1/2/4/6/8 on Max** and **1/2/4/8/12/16 on Ultra**, including
32/40-core Max and 64/80-core Ultra bins and relevant RAM configurations. Publish
the highest passing profile as the default. Unknown profiles keep their existing
qualified limits; preserve architecture-specific narrower limits and explicit
lower operator caps.

Higher concurrency must satisfy all proposed release criteria:

1. Per-request decode p10 at least **30 tokens/s**. Models below this at B1 retain
   their existing qualified policy and receive separate diagnosis.
2. At least **10% more aggregate output throughput** than the next lower selected
   width.
3. Mixed-arrival first-content p95 at most
   `max(3 seconds, 1.5 * same-shape B1 p95)`, within the request's absolute budget.
4. Correct output/constraint behavior, isolation, cancellation, accounting and
   retirement, with no unexpected OOM.
5. Measured activation/KV fit for the serving set and width. Existing B8 evidence
   does not certify B16; mirror any measured floor changes in Swift and Go.

Update default migration, daemon/standalone clamps, heartbeat capacity,
coordinator admission, warm-pool capacity math and status/doctor together. Do not
count theoretical TFLOPS or RAM capacity as qualified service throughput.

### Mixed-prefill policy

Target **75–100 ms incremental prefill work per mixed step**, selected from
measured chunk timing. Decode and delivery add time beyond that allowance.

| Gemma profile to qualify | Mixed prompt-token cap |
|---|---:|
| Slower measured hardware, including M4 Max | 128 |
| M5 Max | 256 |
| M5 Ultra | 512 |
| Generic initial qualification profile | 256 |

Keep Gemma's qualified **2,048-token prefill-only stripe** and one partial prefill
per engine initially. Keep **128** as its ordinary lower bound because smaller
chunks bypass the current final-layer narrowing threshold. Qualify other models
under the same latency objective while preserving recurrent checkpoint geometry,
vision blocks and model-specific efficient shapes. Preserve one-image-at-a-time
vision execution. The existing mixed-prefill knob is process-wide, so implement
per-model policy before applying different profiles together.

Revalidate scheduler projection/runtime parity, cache restoration and memory
accounting whenever geometry changes. A proposed promotion bar is at least 25%
lower mixed-load token-gap p95 with no material first-content regression, no more
than 5% aggregate output-throughput loss and no additional failures. These are
qualification criteria, not measured gains.

## Delivery C: placement and capacity follow-up

Size warm pools from prompt-processing work, generation work and qualified batch
curves. Warm already-downloaded, operator-enabled models when sustained demand
requires them; retain complete load-footprint accounting, slot limits and one
owner for model changes. Use hysteresis to prevent thrashing. Preserve useful
cache locality and spread bursts when waiting outweighs reuse. Include measured
transport in ranking before proposing additional regional infrastructure.

## Validation, direct activation and rollback

Run deterministic routing/admission tests, protocol symmetry, encrypted handler
integration, deadline/refusal ladders, cancellation/terminal ownership, cache
correctness/isolation and required component checks. Hardware qualification covers
supported actual prompts 1k/4k/16k/32k, outputs 128/1k/4k, fixed widths, staggered
arrivals, cold/reused prefixes and competing resident models. Record real forward
widths and power/thermal posture. Missing or failing cells receive no expansion.

After qualification, activate the policy for all applicable traffic. Monitor
once-per-request HTTP outcomes, timely successful requests/s, TTFT p50/p95/p99,
stream TPS/token gaps, retries/refusals per request, cancellations and cleanup.
Existing sampled profiler retention is a measurement limitation, not a requested
shadow or sampled production rollout. Historical comparisons must retain model,
prompt/output shape, hardware, cache and demand cohorts.

Proposed immediate rollback triggers: OOM/isolation/accounting regressions;
timeout/5xx rate up 0.5 percentage points in comparable cohorts; or timely
successful throughput down more than 5% under comparable demand. Keep coordinator,
provider profiles and placement separately reversible without weakening memory,
trust or accounting safeguards.

First-release goals are **50% fewer internal deadline refusals per logical
request** and **15–25% lower normal-load median first content**, while preserving
timely successful throughput. They are targets, not promised gains. An apparent
TTFT win obtained only by shedding more traffic does not satisfy the objective.

## Implementation and documentation map

Keep prediction types/helpers, selection, reservation and IO integration in
focused files; retain thin orchestrators rather than expanding a catch-all file.

| Concern | Current integration point | Documentation when implemented |
|---|---|---|
| Prefill signal validation | [`heartbeat.go`](../../coordinator/registry/heartbeat.go), `maxPrefillTPS`; [`scheduler.go`](../../coordinator/registry/scheduler.go), `resolvePrefillTPS` | [Routing](../architecture/routing.md), [configuration](../reference/configuration.md) |
| Candidate selection and cache work | [`candidate_selection.go`](../../coordinator/registry/candidate_selection.go), `selectRoutingCandidateWithAffinity`; [`cache_service_cost.go`](../../coordinator/registry/cache_service_cost.go), `cacheServiceCost` | [Cache routing](../architecture/cache-aware-routing.md), routing |
| Reservation, plans and retries | [`scheduler.go`](../../coordinator/registry/scheduler.go), `commitProviderReservation`; [`dispatch_plan.go`](../../coordinator/registry/dispatch_plan.go), `ReserveNextFromPlan`; [`dispatch.go`](../../coordinator/api/dispatch.go) | [Scheduling](../architecture/scheduling.md), API contracts if externally changed |
| Provider rate reporting | [`EngineV2Bridge+Accounting.swift`](../../provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+Accounting.swift), `recordPrefillSample`; [`EngineV2Bridge+Capacity.swift`](../../provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+Capacity.swift) | Protocol and telemetry schema/architecture; synchronize Go/Swift/TS mirrors and allowlists |
| Concurrency | [`ProviderLoop.swift`](../../provider-swift/Sources/ProviderCore/ProviderLoop.swift), `clampEngineV2Concurrency`; [`concurrency_cap.go`](../../coordinator/registry/concurrency_cap.go), `effectiveMaxConcurrencyForModelRateLocked` | Provider CLI/configuration, scheduling, release notes |
| Scheduler/projection geometry | [`SchedulerV2.swift`](https://github.com/Layr-Labs/mlx-swift-lm/blob/9f70e68dce563c90ad443fef470a713936bf6a4d/Libraries/MLXLMCommon/ContinuousBatchingV2/SchedulerV2.swift), `plan`; [`FirstTokenDeadlineAdmissionV2.swift`](https://github.com/Layr-Labs/mlx-swift-lm/blob/9f70e68dce563c90ad443fef470a713936bf6a4d/Libraries/MLXLMCommon/ContinuousBatchingV2/FirstTokenDeadlineAdmissionV2.swift), `firstTokenWorkProjection` | [Inference](../architecture/inference.md), memory/profile qualification reports |

## Related

- [Dated production evidence](../reports/2026-09-28-first-content-performance.md).
- [System profiler](../architecture/system-profiler.md) and
  [profiler queries](../operations/profiler-queries.md).
- [Documentation impact rules](../AGENTS.md) and
  [contributor workflow](../../.agents/skills/darkbloom-contributor/SKILL.md).
