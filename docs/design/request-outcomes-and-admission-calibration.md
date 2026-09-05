# Request outcomes and provider admission calibration

> Last updated: 2026-09-05 · commit `bbf6f83d4`

Status: **Proposed** — 2026-09-05 — planning only; the analytics names and implementation work below have not shipped.

This record defines two related workstreams: trustworthy request outcomes and evidence-based correction of coordinator/provider admission disagreements. It gives implementation agents a shared vocabulary and bounded sub-PR ownership. The tracking issues hold the implementation checklists; this record preserves the reasoning and interfaces between them.

## Goal and scope

The goal is to fulfill more requests within their first-content deadline and accurately explain requests the system could not fulfill. A lower internal error count, agreement between two estimates, or an unchanged uptime headline does not establish that goal.

| Workstream | Tracking issue | Deliverable |
|---|---|---|
| Request and attempt analytics | [#845](https://github.com/Layr-Labs/d-inference/issues/845) | A documented counting and outcome contract, accurate aggregation, and a dashboard that separates requests from attempts |
| Coordinator/provider calibration | [#846](https://github.com/Layr-Labs/d-inference/issues/846) | A matched evidence baseline, targeted corrections to established discrepancies, and outcome-based validation |
| Missing provider refusal evidence | [#844](https://github.com/Layr-Labs/d-inference/issues/844) | Investigation of available evidence, minimal telemetry changes, compatibility, overhead, and implementation effort |

This PR changes documentation only. Provider instrumentation remains an investigation under #844. Future code PRs preserve existing deadline, retry, billing, and HTTP behavior unless a separately reviewed behavioral change is part of the calibration work. Deployments require the approvals in the operations runbooks.

## Why the work is grouped this way

1. **An attempt is not a request.** A provider may decline, another provider may succeed, and the client request may complete. Counting every refusal as a failed client request confuses internal activity with final outcomes.
2. **A terminal reason is not a root cause.** A request can encounter provider deadline refusals and later finish with a coordinator timeout. The final reason records the terminating event; the attempt history supplies contributing observations.
3. **Partial response and client departure overlap.** A client can disconnect after content starts while the provider later completes. A provider can also fail after content starts while the client remains connected. These facts need separate dimensions.
4. **Selection and admission observe different boundaries.** The coordinator predicts before dispatch; the provider sees later queue and engine state with less time remaining. Comparing two numbers without their boundaries can manufacture a discrepancy.
5. **The code already accounts for model differences in several places.** Audit the existing per-model/per-hardware calibration, rates, fallbacks, and sample selection rather than introducing a redundant estimator.
6. **Disagreement alone does not identify the faulty side.** Coordinator optimism, provider conservatism, stale observations, incomparable measurements, or a real capacity shortage can each contribute. Improvements must be judged against observed timing and fulfillment.
7. **Retry changes are deferred.** Recovery after refusals can differ by model and workload. Measure retries as part of the baseline, then reassess their policy only after calibration effects are known.

## Shared vocabulary

The distributed request model is simple: a provider decides whether to serve an attempt; the coordinator determines the request outcome. Use lowercase `snake_case` and explicit `int_`/`ext_` prefixes for the agreed normalized analytics codes.

| Level | Proposed code | Display name | Meaning |
|---|---|---|---|
| Internal attempt | `int_provider_deadline_rejected` | Provider declined deadline | A provider explicitly refuses an attempt under its first-content deadline checks or admission policy; another provider may succeed |
| Final request | `ext_first_content_timeout` | First-content timeout | The coordinator ends the request because the allowed wait for first content expired; this does not always prove expiration of the overall request clock |
| Final request | `ext_coordinator_exhausted` | Coordinator exhausted | The coordinator ends the request with no further attempts available under its routing policy, with no more specific terminal classification taking precedence |

`ext_` denotes the final outcome recorded by Darkbloom. It does not prove that OpenRouter or another upstream client received the response. Provider wire status, final HTTP status, normalized analytics code, and client delivery evidence remain separate facts.

“Coordinator exhausted” does not assert that every provider is offline or incapable. Candidates may be ineligible, excluded, already attempted, or bounded by an attempt limit. The exact stopping condition belongs in diagnostics. Do not require a headline root-cause field or treat the last provider refusal as proven causality.

The three codes are not an exhaustive error taxonomy. Specific client errors, queue rejections, provider faults, and post-content stream failures retain their distinctions. Do not map every historical `dispatch_exhausted` record to the new exhaustion meaning without checking its underlying evidence and precedence.

### Compatibility and historical interpretation

- Introduce normalized analytics codes alongside preserved raw values. The current wire vocabulary and retry/breaker classification must not change as a side effect of a dashboard rename.
- Preserve per-attempt `first_chunk_timeout`, accepted-timeout, preamble-timeout, and cancellation events in detailed diagnostics. The headline final timeout is not an additional failed request for each attempt.
- Use explicit unknown/legacy classifications when historical rows cannot establish the intended meaning. Never infer provider failure from a missing row, or a finite projection from a generic refusal.
- Version mappings and published data shapes where necessary. Keep old/new records queryable without silently relabeling uncertain historical data.

## Request counting and completion contract

The analytics issue owns the exact state definitions and precedence. Its implementation must satisfy these invariants:

1. One final result per incoming coordinator request within a declared covered population. An attempt ID is not a client request ID.
2. Declare whether the cohort is selected by request receipt or finalization time, how open requests and late terminals are handled, and which endpoints and early rejection paths are covered.
3. Sampled request profiles cannot be used as a complete request denominator. Publish coverage and sampling limits; add a minimal durable request outcome source only if the source audit establishes it is necessary.
4. Response progress, termination reason, and provider completion are distinct dimensions. A completion requires appropriate terminal and egress evidence for streaming or non-streaming delivery; profile `completed` and route `partial_success` alone are insufficient.
5. If a single summary bucket is needed, publish deterministic precedence and include in-progress/unknown/conflicting-evidence cases. Keep the underlying dimensions available.
6. Client cancellation is observed connection state, not proof of user intent or proof that the provider failed. A response write does not establish upstream receipt.
7. Selection-only profiles and speculative losers do not create extra final request outcomes. Deduplicate finalization races without losing attempt evidence.
8. Keep request fulfillment separate from existing provider-health and uptime metrics. Rename or replace a metric only with an explicit definition and compatibility decision.

## Illustrative request histories

These are examples of classification, not production measurements.

| Observed history | Request presentation | Internal detail retained |
|---|---|---|
| Provider A refuses the deadline; provider B completes and coordinator finishes delivery | Completed | A's `int_provider_deadline_rejected` |
| Provider A refuses; coordinator has no further eligible attempts | Rejected, `ext_coordinator_exhausted` | Attempt refusals and stopping condition |
| Provider A refuses; the coordinator's allowed wait expires | Rejected, `ext_first_content_timeout` | Refusals, timeout boundary, and consumed time |
| A genuine provider fault precedes a deadline refusal | Existing terminal precedence determines the result | Both observations; refusal does not conceal the fault |
| Client disconnects before content | Client departure, no content delivery established | Attempt state and any later provider terminal |
| Client disconnects after content; provider later completes | Content started, client departed, provider completed | Completion and departure remain separate facts |
| Provider fails after the coordinator has begun streaming generated content to the client | Interrupted response | No fabricated replacement pre-content HTTP rejection |
| Non-streaming inference completes but final response write fails | Delivery incomplete/unconfirmed | Provider completion does not become client completion |
| Old or sampled records omit necessary evidence | Unknown or coverage-limited | Raw values and missing-evidence flags |

## Calibration contract

The calibration work uses the same attempt and model identity on both sides. Keep public aliases and canonical model identifiers explicit; pooling distinct models needs a documented justification.

| Comparison dimension | Question to answer |
|---|---|
| Clock and boundary | Are predictions compared with the remaining budget at their own decision boundary? What elapsed during preparation, queueing, transport, and provider submission? |
| Prompt and cache work | Are estimates pricing the actual model template, prompt length, prefix reuse, and media limitations consistently? |
| Rates and hardware | Are measurements model/hardware specific, fresh, and representative of the work being predicted? What happens before calibration warm-up? |
| Queue and concurrency | Are local pending reservations, heartbeat queue state, in-flight work, and admission backlog counted consistently without omission or duplication? |
| Safety policy | Which explicit margins and rate haircuts differ? Does a conservative estimate reject work that an isolated experiment shows is feasible? |
| Sampling and feedback | Are successful, timed-out, cancelled, and raced observations selected differently? Are raw predictions preserved to avoid compounding a calibration multiplier? |
| Actual capacity | Would available providers have met the deadline at all, even with an accurate estimate? |

Existing source includes online TTFT calibration keyed by model and chip family, per-model slot observations, and provider-local projected admission. The baseline must audit their existing learning/apply paths. Runtime flags and provider rollout versions must be verified separately; checked-in configuration and open PR descriptions are not deployment evidence.

Refused attempts do not supply observed completion times, and speculative winners are selected observations. Do not treat successful-only timing data as proof that all refusals were unnecessary. Use representative held-out workloads and isolated experiments to test counterfactual claims.

#844 owns the investigation into whether refusal details can distinguish estimated deadline miss, actual expiration, and unavailable projection. Start the existing-data audit now; mark conclusions that need #844 evidence unresolved rather than requiring speculative provider work up front.

## Sub-PR ownership and dependencies

| Unit | Owner scope | Inputs | Completion boundary |
|---|---|---|---|
| A1: outcome contract and mapping | Analytics definitions, legacy mapping, precedence, fixtures | This record and current producer/consumer audit | Reviewable definitions for every relevant terminal and ambiguous case |
| A2: request recording | Minimum coordinator identity/outcome/egress recording corrections if needed | A1 | Sufficient evidence for accounting, with explicit coverage; no changed routing/billing behavior |
| A3: aggregation and data quality | Request/attempt joins, normalized mappings, covered-population counts, serving payload compatibility | A1 and A2 data contract | Reconciled counts, window semantics, unknown handling, and bounded publication queries |
| A4: dashboard presentation | Request headline, attempt drill-down, completion dimensions, freshness/coverage labels | A3 payload contract | Known histories render correctly and existing serving/freshness contracts hold |
| C1: calibration baseline | Current estimator audit, matched comparison, representative cohorts, existing-work inventory | Can start alongside A1; consumes A1 definitions as they settle | Ranked discrepancies, uncertainty, reusable baseline, and proposed bounded corrections |
| C2: targeted calibration corrections | Only calculations or inputs implicated by C1 evidence | C1; #844 findings only where needed | Focused code changes with meaningful regression coverage and measured effects |
| C3: comparative validation | Fulfillment, first-content timing, model/hardware regressions, rollout/rollback criteria | C2 plus trustworthy A2/A3 metrics | Predeclared decision criteria evaluated; no unsupported success claim |

Each future implementation PR names one unit and links its parent issue. Split C2 further by independently established discrepancy when necessary. A2 owns outcome recording; #844 owns new refusal-evidence scoping; C2 owns estimator behavior. Agents should coordinate across those boundaries rather than editing the same schema or producer in parallel.

The planning PR references the issues without closing them. The issue checklists remain open until their implementation and validation criteria are met. Future feature-branch pushes, merges, provider releases, and production changes follow the applicable repository and environment rules.

## Evidence and related work

Code was reviewed against the stamped revision. The existing source and the following pages are evidence for current behavior; the proposed vocabulary above is not yet implemented.

| Concern | Source |
|---|---|
| Final rejection resolution and timeout transitions | [`coordinator/api/dispatch.go`](../../coordinator/api/dispatch.go), `resolveDominantExhaustedStatus`, `classifyExhaustedStatus`, `run` |
| Attempt terminal classification and completion | [`coordinator/api/route_outcome.go`](../../coordinator/api/route_outcome.go), `preCommitProviderErrorOutcome`, `completeRouteOutcome` |
| Profile client outcome and egress evidence | [`coordinator/api/profiler_dispatch.go`](../../coordinator/api/profiler_dispatch.go), `finalizeProfile`, `writeNonStreamBody`, `relayStamps.done` |
| Existing online calibration | [`coordinator/registry/ttft_calibration.go`](../../coordinator/registry/ttft_calibration.go), `ttftCalibrator`, `calibratedTTFTMs` |
| Provider admission policy | [`provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge.swift`](../../provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge.swift), `firstTokenDeadlineAdmission` |
| Existing outcome and profile architecture | [`request-outcome-observability.md`](../architecture/request-outcome-observability.md), [`system-profiler.md`](../architecture/system-profiler.md) |
| Future docs obligations | [`docs/AGENTS.md`](../AGENTS.md), change-to-document map |

Review related work before implementing: [#755](https://github.com/Layr-Labs/d-inference/pull/755) proposes additional calibration telemetry; [#835](https://github.com/Layr-Labs/d-inference/pull/835) addresses Responses instructions and prompt estimates; [#720](https://github.com/Layr-Labs/d-inference/issues/720) investigates decode sample validity; [#841](https://github.com/Layr-Labs/d-inference/issues/841) addresses coordinator scan saturation. Their status and overlap must be checked at implementation time, and unmerged changes must not be assumed available.

## Planning validation

Review the two issue drafts together for consistent terminology, no duplicated ownership, independently assignable sub-PRs, source-backed claims, and honest unknowns. Run documentation checks on this record and its index. Application tests and live experiments belong to subsequent implementation PRs, not this documentation-only change.
