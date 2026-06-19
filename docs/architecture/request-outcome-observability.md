# Request Outcome Observability

**Status:** Plan (Phase 4 partially implemented — see "Implemented (DAR-332)")
**Scope:** Coordinator inference request outcomes for `/v1/chat/completions`, `/v1/responses`, `/v1/completions`, and `/v1/messages`.
**Related:** [routing-telemetry-and-calibration.md](routing-telemetry-and-calibration.md), [operations/telemetry.md](operations/telemetry.md), [operations/billing.md](operations/billing.md).

## Goal

The coordinator needs one observable outcome model for each inference request that does not collapse client delivery, provider execution, and billing settlement into a single flag.

The model must answer three separate questions:

| Dimension | Question | Examples |
|---|---|---|
| `client_outcome` | What happened to the HTTP client connection and response? | Completed response, partial stream, client disconnected before commit, client disconnected after commit, error response, timeout response. |
| `provider_outcome` | What happened to the provider job after dispatch? | Completed, provider error, provider disconnect, first chunk timeout, accepted timeout, coordinator cancel, no terminal. |
| `billing_outcome` | What happened to reservation, charge, refund, and payout settlement? | Charged, refunded, zero-cost self-route, uncollected zeroed, no-terminal refund, post-terminal sweep refund. |

`final_status` remains the compact query field for route and dashboard rollups, but it must be derived from the three dimensions above rather than treated as the whole truth.

## Current Ground Truth

| Area | Current code path | Current behavior and gap |
|---|---|---|
| Route row writes | `coordinator/api/dispatch.go` (`recordRoutingDecision`, `updateRoutingOutcome`) | Chat-completions dispatch writes a route row and later updates it best-effort. The first committed chunk currently records `final_status = success`, which can be wrong after a later provider terminal or client disconnect. |
| Route storage | `coordinator/store/interface.go` (`InferenceRouteRecord`, `InferenceRouteOutcome`), `coordinator/store/postgres.go` (`inference_routes`, `UpdateInferenceRouteOutcome`, `InferenceRouteRecordsSince`) | Postgres has final outcome columns, and `UpdateInferenceRouteOutcome` writes them. `InferenceRouteRecord` does not expose those fields, and the Postgres reader scans newer outcome fields into local variables instead of returning them. The memory store keeps outcomes separately but `InferenceRouteRecordsSince` returns only the base route record. |
| Admin reads and exports | `coordinator/api/admin_telemetry.go` (`handleAdminRoutes`, `handleAdminRoutesExport`, `routeCSVHeader`) | Admin JSON and CSV/NDJSON exports expose routing-decision metadata, not the final outcome columns. Operators cannot filter or export by `final_status`, `error_class`, token counts, timing decomposition, or backup/admission outcome flags. |
| Provider terminals | `coordinator/api/provider.go` (`handleComplete`, `handleInferenceError`) | Provider completion settles billing and writes success outcome data. Provider errors can refund or penalize reputation, but post-commit and consumer-gone cases are not consistently reflected as request outcomes. |
| Client response relay | `coordinator/api/consumer.go` (`handleStreamingResponseWithFirstChunk`, `handleResponsesStreamingResponseWithFirstChunk`, `handleNonStreamingResponseWithFirstChunk`) | The relay can emit in-band provider errors, stream timeouts, or return on `r.Context().Done()` after response commit. These are client outcomes, but route final status can remain the earlier success written at commit time. |
| Settlement after disconnect | `coordinator/api/settlement.go` (`holdForSettlement`, `claimSettlement`) | A post-commit client disconnect is parked so a late provider terminal can charge or refund correctly. Billing is handled, but the disconnect is not visible as a request outcome class such as `client_gone_after_commit_provider_completed` or `no_terminal_after_cancel`. |
| Provider disconnect cleanup | `coordinator/registry/registry.go` (`Disconnect`) | Disconnect injects a provider error into pending requests and closes channels. The flow should classify pre-commit vs post-commit disconnects rather than letting a prewritten success stand. |
| Generic endpoints | `coordinator/api/consumer.go` (`handleGenericInference`, `handleCompletions`, `handleAnthropicMessages`) | `/v1/completions` and `/v1/messages` use a direct single-attempt flow and do not call `recordRoutingDecision`, so they lack `inference_routes` rows and final outcome updates. |
| Speculative backup dispatch | `coordinator/api/dispatch.go` (`runSpeculative`, `runRace`) | The primary route row is recorded by `dispatchPrimary`. A speculative backup can win and swap `d.requestID` to the backup job, but that backup can lack its own route row, making the final outcome update a no-op for the winning job. |
| Provider aggregate stats | `coordinator/registry/reputation.go`, `coordinator/registry/registry.go` (`RecordJobSuccess`, `RecordJobFailure`), `coordinator/api/stats.go` | Provider aggregates track success/failure and latency but not client cancellations, post-commit drops, no-terminal-after-cancel, or disconnect counters. Client behavior and provider faults need separate counters. |
| Rejection ledger | `coordinator/api/rejection_telemetry.go`, `coordinator/api/consumer.go`, `coordinator/api/server.go` rate-limit helpers | The rejection ledger is partially wired for inference validation, balance, and capacity exits. Some middleware and helper exits still return errors before full request-shape and servability metadata can be recorded. |

## Outcome Taxonomy

`final_status` is a derived summary with these target values:

| `final_status` | Use when | Typical `error_class` |
|---|---|---|
| `success` | The client received a complete successful response, the provider completed, and billing reached a terminal settlement. | Empty. |
| `partial_success` | The response was committed and at least some output may have reached the client, but the stream or client connection did not end cleanly. Post-commit client disconnects live here because partial output already reached the client; billing/refund details are captured separately. | `provider_error_after_commit`, `provider_disconnect_after_commit`, `stream_timeout_after_commit`, `client_gone_after_commit_provider_completed`, `client_gone_after_commit_provider_error`, `no_terminal_after_cancel`. |
| `cancelled` | The client connection was cancelled before response commit, or the provider reported cancellation before visible output. | `client_gone_pre_commit`, `provider_cancelled_pre_commit`. |
| `error` | No successful response was completed because a provider or coordinator error won before a timeout class applied. | `provider_error_pre_commit`, `encryption_missing`, `provider_send_failed`, `provider_disconnect_pre_commit`. |
| `timeout` | No successful response was completed before a coordinator deadline. | `queue_timeout`, `first_chunk_timeout`, `accepted_timeout`, `preamble_liveness_timeout`. |

`error_class` values must be stable enums, not raw provider messages. Provider messages can stay in logs, but not in metadata exports unless scrubbed and explicitly allowed.

| `error_class` | Meaning | Primary code paths to update |
|---|---|---|
| `client_gone_pre_commit` | Client disconnected before headers or first useful response committed. | `dispatch.go` first-chunk and accepted wait `r.Context().Done()` arms; `handleGenericInference` pre-commit waits. |
| `client_gone_after_commit_provider_completed` | Client disconnected after response commit; provider later completed and billing settled from the parked record. | `consumer.go` relay return on `r.Context().Done()`, `settlement.go`, `provider.go` `handleComplete`. |
| `client_gone_after_commit_provider_error` | Client disconnected after response commit; provider later returned an error and the reservation was refunded or finalized as zero. | `settlement.go`, `provider.go` `handleInferenceError`. |
| `no_terminal_after_cancel` | Client disconnected after commit and no provider terminal arrived before the settlement grace expired. | `settlement.go` `holdForSettlement` expiry callback. |
| `provider_error_after_commit` | Provider returned an error after the coordinator had already committed the response. | `consumer.go` streaming and non-streaming relay error arms. |
| `provider_disconnect_after_commit` | Provider disconnected after response commit and before a clean completion. | `registry.go` `Disconnect`, then relay/provider terminal handling. |
| `stream_timeout_after_commit` | The coordinator committed a stream but the idle stream timer expired before a clean terminal. | `consumer.go` streaming relay timer arms. |
| `queue_timeout` | Request entered the coordinator queue but did not receive a provider before queue timeout. | `dispatch.go` queued path; generic queue path in `consumer.go`. |
| `first_chunk_timeout` | Provider was dispatched but produced no first useful content before the TTFT deadline. | `dispatch.go` `waitFirstChunk` and speculative wait helpers; `handleGenericInference` initial wait. |
| `accepted_timeout` | Provider accepted the job or cold load but did not produce first content before the accepted wait deadline. | `dispatch.go` `waitAccepted`; `handleGenericInference` accepted wait. |
| `preamble_liveness_timeout` | Provider produced only preamble or role/lifecycle chunks, then stalled before first useful content. | `dispatch.go` preamble-liveness branches. |

The route row should also persist the raw dimensions that explain the summary:

| Field | Purpose |
|---|---|
| `client_outcome` | Client-visible terminal state independent of provider and billing. |
| `provider_outcome` | Provider terminal state independent of client connection state. |
| `billing_outcome` | Settlement result independent of client and provider status. |
| `response_committed` | Whether headers or stream content were committed before the terminal outcome. |
| `terminal_source` | Which subsystem produced the final transition: `client`, `provider`, `coordinator_timeout`, `settlement_grace`, `disconnect_cleanup`, `billing`. |
| `endpoint` | The surface that received the request, so generic endpoints are not indistinguishable from chat completions. |
| `client_request_id` | Stable HTTP request correlation ID from middleware, distinct from provider job IDs used by retry and backup attempts. |
| `provider_request_id` | Provider job ID for the dispatched attempt. This is the current `PendingRequest.RequestID` used by route rows. |

## Privacy Invariants

This is metadata-only observability.

| Data class | Rule |
|---|---|
| Prompt and response content | Never store prompts, messages, completions, tool arguments, image bytes, audio bytes, embeddings, or raw SSE chunks. |
| Client identity | Store API key hashes via `store.HashKey`, key IDs, account IDs only where already used for billing/admin attribution, and coarse client class. Do not store raw API keys. |
| Network identity | Do not store raw client IPs. Use the existing coarse request location model where needed, subject to aggregation/privacy floors in `coordinator/api/stats.go`. |
| Provider messages | Store stable `error_class` and HTTP-like status code. Keep raw provider error text in operational logs only unless a scrubbed allowlist is added. |
| Media | Store only booleans and counts such as `requires_vision`, `has_image`, `has_audio`, and request body byte size. Do not store image/audio bytes. |
| Timing and billing | Timings, token counts, cost in micro-USD, refund/charge outcome, and provider model/version metadata are allowed. |

## Implementation Phases

| Phase | Deliverable | Notes |
|---|---|---|
| 1. Expose and correct route outcomes | Add final outcome fields to `InferenceRouteRecord`, memory/Postgres readers, admin JSON, CSV/NDJSON exports, and route filters. Correct `final_status` derivation so post-commit failures no longer remain `success`. | Keep writes best-effort through `submitTelemetry`. Add filters for `final_status`, `error_class`, `client_outcome`, `provider_outcome`, and `billing_outcome`. |
| 2. Post-commit and settlement updates | Update route outcomes from relay, provider terminal, disconnect, and settlement-grace paths. | `handleComplete`, `handleInferenceError`, relay timeout/error arms, `holdForSettlement` expiry, and post-terminal sweep need explicit outcome updates. Billing settlement should set `billing_outcome` even when the client is gone. |
| 3. Generic endpoint route rows | Add route rows and outcome updates to `/v1/completions` and `/v1/messages`. | Extract a small route-recorder helper from `dispatchState` or build a shared function that records direct single-attempt dispatch decisions without requiring the full chat retry orchestrator. |
| 4. Provider aggregate counters | Add provider counters for completed, provider_error, timeout, disconnect, client_cancel_pre_commit, client_cancel_after_commit, no_terminal_after_cancel, and dropped_unknown_terminal. | Do not fold client cancellations into provider failure reputation. Export counters through admin/provider stats and Datadog tags for fleet health dashboards. **Partially implemented (DAR-332):** the completed-after-disconnect split (`inference.partial_success`, `inference.no_terminal_after_cancel`) is emitted, and client cancellations are counted by lifecycle phase on `routing.client_gone{phase}` — see "Implemented (DAR-332)" below. |
| 5. Broader rejection ledger and dashboards | Cover auth, RPM/token rate limits, sealed transport, generic dispatch fail-fast exits, and queue exits with `RecordRejection`. Add dashboards for final status, error class, false rejections, and settlement outcomes. | `request_rejections` should remain a rejection ledger, not a replacement for route outcome rows. A rejected request that never dispatches has no provider outcome. |
| 6. Optional request event table | Add an append-only `request_events` table if point-in-time reconstruction is needed after the summary model is stable. | Events would include `http_received`, `route_selected`, `provider_dispatched`, `response_committed`, `client_gone`, `provider_complete`, `provider_error`, `provider_disconnect`, `billing_settled`, and `billing_refunded`. This is optional and should not block the summary columns. |

## Phase Details

### 1. Expose and Correct Route Outcomes

The immediate fix is to make the fields already written by `UpdateInferenceRouteOutcome` visible to operators.

Required changes:

| Change | Reason |
|---|---|
| Add `final_status`, `error_code`, `error_class`, token counts, cost, timing decomposition, `actual_decode_tps`, `admitted_but_failed`, `used_backup`, and `backup_won` to `InferenceRouteRecord`. | Admin reads currently return only the decision snapshot. |
| Update `MemoryStore.InferenceRouteRecordsSince` to merge stored `InferenceRouteOutcome` into returned records. | Memory behavior should match Postgres for local/dev analysis. |
| Update `PostgresStore.InferenceRouteRecordsSince` to scan outcome columns into the returned record. | The columns exist but are not exposed. |
| Update `routeCSVHeader`, `routeCSVRow`, and admin JSON filters. | Exports need the same fields analysts see in JSON. |
| Add endpoint and request correlation fields. | Route rows must distinguish chat, responses, completions, and messages, and must group retry/backup attempts under one client request. |

Correctness changes should treat response commit as a transition, not as final success. `successRoutingOutcome` in `dispatch.go` can mark a provisional committed state, but the terminal provider/client/billing path must be able to replace it with `partial_success`, `cancelled`, `error`, or `timeout` when later evidence arrives.

### 2. Post-Commit and Settlement Outcome Updates

Post-commit paths need explicit terminal writes:

| Path | Desired outcome update |
|---|---|
| Provider completes after client stayed connected | `client_outcome = completed`, `provider_outcome = completed`, `billing_outcome = charged` or `zero_cost`, `final_status = success`. |
| Provider completes after client disconnected post-commit | `client_outcome = cancelled_after_commit`, `provider_outcome = completed`, `billing_outcome = charged` or `zero_cost`, `final_status = partial_success`, `error_class = client_gone_after_commit_provider_completed`. |
| Provider errors after client disconnected post-commit | `client_outcome = cancelled_after_commit`, `provider_outcome = error`, `billing_outcome = refunded`, `final_status = partial_success`, `error_class = client_gone_after_commit_provider_error`. |
| No provider terminal after post-commit disconnect | `client_outcome = cancelled_after_commit`, `provider_outcome = no_terminal`, `billing_outcome = refunded`, `final_status = partial_success`, `error_class = no_terminal_after_cancel`. |
| Provider errors while client is still connected after commit | `client_outcome = partial`, `provider_outcome = error`, `billing_outcome = refunded`, `final_status = partial_success`, `error_class = provider_error_after_commit`. |
| Provider disconnects after commit | `client_outcome = partial` or `cancelled_after_commit` depending on client state, `provider_outcome = disconnect`, `final_status = partial_success`, `error_class = provider_disconnect_after_commit`. |
| Relay idle timeout after commit | `client_outcome = partial`, `provider_outcome = timeout`, `billing_outcome = refunded`, `final_status = partial_success`, `error_class = stream_timeout_after_commit`. |

The update should be idempotent. Provider terminal handling, settlement grace, and post-terminal sweep can race, so the route-outcome writer should only advance to a more specific terminal state or use a compare-and-set style update keyed by `request_id`, `attempt`, and terminal precedence.

### 3. Generic Endpoint Route Rows

`handleGenericInference` should record the same route-attempt metadata as chat-completions:

| Requirement | Detail |
|---|---|
| One row per provider dispatch attempt | Include the selected provider snapshot, scheduler decision, request shape, endpoint, and client/provider request IDs. |
| Queue rows | If the generic path queues, record `outcome = queued` and later update final status. |
| Fail-fast route outcomes | TTFT, model-too-large, queue timeout, no-provider, encryption, provider send, and provider reservation exits should record a rejection row and, when a provider was selected, a route outcome. |
| Shared response terminal updates | The existing streaming/non-streaming relay helpers should update outcome rows regardless of endpoint. |

This avoids calibrating routing only on `/v1/chat/completions` while missing `/v1/completions` and `/v1/messages` traffic.

### 4. Provider Aggregate Counters

Provider aggregates should not rely only on reputation success/failure.

Required counters:

| Counter | Provider fault? | Purpose |
|---|---|---|
| `completed` | No fault | Successful terminal from provider. |
| `provider_error` | Yes, except known capacity/client-cancel classes | Provider returned an error terminal. |
| `provider_timeout` | Usually yes | Provider accepted or was dispatched but did not produce required content in time. |
| `provider_disconnect` | Usually yes | Provider connection dropped with pending work. |
| `client_cancel_pre_commit` | No | Client disconnected before response commit. |
| `client_cancel_after_commit` | No | Client disconnected after response commit. |
| `no_terminal_after_cancel` | Ambiguous | Provider did not send terminal within settlement grace after client cancel. Useful for drop detection but not automatically reputation-faulting. |
| `dropped_unknown_terminal` | Ambiguous | Provider sent a terminal for an unknown request or after the holder expired. |

Reputation should continue to penalize provider-at-fault classes only. Aggregate counters should still expose non-fault cancellations and drops so operator dashboards can distinguish client churn, provider instability, and coordinator cleanup behavior.

#### Implemented (DAR-332): completed-after-disconnect metric split

The first slice of this phase is built. A request that the provider COMPLETES after
the consumer disconnected post-commit is billed and credited identically to a clean
success (provider paid, consumer charged, **not** a provider failure), so it was
previously indistinguishable on dashboards — both emitted only
`d_inference.inference.completions{model}`. The following DogStatsD counters now
make the class observable. All go through the existing `ddIncr` wrapper (no-op when
Datadog is unconfigured) and are emitted in addition to — never instead of — the
unchanged `inference.completions` counter, so existing dashboards keep working.

| Metric | Tags | Emitted from | Meaning |
|---|---|---|---|
| `d_inference.inference.partial_success` | `model`, `error_class` | `api/provider.go` `handleComplete` (when `consumerGone`) | Provider completed and billing settled, but the consumer had already disconnected after commit. `error_class` = `client_gone_after_commit_provider_completed`. Subset of `inference.completions`. |
| `d_inference.routing.client_gone` | `model`, `prompt_bucket`, `chip_family`, `phase` | `phase=before_first_token`: pre-commit client-gone arms in `api/dispatch.go` / `api/consumer.go`; `phase=after_commit`: `api/provider.go` `handleComplete` and `handleInferenceError`, plus the `api/settlement.go` grace-expiry callback | The single client-gone counter. Counts every client disconnect split by lifecycle phase (before vs after the first content token), prompt-size bucket, and provider chip family. Each request emits at most one (exactly one terminal). |
| `d_inference.inference.no_terminal_after_cancel` | `model` | `api/settlement.go` `holdForSettlement` grace-expiry callback | Payout-gap edge: a post-commit disconnect whose settlement grace expired with no provider terminal. The reservation is refunded and the provider is never paid. |

The composed money/reputation/outcome invariant is pinned by regression tests in
`api/settlement_clientgone_test.go` (provider payout credited, consumer charged
exactly the actual cost, `RecordJobSuccess` with `FailedJobs == 0`, and route
`final_status = partial_success` / `error_class = client_gone_after_commit_provider_completed`),
plus the exactly-once boundary (a late terminal after grace-expiry refund is a no-op).
The `before_first_token` client-cancellation emit and the per-provider aggregate
counters in the table above remain unbuilt.

### 5. Rejection Ledger and Dashboards

`request_rejections` answers "what did we say no to before dispatch?" Route outcomes answer "what happened after a route attempt existed?" Both are required.

Coverage gaps to close:

| Exit | Desired rejection record |
|---|---|
| Auth failures on inference paths | `stage = auth`, reason such as `missing_credentials`, `invalid_api_key`, or `forbidden`. Store no body content. |
| Account and key RPM limits | `stage = rate_limit`, `limit_kind = rpm`, `retry_after_ms`, `over_by` when known. |
| Account and key token limits | `stage = rate_limit`, `limit_kind = itpm` or `otpm`, estimated token shape, `retry_after_ms`. |
| Sealed transport/body decode failures | `stage = validation` or `transport`, reason such as `malformed_json`, `payload_too_large`, or `sealed_transport_error`. |
| Generic dispatch fail-fast exits | Same reason codes as chat path: `model_too_large`, `machine_busy`, `no_provider`, `ttft_too_slow`, `queue_timeout`. |
| Provider-price reservation failures before dispatch | `stage = balance`, `reason_code = insufficient_funds_provider_price`, with shortfall when available. |

Dashboards should start from low-cardinality tags and metadata:

| Dashboard | Group by |
|---|---|
| Request final status | endpoint, model, final_status, error_class. |
| Post-commit failures | provider_id, model, provider_version, error_class. |
| Client cancellations | endpoint, model, pre/post commit, client_class. |
| Billing settlement outcomes | model, billing_outcome, service/self-route mode. |
| Provider reliability | provider_id, model, completed/error/timeout/disconnect/cancel counters. |
| Rejection ledger | stage, reason_code, could_have_served, model, client_class. |

### 6. Optional Append-Only Events

Do not start with an event table. Summary columns and dashboards should solve the immediate gaps with less storage and less query complexity.

Add `request_events` later only if operators need exact timeline replay or forensic reconstruction. If added, events must remain metadata-only and keyed by both client-level request correlation and provider attempt ID.

## Acceptance Criteria

| Criterion | Verification |
|---|---|
| Admin route reads expose final outcome fields. | `GET /v1/admin/routes` includes `final_status`, `error_class`, client/provider/billing outcomes, tokens, cost, and timing fields. |
| Route exports include final outcome fields. | `GET /v1/admin/routes/export?format=csv` and `format=ndjson` contain the same outcome fields as JSON. |
| Post-commit provider errors no longer look like success. | A stream that commits and then receives provider error records `partial_success` with `provider_error_after_commit`. |
| Post-commit client disconnects are visible. | A parked settlement completion records `partial_success` with `client_gone_after_commit_provider_completed`; a grace expiry records `partial_success` with `no_terminal_after_cancel`. |
| Generic endpoints are represented. | `/v1/completions` and `/v1/messages` produce route rows and terminal outcome updates. |
| Backup winners have rows. | A speculative backup winner has a route row with `used_backup = true` and `backup_won = true`. |
| Provider counters separate faults from client behavior. | Client cancellations increment cancellation counters but do not increment provider failure reputation. |
| Rejection ledger covers all inference exits before dispatch. | Auth, rate-limit, validation, balance, model, preflight, TTFT, and queue exits are queryable with `could_have_served` where meaningful. |
| Privacy invariants hold. | No exported row contains prompt text, response text, raw IP, raw user agent, image/audio bytes, or raw API keys. |
