# First-content routing

> Last updated: 2026-10-04

The coordinator selects providers by expected time to delivered content, with a
separate conservative forecast for deadline feasibility. The selection policy applies by
default across the catalog. Qualified calibration additionally requires a
compatible provider release, matching reviewed profiles and fresh evidence.
The [design record](../design/first-content-performance.md) separates this
coordinator delivery from subsequent provider and fleet qualification.

## Context

A memory reservation describes the maximum work that can fit, not the time a
request must wait. `max_tokens` remains the completion limit and part of physical
KV admission, but it does not set the first-content selection band. Internal
GPU first token, role-only preamble, delivered content and valid empty completion
remain distinct events.

Existing trust, authorization, model capability, memory, concurrency and owner
gates remain in [routing](routing.md) and [scheduling](scheduling.md). The provider
retains the final atomic admission decision against its current engine state.

## Mechanism

```mermaid
flowchart TD
    R["Request and original deadline"] --> G["Physical and ownership gates"]
    G --> C["Validate cache proof and restore cost"]
    C --> F["estimateFirstContent: expected and conservative"]
    F --> P["Prefer feasible; preserve decode quality"]
    P --> B["100-ms band; least whole-Mac service work"]
    B --> A["Atomic revalidation and pending reservation"]
    A -->|"state changed"| G
    A --> D["Provider dispatch"]
    D -->|"content or valid terminal"| S["Commit and settle once"]
    D -->|"predictive refusal"| Q["Exclude provider; refresh evidence"]
    Q -->|"same remaining clock"| G
    classDef work fill:#dbeafe,stroke:#1d4ed8,color:#172554
    classDef guard fill:#fef3c7,stroke:#a16207,color:#422006
    classDef success fill:#dcfce7,stroke:#15803d,color:#14532d
    class R,C,F,P,B,D,Q work
    class G,A guard
    class S success
```

### Prediction and freshness

`estimateFirstContent` (`coordinator/registry/first_content_forecast.go`) adapts the
request and detached evidence to `forecast.Evaluate`
(`coordinator/internal/registry/forecast/forecast.go`), which prices
handoff, cold load when needed, queued/competing prompt work, cache restoration,
uncached prompt work, and initial decode/delivery. `backlog_ms` remains a
historical commitment diagnostic and is never an elapsed waiting term.
`firstContentForecastEvidence` in `coordinator/registry/first_content_evidence.go`
binds the snapshot to that calculation; `forecast.Allows` in
`coordinator/internal/registry/forecast/admission.go` applies the request's
fresh-feasible and hard-ceiling policy without owning live provider state.

`planPromptRoute` reuses the existing verified renderer/tokenizer contract for
numeric prompt work, including tools and history. It shares a successful cache
plan's count, including short prompts with no reusable boundaries. With cache
routing disabled it can obtain a count without enabling cache reuse. Planning
never waits for tokenizer preload, has bounded concurrency before serialization,
and spends the original request deadline. `api/promptwork` memoizes by concrete
model and complete provider body for this HTTP request only; rewritten fallback
bodies cannot inherit another count.

A cache-planning sampling or QPS denial also prevents a second count-only
sidecar call. Cache routing off still permits independently bounded count-only
work. A temporary miss of the planning concurrency gate is not memoized, so a
later attempt can recover exact counts and cache planning within the original
deadline (`api/promptwork/planner.go`, `Plan`; `api/promptwork/planning.go`).

Before candidate preflight and final dispatch, a current, artifact/contract-bound
exact count can reconcile the SLA's input-token term (`Owner.PromptWorkDeadline`,
`coordinator/api/inference/first_content_prompt_deadline.go`). A larger or smaller exact
count corrects the duration only for a candidate advertising the matching
artifact and renderer contract, always measured from the original ingress time.
Missing or conflicting serving identity retains the original fallback cutoff;
a matching peer cannot grant its count or cutoff to another provider.
`FirstContentDeadlineForIdentity`
(`coordinator/registry/first_content_deadline_identity.go`) applies the same
serving identity qualification as the candidate's prompt count.
Planning and unselected scans use the larger of the two absolute cutoffs as
their outer bound. Candidate feasibility uses its own cutoff, which is bound
at reservation for provider handoff and response arbitration. That outer bound
does not authorize the provider to use a larger budget. An unsent exact-bound
attempt whose renderer identity changes before writer authorization is rejected.
An earlier caller context cutoff still wins; planning uses its original bounded
context and never gets another budget. Calibrated uncertainty, heuristic,
missing, malformed or stale work retains the initial duration. Account exemption
and explicit public-alias policy are resolved independently; physical token
reservations and billing remain unchanged. Provider recount after dispatch
does not extend the reconciled clock.

`prompt_work` carries the count, upper bound and artifact/template identity to
preflight, selection and provider reconciliation. Exact and calibrated counts
require the candidate's advertised `prompt_work_identity` artifact and renderer
contract, including when an exact cache plan supplies the count. Loaded engines
publish this identity independently of prefix-cache enablement. Older providers
can establish the same pair through validated cache capabilities; missing or
conflicting identity retains heuristic counts. `providerPromptWorkIdentityLocked`
in `coordinator/registry/prompt_work_identity.go` supplies the advertised model,
capacity and validated cache capabilities to `promptidentity.Resolve`
(`coordinator/internal/registry/promptidentity/identity.go`). A matching loaded
engine identity takes precedence; malformed or conflicting evidence cannot
borrow the request's identity. `forecast.PromptCounts`
(`coordinator/internal/registry/forecast/prompt.go`) then selects counts against
that resolved artifact and contract. Calibrated template estimates
also require a reviewed measured domain
and independent held-out coverage. Unmeasured prompt-rendering controls also
withdraw fallback qualification; exact tokenizer planning remains available.
Unsupported shapes retain heuristic provenance
with unknown uncertainty. Billing and physical reservation inputs stay separate.
The provider checks its actual tokenized count and verified factory identity;
a mismatch withdraws calibrated prediction without extending the deadline.

The reviewed fallback catalog contains six Qwen3.8 text/tool shape groups from
9,000 actual template/tokenizer runs. Every record binds the exact artifact,
template and training domain; gaps between measured size groups remain
heuristic. Raw corpus receipts are archived separately; the
[qualification procedure](../developer/serving-performance-qualification.md#verify-local-evidence)
describes their optional replay checks.

Qualified prompt-count bounds also apply to ordinary rate forecasts when no
timing profile exists. An in-domain upper bound can exceed the historical
heuristic and classify a previously admitted tight-budget request as
`predicted_late`; `MaxTTFTMs` or `RequireFreshFeasible` can then exclude that
candidate. Exact tokenizer counts take precedence when available. Removing the
fixed throughput reduction does not remove these measured prompt-work bounds.

The expected and conservative handoff allowances are policy constants, not
measured transport latency.

Accepted capacity freshness comes from `CapacityAcceptedAt`; repeated/out-of-order
frames and liveness-only heartbeats cannot renew it. Performance freshness is
tracked separately for accepted isolated-prefill and observed-decode EWMAs. A
changed value establishes a conservative lower bound from the prior accepted
frame; the older of the two measurement ages controls confidence. Each first
observed value has unknown sample age. An unchanged EWMA never becomes
fresh merely because another heartbeat arrives. Provider sample-age/count and
workload profiles remain the separate provider delivery in the design.

The existing coordinator and provider validation envelopes both accept prefill
rates through `maxPrefillTPS = 20000.0` tokens/s. Invalid rates retain their
diagnostics and fallback behavior (`coordinator/registry/heartbeat.go`,
`resolvePrefillTPS` in `coordinator/registry/scheduler.go`).

| Forecast class | Interpretation | Selection |
|---|---|---|
| `feasible` | Fresh, sufficiently matched conservative evidence fits the original remaining budget | Preferred pool |
| `unknown` | Missing/stale measurement, unqualified competing or cold work, vision work, or no deadline | Nonzero expected forecast and bounded fallback; an idle provider whose only gap is performance evidence joins the preferred pool after the exploration bound |
| `predicted_late` | Credible conservative forecast exceeds the remaining budget | Lower preference; existing explicit hard rejection policy can exclude it |

Performance evidence requires serving work, so feasible-first selection can
indefinitely exclude a provider with missing or stale measurements. A loaded,
idle provider with a `performance_missing` or `performance_age_unknown_or_stale`
forecast can compete beside feasible peers after
`firstContentEvidenceExplorationAfter` (`forecast.EvidenceExplorationAfter = 5 * time.Minute`). This threshold uses the older
paired measurement's age, or connection age when either measurement is undated;
it is not a continuous-idle timer or time since evidence expired. Unknown
connection age cannot qualify (`forecast.EvidenceGapAgeMS` and
`forecast.EvidenceExplorable`, `coordinator/internal/registry/forecast/exploration.go`;
registry adapters in `coordinator/registry/first_content_exploration.go`).

Outstanding service-retirement shadows, reported service usage or reservations,
load transitions, competing slot work and pending requests prevent the idle
exception (`fillFirstContentSnapshot`,
`coordinator/registry/first_content_snapshot.go`). Legacy providers may omit the
service fields and still qualify using their existing slot telemetry. Reservation
rechecks the exception under the provider lock and rescans if eligibility changed.
The candidate stays `unknown`, so hedge and fresh-feasible requests still exclude
it. Ordinary ranking need not select it, and a served request need not refresh
both measurements: cache reuse can leave isolated-prefill evidence unchanged, as
can an unchanged legacy EWMA. Exploration offers an opportunity, not guaranteed
selection or recovery.

### Automatic MiMo calibration

After native MiMo slot publication and on provider capacity ticks,
`refreshMimoCalibration` asks the loaded bridge to measure its actual serving
configuration. Calibration runs only on an idle Mac in nominal thermal state
outside Low Power Mode, with no reviewed deadline profile. The existing engine,
MTP configuration, context limit, memory gates and concurrency ceiling are used;
calibration never certifies a higher concurrency or changes a memory floor.

`MimoCalibrationPolicy.bootstrap` excludes one warmup, measures two short and
two longer text cells, sweeps the supported concurrent widths, and finishes with
a solo cell. Prompts contain built-in prose and code, not customer content; the
complete chat template is rendered to at most 128 warmup, 512 short or 4,096
longer prepared tokens. Measured cells request at most 32 output tokens, with
prefix caching disabled. Longer/batched cells require recent phase rates whose
serialized-work estimate fits `maximumGroupSeconds` (`15.0`); otherwise they
are skipped. Context/KV refusals remain authoritative. The group timer cancels
actual requests rather than fabricating retirement. Solo short/long/short probes
refresh an idle engine when either phase is older than `refreshAge` (`.seconds(90)`),
with the same affordability gate on the longer cell. Failed
attempts back off `failureBackoff` (`.seconds(120)`), interruptions
`interruptionBackoff` (`.seconds(30)`). Engine replacement starts a new epoch.

`IdleCalibrationCoordinator` prevents another calibration while a foreground
request prepares or admits. A request on any loaded model cancels the existing
probe and waits for its native retirement before acquiring service/KV. The
request's original first-content clock continues during that wait. Expiry or
cancellation at retirement records the ordinary deadline verdict before any
service/KV admission. Unload and
shutdown stop the calibration; no background task can retain retired weights.

Only completed, uncached, isolated calibration receipts seed ordinary phase
rates. They replace the previous estimate while preserving monotonic producer
counts and the engine epoch; subsequent serving observations resume EWMA smoothing.
Warmup is excluded; batched observations populate workload buckets with
measured `concurrent_requests` and do not overwrite solo admission rates.
Peak overlap is not proof of fused GPU batch width. Fresh cold isolated
measurements in the matching prompt-size bucket cap the aggregate prefill
projection in both coordinator and provider; they do not grant independent
freshness or extrapolate short prompts into longer domains.
Calibration output, requests and prefill tokens are excluded from served-work
counters and delivered/end-to-end observations. Physical in-flight work stays
visible in capacity until real retirement. This does not remove deadline or
actual-capacity 429s: it supplies fresh evidence through the existing event
heartbeats so idle machines can be selected before receiving customer traffic.

```mermaid
flowchart TD
    A["Native MiMo published / capacity tick"] --> B["startMimoCalibrationIfNeeded"]
    B --> C{"Mac idle and evidence needs refresh?"}
    C -->|Yes| D["Loaded engine: warmup, cold text, bounded batches"]
    D --> E["Real phase receipts and workload buckets"]
    E --> F["Performance refresh → heartbeat → routing"]
    G["Customer request on any model"] --> H["IdleCalibrationCoordinator.beginForeground"]
    H --> I["Cancel probe and await actual retirement"]
    I --> J["Ordinary admission on original deadline"]
```

### Provider recovery of expired text prefill evidence

Native engines with generation-bound retirement support can renew an expired
isolated-prefill estimate through one short text request. The evidence expires
after `EnginePerformanceMeasurements.freshness` (`.seconds(120)`). A recovery
request must have a live first-content deadline, no media, no reviewed deadline
profile, and at most `PrefillEvidenceRecovery.maximumPromptTokens` (`1_024`)
actual prepared tokens with a positive output limit. This is a bounded exploration policy, not a throughput
guarantee (`canRecoverPrefillEvidence`,
`provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+PrefillRecovery.swift`).

The provider atomically acquires the entire `WholeMacServiceBudget` only when
there are no service owners or unbounded device activities. That exclusive
lease prevents another model or request from claiming inference service until
prompt completion. The final idle check and synchronous native registration
share the budget lock, so device activity cannot start between those operations.
Loading or device work after that admission boundary invalidates the evidence guard;
an interrupted receipt cannot train an isolated rate. Short recovery uses the
existing unmeasured-prefill submission path, with no invented service rate or
predicted duration. Original-clock expiry checks run before and after submission;
the coordinator's first-content timeout still bounds waiting for content.
Physical KV, memory, cache, trust and cancellation checks remain in force.

The SDK prompt-completion receipt reduces the full-Mac allowance to the ordinary
configured serving fraction, including cache-only or contended receipts. The same
service reservation, its lifetime and all memory/cache ownership remain held until
actual retirement. Long completions therefore retain ordinary concurrency instead
of monopolizing the Mac. If prefill never completes, exclusivity remains held
through retirement (`reduceExclusiveAllowance`,
`provider-swift/Sources/ProviderCore/Inference/Performance/WholeMacServiceBudget.swift`).

Outside this exclusive recovery path, native requests retain ordinary predictive
admission using their observed rates. Expiration alone does not remove a healthy
idle provider's ability to serve a larger prompt. Engines without generation-bound
retirement retain their legacy policy. A failed
or cache-only recovery waits `PrefillEvidenceRecovery.failureBackoff`
(`.seconds(120)`) after actual retirement before another recovery can start.
A successful cold isolated sample releases the recovery permission at retirement;
receipt publication alone never releases device ownership.
Refusals before engine admission commits do not start the recovery backoff.

The first new sample after an evidence gap reseeds its phase EWMA rather than
blending with the expired rate. Producer epoch and sample counts remain monotonic,
and heartbeats alone do not renew measurements. A cache hit, incomplete prefill,
contended sample or invalid timing cannot replace isolated-prefill evidence.
Coordinator exploration still controls whether an unknown provider gets a request;
provider recovery supplies a measurement opportunity once it is selected.

Even a feasible forecast is advisory. The ordinary forecast uses resolved
prefill and decode rates directly: it no longer multiplies either rate by 0.5.
The conservative prefill rate is still capped by a valid isolated-prefill
observation, while prompt-count upper bounds, queued work, cache restoration,
cross-model contention and delivery allowances remain explicit. A rate-based
estimate can still miss its deadline if subsequent execution slows down.

Optional reviewed `deadline_calibration` cells supply measured prediction-error
ratios and additive tail allowances only inside exact prompt/context, cache and
contention envelopes. Both compiled runtimes independently verify the stored
validation counts meet a one-sided 95% binomial confidence test at the claimed
tail target, even when the raw evidence archive is unavailable. Fresh live
evidence can make those rates slower; it cannot
make them faster than the reviewed values.

`DeadlinePerformanceProfile` binds those cells to the exact constructed
scheduler, model, template, MTP runtime and hardware. Its configured context is
runtime identity, while each cell bounds measured request and competing-work
contexts. The separate `deadline_profile` reference grants no authority over
concurrency, whole-Mac charges or mixed-prefill caps. Those serving policy
changes still require the complete `ServingPerformanceProfile` qualification
matrix; narrow first-content evidence cannot certify them. The deadline catalog
is currently empty, so that optional timing path remains disabled. The ordinary
forecast's removal of the fixed rate reduction is active without a catalog
entry. Enabling reviewed timing profiles requires independently qualified
evidence with continuous power observations. Concurrency, chunk and memory
defaults remain unchanged. Review-controlled records are decoded by
`deadline.DecodeProfiles` and selected by `Catalog.Qualified`
(`coordinator/internal/registry/deadline/catalog.go`); generated bytes remain in
`coordinator/internal/registry/deadline/catalog_data.go` (`CompiledProfilesJSON`).
Record validation is `Profile.Valid`
(`coordinator/internal/registry/deadline/profile.go`).

A compiled profile must match the qualifier's current scheduler and posture
domain: one partial prefill at a time, an absent mixed cap or exactly 128, 256
or 512 tokens, 20 seconds of whole-Mac quiescence, 5 seconds of stable nominal
posture, and Automatic power mode on AC. Every cell must fit the declared
scheduler width and carry the profile's qualification-report digest. This deadline-policy
revision cannot transfer AC measurements to Battery Automatic. The provider advertises the
reference only while these prerequisites hold. The coordinator requires
explicit nominal thermal state and `low_power_mode=false`, and invalidates
an old idle reference after locally tracked work, load transitions or reported
GPU activity (`coordinator/registry/deadline_applicability.go` delegates to
`deadline.PosturePolicy`, `coordinator/internal/registry/deadline/posture.go`).
`Posture.Activity`, `InvalidatePosture` and `Allows` run under the provider's
existing critical section; they do not move live locking into the detached
forecast calculation. This does not
delay requests: ineligible work retains conservative admission. Provider
retirement and the final atomic evidence guard remain authoritative. Phase
rates from earlier posture epochs are omitted from profiled capacity snapshots,
so recovered power/thermal eligibility cannot revive old measured rates.

Busy work accounting requires fresh `deadline_work` envelopes correlated
with the whole-Mac reservation snapshot. The currently permitted cooled policy
withdraws calibration while the Mac is busy; a different applicability policy
needs separate qualification and a reviewed validator change. Existing owners retain conservative
prompt/output bounds through pre-submit and retirement. Missing owners, changed
epochs, unrepresented GPU work or unmatched competing profiles stay unknown.
A nonempty work envelope must retain positive original prompt work, including
cache-reused requests. Its aggregate token counts, owner count and maximum
context must also agree; an impossible report cannot certify existing work.
The provider takes the larger of actual scheduler work and existing same-model
lease bounds, adds qualified competing work, then prices only the incoming work
to first content. The cell's context bound includes the bounded incoming early
decode allowance. Its requested full output remains a memory commitment and is
not added to the incoming first-content projection. Overlapping scheduler and
lease work is bounded with a maximum rather than counted twice.
An unrelated `idle_shutdown` slot with no activity does not compete for work or
require active-engine telemetry. Positive activity and local reservations still
count; loading, crashed and unknown slot states remain conservative.

### Native media target observations

Native MiMo preparation expands media into its actual target-decoder prompt
before deadline admission. A short text sample is not a measured media rate.
`NativeMediaPrefillRates` retains at most 32 samples in each existing prompt
size band, using the slowest unexpired rate only within the smallest-to-largest
actually observed prompt range. Each sample expires after 120 seconds; new
observations do not refresh older samples. Engine replacement resets the table.
Only cold, unpacked, non-preempted target-prefill intervals with exclusive
whole-Mac ownership and an unchanged nominal AC/Automatic posture enter it.
Media encoder preparation and failed native drains invalidate isolated evidence.
Native online observations require five seconds of stable nominal posture and
actual retirement of earlier device work. They may start immediately after
successful media preparation; they carry no 20-second recovery proof and never
enter the reviewed text-calibration catalog. The text catalog retains its full
20-second quiescence requirement. A late prepared/request drain failure marks
the shared service budget unbounded at the failure transition, even when the
earlier preparation activity has already finished.

Submission captures one whole-Mac/posture snapshot shared by the prefill receipt
and `EngineV2Bridge+MiMoDeadline.swift`; a missing snapshot cannot be upgraded
between those consumers. The latter passes the incoming target's observation
to the SDK. The SDK prices any pre-existing
prefill at its original rate and any decode at its own rate. Missing, expired,
out-of-range or invalidated media evidence is not replaced by a text prediction.
These runtime observations do not populate the reviewed calibration catalog.

When that table has no applicable observation, one owned native request can
gather evidence under the same absolute first-content deadline. The SDK checks
physical capacity, exactly one scheduler row, no in-flight step, no decode or
mixed work, no adopted prefix, and the live whole-Mac guard. The provider allows
at most one such request until actual retirement. Failed or ineligible attempts
back off for 120 seconds per engine; an eligible target-prefill sample releases
that backoff only at its owner's retirement, including an eligible ordinary
request with no first-content deadline, so new shapes can build a fresh range.
Busy, unowned, stale-posture or cooldown cases keep a capacity refusal;
no deadline, memory, cancellation or trust check is disabled. The explicit SDK
`unmeasuredNativeMedia` result records bounded work with unknown service time,
not a zero-time prediction. Cancellation transfers retain the bootstrap owner
until the existing retirement path releases the service allowance.

### Selection and reservations

`selectRoutingCandidateWithAffinity`
(`coordinator/registry/candidate_selection.go`) uses the minimum health-adjusted expected
first-content time, retains the `firstContentFastBandMs` band, and chooses the
least committed whole-Mac service work within it. Existing health derating,
owner semantics and decode-quality preference remain. Valid cache affinity
breaks close choices; equivalent choices spread. The whole-Mac service estimate
is distinct from the physical prompt-plus-maximum-output reservation.

Cache proof is validated before forecasting and again at reservation. Reusable
tokens are bounded by the real prompt work, age weighted and expired normally;
restoration is charged once. See [cache-aware routing](cache-aware-routing.md).

`commitProviderReservation` (`coordinator/registry/scheduler.go`) rebuilds the
candidate while holding the provider lock and reserves capacity in the same
critical section. Pending prompt work immediately becomes visible to subsequent
routing. Changed state triggers a bounded rescan. The same request-absolute
clock covers lock waits, cache work, quotes, queues and provider writer handoff.
Preflight releases its CPU routing-scan permit during prompt-contract planning
and fallback body preparation, then reacquires it against the remaining clock
before another fleet walk (`admissionScanPermit`,
`coordinator/api/inference/inference_admission_scan.go`).
Reservation cleanup follows the existing pending-request lifecycle on refusal,
disconnect, timeout, cancellation and terminal completion.

`recordReservedPrefill` and `fillFirstContentPending`
(`coordinator/registry/first_content_pending.go`) use `forecast.ReservePrefill`
and `PrefillQueue.Add`/`Ahead` (`coordinator/internal/registry/forecast/prefill.go`).
They retain cache-adjusted prompt work at the same reservation boundary and
reconcile earlier local work with reported work using a maximum; reservations
at or after the accepted capacity frame are additional unreported work.
`fillFirstContentSnapshot` (`coordinator/registry/first_content_snapshot.go`)
uses `forecast.WorkBuilder` (`coordinator/internal/registry/forecast/work.go`)
for whole-Mac service accounting under the same provider lock. These components
do not acquire a separate live-state lock or release pending reservations.

### Retries, quotes and hedges

Retained plans are reranked from current evidence before reservation; a quote
does not reserve capacity. Predictive refusals exclude the refusing provider for
the logical request without counting as permanent health faults. After two such
refusals from distinct providers, including speculative race losers, another
dispatch requires fresh feasible evidence. Quote fanout is
bounded to two providers and spends the original deadline. Existing provider
quote quantiles lack sample-age and workload provenance. A recent quote therefore
needs independently fresh, matching local evidence and cannot lower the local
forecast; busy, cold, vision or stale observations remain Unknown.

The registry's `DispatchPlan` (`coordinator/registry/dispatch_plan.go`) embeds
`QuotePlan` (`coordinator/registry/quote_plan.go`), sharing its candidate storage
and leaf mutex. `QuoteCandidate` retains immutable ranking evidence and
`CandidateBinding` (`coordinator/registry/candidate_binding.go`) retains connection
identity; neither grants admission. `shortlist.Order`
(`coordinator/internal/registry/shortlist/order.go`) owns only bounded handles,
quote ordering and consumption, with `MaxAlternates = 8`. `claimEntry` in
`coordinator/registry/first_content_plan.go` consumes an identity through
`Order.Claim` under the plan mutex; inspecting or reranking surviving entries
does not consume them. Its `applyFirstContentQuote` adapter calls
`forecast.ApplyQuote`; `QuotePlan.BestConfirmedBackup`
(`coordinator/registry/quote_plan_evidence.go`) calls
`forecast.BackupTiming` (`coordinator/internal/registry/forecast/quote.go`). Both
retain the local freshness requirements rather than treating a quote as a new
performance measurement. The request-scoped inference `Plan` remains a
separate owner of dispatch, probe and shared refresh sequencing.

A logical request launches at most one hedge, on a distinct feasible provider
with spare service allowance, under the existing hedge governor. Exempt requests
use `FirstContentPlanningHorizon` to assess hedges and recovery after repeated
predictive refusals; this advisory horizon creates no first-content deadline or
timer. Ordinary exempt primary selection remains deadline-free. The loser is
cancelled and retired through the normal terminal/accounting arbitration.
Providers with different rendering contracts can have different cutoffs, both
anchored to the original arrival. The race first visits the earlier cutoff and
retires only that expired attempt; a viable survivor keeps its own remaining
budget (`Clock.RaceWait`, `coordinator/internal/inference/firstcontent/attempt_clock.go`;
`expireBoundRacer`,
`coordinator/internal/inference/attempt/race_deadlines.go`). On-time content ingress
still beats expiry while classification is pending. If classification proves
the event is boilerplate, the expired cutoff is revisited without a fresh window.
A shorter selected interval advances the original hedge point to at most its
halfway point; an earlier model or quote point stays earlier
(`Clock.ForPending`, `coordinator/internal/inference/firstcontent/attempt_clock.go`).

Public deadline-bound requests wait for capacity only when evidence supports a
useful release within the remaining first-content budget. A configured queue
maximum is a limit, not a target. Explicit self/owner behavior, deadline-exempt
requests and structural-error semantics remain intact.

## Invariants

1. Physical admission still reserves prompt plus maximum output and all existing
   activation/KV allowances (`memorypolicy.Admits`, `coordinator/internal/registry/memorypolicy/admission.go`).
2. A new attempt cannot reset the first-content deadline (`RefreshFirstContentBudget`,
   `coordinator/registry/pending_request.go`).
3. Cache hints never replace endpoint identity, proof or current-capacity checks
   (`applyCacheRoutingCostPLocked`, `coordinator/registry/scheduler.go`).
4. Expected forecasts rank; only credible conservative evidence establishes
   feasibility (`estimateFirstContent`, `coordinator/registry/first_content_forecast.go`).
5. Provider concurrency limits, measured memory floors and warm-pool placement
   remain separately qualified policies; this coordinator change expands none.

## Failure modes and evidence

Missing observations reduce feasibility coverage, not physical safety. Unknown
fallbacks can still be refused by the provider. The retry ladder is bounded and
keeps the original overload, fault and timeout outcomes; it does not claim every
predicted refusal would actually miss in execution.
An expired candidate cutoff is a known deadline refusal even when performance
is Unknown. The scan preserves that cause separately from other TTFT filters
(`CandidateScan.DeadlineRejections`, `coordinator/registry/reservation_candidates.go`). If no fitting peer
has a live cutoff, preflight retains the retryable deadline refusal and avoids
cold spill; an expired fitting peer is not a permanent model-size failure
(`Admission.Run`, `coordinator/api/inference/inference_admission.go`).

The profiler persists each candidate's `first_content` object with expected and
conservative times, class/reason, remaining budget, evidence ages, cache work and
service-work estimate (`DecisionJSON`, `coordinator/internal/observation/profile/profiler_record.go`). The
winner carries its commit-time evidence. Existing cost and calibrated TTFT
columns remain separate diagnostics; [profiler sampling](system-profiler.md)
does not represent a random sample of all outcomes.

## Code map

| Concern | Source |
|---|---|
| Forecast types and classification | `coordinator/internal/registry/forecast/forecast.go` (`Estimate`, `Evaluate`, `UnknownReason`); `coordinator/registry/first_content_forecast.go` (`estimateFirstContent`) binds detached evidence |
| Forecast inputs and admission | `coordinator/registry/first_content_evidence.go` (`firstContentForecastEvidence`); `coordinator/internal/registry/forecast/admission.go` (`Allows`) |
| Prompt accounting and bounded planning | `coordinator/api/promptwork/` — `Memo`, `Plan`, `Calibration` |
| Candidate-local cutoff and binding | `coordinator/registry/first_content_deadline_identity.go` — `FirstContentDeadlineForIdentity`, `FirstContentDeadlineEnvelope`; `coordinator/registry/scheduler.go` — `commitProviderReservation` |
| Prompt identity and count qualification | `coordinator/internal/registry/promptidentity/identity.go` (`Resolve`); `coordinator/registry/prompt_work_identity.go` (`providerPromptWorkIdentityLocked`); `coordinator/internal/registry/forecast/prompt.go` (`PromptCounts`) |
| Qualified prediction arithmetic | `coordinator/registry/firstcontent/` — `Calibration`, `Predict` |
| Independent deadline profile identity | `coordinator/internal/registry/deadline/profile.go` (`Profile.Valid`); `coordinator/internal/registry/deadline/catalog.go` (`Catalog.Qualified`); `coordinator/registry/deadline_profile.go` (`qualifiedDeadlineProfileLocked`) retains the provider critical section |
| Generated deadline catalog and posture | `coordinator/internal/registry/deadline/catalog_data.go` (`CompiledProfilesJSON`); `coordinator/internal/registry/deadline/posture.go` (`PosturePolicy`, `Posture.Allows`) |
| Existing work ownership | `coordinator/registry/first_content_calibrated_work.go` — `fillCalibratedWorkSnapshot` |
| Pending prefill and whole-Mac service accounting | `coordinator/internal/registry/forecast/prefill.go` (`ReservePrefill`, `PrefillQueue`); `coordinator/internal/registry/forecast/work.go` (`WorkBuilder`, `PendingServiceMS`); registry adapters in `coordinator/registry/first_content_pending.go` and `coordinator/registry/first_content_snapshot.go` |
| Idle evidence exploration | `coordinator/internal/registry/forecast/exploration.go` (`EvidenceGapAgeMS`, `EvidenceExplorable`); `coordinator/registry/first_content_exploration.go` (`firstContentEvidenceExplorable`) |
| Candidate selection | `coordinator/registry/candidate_selection.go` — `selectRoutingCandidateWithAffinity` |
| Physical reservation | `coordinator/registry/scheduler.go` — `commitProviderReservation` |
| Cache-aware preflight | `coordinator/registry/first_content_preflight.go` — `QuickFirstContentCapacityForRequestWithDeadlines` |
| Expired-provider response | `coordinator/api/inference/first_content_preflight_response.go` — `writeFirstContentDeadlineExpired` |
| Selected clock and asymmetric hedge expiry | `coordinator/internal/inference/firstcontent/attempt_clock.go` — `Clock.ForPending`, `Clock.RaceWait`; `coordinator/internal/inference/attempt/race_deadlines.go` — `Race.expireBoundRacer` |
| Exact-bound unsent renderer drift | `coordinator/registry/inference_authorization.go` — `InferenceHandoff.Authorize` |
| Retained alternatives | `coordinator/registry/dispatch_plan.go` (`DispatchPlan`, `ReserveNextFromPlan`, `RefreshDispatchPlan`); `coordinator/registry/quote_plan.go` (`QuotePlan`, `NewQuotePlan`); `coordinator/registry/quote_plan_evidence.go` (`ConfirmEntry`, `DemoteEntry`, `BestConfirmedBackup`); `coordinator/internal/registry/shortlist/order.go` (`Order.Claim`, `Order.Rank`); `coordinator/registry/selection/retain.go` (`Retain`); `coordinator/registry/first_content_plan.go` (`reserveFirstContentFromPlan`, `claimEntry`) |
| Request-scoped plan and probe budget | `coordinator/internal/inference/dispatch/plan.go` (`Plan.Scan`, `Plan.Next`); `plan_probes.go` (`Plan.Probe`, `Plan.RefreshQuotes`) retains the initial chain, shares one refresh across retry and hedge, and waits for the initial quote round before refreshing evidence |
| Quote correlation | `coordinator/internal/registry/capacityquote/tracker.go` (`Tracker.Add`, `Take`, `Resolve`, `FailProvider`); `coordinator/registry/capacity_quotes.go` (`ProbePlanCandidates`, `HandleCapacityQuote`) |
| Quote qualification and backup timing | `coordinator/internal/registry/forecast/quote.go` (`ApplyQuote`, `BackupTiming`); adapters in `coordinator/registry/first_content_plan.go` (`applyFirstContentQuote`) and `coordinator/registry/dispatch_plan.go` (`BestConfirmedBackup`) |
| Request retry and terminal ownership | `coordinator/api/inference/dispatch.go` — `dispatchState` |
| Persisted forecast evidence | `coordinator/internal/observation/profile/profiler_record.go` — `DecisionJSON` |
| Native text measurement recovery | `provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+PrefillRecovery.swift` — `canRecoverPrefillEvidence`; `provider-swift/Sources/ProviderCore/Inference/Performance/PrefillEvidenceRecovery.swift` — `PrefillEvidenceRecovery` |
| Automatic MiMo calibration and customer preemption | `provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+MimoCalibration.swift` — `startMimoCalibrationIfNeeded`; `provider-swift/Sources/ProviderCore/Inference/Performance/IdleCalibrationCoordinator.swift` — `beginForeground` |
| Conservative prompt-size evidence | `coordinator/registry/prefill_workload_rates.go` — `capPrefillByWorkload`; `provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EnginePerformanceMeasurements.swift` — `freshIsolatedPrefillRate` |

## Related

- [Routing](routing.md), [scheduling](scheduling.md), [configuration](../reference/configuration.md).
- [Production investigation](../reports/2026-09-28-first-content-performance.md).
- [Performance plan and qualification targets](../design/first-content-performance.md).
