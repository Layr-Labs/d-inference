# Admission calibration baseline and pending-prompt correction

> Last updated: 2026-09-06 · commit `bbf6f83d4`

This source audit and isolated comparison for [#846](https://github.com/Layr-Labs/d-inference/issues/846) establishes one coordinator input defect: an idle heartbeat caused every pending prompt to be priced at the incoming prompt's length. The correction uses available local prompt estimates and preserves successful alternative delivery in a real coordinator HTTP/WebSocket test. It does not establish production service-time accuracy or close the broader production evaluation in #846.

## Evidence boundary

The baseline is `bbf6f83d4`; the corrected behavior is the accompanying change to `fillSnapshotPendingAndPool` and `queuedPrefillTokensAhead` in [`scheduler.go`](../../coordinator/registry/scheduler.go). Local synthetic observations were made on 2026-09-06 with Go 1.26.1. No production request records, runtime configuration, traffic, or provider model runs were accessed. Synthetic identifiers and numeric prompt lengths contain no user content.

The engine submodule pinned by this revision is [`d4335f02d9c466a9d02e4bd576354b6b10ac7674`](https://github.com/Layr-Labs/mlx-swift-lm/tree/d4335f02d9c466a9d02e4bd576354b6b10ac7674). Its `EngineLoopV2` admission path was read at that exact revision. This differs from the engine revision cited in the original issue. Neither a Git commit nor a checked-in environment file establishes the deployed provider build or effective configuration.

| Evidence | Population / coverage | Limitation |
|---|---|---|
| Core estimator comparison | Three deterministic incoming requests, each with one existing same-model reservation; all three snapshots and gate decisions observed | No provider dispatch or observed execution; provider admission and final outcomes are unknown, not zero |
| Alternative-selection and retained-plan regressions | One incoming request per case, full registry path | Selection is not proof of provider completion |
| New HTTP comparison | One incoming chat request in each revision, every dispatch captured by scripted encrypted WebSocket providers; response fully drained | No actual MLX compute, production variance, or upstream-router receipt evidence |
| Existing deadline recovery tests | Three independent incoming requests across chat, completions and messages; two captured dispatches per request | Scripted provider refusals; a recovered request does not show that its first provider could have served it |
| Production cohort | No records inspected; denominator, join coverage, sampling and drop rates unknown | No production fulfillment rate, error quantile, or avoidable-refusal percentage is reported |

## C1: current formulas, boundaries and provenance

| Boundary | Existing source behavior | Comparison rule |
|---|---|---|
| Selection and reservation | [`scheduler.go`](../../coordinator/registry/scheduler.go), `snapshotProviderIntoPLockedEx`, reads the matching concrete-model slot, hardware, local pending reservations and heartbeat age. `commitProviderReservation` resnapshots and rechecks the gate. [`dispatch_plan.go`](../../coordinator/registry/dispatch_plan.go), `ReserveNextFromPlan`, does the same for retained alternates. | Compare the committed candidate's snapshot and model build, not a different scan or public alias. |
| Live raw TTFT | `ttftMsFromSnapshot`: state penalty + queued prompt tokens / prefill rate + incoming prompt tokens / prefill rate + one token / effective decode rate, converted to milliseconds | This is separate from full routing cost and token-budget memory reservations. |
| Rate fallback | `resolvePrefillTPS`: positive slot prefill EWMA, otherwise registration prefill or decode × configured ratio, capped at `maxPrefillTPS`. `resolveEffectiveTPS`: slot decode EWMA, then model/chip fleet median, then load-scaled registration decode. | Missing or stale rates do not become measured service rates. Registration benchmarks and EWMAs have different provenance. |
| Existing calibration | [`ttft_calibration.go`](../../coordinator/registry/ttft_calibration.go): median of the latest 200 actual/raw ratios, 50-observation warm-up, model/chip then model then 1.0 fallback, applied clamp [0.2, 1.5]. Cold-load state penalty stays unscaled. | Reuse this calibrator. Its sample-count window has no sample-age expiry, and its median is not a deadline-tail guarantee. |
| Learning boundary | [`settlement.go`](../../coordinator/api/settlement.go), `observeTTFTCalibration`, learns at committed first content using coordinator dispatch-to-first-content duration. Warm text predictions only; speculative racers and cache-routing participants are excluded. Unmatched/invalid timing pairs are ignored. | A first-content observation is not completed delivery. Refused attempts have no actual TTFT; timeouts/cancellations are censored. Successful-only residuals cannot establish refusal necessity. |
| Coordinator dispatch | [`consumer.go`](../../coordinator/api/consumer.go), `dispatchWithReserver`, and [`provider_wire.go`](../../coordinator/api/provider_wire.go), refresh the remaining original budget before the writer handoff | Reservation, preparation/encryption, writer queue and transport consume budget. Compare each estimate with remaining time at its own boundary. |
| Provider measurements | [`EngineV2Bridge.swift`](../../provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge.swift), `recordPrefillSample`, observes successful cold-prefill prompt tokens divided by the atomic admission-to-first-token window. The ordinary EWMA can include interference; the isolated EWMA additionally requires an isolated submit and revokes eligibility on overlap. | The similarly named reported prefill rate and projection service rate are not interchangeable. Cache hits cannot train cold-prefill rates. |
| Provider projection | `firstTokenDeadlineAdmission` uses half the isolated prefill rate and half any valid decode rate. It is conditional on enforce mode, projection enabled, isolated prefill initialization and non-media input. The policy is built after pre-submit preparation. | The fixed 2× service envelope is deliberate; this patch does not remove it or treat coordinator/provider disagreement as proof either policy is wrong. |
| Atomic verdict | [`EngineLoopV2.swift`](https://github.com/Layr-Labs/mlx-swift-lm/blob/d4335f02d9c466a9d02e4bd576354b6b10ac7674/Libraries/MLXLMCommon/ContinuousBatchingV2/EngineLoopV2.swift), `enqueueForFirstTokenDeadline` / `firstTokenProjectedWork`, accepts bounded projected service only when it fits the remaining monotonic deadline; unbounded projection is rejected. Rejected admission releases its resources. | Queue wait and projection CPU time consume the original deadline. Do not subtract independent host wall clocks. |
| Refusal evidence | The bridge records bounded projected work, service duration and remaining budget in the admitted branch; its `.deadlineUnreachable` branch discards the associated projection details. Provider absolute-expiry checks can produce the same terminal refusal class. | Unknown projection is not a finite projected miss. More refusal evidence remains [#844](https://github.com/Layr-Labs/d-inference/issues/844), not an instrumentation addition in this change. |

`EIGENINFERENCE_TTFT_ADMISSION_MODE=enforce` remains diagnostic shadow behavior in [`ttft_shadow.go`](../../coordinator/registry/ttft_shadow.go). `EIGENINFERENCE_TTFT_HARD_REJECT` controls a different live gate; the alpha occupancy term stays out of that gate. `EIGENINFERENCE_TTFT_CALIBRATION=off` returns an applied ratio of 1 while learning continues. These are source semantics; all production effective values are unknown. [`prompt_calibration.go`](../../coordinator/api/prompt_calibration.go) calibrates context fit, not the TTFT token estimate. Billing estimation, original deadlines, provider resource safety and retry policy are unchanged.

### Existing records and joins

[`profiler_record.go`](../../coordinator/api/profiler_record.go), `buildProfileRecord`, persists raw and calibrated predictions, applied ratio, snapshot age, pending counts, model, folded chip/version, coordinator timing and optional provider profile. Selection-only records are distinguishable by absent dispatch. The profile's coordinator request ID identifies an incoming request; its route request ID plus attempt identifies an attempt. Public aliases must be kept separate from the resolved model build.

Profiles are not a request census. [`profiler.go`](../../coordinator/api/profiler.go), `sampled`, defaults to 0.1 for ordinary success profiles and hashes the coordinator ID so a request's attempts sample together; exceptional/slow cases have separate keep rules. [`profiler_sink.go`](../../coordinator/api/profiler_sink.go) can drop on buffer pressure or persistence failure. Provider profiles may be absent, invalid or late. Existing route rows preserve attempt statuses, but do not independently establish an unsampled incoming-request denominator. The exact pending prompt set used by the corrected sum is not persisted; reconstructing it retrospectively from aggregate route fields is unsupported. Some provider workload fields named `*AtAdmit` are sampled at bridge engine-submit, before the asynchronous atomic admission; retain that boundary when comparing them.

For a future bounded received-at cohort, start from [#845](https://github.com/Layr-Labs/d-inference/issues/845)'s versioned incoming-request outcome source, then left-join each recorded attempt identity to route/profile evidence. Count missing, duplicate, selection-only, late and contradictory joins; keep open requests unknown until the stated finalization horizon. Publish source coverage and loss counters alongside counts. Use `int_provider_deadline_rejected` only for explicit attempt refusals, and distinguish final `ext_first_content_timeout` or `ext_coordinator_exhausted` outcomes from their attempt history. Request progress, provider completion, coordinator egress and client departure remain separate facts. The dashboard part of #845 is deferred and is not delivered by this repository change.

### Related work reconciled on the audit date

| Work | Observed state | Consequence |
|---|---|---|
| [#755](https://github.com/Layr-Labs/d-inference/pull/755) | Open, unmerged; proposes additional route/candidate/capacity persistence | Current profile fields already supply part of the proposed calibration evidence. This change adds no competing telemetry schema or ingestion path. |
| [#835](https://github.com/Layr-Labs/d-inference/pull/835) | Open, unmerged; current Responses lowering does not include its instructions fix | Prompt-normalization discrepancy remains owned there; do not duplicate or claim it shipped. |
| [#720](https://github.com/Layr-Labs/d-inference/issues/720) | Open issue, but current `recordFinish` requires completion tokens strictly after `firstEmissionTokens` before updating decode EWMA | The original single-token startup-seed defect no longer exists in this source. The MTP first-burst regression in `EngineV2PrefillSamplingTests.swift` guards that exclusion. Deployment and other sample-validity concerns remain unverified. |

### Ranked findings

| Rank / discrepancy | Cohort and evidence | Confidence | Correction or next measurement | Expected benefit / regression risk |
|---|---|---|---|---|
| 1. Pending prompt lengths replaced by incoming length | Same-model local reservations with zero running/waiting heartbeat; direct source plus failing registry/HTTP regression | High for estimator input error; production frequency unknown | Use each available local prompt estimate, excluding committed content; retain proxy for unknown/cache work | Can preserve a feasible alternative or avoid an early TTFT rejection; full-prompt estimates can still exceed residual work during partial prefill |
| 2. Reflected queue phase and residual work unknown | Nonzero running/waiting snapshots cannot be joined to local requests | High for missing information; effect unmeasured | Keep existing proxy; request queue-position/residual-work evidence through #844 if needed | Avoid double counting while recognizing mixed queues remain approximate |
| 3. Different rates and timing boundaries | Source distinguishes observed versus isolated prefill and a 0.5 rate haircut; elapsed pre-admission time exists | High for mechanism; no matched production attempts | Match coordinator/provider durations and decision budgets before judging margins | Could explain valid refusals; changing margins without evidence risks missed deadlines |
| 4. Sample coverage, age and tail bias | Median feedback excludes racers/cache and lacks actuals for refusals; samples never age out by time | High for mechanism; no measured drift | Stratify model/chip, prompt/load, engine version and sample age; report under/overprediction and tail residuals on uncensored pairs | No justified expiry duration, clamp change or fleet multiplier yet |
| 5. Responses prompt normalization | Source and open #835 | High for source discrepancy | Consume #835 after it lands and verify effective provider body/token estimate | Avoid overlapping prompt/billing edits in this PR |
| 6. Actual capacity shortage | No production or real-model workload measurements | Unknown | Measure the eligible fleet and isolated model/hardware workloads separately | A better estimate cannot create unavailable capacity |

Model/build, requested alias, chip and memory are represented at selection. Engine version and cache residual work require more care; the test fleet is synthetic and cannot certify all model/hardware combinations. The correction has no fitted constants: equal-size pending prompts stay unchanged, other-model work stays outside this model's prefill sum, no-capacity providers remain without a reliable TTFT, and mixed/reflected snapshots keep the old proxy. Cache participants keep their prior proxy rather than receiving fictional full uncached work.

## C2: concrete before and after

The core fixtures use an idle heartbeat, 1000 prefill tokens/s, 100 decode tokens/s and one outstanding reservation. Durations below are **computed estimates**, not measured provider TTFT. Each cohort has one incoming request, so there is no statistical uncertainty interval or production frequency estimate.

| Pending / incoming prompt tokens | Raw before → after (ms) | With existing 0.5 calibration (ms) | Raw gate | Before → after selection |
|---|---|---|---|---|
| 4000 / 100 | 210 → 4110 | 105 → 2055 | 3000 ms | Candidate passes → fails |
| 100 / 4000 | 8010 → 4110 | 4005 → 2055 | 5000 ms | Candidate fails → passes |
| 500 / 500 | 1010 → 1010 | 505 → 505 | 2000 ms | Passes → passes |

The three raw-gate fixtures still admit two of three incoming requests in either revision. The useful change is which request/provider combination is feasible under the same formula, not a lower aggregate rejection count. A two-provider regression confirms that the first case selects the eligible idle alternative (1100 ms estimate), preserving the original 3000 ms budget. The retained-plan case rechecks newly arrived prompt work against a decreased 2900 ms budget.

The HTTP fixture gives the busy provider one 20,000-token pending reservation and an idle provider with slower decode but sufficient first-content budget. The busy provider's refusal is scripted; the idle provider returns normal encrypted chunks and completion. The incoming request is the same in both revisions.

| HTTP fixture outcome | Before | After |
|---|---|---|
| Incoming requests | 1 | 1 |
| Dispatched attempts | 2 | 1 |
| Scripted provider refusals | 1 | 0 |
| Timely first content / completed HTTP responses | 1 / 1 | 1 / 1 |
| Client departures / interrupted responses | 0 / 0 | 0 / 0 |

This establishes preserved local completion with one less avoidable **scripted** attempt. It does not establish improved production fulfillment, a real provider's admission verdict, or a claim that the refused provider would have succeeded. No latency distribution or model-throughput improvement is inferred from this fixture.

## C3: reproduction, guardrails and remaining evaluation

Run from the repository root with its Go toolchain. Tests use memory storage and local sockets only; no database or cloud credentials are needed.

```bash
go test ./coordinator/registry ./coordinator/api -run TestTTFTPendingPrompt -count=1 -v
go test ./coordinator/registry ./coordinator/api -run 'TestTTFT|TestObserveTTFT|TestDeadlineUnreachableFailoverCarriesDecreasingBudgets|TestGenericEndpointsShareDeadlineFailover|TestFirstToken|TestDispatchPlan|TestReserveNextFromPlan|TestCache' -count=1 -timeout=120s
go test -race ./coordinator/registry ./coordinator/api -run 'TestTTFTPendingPrompt|TestObserveTTFT|TestDeadlineUnreachableFailoverCarriesDecreasingBudgets' -count=1 -timeout=120s
make docs-check
```

`ttft_pending_prompt_test.go` prints the three comparisons and covers first-content exclusion, unknown/negative prompts, the preflight's existing default for non-positive incoming sizes, other models, cache participants, reflected queue behavior, overflow and retained-plan revalidation. `ttft_pending_prompt_integration_test.go` prints captured HTTP outcome counts. Restoring only `scheduler.go` from the baseline while retaining these tests reproduces the failures and the two-dispatch HTTP result. Restore the corrected source before continuing. Existing calibration tests cover warm-up, model/chip fallback, median clamps, kill switch, no matching observations, pending TTL/capacity, cold and vision exclusions, and sample convergence; existing HTTP tests preserve refusal recovery and decreasing request budgets.

Verification on the corrected source passed: the complete registry suite with race detection; the focused API calibration and deadline recovery tests with race detection; the broader focused calibration/plan/cache tests; `go build ./coordinator/...`; and `scripts/docs-check.sh --all` (133 documents). The new regression suite fails against the baseline and passes with race detection after restoring the correction. Provider/engine code is unchanged; Swift execution and real-model benchmarks were not run.

A production evaluation remains pending. Before any separately authorized deployment or experiment:

1. Establish a bounded received-at baseline window and a finalization horizon using the #845 outcome contract. Record effective config, coordinator/provider revisions, model builds, supported chips, and profile/route/outcome loss and join coverage. A partial source cannot produce a claimed complete fulfillment rate.
2. Group by model/build and chip, then pending/incoming prompt-size relationship, heartbeat occupancy/age, load, cache participation and rate provenance. Keep zero-occupancy corrected cases separate from unchanged mixed queues. Report sample counts and unknown strata. Determine comparison duration and minimum sample size from observed traffic and baseline variance, not an invented percentage target.
3. Compare distinct-request completion and timely first content, final rejection/timeout, interrupted delivery, departure, recovery after refusal and dispatches per request. For joined uncensored attempts, compare raw/calibrated residuals, underprediction versus overprediction and tail errors. Keep refused and timed-out observations in their denominators without fabricating completion times.
4. Run real isolated model/hardware experiments before claiming compute or batching accuracy. Check partial prefill, cache preparation, cold load, co-resident models, memory safety and provider refusal mechanisms. Ask #844 for the specific missing decision evidence instead of inferring a finite projection from a generic refusal.
5. Predeclare regression tolerances from the measured baseline, including per-model request completion/first-content tails and resource stability. Keep retries, provider margins and deadlines fixed. Any invariant failure or statistically supported cohort regression requires reverting this coordinator change; the calibration off switch alone does not revert the corrected raw prompt input. Reassess retry policy only after these results exist.

The source audit, targeted correction and isolated validation are complete for this discrepancy. Matched production error/fulfillment measurements, unknown refusal mechanisms, representative real-model experiments and rollout criteria based on measured variance remain open in #846/#844; this report supplies an evaluation procedure, not those missing results.
