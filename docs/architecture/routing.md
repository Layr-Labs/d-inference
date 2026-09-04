# Routing: how a request becomes a provider choice

> Last updated: 2026-09-04 · commit `075d37a91`

Routing is the part of the coordinator that, given one inference request and
the live fleet, picks the provider that should run it. It filters the fleet
through a fixed sequence of eligibility gates, prices every survivor in
estimated milliseconds, selects the cheapest, and — when the chosen provider
is slow to produce first content — races a second provider against it.
Capacity, queues, slot states and the warm pool are covered in
[`scheduling.md`](scheduling.md); this page covers only choosing among
eligible providers.

## Context

The fleet is heterogeneous consumer Apple-silicon hardware that comes and
goes. Any single provider may be cold for a model, thermally throttled,
memory-starved, mid-attestation, or silently rejecting work. The scheduler
therefore never trusts one signal: it combines the provider's own heartbeat
telemetry (`BackendCapacity`, see
[`protocol-messages.md`](../reference/protocol-messages.md)), coordinator-side
fault tracking (cooldowns, breakers, ejection) and request-shape estimates
(prompt tokens, `max_tokens`, vision, tool constraints) into one ranked
decision per request.

Two properties shape the design:

- **Cost is expressed in milliseconds.** Every penalty in the model is an
  estimate of added latency for *this* request, so terms can be summed and
  compared directly, and the routing breakdown that is logged per decision
  (`costBreakdown`, `coordinator/registry/scheduler.go`) always sums to the
  total.
- **Every rejection has a name.** Gate outcomes (`GateReason`) and selection
  outcomes (`SelectionPath`) are closed vocabularies
  (`coordinator/registry/gate_reason.go`) so telemetry and the simulation
  harness can account for every provider the scanner looked at.

The coordinator decrypts consumer bodies in Confidential VM memory only far
enough to estimate tokens and detect request shape; routing never sees prompt
content beyond that. See [`data-flow.md`](data-flow.md) and
[`security/encryption.md`](security/encryption.md).

## Mechanism

### Entry points

`ReserveProviderWithPlan` (`coordinator/registry/scheduler.go`) is the
dispatch-time entry point. It scans the fleet
(`scanCandidatesLocked`), gates and prices each provider
(`buildCandidateGateLocked`), selects a winner (`selectRoutingCandidate`) and
returns a bounded **dispatch plan** (`coordinator/registry/dispatch_plan.go`)
holding the winner plus up to `dispatchPlanMaxAlternates = 8` retained
alternates. The API layer (`coordinator/api/dispatch.go`) consumes the plan:
it dispatches to the winner, may probe alternates for capacity quotes
(`capacityProbeWindow = 250 * time.Millisecond`,
`dispatchPlanProbeFanout = 8`, `coordinator/api/dispatch_plan_wiring.go`) and
falls through the plan on retry or hedge.

The same gate chain is reused by the preflight admission check
(`PredictServable`, `coordinator/registry/servability.go`) and by the queue
drain path (`scheduling.md`), so the set of providers a request can queue for
is the set it can be dispatched to.

```mermaid
flowchart TD
    R[Request: model, prompt tokens, max_tokens, traits] --> S[scanCandidatesLocked]
    S -->|allowlist / excluded| X1[tallyGate]
    S --> G[providerRoutingGateReasonLockedEx]
    G -->|not_serving_model, dedicated, cooldowns, breaker, ejection, liveness, trait_floor| X2[tallyGate]
    G --> V{RequiresVision?}
    V -->|provider lacks vision| X3[tallyGate vision]
    V --> B[buildCandidateGateLocked]
    B -->|slot_crashed / slot_reloading / no_headroom / thermal_critical / model_too_large / free_memory| X4[tallyGate]
    B --> C[cost = state + queue + pending + backlog + thisReq + health + capacityRate]
    C -->|ttft_ceiling| X5[tallyGate]
    C --> D[applyCacheRoutingDiscount]
    D --> P[pool narrowing: prefer owner, avoid version, min decode TPS]
    P --> SEL[selectRoutingCandidate: unique_min / tie_queue / tie_pending / cache_tiebreak / random]
    SEL --> PLAN[dispatch plan: winner + alternates]
    PLAN --> DISP[dispatch to winner]
    DISP -->|no first content by speculativeAt| H[runSpeculative: hedge governor + backup]
    H --> RACE[runRace: first content wins, loser cancelled]
    DISP -->|first content| OK[stream]
    RACE --> OK
```

### Eligibility gates and the `GateReason` vocabulary

Gates run in the order below. The first failing gate names the rejection;
`scanCandidatesLocked` tallies exactly one `GateReason` per rejected provider.
`GateReasonCount` is the "passed every gate" sentinel and is reported as
`EligibilityReasonEligible = "eligible"`.

| Order | `GateReason` | snake_case | Enforced in | Meaning |
|---|---|---|---|---|
| 1 | `GateAllowlist` | `allowlist` | `scanCandidatesLocked` | Request is `SelfRouteOnly` and the provider is not owned by the caller, or the request carries allowed serials the provider does not match. |
| 2 | `GateExcluded` | `excluded` | `scanCandidatesLocked` | Provider is in the caller's exclude set (already failed this request, or a prior attempt). |
| 3 | `GateNotServingModel` | `not_serving_model` | `providerServesRoutableModelReasonLocked` | Provider does not advertise the model. |
| 4 | `GateDedicated` | `dedicated` | `providerServesRoutableModelReasonLocked` | Model belongs to a dedicated family and the provider's catalog is not exclusively that family. Owners self-routing to their own box are exempt. |
| 5 | `GateDispatchLoadCooldown` | `dispatch_load_cooldown` | `providerRoutingGateReasonLockedEx` | Pair is cooling down after a dispatch-time `load_model` failure (`dispatchLoadCooldownTTL`, [below](#cooldowns-breakers-and-ejection)). |
| 6 | `GateErrorCooldown` | `error_cooldown` | `providerRoutingGateReasonLockedEx` | Shape-keyed inference-error breaker is open ([constants](#cooldowns-breakers-and-ejection)). |
| 7 | `GateCapacityCooldown` | `capacity_cooldown` | `providerRoutingGateReasonLockedEx` | Pair is in capacity-reject cooldown (black-hole 503s). |
| 8 | `GateBreaker` | `breaker` | `providerRoutingGateReasonLockedEx` | Node-health breaker open for genuine-fault errors. |
| 9 | `GateEjection` | `ejection` | `providerRoutingGateReasonLockedEx` | Stable-identity health ejection open. |
| 10 | `GateOffline` | `offline` | `providerLivenessGateReasonLocked` | `Status == StatusOffline` — set by the provider socket handler (`coordinator/api/provider.go`) the moment the WebSocket dies, before the deferred `Disconnect()` removes the record ([`scheduling.md`](scheduling.md#disconnect)). |
| 11 | `GateUntrusted` | `untrusted` | `providerLivenessGateReasonLocked` | `Status == StatusUntrusted`. |
| 12 | `GatePrivateOnly` | `private_only` | `providerLivenessGateReasonLocked` | Provider is `PrivateOnly` and the request is not from its owner. |
| 13 | `GateTrustFloor` | `trust_floor` | `providerLivenessGateReasonLocked` | `TrustLevel` ranks below the floor ([below](#trust-floor-and-self-route-relaxation)). |
| 14 | `GateRuntimeUnverified` | `runtime_unverified` | `providerLivenessGateReasonLocked` | `RuntimeVerified` is false. |
| 15 | `GatePrivateText` | `private_text` | `providerLivenessGateReasonLocked` | `providerSupportsPrivateTextLocked` is false (code attestation not proven). |
| 16 | `GateChallengeStale` | `challenge_stale` | `providerLivenessGateReasonLocked` | Last passed challenge is missing or older than `challengeFreshnessMaxAge` ([below](#challenge-freshness)). |
| 17 | `GateTraitFloor` | `trait_floor` | `providerRoutingGateReasonLockedEx` | Provider cannot satisfy a request trait (for example inference-time tool constraints). |
| 18 | `GateVision` | `vision` | `providerServesVisionModelLocked` | Request `RequiresVision` and the provider's build of the model does not serve vision. |
| 19 | `GateSlotCrashed` | `slot_crashed` | `buildCandidateGateLocked` / `slotStatePenalty` | Slot state `crashed`. |
| 20 | `GateSlotReloading` | `slot_reloading` | `buildCandidateGateLocked` / `slotStatePenalty` | Slot state `reloading`. |
| 21 | `GateNoHeadroom` | `no_headroom` | `hasConcurrencyHeadroomForModelCapResolvedLocked` | Provider or slot is at its concurrency cap ([`scheduling.md`](scheduling.md#concurrency-caps)). |
| 22 | `GateThermalCritical` | `thermal_critical` | `buildCandidateGateLocked` | `SystemMetrics.ThermalState == "critical"`. |
| 23 | `GateModelTooLarge` | `model_too_large` | `modelFitsHardware` | Model is not resident and cannot fit the node's total memory. Permanent, not capacity. |
| 24 | `GateFreeMemory` | `free_memory` | `freeMemoryAdmits` | Token-budget or memory admission fails, or the pair is budget-clamped. |
| 25 | `GateTTFTCeiling` | `ttft_ceiling` | `scanCandidatesLocked` | Estimated TTFT exceeds `pr.MaxTTFTMs` (public non-vision requests with a ceiling only). |

Gates 5–9 are the coordinator's own fault memory and are evaluated *before*
liveness so a breaker-open provider is counted as `breaker`, not as whatever
else may also be wrong with it. `scanCandidatesLocked` separately counts
providers rejected by gates 8–9 (`breakerRejected`) and providers that would
have been routable but for gate 7 (`capacityRejections`) because both feed the
fail-open and 429 decisions described under [Failure modes](#failure-modes).

### Trust floor and self-route relaxation

`Registry.MinTrustLevel` is the lowest `TrustLevel` a provider may hold and
still receive public traffic; `NewRegistry` (`coordinator/registry/registry.go`)
sets it to `TrustHardware`. What the levels mean, how they are earned and how
the floor is configured is the subject of
[`security/attestation.md`](security/attestation.md).

Two request policies relax the gate for the caller's **own** machines only:
`SelfRouteOnly` (route exclusively to owned providers) and `PreferOwner`
(prefer owned, fall back to public). In `scanCandidatesLocked`,
`relaxTrust := owned && (pr.SelfRouteOnly || pr.PreferOwner)`. When relaxed,
`providerRoutingGateReasonLockedEx` substitutes `TrustNone` for the floor,
`providerLivenessGateReasonLocked` admits `PrivateOnly` providers, and
`providerServesRoutableModelReasonLocked` waives dedicated-catalog isolation.
Every other gate — runtime verification, private-text attestation, challenge
freshness, slot state, memory — still applies to owned machines.

### Challenge freshness

`challengeFreshnessMaxAge = 16 * time.Minute`
(`coordinator/registry/scheduler.go`). A provider whose `LastChallengeVerified`
is zero or older than this fails `challenge_stale`. The constant was raised
from 6 minutes when attestation churn was reworked
([`../design/routing-v2-attestation-churn.md`](../design/routing-v2-attestation-churn.md)).

`MaxFailedChallenges = 3` (`coordinator/registry/registry.go`) governs how
failures clear that timestamp in `RecordChallengeFailure`: a *security*
failure (bad signature, SIP off, binary hash mismatch) clears
`LastChallengeVerified` immediately; a *transient* failure (the provider did
not answer in time) only clears it once `FailedChallenges` reaches the
threshold, so a single missed challenge does not deroute a provider verified
seconds earlier. Both paths also record the failure into reputation.

### Cost model

`buildCandidateGateLocked` prices an eligible provider as

```text
cost = statePenalty + queueMs + pendingMs + backlogMs + thisReqMs + healthMs + capacityRateMs
```

and stores every term in `costBreakdown` with `Total = cost`
(`coordinator/registry/scheduler.go`). All constants below live in
`coordinator/registry/scheduler.go` unless another file is named.

| Symbol | Value | Applied as |
|---|---|---|
| `slotStatePenaltyRunning` | `0.0` | Slot state `running`, `idle`, or empty (`slotStatePenalty`). |
| `slotStatePenaltyUnknown` | `30_000.0` | Slot state `unknown` or any unrecognised state — the model must be loaded first. |
| `slotStatePenaltyIdleShutdown` | `20_000.0` | Slot state `idle_shutdown` (weights evicted, engine warm). |
| `queueDepthPenaltyMs` | `3_000.0` | × `snapshotOccupancy` = max(pending on this model at this provider, backend `NumRunning + NumWaiting`). |
| `totalPendingPenaltyMs` | `750.0` | × total in-flight requests on the provider across all models. |
| `memoryPressurePenaltyMs` | `4_000.0` | × `SystemMetrics.MemoryPressure` (`healthPenaltyMs`). |
| `cpuUsagePenaltyMs` | `1_500.0` | × `SystemMetrics.CPUUsage`. |
| `gpuUtilizationPenaltyMs` | `5_000.0` | × `GPUMemoryActiveGB / TotalMemoryGB`, clamped to [0, 1]. |
| `thermalPenaltyFairMs` | `2_000.0` | Added when `ThermalState == "fair"`. |
| `thermalPenaltySeriousMs` | `8_000.0` | Added when `ThermalState == "serious"` (`critical` is a gate, not a penalty). |
| `defaultCapacityRatePenaltyMs` | `15_000.0` | × windowed capacity-503 rate (`capacity_rate.go`, [below](#gray-box-capacity-signals)). |
| `nearTieCostWindowMs` | `3_000.0` | Width of the near-tie band in `selectRoutingCandidate`. |
| `defaultRequestedMaxTokens` | `256` | Used for `max_tokens` when the request does not set one. |
| `effectiveTPSLoadFactor` | `0.39` | Per-concurrent-decode TPS derating (`effectiveDecodeTPS`). |
| `kvCacheBytesPerToken` | `400_000` | Fallback KV bytes per token when the slot does not report `KVBytesPerToken`. |
| `modelMemoryHeadroomFactor` | `2.0` | `modelFitsHardware`: model GB × 2 must fit total memory when the manifest gives no `minRAMGb`. |
| `maxPrefillTPS` | `5000.0` | Cap on any prefill rate used for pricing (`resolvePrefillTPS`, `coordinator/registry/registry.go`). |
| `defaultPrefillToDecodeRatio` | `12.0` | Static prefill TPS = decode TPS × ratio when the provider reports no prefill rate. |
| `defaultLongPromptThresholdTokens` | `0` | Long-prompt bias is off until a threshold is set. |
| `defaultLongPromptPrefillWeight` | `2.0` | Multiplier on first-token-blocking time for long prompts. |

The remaining terms are request-shaped:

- **`backlogMs`** — tokens ahead of this request divided by effective TPS.
  For a slot that reports a token budget it is
  `(ActiveTokenBudgetUsed + QueuedTokenBudget) / effectiveTPS`; otherwise
  `backlogTokenMs` sums `MaxTokensPotential`, the backend's waiting requests ×
  `max_tokens`, and coordinator-side pending tokens the backend has not yet
  seen.
- **`thisReqMs`** — `promptTokens / prefillTPS + maxTokens / effectiveTPS`,
  plus `longPromptPenalty`.

**Effective TPS.** `resolveEffectiveTPS` prefers the slot's
`ObservedDecodeTPS` EWMA, then the fleet median for the model, then the
static registration rate derated by load:
`effectiveDecodeTPS = staticTPS / (1 + effectiveTPSLoadFactor × backendRunning)`,
floored at 1 tok/s. `resolvePrefillTPS` prefers `ObservedPrefillTPS`, else
the static prefill rate (`resolvedPrefillTPS`: the registered `PrefillTPS`,
or decode × `prefillToDecodeRatio`), capped at `maxPrefillTPS`.
`SetPrefillToDecodeRatio` changes the ratio process-wide; the coordinator
binary wires it to `EIGENINFERENCE_PREFILL_DECODE_RATIO`
(`coordinator/cmd/coordinator/main.go`).

**Prefill weighting for long prompts.** `longPromptPenalty(promptTokens,
ttftBlockMs)` returns `(longPromptPrefillWeight − 1) × ttftBlockMs` when a
threshold is set and the prompt reaches it, else `0`. `ttftBlockMs` is the
request's prefill time plus, for a provider that is not resident, its slot
state penalty — so the bias cannot pull a long prompt onto a cold box whose
fast prefill is dwarfed by the load. The setters are
`SetLongPromptThreshold` and `SetLongPromptPrefillWeight`, wired to
`EIGENINFERENCE_LONG_PROMPT_TOKENS` and
`EIGENINFERENCE_LONG_PROMPT_PREFILL_WEIGHT`. The penalty is folded into
`thisReqMs` so the breakdown invariant holds.

**TTFT estimate.** Separately from cost, each candidate carries an estimated
time-to-first-token (`ttftMsFromSnapshot`): slot state penalty + prefill of
tokens queued ahead + this request's prefill + one decode step
(`1000 / effectiveTPS`), then multiplied by the per-(model, chip family)
calibration ratio learned from settled requests
(`ttftCalibration.appliedRatio`, `coordinator/registry/ttft_calibration.go`).
`ttftOccupancyAlpha` (default `0.0`, `SetTTFTOccupancyAlpha`) optionally
blends in occupancy. This estimate drives the `ttft_ceiling` gate, hedge
timing and the `Retry-After` header; it is not a cost term.

**Cache discount.** After pricing, `applyCacheRoutingDiscount` subtracts a
bounded discount for providers holding a confirmed prefix cache for the
request. The discount rules and their flag are the subject of
[`cache-aware-routing.md`](cache-aware-routing.md).

### Selection paths

Before selection the candidate pool may be narrowed, each step only when it
leaves at least one candidate (`scanCandidatesLocked`):

1. `PreferOwner` — keep only providers owned by the caller.
2. `Traits.AvoidVersion` — keep only providers not running the version that
   just failed this request (version-diverse retry).
3. `MinDecodeTPS` — keep only providers whose
   `projectedPerRequestDecodeTPS` meets the request's floor. The coordinator
   binary sets the floor from
   [`EIGENINFERENCE_MIN_DECODE_TPS`](../reference/configuration.md#routing-admission-and-ttft);
   `0` disables it.

`selectRoutingCandidate` then picks from the pool:

1. **Best cost.** The minimum `costMs`.
2. **Near ties.** Every candidate within `nearTieCostWindowMs` ([cost
   model](#cost-model)) of the best. Among near ties the winner is the lowest `effectiveQueue`, then
   the lowest `totalPending`.
3. **Equivalents.** Near ties sharing the winner's queue depth and pending
   count. If any equivalent carries a cache discount, the cheapest equivalent
   wins (`cache_tiebreak`; exact cost ties fall to `random`). Otherwise more
   than one equivalent resolves by `random`.
4. **Path label** (`tieBreakPath`): `unique_min` when there was a single near
   tie; `tie_pending` when another near tie shared the winner's queue depth
   (pending count decided); else `tie_queue`.

`SelectionPath` values (`coordinator/registry/gate_reason.go`): `none`,
`unique_min`, `tie_queue`, `tie_pending`, `cache_tiebreak`, `random`. The
runner-up (`lowestCostOther`) is recorded alongside the winner for telemetry
and as the first alternate in the dispatch plan.

### Hedged (speculative) dispatch

A request that has not produced first content by its **speculative point**
launches a backup and races the two. The mechanics live in
`coordinator/api/dispatch.go` (`runSpeculative`, `runRace`) with timing in
`coordinator/api/hedge_schedule.go` and `coordinator/api/first_token_clock.go`.

**Launch offset.** The initial speculative point is
`deadline × speculativeTimerRatio`, `speculativeTimerRatio = 0.5`
(`coordinator/api/consumer.go`). When the probe round returns a
high-confidence quote for the best alternate, it may deliver one strictly
earlier absolute launch instant through `hedgeAdvanceCh`, computed by
`hedgeLaunchOffset(deadline, backupTTFTQ90, confidence)`:

```text
halfPoint    = deadline / hedgeRatioDenominator          # hedgeRatioDenominator = 2
backupBudget = max(backupTTFTQ90, hedgeMinBackupBudget)  # hedgeMinBackupBudget = time.Second
latestUseful = deadline − backupBudget − hedgeCommitGuard # hedgeCommitGuard = 500 * time.Millisecond
offset       = max(0, min(halfPoint, latestUseful))      # halfPoint alone unless confidence == hedgeConfidenceHigh
```

`firstTokenSpeculativeWait` converts the offset into a wait measured from the
request's `ReceivedAt`, so retries do not restart the clock.

**Backup selection.** The backup is drawn from the retained dispatch plan
(`dispatchFromPlanMachinery`) or, when the plan is exhausted, from a fresh
`dispatchOneProvider` scan with the primary and every previously failed
provider excluded. A `PreferOwner` request being served by the owner's own
machine never hedges onto the paid public fleet.

**Governor.** `hedgeGovernor.tryAcquireHedge` (`coordinator/api/hedge_governor.go`)
must return `hedgeAllow` before a backup launches; the verdict and the budget
slot are one atomic operation. Suppression verdicts, in evaluation order:

| Verdict | Condition |
|---|---|
| `hedgeSuppressQueued` | The model has coordinator-queued demand (`modelQueueDepth > 0`). |
| `hedgeSuppressNoIdleCapacity` | No idle eligible alternative exists and fleet idle slots < `hedgeFleetIdleHeadroomSlots = 2`. |
| `hedgeSuppressGlobalBudget` | Active hedges ≥ `max(1, fleetIdleSlots / hedgeGlobalBudgetDivisor)`, `hedgeGlobalBudgetDivisor = 4` (budget `0` when nothing is idle). |
| `hedgeSuppressWinRate` | Model win-rate EWMA (`hedgeWinRateAlpha = 0.2`) < `hedgeWinRateFloor = 0.10` after ≥ `hedgeWinRateMinSamples = 8` outcomes; every `hedgeWinRateExploreInterval = 16` suppressions one hedge is allowed through to re-measure. |

**Cancel and win.** `runRace` commits whichever attempt delivers first
content and calls `cancelDispatch` on the other, which sends the provider a
cancel and releases the reservation. A backup win sets `BackupWon`, emits
`inference.speculative_win`, and is counted by
`recordHedgeOutcome`. Both attempts are marked `UsedBackup`; settlement
excludes them from TTFT calibration (`observeTTFTCalibration`,
`coordinator/api/settlement.go`). The acquired governor slot is released
exactly once on every exit path (`noteHedgeResolved`).

### Early-429 servability predictor

Before a request is queued or dispatched, `PredictServable`
(`coordinator/registry/servability.go`) asks whether the fleet can
*structurally* serve it. It returns a `ServabilityVerdict` with one of two
reasons:

- `context_exceeded` — `contextPromptTokens + max_tokens` exceeds the model's
  context window.
- `prompt_too_long` — every eligible provider has a *known* structural token
  budget and `estimatedPromptTokens + max_tokens` exceeds the largest
  (`FleetMaxBudget`). If any eligible provider's budget is unknown the
  verdict stays servable.

A provider's structural budget (`snapshotStructuralBudget`) is its reported
`ActiveTokenBudgetMax` when the slot reports one; for a provider that is not
resident it is `coldTokenBudgetEstimate`:

```text
weightsGiB   = measured resident GiB (version ≥ 0.8.16 and model in table) else catalogGB × coldLoadCatalogGBToMemGiB
postLoadGiB  = servabilityCapFraction × totalMemoryGB − weightsGiB        # mirrors the provider cap fraction
tokens       = (postLoadGiB − activationFloorGiB) × 2^30 / kvBytesPerToken  # kvCacheBytesPerToken when unreported
```

`coldLoadCatalogGBToMemGiB = 1.2 * (1e9 / float64(int64(1)<<30))` (≈ 1.1176,
`coordinator/registry/scheduler.go`). `servabilityCapFraction`,
`servabilityActivationFloorGB` and `servabilityModelActivationFloorsGB` mirror
the provider's `UnifiedMemoryCap` constants, whose values are stated once in
[`hardware-support.md`](hardware-support.md#constants); the two tables move in
the same commit. The activation floor is version-gated
(`servabilityActivationFloor`):

| Provider version | Floor |
|---|---|
| empty or `< 0.8.0` (`servabilityActivationFloorMinVersion = "0.8.0"`) | `servabilityLegacyActivationFloorGB = 3.0` |
| `< 0.8.16` (`servabilityPerModelFloorMinVersion = "0.8.16"`) | `servabilityActivationFloorGB` |
| `≥ 0.8.16` | per-model table, else `servabilityActivationFloorGB` |

Per-model tables (`coordinator/registry/servability.go`):

| Table | Entries |
|---|---|
| `servabilityModelActivationFloorsGB` | `gpt-oss-20b` (mirrors `measuredActivationFloorsBytes`) |
| `servabilityMeasuredResidentGiB` | `"gpt-oss-20b": 11.5` |

The consumer path turns an unservable verdict into an immediate `429` instead
of queueing; the coordinator binary enables this by default and
`EIGENINFERENCE_SERVABILITY_GATE=false` disables it
(`coordinator/cmd/coordinator/main.go`, `SetServabilityGate`).

### Gray-box capacity signals

Three mechanisms handle providers that reject with capacity-shaped 503s while
their heartbeat still advertises room.

**Budget clamp** (`coordinator/registry/budget_clamp.go`). The first
capacity/token-budget rejection for a (provider, model) pair
(`recordBudgetClampLocked`, fed by `RecordCapacityReject`) makes admission
stop believing that pair's heartbeat budget: `freeMemoryAdmits` rejects it as
`free_memory` and `providerBudgetFits` reports zero live headroom. Release
requires both a heartbeat delivered after the clamp showing at least
`budgetClampReleaseMinHeadroomTokens = 1024` tokens of headroom
(`releaseBudgetClampsOnHeartbeat`) and an accept for the pair after the clamp
(`noteBudgetClampAcceptLocked`). A clamp fails open after
`defaultBudgetClampTTL = 5 * time.Minute`. Kill switch
[`EIGENINFERENCE_BUDGET_CLAMP`](../reference/configuration.md#routing-admission-and-ttft);
TTL override `EIGENINFERENCE_BUDGET_CLAMP_TTL_SECONDS`.

**Capacity-rate penalty** (`coordinator/registry/capacity_rate.go`). A pair
whose capacity-503 rate over `capacityRateWindow = 5 * time.Minute` exceeds
`capacityRateThreshold = 0.25` with at least `capacityRateMinSample = 8`
outcomes pays `rate × defaultCapacityRatePenaltyMs` ([cost model](#cost-model);
override `EIGENINFERENCE_CAPACITY_RATE_PENALTY_MS`) in the cost model. A soft
derater: the candidate stays in the pool.

**Capacity cooldown** (`coordinator/registry/capacity_cooldown.go`). A pair
that accumulates `defaultCapacityCooldownThreshold = 5` capacity rejects
within `defaultCapacityCooldownWindow = 60 * time.Second` with no interleaved
accept is gated (`capacity_cooldown`) for `defaultCapacityCooldownTTL =
120 * time.Second`, doubling per trip up to `defaultCapacityCooldownMaxTTL =
10 * time.Minute`. A probe outcome within `capacityProbeOutcomeWindow =
30 * time.Second` counts toward the same tally. Overrides:
`EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD`,
`EIGENINFERENCE_CAPACITY_COOLDOWN_WINDOW_SECONDS`,
`EIGENINFERENCE_CAPACITY_COOLDOWN_TTL_SECONDS`,
`EIGENINFERENCE_CAPACITY_COOLDOWN_MAX_TTL_SECONDS`.

First-content accepts carry their observation time from
`coordinator/api/dispatch.go` (`commitFirstContent`) to
`coordinator/registry/capacity_cooldown.go` (`RecordCapacityAcceptObserved`).
The recorder runs asynchronously so the first client byte does not wait for
`registry.mu`. Reject strikes after the observation survive a delayed accept;
a cooldown remains when those surviving strikes independently reach the
threshold. A later budget clamp also requires a later accept to prove release.
The request is stamped before scheduling the recorder to count its capacity-rate
outcome exactly once at first content or completion.

### Cooldowns, breakers and ejection

| Mechanism | File | Keyed by | Trips when | Holds for |
|---|---|---|---|---|
| Inference-error cooldown (`error_cooldown`) | `coordinator/registry/error_cooldown.go` | provider × model × error shape | `inferenceErrorThreshold = 2` strikes within `inferenceErrorWindow = 60 * time.Second` | `inferenceErrorCooldownTTL = 5 * time.Minute` |
| Node-health breaker (`breaker`) | `coordinator/registry/provider_breaker.go` | stable provider identity | `providerBreakerConsecTrip = 5` consecutive genuine faults, or fail rate ≥ `providerBreakerFailRate = 0.80` over ≥ `providerBreakerMinVolume = 20` outcomes in `providerBreakerWindow = 120 * time.Second` (ring of `providerHealthRingSize = 20`) | `providerBreakerBaseCooldown = 60 * time.Second`, doubling to `providerBreakerMaxCooldown = 5 * time.Minute` |
| Health ejection (`ejection`) | `coordinator/registry/health_ejection.go` | stable provider identity | `healthEjectionConsecTrip = 8` consecutive failures, or success rate < `healthEjectionMinSuccessRate = 0.10` over ≥ `healthEjectionMinSample = 15` outcomes in `healthEjectionWindow = 10 * time.Minute`, or `healthEjectionCapacityConsecTrip = 10` consecutive capacity rejects | `healthEjectionBaseCooldown = 60 * time.Second`, doubling to `healthEjectionMaxCooldown = 10 * time.Minute` |
| Dispatch-load cooldown (`dispatch_load_cooldown`) | `coordinator/registry/registry.go` | provider × model | a dispatch-time `load_model` fails | `dispatchLoadCooldownTTL = 2 * time.Minute` |

Fault state keys by the provider's stable identity when one is bound, so it
survives disconnect and reconnect (`Disconnect`, `coordinator/registry/registry.go`).

**Fail-open.** If the scan produced no winner, at least one provider was
rejected only by the breaker or ejection, and there were no capacity or TTFT
rejections, `shouldBypassBreakerFailOpen` re-runs the scan with
`ignoreProviderBreaker` so a degraded-but-only fleet still serves rather than
returning `no_provider`.

### Reputation

`Reputation.Score` (`coordinator/registry/reputation.go`) is

```text
score = 0.4 × jobRate + 0.3 × uptimeRate + 0.2 × challengeRate + 0.1 × responseTimeFactor
```

- `jobRate` = `SuccessfulJobs / TotalJobs` (`0.5` with no jobs).
- `uptimeRate` = `TotalUptime / 24h`, floored at `0.5`, capped at `1.0`.
- `challengeRate` = passed / (passed + failed) (`0.5` with no challenges).
- `responseTimeFactor` = `1.0` at ≤ 1 000 ms average, `0.0` at ≥ 10 000 ms,
  linear between (`0.5` with no data). The average is an EWMA of
  prefill-adjusted first-content latency, `ttftEWMAAlpha = 0.2`
  (`RecordLatency`).

A provider with no history scores `0.5`. The score is exposed on the
provider-facing `/me` endpoints (`coordinator/api/me_handlers.go`) and
persisted; **it is not a term in the routing cost** — `buildCandidateGateLocked`
never reads it. The header comment in `reputation.go` still says the score
factors into routing; the code does not. Reputation inputs do reach routing
indirectly: `RecordChallengeFailure` feeds `challenge_stale`, and the latency
EWMA is fed only by non-cache, non-hedge first-content samples
(`coordinator/api/dispatch.go`).

### `Retry-After` derivation

When the consumer path sheds a request with `429`, `estimateRetryAfter`
(`coordinator/api/consumer.go`) derives the header:

1. Base `2` seconds. If the model's queue is non-empty,
   `queueDepth × 3`, clamped to [2, 30].
2. Distress override: if the attempt-0 route latency EWMA
   (`routeLatencyEWMAAlpha = 0.2`) exceeds
   `degradedRouteEWMAThresholdMs = 1000.0`, use
   `ceil(ewmaSeconds) × 5`, capped at
   [`maxDistressRetryAfter`](../reference/api-contracts.md#timeouts-and-constants),
   when larger than the base.

For a TTFT shed, `estimateTTFTRetryAfter` uses `ceil(bestTTFT − threshold)`
in seconds, floored at the base estimate and clamped to [2, 30]. Self-route
sheds use fixed values.

### Routing simulation harness (`routingsim`)

`coordinator/registry/routingsim/` is a Go library that replays arrivals
against the **real** scheduler — the same `PredictServable` and candidate
scan production uses — so that routing changes can be evaluated on recorded
traffic before deploy. It has no binary; it is driven from tests.

- `runner.go` — `Classify` / `ClassifyWithGate` run one arrival through the
  preflight capacity check and return an `Outcome`: `served`,
  `machine_busy`, `ttft_too_slow`, `no_provider`, `model_too_large`. `Run` /
  `RunWithGate` classify a whole trace; `TTFTDeadline` applies the production
  first-content deadline policy (`coordinator/modelpolicy/first_content_deadline.go`)
  with a 5 s base.
- `fleet.go` — `BuildFleet` registers a synthetic fleet
  (`FleetConfig`, `DefaultHardwareSpec`) into a fresh `Registry`.
- `fleet_ndjson.go` — `LoadFleetNDJSON` reconstructs a fleet from exported
  fleet snapshots (`store.FleetSnapshotRow`) at the tick nearest a given time.
- `trace.go` / `trace_ndjson.go` — `GenerateTrace` and
  `CalibrationPromptMix` build synthetic prompt mixes;
  `LoadProfilesNDJSON` turns exported request profiles into arrivals.
- `report.go` — `Summarize` buckets results by prompt length and
  `EstimatedCliff` finds the prompt size where acceptance collapses.

Run it with the package tests, for example
`go test ./coordinator/registry/routingsim/...` (`TestRoutingSimCalibration`
and friends in `routingsim_test.go`). Tests that change process-wide tunables
such as `SetPrefillToDecodeRatio` restore them afterwards, so the harness
must not run in parallel with other scheduler tests in the same process.

## Invariants

1. **A provider never receives a model it does not advertise, and dedicated
   families never share a box with other models** —
   `providerServesRoutableModelReasonLocked`
   (`coordinator/registry/routing_eligibility.go`).
2. **Public traffic never routes below the trust floor; relaxation applies
   only to a caller's own machines** — `providerRoutingGateReasonLockedEx`
   and `providerLivenessGateReasonLocked`.
3. **No provider is routed without a fresh passed challenge** —
   `providerLivenessGateReasonLocked` with `challengeFreshnessMaxAge`.
4. **A model that is not resident is never routed to hardware it cannot
   fit** — `modelFitsHardware` in `buildCandidateGateLocked`; resident slots
   (`slotStateModelLoaded`) are exempt because they have demonstrably fit.
5. **Every scanned provider is accounted for exactly once**: as a candidate
   or under one `GateReason` — `scanCandidatesLocked.tallyGate`.
6. **The cost breakdown sums to the total** — `buildCandidateGateLocked`
   folds `longPromptPenalty` into `ThisReqMs` and sets `Total = cost`.
7. **Pool narrowing never empties the pool** — each `PreferOwner`,
   `AvoidVersion` and `MinDecodeTPS` filter in `scanCandidatesLocked` is
   applied only when its result is non-empty.
8. **A hedge never launches while the model has queued demand, and never
   exceeds the fleet-wide hedge budget** — `hedgeGovernorVerdict`;
   acquisition and release are exactly-once (`tryAcquireHedge`,
   `noteHedgeResolved`).
9. **Exactly one attempt of a race commits; the other is cancelled** —
   `runRace` calls `cancelDispatch` on the loser before committing.
10. **Fault memory survives reconnects** — `Disconnect` preserves breaker,
    cooldown and ejection state keyed by stable identity.

## Failure modes

| Symptom | Cause | What the code does |
|---|---|---|
| `no_provider` | No provider advertises the model, or every advertising provider fails a non-capacity gate (`candidateCount == 0` with no capacity rejections). | Preflight returns `429` with `Retry-After` and reason code `no_provider` (`coordinator/api/inference_admission.go`). With [`EIGENINFERENCE_COLD_DISPATCH`](../reference/configuration.md#routing-admission-and-ttft) enabled and an idle on-disk provider that could load the model, the request is queued for a cold dispatch instead (`coldSpillAvailable`, `coordinator/api/cold_dispatch.go`). With breaker-only rejections, fail-open re-scans first (`shouldBypassBreakerFailOpen`). |
| `model_too_large` | Every advertising provider is cold and `modelFitsHardware` fails (`rejectModelTooLarge`). | Permanent rejection for this fleet composition; `routingsim` reports `OutcomeModelTooLarge`. |
| All gated on capacity (`machine_busy`) | Providers serve the model but all are at `no_headroom`, `free_memory` or `capacity_cooldown`. | With [`EIGENINFERENCE_QUEUE_BEFORE_SHED`](../reference/configuration.md#routing-admission-and-ttft) enabled (`coordinator/api/cold_dispatch.go`) the request queues per [`scheduling.md`](scheduling.md); otherwise `429` with `Retry-After` from `estimateRetryAfter`. |
| `ttft_too_slow` | Every candidate's estimated TTFT exceeds the first-content deadline. | Soft by default: the best-available provider still serves. `EIGENINFERENCE_TTFT_HARD_REJECT=true` restores the legacy `429`; vision requests are never TTFT-gated. |
| Queue timeout | A queued request found no eligible provider within the queue's wait bound. | `ErrQueueTimeout` → `429` with `Retry-After`; see [`scheduling.md`](scheduling.md#per-model-request-queue). |
| Budget-clamped fleet | Every pair for the model is clamped after capacity 503s. | Pairs show as `free_memory` until release or `defaultBudgetClampTTL` ([above](#gray-box-capacity-signals)); heartbeat headroom plus one accept releases early. |
| Hedge suppressed under load | Governor returns a suppress verdict. | Primary alone is waited on for the remaining deadline (`waitNoBackup`); `routing.hedge_governor_suppressed` counts the verdict. |

## Code map

| Concern | File / symbol |
|---|---|
| Dispatch-time selection, cost model, TTFT estimate | `coordinator/registry/scheduler.go` — `ReserveProviderWithPlan`, `scanCandidatesLocked`, `buildCandidateGateLocked`, `selectRoutingCandidate`, `slotStatePenalty`, `healthPenaltyMs`, `resolveEffectiveTPS`, `ttftMsFromSnapshot`, `longPromptPenalty` |
| Shared gate primitives | `coordinator/registry/routing_eligibility.go` — `providerLivenessGateReasonLocked`, `providerServesRoutableModelLocked` |
| Closed vocabularies | `coordinator/registry/gate_reason.go` — `GateReason`, `SelectionPath`, `SlotState` |
| Trust floor, challenge failures, dispatch-load cooldown, `Disconnect` | `coordinator/registry/registry.go` — `MinTrustLevel`, `MaxFailedChallenges`, `RecordChallengeFailure`, `dispatchLoadCooldownTTL` |
| Bounded dispatch plan | `coordinator/registry/dispatch_plan.go` — `dispatchPlanMaxAlternates`, `PlanEntry` |
| Servability predictor | `coordinator/registry/servability.go` — `PredictServable`, `coldTokenBudgetEstimate`, `servabilityActivationFloor` |
| Budget clamp | `coordinator/registry/budget_clamp.go` — `recordBudgetClampLocked`, `releaseBudgetClampsOnHeartbeat` |
| Capacity-rate penalty and cooldown | `coordinator/registry/capacity_rate.go`, `coordinator/registry/capacity_cooldown.go` |
| Breakers and ejection | `coordinator/registry/error_cooldown.go`, `coordinator/registry/provider_breaker.go`, `coordinator/registry/health_ejection.go` |
| Reputation | `coordinator/registry/reputation.go` — `Score`, `RecordLatency` |
| TTFT calibration | `coordinator/registry/ttft_calibration.go`; fed by `observeTTFTCalibration` in `coordinator/api/settlement.go` |
| Hedge timing, governor, race | `coordinator/api/hedge_schedule.go`, `coordinator/api/hedge_governor.go`, `coordinator/api/dispatch.go` (`runSpeculative`, `runRace`), `coordinator/api/first_token_clock.go` |
| Probes and plan wiring | `coordinator/api/dispatch_plan_wiring.go` |
| `Retry-After`, speculative ratio, route EWMA | `coordinator/api/consumer.go` — `estimateRetryAfter`, `estimateTTFTRetryAfter`, `speculativeTimerRatio` |
| Queue-before-shed and cold dispatch flags | `coordinator/api/cold_dispatch.go` |
| Flag wiring at startup | `coordinator/cmd/coordinator/main.go` |
| Simulation harness | `coordinator/registry/routingsim/` — `runner.go`, `fleet.go`, `fleet_ndjson.go`, `trace.go`, `report.go` |

## Related

- [`scheduling.md`](scheduling.md) — queues, slot states, token-budget admission, warm pool, heartbeat and eviction.
- [`cache-aware-routing.md`](cache-aware-routing.md) — prefix-cache discount and tiebreak.
- [`security/attestation.md`](security/attestation.md) — trust levels, challenges, `MinTrustLevel` configuration.
- [`../reference/protocol-messages.md`](../reference/protocol-messages.md) — `heartbeat`, `BackendCapacity`, `BackendSlotCapacity`.
- [`../reference/configuration.md`](../reference/configuration.md) — coordinator environment reference.
- [`../operations/routing-v2-rollout.md`](../operations/routing-v2-rollout.md) — kill switches for the routing flags named on this page.
- [`../design/routing-v2.md`](../design/routing-v2.md), [`../design/routing-telemetry-and-calibration.md`](../design/routing-telemetry-and-calibration.md) — the design history behind the current constants.
- [`request-outcome-observability.md`](request-outcome-observability.md) — how routing outcomes surface in telemetry.
