# Coordinator/provider admission calibration audit

> Last updated: 2026-09-05 · commit `bbf6f83d4`

The coordinator substituted an incoming request's prompt length for every
pending prefill. This creates deterministic errors in both directions for
mixed prompt lengths. The accompanying correction uses known prompt lengths
for reservations newer than the applied capacity snapshot. Scripted local
tests demonstrate corrected admission and complete response delivery; they
do not measure MLX service time or production fulfillment improvement.

## Evidence scope and related work

This audit covers source `bbf6f83d4` plus the accompanying correction. The
provider engine pin is `d4335f02d9c466a9d02e4bd576354b6b10ac7674`; its
`EngineLoopV2.swift` was read at that exact GitHub ref. Production coordinator
revision, provider versions, effective flags, and model/rate distributions
were not verified. No production experiment or configuration change ran.

The existing private audit from the separate session was inspected for query
provenance. Its profile aggregates cannot establish the full request
denominator: profiles are sampled, incomplete delivery is not equivalent to
provider failure, and the historical projection branch omits refusal details.
Its average budget subtraction does not establish provider-local remaining
time at atomic admission. No raw
identifiers or production counts from that artifact are published here. The
reproducible public baseline below is entirely synthetic.

| Related work, checked 2026-09-05 | Current finding and disposition |
|---|---|
| [#755](https://github.com/Layr-Labs/d-inference/pull/755) | Open, unmerged. Do not assume its candidate/capacity tables exist. Current `request_profiles` already store raw/calibrated prediction, ratio, top-four candidates, and provider timing; current fleet snapshots store slot rates. No duplicate schema is added. |
| [#835](https://github.com/Layr-Labs/d-inference/pull/835) | Open, unmerged. Responses instruction normalization/estimation remains owned there. This change uses existing `EstimatedPromptTokens`; it does not duplicate normalization or change billing. |
| [#720](https://github.com/Layr-Labs/d-inference/issues/720) | Issue still open, but current `recordFinish` updates decode EWMA only for successful tokens after `firstEmissionTokens`. A startup single-token/first-burst-only completion no longer seeds it. `EngineV2PrefillSamplingTests.firstMTPBurstDoesNotInflateDecodeRate` already covers this guard. No duplicate provider fix. |
| [#844](https://github.com/Layr-Labs/d-inference/issues/844) | Owns missing refusal mechanism/projected-work telemetry. Explicit missing evidence below stays with that issue. |
| [#845](https://github.com/Layr-Labs/d-inference/issues/845) | Owns request identity, durable outcome coverage, delivery evidence and normalized analytics. This independent branch preserves raw wire/outcome names and uses its agreed semantics in evaluation. |

## Common comparison contract

| Boundary | Available source and meaning | Limits |
|---|---|---|
| Selection/reservation | `scheduler.go`: canonical build `Model`, public alias separately, chip family, provider version, matching slot, rates, raw TTFT, applied ratio, calibrated TTFT, pending counts, original deadline | `snapshot_age_ms` measures liveness age; stale-sequence frames refresh it without applying capacity. New private `capacitySnapshotAt` tracks the actual applied boundary. |
| Dispatch | `RequestTiming.DispatchedAt` to committed `FirstContentAt`; profiler offsets describe reservation/encryption/writer phases | The raw forecast is made before dispatch. Do not interpret this learned pair as engine service time or subtract timestamps from different host clocks. |
| Provider preparation | `EngineV2Bridge.submitTokenized`: tokenization/cache preparation/shared-KV work before serialized admission | Prefix cache participation changes work and preparation time. Queue state can change after selection; provider knows more and has less time left. |
| Atomic provider admission | `EngineLoopV2` asks `scheduler.firstTokenWorkProjection`; bounded duration must fit `deadline - clock.now()`, while unbounded work is refused | Generic `deadline_unreachable` also represents actual expiry. The refusal branch discards projected-work details; an absent duration must stay unknown. |
| First content | API `observeTTFTCalibration` joins attempt ID/attempt number to the raw reservation prediction | First content does not establish terminal delivery. Speculative-race and cache-routing participants are excluded, cold/vision reservations do not create training pairs, absent/invalid/expired pairs are ignored. |
| Final request | Deduplicate on incoming `coord_request_id`, join actual dispatched attempt IDs, then apply #845 final outcome and egress dimensions | Route IDs identify attempts. Selection-only profiles and speculative losers cannot create extra requests. Neither a successful route nor a `completed` profile alone proves upstream receipt. |

## Calculation and sample audit

| Dimension | Inspected behavior | Result |
|---|---|---|
| Live TTFT | `ttftMsFromSnapshot`: state penalty + queued prompt work/prefill TPS + this prompt/prefill TPS + one decode step | Active and output token budgets remain memory reservations. No serial drain of all reserved output is added. |
| Prefill rate | `resolvePrefillTPS`: matching slot observed rate, registration prefill, or decode × configured fallback; observed value capped | Provider `observedPrefillTpsEwma` divides cold prompt tokens by submit-to-first-token, including queue interference. It is not isolated service TPS. |
| Decode rate | `resolveEffectiveTPS`: observed matching slot, model/chip fleet median, load-scaled benchmark | Same model/chip does not isolate memory tier, engine version or workload. No new unvalidated hardware pooling or rate multiplier. |
| Provider projection | Isolated cold-prefill EWMA requires no other active/pending work at submission. Decode EWMA excludes first emission. `firstTokenDeadlineAdmission` halves each available phase rate | Deliberate conservative envelope remains unchanged. No claim that a coordinator median predicts this bound. Projection also requires enforce mode, supported scheduler posture, measured prefill, and non-multimodal input. |
| Existing calibrator | Per model/chip median, model fallback, 50-observation warm-up, 200-sample ring, applied clamp `[0.2, 1.5]`, raw denominator, cold penalty unscaled | No competing calibrator. Unmatched pairs expire after 10 minutes; learned windows have no time expiry and do not key engine version. Their current production bias is unknown. |
| Calibration censoring | Only eligible attempts reaching first content train; refusals/timeouts do not reveal actual service time | A median of survivors cannot establish the tail of all incoming requests. A later successful provider does not prove the first would have served. |
| Request shape | `request_introspection.go` supplies raw routing estimates. `prompt_calibration.go` changes context-fit only. Billing is a separate byte upper bound | Template/tools/media inaccuracies remain separate hypotheses or #835 work. Vision retains its text-TTFT hard-gate exemption. |
| Queue identity | Anonymous provider counts are reconciled with pending count. Previously every implied waiting row used this arrival's prompt | Proven defect for reservations after the applied snapshot, where each existing prompt estimate is available and cannot be reflected already. Corrected here. |
| Queue telemetry | Provider `queuedPrefillTokens` counts submissions whose engine submit has not returned; engine running includes partial prefill | This is not automatically total remaining prefill work. Do not replace the whole queue formula with that field or add it without overlap accounting. |
| Clock/configuration | Request-absolute deadline decreases through queue, retry and writer dequeue. Provider carries a monotonic deadline through preparation. `TTFT_ADMISSION_MODE=enforce` is still diagnostic shadow; `TTFT_HARD_REJECT` is separate | No deadline extension, retry change, shadow activation, safety-margin change, or runtime inference from checked-in env files. |

## Correction and ownership

`Provider.addPendingLocked` records a coordinator-local reservation instant.
`Heartbeat` records the instant it applies the current capacity snapshot.
Discarded/duplicate sequence frames advance only `LastHeartbeat`; a nil
capacity frame clears the applied timestamp. Reconnect creates a new
`Provider`, so no timestamp or old pending set survives the session.

`fillSnapshotPendingAndPool` also collects the known new prefill work for the
requested model. `queuedPrefillTokensAhead` separates these new reservations
from older pending-count reconciliation. It sums their own prompt estimates,
uses the existing incoming-prompt proxy for unknown lengths and older anonymous
work, and stops charging a new attempt after per-attempt content ingress.
All reads and mutations follow the existing provider/ingress lock order.

The memory/KV/output accounting, rates, cache discounts, speculative policy,
retry policy, absolute deadline, and billing stay unchanged. New reservations
are not counted twice against the older heartbeat. State exists on the pending
request and current provider, so normal removal/disconnect releases it without
a new side map or timeout cleanup process.

Residual limitation: a fresh heartbeat received after reservation may have
been generated before provider receipt. Without per-request queue identities,
that overlap is unknowable; the existing anonymous fallback remains. Partial
prefill, cross-model compute contention, cache reuse and provider processing
time cannot be fully inferred from coordinator pending lengths.

## Reproducible synthetic baseline

Run from `coordinator` with the pinned Go toolchain:

```sh
go test ./registry ./api -run 'TestTTFTPending|TestPendingPrefillAdmissionCompletesRequest|TestDeadlineUnreachableFailoverCarriesDecreasingBudgets|TestObserveTTFTCalibration|TestTTFTCalibration' -count=1 -v
```

The before run substitutes the original `queuedPrefillTokensAhead` body from
`bbf6f83d4`; the after run uses the correction. Both run the same fixtures.
These are fixed inputs, with no stochastic performance confidence interval.
The two mixed-length regression cases and HTTP test fail under the original
body and pass after restoration of the correction.

| Scheduler cohort, one incoming request each | Before raw TTFT | After raw TTFT | Gate at 5,000 ms |
|---|---:|---:|---|
| Pending 8,000 tokens, arrival 100 | 210 ms | 8,110 ms | Old admits; corrected declines this candidate |
| Pending 100 tokens, arrival 4,000 | 8,010 ms | 4,110 ms | Old falsely sheds; corrected admits |
| Both prompts 2,000 | 4,010 ms | 4,010 ms | Both admit |
| Unknown pending length, arrival 4,000 | 8,010 ms | 8,010 ms | Legacy fallback retained |

These numbers use a warm model, 1,000 prefill TPS and 100 decode TPS. The
observed-rate/calibration test separately uses 2,000 measured prefill TPS and
the existing learned ratio 0.5: raw 4,060 ms, calibrated 2,030 ms. All these
tests call the real scheduler and preflight; neither establishes the
counterfactual service time of a rejected provider.

The HTTP fixture has one received/finalized streaming request, one provider,
a known 100-token pending prompt, a 4,000-character incoming prompt, registered
fixture prefill 250 TPS, and configured first-content base of 5 seconds.
The actual budget follows the unchanged prompt-scaled policy. Its provider
returns scripted content through the real encrypted WebSocket and terminal
path; no MLX compute occurs.

| Covered request/attempt measure | Before | After |
|---|---:|---:|
| Distinct requests / final results | 1 / 1 | 1 / 1 |
| Provider dispatches / admitted scripted attempts | 0 / 0 | 1 / 1 |
| Complete response delivery / timely first content | 0 / 0 | 1 / 1 |
| Final rejections | 1 (429) | 0 |
| Provider deadline refusals / timed-out attempts | 0 / 0 | 0 / 0 |
| Retries / client departures / interrupted delivery | 0 / 0 / 0 | 0 / 0 / 0 |

This fixture improves completed requests even though its refusal count is
unchanged. Identity/join coverage is 1/1 request and all dispatched attempts;
there is no sampling or dropped fixture evidence. The existing deadline
refusal/fallback test adds one request, two attempts, one refusal, one complete
response, and strictly decreasing wire/admission budgets. Results for that
separate guardrail are not pooled into the one-request comparison.

## Ranked findings and evidence gaps

| Rank | Discrepancy/cohorts | Evidence/confidence | Correction or next measurement | Benefit and regression risk |
|---|---|---|---|---|
| 1 | Mixed prompt lengths during a heartbeat gap | Exact source arithmetic plus real scheduler/HTTP regression; high confidence | Use own prompt estimates for known new reservations | Removes deterministic false shedding and optimism; unknown remaining prefill/cache work can still overstate work |
| 2 | Liveness age mistaken for applied capacity freshness | Real sequence-10/reserve/sequence-9 test; high confidence | Separate private applied-capacity timestamp, clear on nil/reset on reconnect | Stale frames cannot erase known work; legacy/unknown snapshots retain fallback |
| 3 | Refusal mode versus bounded projection/actual expiry | Refusal branch drops details; high confidence in evidence gap, unknown production incidence | #844: preserve mechanism, work, remaining monotonic budget and phase-rate provenance | Needed to assess avoidable refusal; no provider policy change justified yet |
| 4 | Learned ratio age, censoring, sparse chip/version cohorts | Source ring/exclusions verified; production effect unknown | Held-out time/cohort evaluation before changing expiry, keying or clamps | Could reveal drift; arbitrary reset/ratio changes can reject more requests |
| 5 | Prompt normalization, cache and queue overlap | Source distinctions verified; exact contribution unknown | #835 normalization; compare provider-tokenized lengths, actual reuse and queue timing | Avoid duplicate fixes and double-counted work |
| 6 | Actual capacity shortage or excessively conservative projection | No controlled compute evidence in this PR | Isolated representative engine runs with fixed retry policy | No capacity/throughput or unnecessary-refusal claim supported yet |

## Outcome evaluation and rollout gate

Use #845's covered population selected by request receipt time, retain open
requests until the original clock plus terminal-settle allowance, and report
late terminals/unknowns separately. Join `coord_request_id` first, then actual
dispatched attempt IDs. Report missing/duplicate joins, invalid provider
profiles, sampling mode/rate, sink drops and source lag beside every cohort.
The current profiler defaults to 0.1 sampling with always-retain predicates;
it is not the request denominator. `inference_routes` and profile sinks are
best effort, so absent attempt rows are unknown rather than refusals.

For each canonical model/build, chip/tier, provider version, prompt bin,
warm/cold/cache state and load band, compare raw and calibrated error medians
and quantiles, signed under/overprediction, timely first content and complete
delivery. Retain refusal, timeout, cancellation and speculative exclusions in
the population audit instead of silently training/evaluating only survivors.
Use `int_provider_deadline_rejected` for attempt refusal, with
`ext_first_content_timeout` and `ext_coordinator_exhausted` only when their
final request evidence supports them. Preserve raw wire codes.

Before rollout, collect matched baseline windows that include the relevant
peak and quiet traffic regimes, then select experiment duration and minimum
per-cohort sample counts from observed variance and the smallest meaningful
effect. Predeclare tolerances for completion, timely content, final rejection,
interruption and departure, plus provider memory pressure/OOM, crashes, token
budget refusals and latency tails. Keep retries and provider deadline margins
fixed. Do not invent a universal percentage threshold or silently combine
unsupported model cohorts. Sparse cohorts remain inconclusive.

A human-approved staged rollout may proceed only after those denominators,
coverage and tolerances are established. Roll back on a resource-safety
failure or a cohort breach; stop evaluation when joins/coverage are unreliable.
Reverting the change restores the old queue estimate. Do not use the TTFT
calibration off switch as a substitute for reverting the queue calculation.
No rollout was performed here. Retry-policy changes remain deferred until
this outcome comparison and any required #844 evidence exist.

## Code map

| Concern | Source |
|---|---|
| Applied snapshot and reservation ownership | [`registry.go`](../../coordinator/registry/registry.go), `Heartbeat`, `addPendingLocked`, `PendingRequest.HasFirstContentIngress` |
| Pending-work correction | [`ttft_prefill_backlog.go`](../../coordinator/registry/ttft_prefill_backlog.go), `addPendingPrefillToSnapshot`, `queuedPrefillTokensAhead` |
| Real scheduler regressions | [`ttft_prefill_backlog_test.go`](../../coordinator/registry/ttft_prefill_backlog_test.go) |
| Real transport/delivery regression | [`ttft_pending_prefill_integration_test.go`](../../coordinator/api/ttft_pending_prefill_integration_test.go) |
| Existing learning loop | [`ttft_calibration.go`](../../coordinator/registry/ttft_calibration.go), [`settlement.go`](../../coordinator/api/settlement.go) |
| Provider phase rates and refusal branch | [`EngineV2Bridge.swift`](../../provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge.swift), `recordFinish`, `recordPrefillSample`, `firstTokenDeadlineAdmission` |
| Engine atomic verdict | [Pinned `EngineLoopV2.swift`](https://github.com/Layr-Labs/mlx-swift-lm/blob/d4335f02d9c466a9d02e4bd576354b6b10ac7674/Libraries/MLXLMCommon/ContinuousBatchingV2/EngineLoopV2.swift) |
