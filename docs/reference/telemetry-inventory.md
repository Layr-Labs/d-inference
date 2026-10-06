# Telemetry inventory

> Last updated: 2026-10-06

Every datum the system collects today, with its producer, sink, cadence and
retention. Anything not on this page is not emitted by the code at this commit.
The wire shape of each field is in [`protocol-messages.md`](protocol-messages.md);
the event contract is in [`telemetry-schema.md`](telemetry-schema.md); the
design and failure modes are in [`../architecture/telemetry.md`](../architecture/telemetry.md).

## What is live and what is not

| Path | State |
|---|---|
| Provider heartbeat → registry → Datadog gauges/counters | live; the only provider-diagnostic channel |
| Coordinator-emitted telemetry events → slog + in-process counter + Datadog Logs API | live |
| Per-request rows (`inference_routes`, `request_rejections`, `usage`, `request_profiles`) and 60 s `fleet_snapshots` | live |
| DogStatsD / HTTPS series metrics from request handling, routing, billing, cache | live |
| Provider or console client telemetry events (`POST /v1/telemetry/events`) | retired — the coordinator route is gone (404) ([retired paths](#retired-paths-that-emit-nothing)); provider and console facades are no-ops |
| `telemetry_events` table | removed |
| Datadog APM spans | tracer is started (`ddtracer.Start`) but no code creates spans; `dd.trace_id`/`dd.span_id` therefore never appear in logs |

## Provider → coordinator

Producer: the Swift provider over the `GET /ws/provider` WebSocket. Consumer:
`providerReadLoop` (`coordinator/api/provider/session.go`).

| Datum | Message | Cadence | Coordinator sink | Retention |
|---|---|---|---|---|
| `hardware`, `models[]`, `backend`, `version`, hashes, capabilities | `register` | once per connection | registry `Provider` (memory); `providers` row via `UpsertProvider`; `providers.registrations{trust_level}` counter; `provider registered` event | `providers` grows unbounded |
| `status`, `active_model`, `warm_models` | `heartbeat` | baseline every `heartbeat_interval_secs` ([`../provider/cli-reference.md`](../provider/cli-reference.md#providertoml-keys-read-by-the-cli)); event heartbeats when capacity changes materially (slot roster/state/`num_running`/`num_waiting`, or token shift ≥ 1024 or ≥ 10 %), coalesced to one per 500 ms (`CapacityHeartbeatThrottle`, `provider-swift/Sources/ProviderCore/CapacityEventHeartbeats.swift`) | registry `Provider` (memory) | until disconnect |
| `stats.*` (cumulative counters) | `heartbeat` | same | `Registry.Heartbeat` delta-merges into `Provider.Stats`; `provider_reputation` via `UpsertReputation` | persisted at most every 30 s per provider (`PersistProviderThrottled`, `coordinator/registry/persistence.go`); unbounded |
| `system_metrics` (`memory_pressure`, `cpu_usage`, `thermal_state`) | `heartbeat` | same; collected at send time by `SystemMetricsCollector` (`provider-swift/Sources/ProviderCore/Hardware/SystemMetrics.swift`) | registry, clamped to `[0, 1]`; `thermal_state` folded by `ThermalStateFold` for gates and `fleet_snapshots` | memory; `fleet_snapshots` retention ([below](#coordinator-per-request-records-postgres)) |
| `backend_capacity` (`slots[]`, GPU memory, `free_for_load_gb`, `capacity_seq`, `mlx_cache_reclaimer`) | `heartbeat` | same; the provider recomputes capacity every `max(1, heartbeat_interval_secs / 2)` s, integer division (`capacityRefreshTick`, `provider-swift/Sources/ProviderCore/ProviderLoop+Capacity.swift`) | `canonicalHeartbeatModelState` clones then `clampBackendCapacity` (`coordinator/registry/heartbeat.go`); stale `capacity_seq` frames update only `LastHeartbeat` | memory; sampled into `fleet_snapshots` |
| `slots[].telemetry`, `backend_capacity.telemetry` | `heartbeat` | same | clamped by `clampBackendCapacity`; sampled into `fleet_snapshots` | `fleet_snapshots` retention ([below](#coordinator-per-request-records-postgres)) |
| `slots[]` engine-health fields (`steps_executed`, `admits`, `wedge_suspected`, `eval_in_flight_ms`, …) | `heartbeat` | same | `recordBackendWedgeTelemetry` (`coordinator/internal/provider/heartbeat/provider_wedge_telemetry.go`) → Datadog counters; measurement only, never a gate | Datadog |
| `slots[].prefix_cache`, `prefix_cache_maintenance` | `heartbeat` | Cached per-store observation at the configured stats interval; age and process maintenance counters refreshed with capacity | `recordPrefixCacheTelemetry` (`coordinator/internal/provider/heartbeat/provider_prefix_cache_telemetry.go`), after registry clone/clamp and capacity-sequence acceptance | live registry baseline and Datadog; no prompt/cache identities |
| `slots[].paged_storage` | `heartbeat` | `PagedKVPool.segmentStorageSnapshot` on the engine queue; `PagedStorageTelemetryAdapter` preserves capture sequence/time through heartbeat polling | `recordPagedStorageTelemetry` (`coordinator/internal/provider/heartbeat/provider_paged_storage_telemetry.go`), after registry clone/clamp and sample freshness reconciliation | live registry baseline and Datadog; no admission changes or new Postgres columns |
| `backend_capacity.telemetry.process_memory` | `heartbeat` | `ProcessMemoryTelemetrySampler` at coherent provider capacity refresh; heartbeat stamps preserve capture sequence and age | `recordProcessMemoryTelemetry` (`coordinator/internal/provider/heartbeat/provider_process_memory_telemetry.go`) after accepted registry replacement and freshness reconciliation | live registry baseline and Datadog; no routing authority or new Postgres columns |
| GPU memory and `mlx_cache_reclaimer` | `heartbeat` | same | `recordMLXCacheTelemetry` (`coordinator/internal/provider/heartbeat/provider_mlx_cache_telemetry.go`) → histograms (DogStatsD-only) or latest-value gauges (HTTPS), and counter deltas tagged `chip_family`, `provider_version` | Datadog |
| `prefix_cache_statuses`, `prefix_cache_donation_outcomes`, `prefix_cache_v2_models` | `register`, `heartbeat` | same | registry exact-cache state; `exact_cache.*` gauges; `routing.cache_telemetry_rejected{source:heartbeat}` on validation failure. `prefix_cache_donation_outcomes` aggregates 24 known outcomes including `skipped_novel` and `write_speculative_limited` (first-sight checkpoints that yielded to write-budget, writer or disk pressure; like every donation outcome it is a public fleet-wide total on the unauthenticated `GET /v1/cache/status`, with no provider, model or account; `write_priority_limited`, `write_rate_limited` and `write_queue_full` no longer include first-sight offers) (`PrefixCacheDonationOutcomes`, `coordinator/registry/cache_eligibility.go`); unknown future outcomes are dropped entry-wise | memory |
| `apns_device_token`, `apns_environment` | `register`, `heartbeat` | when changed | code-attestation re-arm (`MaybeRearmCodeAttest`) | memory |
| `usage`, `stop_sequence`, `response_hash`, `se_signature` | `inference_complete` | per attempt | `handleComplete` → `inference_routes` outcome columns, `usage` row, billing; `inference.completions`, `inference.ttft_ms`, `inference.decode_tps` | `inference_routes`/`usage` unbounded |
| `error`, `status_code`, `error_reason`, `failure_code`, `terminal_cause`, `attempt_usage`, capacity fields | `inference_error` | per failed attempt | `sanitizeProviderInferenceError` then `HandleInferenceError` → route outcome, `inference.typed_terminal{cause}`, `inference.typed_terminal_unknown_cause`, `inference.invalid_failure_code`; classification in [`../architecture/request-outcome-observability.md`](../architecture/request-outcome-observability.md) | `inference_routes` unbounded |
| `profile` (on both terminals) | `inference_complete`, `inference_error` | per attempt, ≤ `MaxInferenceProfileBytes` ([`protocol-messages.md#inference_complete`](protocol-messages.md#inference_complete)) | raw bytes retained on the attempt, decoded on the profile-sink worker → `request_profiles`; `profiler.provider_profile{valid, reason}` | `request_profiles` retention ([below](#coordinator-per-request-records-postgres)) |
| `cache_stage_ms` and prefix-cache receipts | `inference_complete.usage`, `prefix_cache_lookup*`, `prefix_cache_ready*` | per attempt | `routing.cache_stage_ms`, `routing.cache_lookup_receipt`, `routing.cache_ready_receipt`, `routing.cache_receipt_rejected`, `exact_cache.*`. A receipt mismatch opens or escalates a proof fence, reported by the gauges `exact_cache.fence` tagged `event:applied` or `event:expired` and `exact_cache.fenced_capabilities` (Prometheus `exact_cache_fence{event}`, `exact_cache_fenced_capabilities`; `EmitExactCacheDDGauges`, `coordinator/api/inference/exact_cache_metrics.go`). Holder removals are `exact_cache.holder_removed` tagged `reason`, including `reason:shorter_hit` for a hit below a recorded boundary (Prometheus `exact_cache_holder_removed{reason}`). The observed-demand index reports `exact_cache.demand_entries` and `exact_cache.demand_cap_evictions` (Prometheus `exact_cache_demand_entries`, `exact_cache_demand_cap_evictions`) | Datadog |
| `capacity_quote` | reply to `capacity_probe` | per probed request, within `capacityProbeWindow` ([`../architecture/routing.md#entry-points`](../architecture/routing.md#entry-points)) | `Registry.HandleCapacityQuote` — ledger drift correction | memory |
| Disconnect | WebSocket close / read error | per session | `ws.disconnects{reason:peer_close, code}` or `{reason:read_error|read_error_control_frame}`; `provider.oom_suspected` when `ClassifyDisconnectReason` (`coordinator/registry/disconnect_classify.go`) sees `memory_pressure ≥ 0.90`, or `≥ 0.80` with in-flight work; `provider_sessions.disconnect_reason` via `CloseProviderSession` (`coordinator_shutdown` when the coordinator itself closed the socket for shutdown, or processed the registration after that close began; `oom_suspected`, `ws_close_<code>`, `read_error`, `read_error_control_frame`, sweep default `disconnect`) | `provider_sessions` unbounded |
| `darkbloom report` log bundle | `POST /v1/provider/log-report` (`HandleUploadLogReport`, `coordinator/api/operations/log_reports.go`) | operator-initiated | `provider_log_reports`, ≤ 10 MiB (`maxLogReportBodySize`); `?serial` → `426` | unbounded |

Fields the v0.8.16 provider declares but never populates: `register.prefill_tps`
/ `decode_tps`, `slots[].queued_token_budget` (hard-coded 0),
`slots[].idle_clear_in_flight_ms`.

## Coordinator-derived Datadog metrics

All names carry the `d_inference.` namespace and the constant tags `env:`
(`DD_ENV`) and `service:` (`DD_SERVICE`; defaults in
[`configuration.md#telemetry-datadog-and-profiling`](configuration.md#telemetry-datadog-and-profiling)).
Transport and fallback rules:
[`../architecture/telemetry.md#mechanism`](../architecture/telemetry.md#mechanism).
This table covers the metrics that derive from provider telemetry, request
outcomes and the telemetry pipeline itself; billing, exact-cache, MDM and
rate-limit families are emitted from their own subsystems (`rg 'dd(Incr|Count|Gauge|Histogram)\(' coordinator/api`
lists every name).

### From provider heartbeats and sessions

| Metric | Type | Tags | Emitted |
|---|---|---|---|
| `provider.mlx_memory.active_gb`, `.peak_gb`, `.cache_gb` | histogram (DogStatsD-only) / latest-value gauge (HTTPS) | `chip_family`, `provider_version` | accepted heartbeat snapshot (`coordinator/internal/provider/heartbeat/provider_mlx_cache_telemetry.go`, `recordMLXCacheTelemetry`) |
| `provider.mlx_cache.limit_bytes`, `.last_reclaimed_bytes`, `.last_reclaim_duration_ms` | histogram (DogStatsD-only) / latest-value gauge (HTTPS) | `chip_family`, `provider_version` | limit each accepted heartbeat; last-reclaim samples only when reclaim count increases (`recordMLXCacheTelemetry`) |
| `provider.mlx_cache.sweep_signals`, `.reclaims`, `.reclaimed_bytes` | count | `chip_family`, `provider_version` | positive deltas from the previous accepted snapshot; first observation/reset contributes no delta (`ddCountDelta`) |
| `provider.prefix_cache.sample_age_ms`, `.sample_fresh` | histogram (DogStatsD-only) / latest-value gauge (HTTPS) | `chip_family`, `provider_version`, `cache_kind` | Every accepted instrumented slot heartbeat; fresh means age ≤ five minutes (`recordPrefixCacheTelemetry`) |
| `provider.prefix_cache.entries`, `.disk_bytes`, `.staging_bytes`, `.staging_peak_bytes` | histogram (DogStatsD-only) / latest-value gauge (HTTPS) | same | A new fresh store observation; peak is complete-store only |
| `provider.prefix_cache.stages`, `.files_written`, `.written_bytes`, `.donation_drops`, `.corrupt_drops`, `.evictions`, `.ttl_expired`, `.recurrent_capture_disarmed_packed` | count | same | Positive store-lifetime counter deltas; first observation/reload/reset/missing baseline contributes no count (`recordPrefixCacheTelemetry`). Complete `.donation_drops` covers queued-write `writesDropped`, while prequeue refusals use donation outcome telemetry |
| `provider.prefix_cache.files_read`, `.read_bytes`, `.stage_read_bytes`, `.donation_read_bytes`, `.stage_duration_us`, `.write_duration_us` | count | same | Complete-store deltas only; duration counters sum elapsed microseconds, never request-latency distributions |
| `provider.prefix_cache.sweep.ttl_expired`, `.budget_evicted`, `.temp_removed` | count | `chip_family`, `provider_version` | Whole-root maintenance deltas across all models, including unloaded stores; distinct from active-store eviction counters |
| `provider.paged_storage.sample_age_ms`, `.sample_fresh` | histogram (DogStatsD-only) / latest-value gauge (HTTPS) | `chip_family`, `provider_version` | Each accepted instrumented slot heartbeat; Swift producer preserves native capture age (`recordPagedStorageTelemetry`, `coordinator/internal/provider/heartbeat/provider_paged_storage_telemetry.go`) |
| `provider.paged_storage.grant_bytes`, `.committed_bytes`, `.reserved_page_bytes`, `.live_page_bytes`, `.poison_bytes`, `.slack_bytes`, `.over_grant_bytes`, `.segment_count`, `.address_pages` | histogram (DogStatsD-only) / latest-value gauge (HTTPS) | same | New fresh queue capture only; overlapping gauges, not an additive memory total; [wire semantics](protocol-messages.md#slotspaged_storage) |
| `provider.paged_storage.allocator_padding_bytes`, `.last_allocation_allowance_bytes` | histogram (DogStatsD-only) / latest-value gauge (HTTPS) | same | Optional; new fresh capture only. Retained nonusable padding and last released preparation allowance have different scopes; [wire semantics](protocol-messages.md#slotspaged_storage) |
| `provider.paged_storage.nominal_kv_bytes`, `.physical_floor_overhead_bytes` | histogram (DogStatsD-only) / latest-value gauge (HTTPS) | same | Only when instrumented; new fresh capture; ownership overlaps other gauges (`recordPagedStorageTelemetry`) |
| `provider.paged_storage.allocation_failures`, `.admission_refusals`, `.grant_refusals`, `.grant_epoch_retries` | count | same | Positive cumulative deltas within one pool generation; initial/reset/missing baseline contributes no count (`recordPagedStorageTelemetry`) |
| `provider.process_memory.sample_age_ms`, `.sample_fresh` | histogram (DogStatsD-only) / latest-value gauge (HTTPS) | `chip_family`, `provider_version` | Each accepted instrumented capacity heartbeat, including no-slot samples (`recordProcessMemoryTelemetry`) |
| `provider.process_memory.cap_bytes`, `.activation_reserve_bytes`, `.active_bytes`, `.cache_bytes`, `.charged_bytes`, `.materialized_bytes`, `.unmaterialized_bytes`, `.remaining_bytes`, `.commitment_debt_bytes`, `.owner_count`, `.closing_owner_count` | histogram (DogStatsD-only) / latest-value gauge (HTTPS) | same | New fresh capture only; C includes M, so projected usage is active+cache+(C−M); [wire semantics](protocol-messages.md#backend_capacitytelemetryprocess_memory) |
| `provider.process_memory.system_available_bytes` | histogram (DogStatsD-only) / latest-value gauge (HTTPS) | same | New fresh capture only when the OS observation is available; omitted is not zero |
| `provider.first_token_wedge_suspected` | count | `model` | per slot with `wedge_suspected` true, per heartbeat |
| `provider.eval_in_flight_long` | count | — | at most once per heartbeat when any slot's `eval_in_flight_ms ≥ evalInFlightLongMs = 2000` |
| `provider.oom_suspected` | count | — | abrupt disconnect classified as OOM |
| `provider.enqueue_failed` | count | `msg:runtime_status`, `msg:trust_status` | outbound frame could not be queued |
| `providers.registrations` | count | `trust_level` | each `register` |
| `ws.disconnects` | count | `reason:peer_close` + `code:<n>`, or `reason:read_error|read_error_control_frame` | each session end (`coordinator/api/provider/`, `readErrorDisconnectReason`); mirrored by `ws_disconnects_total` |
| `routing.cache_telemetry_rejected`, `routing.cache_capability_rejected` | count | `source:heartbeat` | heartbeat prefix-cache payload failed validation |
| `inference.unknown_request_frames` | count | `kind:chunk`, `complete`, `duplicate_complete`, `error`, `duplicate_error` | frame for an unknown or already-closed request |
| `routing.throughput_anomaly` | count | `model`, `chip_family` | observed vs advertised throughput divergence (`coordinator/api/observation/throughput_anomaly.go`); mirrored to the in-process registry |
| `provider_version_below_minimum` (no `provider.` prefix) | count | `gate:registration`, `challenge_revalidation`, `manifest_sync`; `version` (`version:unknown` when the provider reported none) | provider below `EIGENINFERENCE_MIN_PROVIDER_VERSION` (or version-less while a floor is set) at one of the three gates |
| `provider.load_model_status_rejected` | count | `reason:invalid_status`, `no_pending_command` | `load_model_status` frame that did not match an outstanding `load_model` |
| `attestation.challenges_sent`, `attestation.challenges` (`outcome:passed`, `failed`, `status_sig_missing`, `status_sig_failed`), `attestation.failures{reason}`, `attestation.force_reconnect{reason}` | count | as listed | SE challenge lifecycle per provider session |

### From request outcomes

| Metric | Type | Tags | Emitted |
|---|---|---|---|
| `inference.request_outcome` | count | `model`, `class` (`success`, `provider_5xx`, `timeout`, `rate_limited`, `client_error`; `mid_stream` declared, never produced), `kv_backend`, `kv_backend_fallback` | once per chat/responses request (`coordinator/api/inference/openrouter_uptime.go`); `/v1/completions` and `/v1/messages` dispatches excluded, their pre-dispatch rejections included |
| `inference.request_outcome_or_view` | count | `model`, `class` (`success`, `provider_5xx`, `timeout`, `mid_stream`, `rate_limited`, `client_error`, `client_gone`) | request-level terminal view: pre-dispatch rejection, dispatch terminal (including attempt-zero TTFT rejection), client departure, or committed route outcome; `client_gone` excludes early/post-commit client aborts while pre-content aborts at the deadline count as `timeout` (`coordinator/api/inference/attempt_outcome_metrics.go`, `recordRequestOutcomeORView`) |
| `routing.route_latency_ms` | histogram (DogStatsD only) | `model` | attempt-zero non-queued provider selection: `RoutedAt` minus `MediaFetchedAt` when set, otherwise `ReservedAt`; requires valid timing anchors (`coordinator/api/inference/attempt_outcome_metrics.go`, `emitRouteLatency`). No in-process mirror. |
| `routing.provider_draining` | count | `model` | transition into draining announced by a validated error terminal, before releasing pending capacity (`coordinator/api/inference/provider_drain.go`, `noteProviderDraining`). No in-process mirror. |
| `inference.completions` | count | `model` | each `inference_complete` |
| `inference.dispatches` | count | `status:success`, `failure`, `timeout`, `retry`, `retry_precontent` | each attempt |
| `inference.ttft_ms`, `inference.decode_tps` | histogram | `model`, `kv_backend`, `kv_backend_fallback` | Measured on the coordinator's clock, not reported by the provider: TTFT is dispatch → first content chunk, the same value `handleComplete` persists as `inference_routes.actual_ttft_ms`; decode TPS is the outcome row's `actual_decode_tps`. Emitted once per completion with a positive finite value (`coordinator/api/inference/kv_backend_metrics.go`) |
| `inference.timing.parse_ms`, `.reserve_ms`, `.route_ms`, `.encrypt_ms`, `.queue_wait_ms`, `.dispatch_ms`, `.total_duration_ms` | histogram | `model`, `final_status` | each finalized route (`coordinator/api/inference/timing_metrics.go`); the same segments ride the `X-Timing` header ([`api-contracts.md#headers`](api-contracts.md#headers)) |
| `inference.error` | count | `reason`, `model` | non-success final status with a normalized `error_reason` |
| `inference.partial_success` | count | `model`, `error_class` | client gone after commit |
| `inference.no_terminal_after_cancel` | count | `model` | settlement grace expired without a terminal |
| `inference.typed_terminal` / `inference.typed_terminal_unknown_cause` | count | `cause` / — | each provider error terminal |
| `inference.invalid_failure_code`, `inference.in_band_error`, `inference.first_content_after_deadline`, `inference.speculative_dispatch`, `inference.speculative_win`, `inference.zombie_stream_cancel`, `inference.chunk_overflow_abort` | count | various | dispatch edge cases (`coordinator/api/inference/dispatch.go`, `provider.go`) |
| `inference.prompt_tokens`, `inference.completion_tokens` (histogram); `inference.prompt_tokens_total`, `inference.completion_tokens_total` (count) | — | `model` | each completion |
| `registry.mu.write_wait_ms` | histogram | `site` | Registry write-lock acquisition wait, emitted after unlock (`coordinator/registry/lock_wait.go`, `lockWrite`); dispatch-load failure and recovery are separate sites. |
| `registry.gate.wait_ms` | histogram (DogStatsD only) | `site` | per-identity recorder gate waits over `gateWaitReportThreshold`, emitted after release (`coordinator/internal/registry/identitygate/gate_lock.go`, `Directory.SetGateWaitObserver`; registry adapter `coordinator/registry/gate_index.go`, `SetGateWaitObserver`; `coordinator/api/server.go`). No in-process mirror. |
| `routing.scans` | count | `model`, `outcome` | Full reservation scans including retries (`coordinator/api/inference/dispatch.go`, `recordRoutingDecisionFor`). |
| `routing.decisions` | count | `model`, `model_type`, `outcome` (`selected`, `queued`, `model_shed`, `ttft_429`, `model_too_large`, `over_capacity`, `routing_saturated`, `capacity_queue_spill`, `capacity_429`, `cold_dispatch_spill`, `dedicated_capacity_429`, `no_eligible_provider`, `ttft_soft_served`, `unservable_429`) | each admission decision |
| `inference.attempt_outcome`, `inference.queue_outcome` | count | `model`, `class` | dispatched-attempt and queue-only outcomes kept separate; `media_memory_unavailable` attempts count as `capacity` (`coordinator/api/inference/attempt_outcome_metrics.go`, `emitAttemptOutcomeMetric`, `isCapacityClassErrorReason`) |
| `inference.unknown_frames` | count | `kind`, `provider_version` | unrecognized chunk/complete/error frames (`coordinator/api/inference/lifecycle_metrics.go`, `emitUnknownFrame`) |
| `inference.cancel_sent`, `inference.cancel_unresolved` | count | `cause`, `model` | enqueue accepted / tracker expiry without a terminal or post-send stray chunk (`coordinator/internal/inference/cancellation/cancel_lifecycle.go`) |
| `inference.cancel_send_failed` | count | `reason` | enqueue rejected (`sendProviderCancel`) |
| `inference.cancelled_terminal` | count | `outcome`, `cause`, `delivered` | terminal correlation; `delivered` means enqueue accepted (`ResolveCancelledTerminal`) |
| `inference.cancel_to_terminal_ms` | histogram | `terminal`, `model`, `cause` | first successful enqueue to terminal or last later stray chunk; no sample for an unsent cancel (`EmitExpiredCancelEntries`) |
| `routing.client_gone` | count | `model`, `prompt_bucket`, `chip_family`, `phase` (`before_first_token`, `after_commit`), `deadline_bucket` | consumer disconnect (`coordinator/internal/inference/metrics/prompt_buckets.go`, `emitClientGoneBucketed`) |
| `routing.provider_breaker_open` / `_closed`, `routing.provider_ejected` / `routing.provider_ejection_recovered`, `routing.cooldown_entered`, `routing.capacity_cooldown_tripped`, `routing.load_failure_cooldowns` | count | `model` (+ `provider_id` for capacity cooldown) | fault-tracker transitions (`coordinator/api/inference/consumer.go`, `provider.go`) |
| `routing.ttft_calibration_ratio` | gauge | `model` | each TTFT observation (`coordinator/api/inference/settlement.go`) |
| `routing.unservable_reclassified`, `routing.first_chunk_timeout_reclassified`, `routing.client_error_passthrough`, `routing.oversized_request_rejected`, `routing.deadline_unreachable_rejected`, `routing.invalid_ttft`, `routing.dispatch_client_error_stop`, `routing.first_chunk_timeout_ladder_capped`, `routing.hedge_governor_suppressed`, `routing.pending_load_backoff`, `routing.scan_admission_timeout`, `routing.ttft_admission`, `routing.ttft_spread`, `routing.provider_selected`, `routing.load_model_rejects` | count | mostly `model` | routing edge cases |
| `http.requests` (count), `http.latency_ms` (histogram) | — | `method`, `path`, `status_code` | every HTTP request (`loggingMiddleware`, `coordinator/internal/api/middleware/middleware.go`) |

### Optional cache-planning decisions

`coordinator/internal/inference/routeplan/cache_planning.go` (`CachePlanner.PlanResult`) records one decision each
time a request's cache plan is computed, across the four inference endpoints.
`planPromptRoute` (`coordinator/api/inference/prompt_work.go`) calls it once per
concrete model and provider-bound body through the request's plan memo, so
queueing, retries and hedges retain that decision rather than adding another
sample per attempt. For a request that takes the public capacity preflight, the
plan is first computed while admission builds its first-content forecast
(`Admission.Run`, `coordinator/api/inference/inference_admission.go`): a request
that preflight then rejects is already counted, and an alias fallback probe
records a further decision for the previous build it probes. Self-route and
owner-preferred requests skip that forecast and are counted at the plan lookup
after admission. A request rejected before any plan is computed is not counted.

Missing dependencies, unready artifacts and media requests are recorded
immediately. Otherwise the planner, including its preload check, runs inside the
prompt-accounting bound, and no decision is recorded when `promptwork.Account`
(`coordinator/api/promptwork/accounting.go`) declines first: its 16-slot gate is
full, the body exceeds `promptcontract.DefaultMaxRequestBytes`, or the request
context has already ended. A gate miss is not memoized, so the request's next
plan lookup tries again. A generic-endpoint body that cannot be lowered is
counted as `lowering_unsupported` after admission, directly by
`handleGenericInference` (`CachePlanner.EmitDecision`,
`coordinator/api/inference/consumer.go`); `CachePlanningInput.LoweringFailed`
yields the same reason through the planner, but production does not set it.

| Admin metric | Datadog name, before the configured prefix | Labels | Meaning |
|---|---|---|---|
| `exact_cache_planning_decision_total` | `exact_cache.planning_decision` | `reason` | One optional-planning decision for one concrete model and provider-bound body of a request, not an HTTP-arrival, provider-attempt, Rust-execution or cache-hit count |
| `exact_cache_planning_decision_latency_ms` | `exact_cache.planning_decision_latency_ms` | `reason` | Nonnegative helper elapsed milliseconds, including early refusals; not consumer TTFT or only sidecar execution time |

The closed reasons, in prerequisite order, are `lowering_unsupported`,
`dependencies_unavailable`, `artifact_missing`, `artifact_failed` or
`artifact_pending`, `artifact_invalid`, and `preload_not_ready`. Once those gates
pass, the Registry supplies `off`, `ineligible`, `sampled_out`, `throttled`,
`cold_only`, `sidecar_error`, `no_boundaries`, `invalid_plan` or `planned`;
unrecognized future results map to `unknown_outcome` only in this new metric.
`lowering_unsupported` describes the generic native-forward fallback, not every
normalization rejection before preflight. Error text, artifact paths, accounts,
scopes, hashes, aliases and request IDs never become reason labels
(`coordinator/internal/inference/routeplan/cache_planning_telemetry.go`).

The existing metrics keep their definitions: `exact_cache_plan_total` (Datadog
`exact_cache.plan`) records every Registry-planner result, while
`exact_cache_plan_latency_ms` records only results with `SidecarCalled=true`.
One population is larger than before the planning-decision metric existed: a
media request (image, video or audio input) whose model's artifacts are verified
and whose contract is preload-acknowledged is counted as `ineligible` in
`exact_cache_plan_total` / `exact_cache.plan`, once per planning decision. The
planner is consulted to record its decision, and the Registry declines media
before sampling, the QPS gate and the sidecar (`planPromptRoute`,
`coordinator/api/inference/prompt_work.go`; `PlanCacheRouteWithResult`,
`coordinator/registry/cache_route_keys.go`), so there is no routing or billing
effect. Off/ineligible/sampled-out/throttled decisions can increment
`exact_cache_plan_total` without a sidecar latency sample. `SidecarCalled`
means the Go client was invoked; an expired or refused client call can submit
no Unix-socket request. Do not treat the broader new denominator as a historical
hit-rate improvement or regression. Public cache-status JSON is unchanged.

### Cache results by model (internal)

`coordinator/api/observation/cache_model_telemetry.go` emits the following Datadog counters
under `d_inference.routing.cache_model.`. Their admin counterparts are
`cache_model_<suffix>_total` in `GET /v1/admin/metrics`. The `model` label is the
resolved active catalog ID (`coordinator/registry/model_catalog.go`,
`CatalogModelID`), never the requested alias or a provider-supplied arbitrary
model. Off-catalog/removed IDs, an unconfigured catalog and malformed labels
collapse to `unknown`. No account, provider, request, cache scope, nonce, weight
hash or prompt-derived identity is attached. Existing `exact_cache.*` metrics
and the public cache status retain their aggregate-only contract.

The retained cache-attempt ledger adds three aggregate gauges, each mirroring a
`lifecycle` field of `/v1/cache/status` (`coordinator/api/inference/exact_cache_metrics.go`):
`exact_cache_attempt_bytes` / Datadog `exact_cache.attempt_bytes` (logical bytes held
against the 64 MiB budget), `exact_cache_attempt_budget_refused` /
`exact_cache.attempt_budget_refused` (dispatches sent without a cache scope because
the byte budget had no room for their record even counting up to 64 finished
requests' records, or the record alone exceeds it) and
`exact_cache_attempt_grace_reclaimed` / `exact_cache.attempt_grace_reclaimed`
(finished requests' records reclaimed inside their terminal grace). They carry no
labels; see [attempt-record memory accounting](../architecture/cache-aware-routing.md#attempt-record-memory-accounting).

| Suffix | Labels besides `model` | Population / interpretation |
|---|---|---|
| `planning_decision` | `reason` | Same population and closed reasons as the aggregate planning-decision metric. The existing catalog-bounded model label is captured once at helper entry, not taken from the caller alias. |
| `planning_decision_latency_us`, `planning_decision_latency_samples` | `reason` | Helper latency sum in rounded microseconds and sample count for the same decisions, including early refusals; not total request TTFT. |
| `usage` | `outcome`, `tier` | Completion terminals with retained pending/parked ownership, at the same seam as aggregate cache usage. Outcome is `hit`, `miss_absent`, `miss_corrupt`, `skipped_capacity`, `skipped_cost`, `skipped_policy`, `invalid` or `unreported`. `invalid`/`unreported` use tier `none`; they are coverage gaps, not misses. Duplicate and unknown terminals do not count. |
| `cached_tokens`, `prefill_tokens_saved` | `tier` | Validated provider-reported token totals. Cached tokens may exceed saved prefill tokens when replay is required. Neither count requires an accepted routing proof. |
| `provider_stage_us`, `provider_stage_samples` | `outcome`, `tier` | Sum of provider-reported staging microseconds (rounded per sample) and sample count for valid usage. Divide to obtain mean stage time. This is overhead, not time saved. |
| `lookup` | `outcome`, `tier` | Only coordinator-accepted V2 lookup proofs; distinct from terminal provider usage. Rejected proofs remain separate in the `receipt` reason counters. |
| `usage_prompt_tokens`, `usage_prefill_tokens_saved` | `outcome`, `tier` | Same valid completion population and same labels for numerator/denominator. Prompt counts must be 1–1,000,000; invalid/missing counts never enter these counters. Filter `outcome=hit` for hit-conditioned coverage. |
| `lookup_prompt_tokens`, `lookup_prefill_tokens_saved` | `outcome`, `tier` | Accepted V2 proof population; exact coordinator-plan prompt denominator and validated expected saved-token numerator. |
| `selection_prompt_tokens`, `selection_prefill_tokens_saved` | Same as `selection` | Valid provider usage in the exactly-once cache-selection terminal population; filter `selected=true,result=hit` for selected reported hits. |
| `receipt` | `type`, `outcome`, `reason`, `tier` | Every V2 receipt decision, including rejection; reported model maps to the bounded active catalog or `unknown`. A model label on a rejected receipt does not imply its attempt binding was accepted. |
| `prompt_mismatch` | `detail`, `tier` | Exact prompt-anchor rejection after attempt/connection/capability binding: `same_length_hash`, `provider_shorter`, `provider_longer`. No hashes, exact counts or prompt-derived identifiers are emitted. |
| `donation` | `tier` | Accepted V2 ready receipts, not number of files, unique prefixes or requests. |
| `selection` | `mode`, `tier`, `selected`, `result`, `lookup_outcome`, `cache_read` | Existing exactly-once cache terminal population. `selected=true` identifies cache-favored routing; combine with `result=hit` for reported reuse. `result` describes cache usage, not consumer request success. Here `tier` is the selected routing tier (`none` for an unselected provider); `usage.tier` instead describes actual reported reuse. Error terminals can be `unreported`. |
| `ttft_us`, `ttft_samples` | Same as `selection` | Coordinator-measured first-content latency for valid reported usage in active cache routing. Compare hit/miss and selected/unselected populations; this is observed latency, not estimated savings. |
| `estimated_ttft_saved_us`, `estimated_ttft_saved_samples` | Same as `selection` | Positive finite scheduler estimates, split by the terminal cache outcome. These are not measured counterfactual savings or success-only totals. |

Timing sums/sample counters work with both HTTPS and DogStatsD. The admin
registry additionally exposes `cache_model_provider_stage_ms` and
`cache_model_ttft_ms` and `cache_model_estimated_ttft_saved_ms` histograms with the corresponding labels.
`coordinator/internal/inference/routeplan/cache_planning_telemetry.go` uses the same counter/timing helpers;
its admin histogram is `cache_model_planning_decision_latency_ms{model,reason}`.
Its Datadog model names are `routing.cache_model.planning_decision`,
`routing.cache_model.planning_decision_latency_us` and
`routing.cache_model.planning_decision_latency_samples`; no per-model Datadog
latency histogram is added by these helpers.
Admin `cache_model_usage_prefill_saved_percent` and
`cache_model_selection_prefill_saved_percent` histograms report per-request
percentages; use same-label summed counters for token-weighted coverage.
Admin counters reset on coordinator restart; all model breakdowns begin only
when this instrumentation is deployed. Historical aggregate hits cannot be
backfilled into models. Provider usage, receipt counts and selection counts
have different populations and must not be summed together.

### Cache reuse loss funnel (status endpoint and admin metrics)

The `funnel` field of `GET /v1/cache/status` is an in-process aggregate
(`coordinator/internal/observation/cachefunnel/`); it emits no Datadog metric
and resets on coordinator restart. The endpoint is unauthenticated, so the
field holds counts of requests and attempts only and no token sum. Its population is every text request for a
catalog model while cache routing is on, counted once per request regardless
of retries and hedges. It is a different population from every counter above
and must not be summed with them.

| Field | Meaning |
|---|---|
| `entered`, `closed`, `in_flight` | Requests admitted to the population, classified, and still open. `entered = closed + in_flight`. |
| `reasons[]` | One entry per terminal reason, always present, in lifecycle order; `requests` over all entries sums to `closed`. Reasons are defined in [the cache routing architecture page](../architecture/cache-aware-routing.md#reuse-loss-funnel). |
| `total` | The same counters summed over all reasons. |
| `requests`, `attempts` | Requests in the reason, and the provider attempts they used. |
| `dispatched_without_scope` | Requests whose classifying attempt went to a provider that received no cache scope. |
| `lookup_outcome_reported` | Requests whose completing provider reported a lookup outcome in its usage. |
| `prompt_tokens_unknown`, `repeated_prefix_tokens_unknown`, `predicted_tokens_unknown`, `reused_tokens_unknown` | Requests where that token quantity was not observed. Unknown is never folded into a sum as zero. |
| `unobserved[]` | Stages the coordinator does not feed into the funnel, each with the reason. |

The token sums are in-process counters on the admin-authenticated
`GET /v1/admin/metrics` only (`ObserveCacheFunnelRecord` in
`coordinator/api/observation/cache_funnel_telemetry.go`). Each is labelled by
terminal `reason` and adds a closed request's count only when that quantity
was observed.

| Counter | Meaning |
|---|---|
| `exact_cache_funnel_prompt_tokens_total{reason}` | Exact prompt tokens counted by the planning decision for the dispatched body. |
| `exact_cache_funnel_repeated_prefix_tokens_total{reason}` | Repeated-prefix tokens (demand evidence) of the dispatched plan. |
| `exact_cache_funnel_predicted_tokens_total{reason}` | Tokens the coordinator expected the chosen provider to restore. Not fed today, so always absent. |
| `exact_cache_funnel_reused_tokens_total{reason}` | Provider-reported cached tokens of the completing attempt. |

### Telemetry pipeline and platform gauges

| Metric | Type | Tags | Emitted |
|---|---|---|---|
| `telemetry.sink_depth` | gauge | `sink:profile`, `sink:route` | each 60 s fleet sample |
| `telemetry.sink_dropped` | count | `sink:profile` | non-blocking submit found the 4096-slot profile channel full (warned at powers of ten). The route sink counts drops in an atomic exposed as `fleet_snapshots.route_sink_dropped_total` and in its slog line, not as a Datadog counter |
| `request_outcomes.received` | count | `endpoint` (four inference paths) | once on covered incoming request receipt; no request IDs in labels |
| `request_outcomes.records` | count | `status:written`, `write_failed`, `dropped` | unsampled compact persistence snapshots, not unique request counts; [contract](../architecture/request-accounting.md) |
| `profiler.records` | count | `status:written`, `write_failed`, `sampled_out` | each profile batch |
| `profiler.provider_profile` | count | `valid`, `reason` (`none`, `size`, `decode`, `schema`, `range`, `order`, `enum`, `duplicate`, `late`) | each provider `profile` |
| `profiler.fleet_snapshot` | count | `status:written`, `write_failed` | each fleet sample |
| `profiler.pruned_rows` | count | — | each hourly retention sweep |
| `providers.online`, `providers.per_model{model}`, `providers.per_version{version}`, `providers.by_trust_status{…}`, `providers.by_mdm_failure{reason}`, `attestation.code_attested`, `attestation.code_enforced`, `coordinator.min_provider_version_set{min_version}`, `request_queue.depth`, `utilization.network`, `utilization.warm`, `utilization.token_budget`, `utilization.bottleneck`, `utilization.model{model}`, `capacity.tps`, `capacity.demand_concurrency`, `capacity.serving_capacity`, `capacity.spill_arrival_rate` | gauge | as listed | every 15 s from `StartDDGaugeLoop` (`coordinator/api/observation/fleet_gauge_loop.go`), which also pushes the `exact_cache.*` gauges (`EmitExactCacheDDGauges`, `coordinator/api/inference/exact_cache_metrics.go`); the loop returns immediately when no Datadog client is configured |
| `exact_cache.artifact_allowlist.stale_models` | gauge | — | every gauge-loop tick; catalog models the cache-routing allowlist names only under a superseded artifact, `0` unless routing is `on`. Aggregate only: the tuple to append is named in the coordinator log, never in a metric (`EmitExactCacheDDGauges`, `coordinator/api/inference/exact_cache_metrics.go`; `missingAllowlistEntries`, `coordinator/api/inference/exact_cache_allowlist_staleness.go`) |
| `exact_cache.activation.total` | gauge | `outcome` (`evaluated`, `sampled_in`, `sampled_out`, `rate_limited`, `admitted`, `planned`, `cold_only`, `plan_empty`, `plan_failed`, `first_sight`) | every gauge-loop tick; the `activation` counters of `GET /v1/cache/status`, cumulative since the coordinator started. `first_sight` counts plans that [first sight](../architecture/cache-aware-routing.md#first-sight) prepared and is a subset of `planned`, not a tenth outcome of the same population (`EmitExactCacheDDGauges`, `coordinator/api/inference/exact_cache_metrics.go`; `CacheRoutingActivationStatus`, `coordinator/internal/registry/cacheactivation/status.go`) |
| `request_queue.depth_by_model`, `request_queue.oldest_age_ms` | gauge | `model` | every gauge-loop tick for served or queued models; a disappearing model gets one final zero for both series and is then forgotten (`coordinator/internal/observation/fleet/fleet_gauges.go`, `emitPerModelQueueGauges`) |

### In-process registry (not Datadog)

`Metrics` (`coordinator/api/`) keeps `http_requests_total`,
`telemetry_events_total{source, severity, kind}`, `routing.throughput_anomaly`
and computed gauges in memory; `GET /v1/admin/metrics` returns them as JSON or
Prometheus text (`?format=prom`). Reset on restart.

| In-process counter | Labels | Source / Datadog counterpart |
|---|---|---|
| `inference_attempt_outcome_total` | `model`, `class` | `inference.attempt_outcome`; terminal dispatched-attempt outcomes (`coordinator/api/inference/attempt_outcome_metrics.go`, `emitAttemptOutcomeMetric`) |
| `inference_queue_outcome_total` | `model`, `class` | `inference.queue_outcome`; queue exits that dispatched no attempt (`coordinator/api/inference/attempt_outcome_metrics.go`, `emitQueueOutcomeMetric`) |
| `inference_request_outcome_or_view_total` | `model`, `class` | `inference.request_outcome_or_view`; the same request-terminal classes and counting boundaries (`coordinator/api/inference/attempt_outcome_metrics.go`, `recordRequestOutcomeORView`) |
| `inference_unknown_frames_total` | `kind`, `provider_version` | `inference.unknown_frames`; unrecognized chunk/complete/error frames (`coordinator/api/inference/lifecycle_metrics.go`, `emitUnknownFrame`) |
| `ws_disconnects_total` | `reason`, plus `code` for `peer_close` | `ws.disconnects`; `reason` is `peer_close`, `read_error`, or `read_error_control_frame` (`coordinator/api/provider/`, `providerReadLoop`) |


## Coordinator-emitted events

Producer: `Emitter.Emit` (`coordinator/telemetry/emitter.go`) via `s.emit`,
`Owner.EmitRequest`, `Owner.EmitPanic` (`coordinator/api/observation/events.go`). Sinks, in order:
`slog` line `telemetry: <message>`, `telemetry_events_total`, Datadog Logs API
(`ForwardLog`, batched 100 or every 5 s, only with `DD_API_KEY`). Retention is
Datadog's; nothing is stored locally.

| Message | Severity · kind | Fields | Site |
|---|---|---|---|
| `provider registered` | info · `log` | `provider_id`, `trust_level`, `hardware_chip`, `memory_gb` | `coordinator/api/provider/` |
| `provider websocket read error` | warn · `connectivity` | `provider_id`, `ws_state:read_error`, `reason:read_error|read_error_control_frame`, `last_error` | `provider.go` |
| `provider disconnected under memory pressure (suspected OOM)` | error · `oom` | `provider_id`, `memory_pressure`, `in_flight` | `provider.go` |
| `attestation challenge failed` | warn or error · `attestation_failure` | `provider_id`, `reason`, `reconnect_count` | `provider.go` |
| `provider failed, retrying` / `provider failed after accepting request, retrying` | warn · `inference_error` | `provider_id`, `attempt`, `reason:provider_error`, `status_code` (+ `request_id`) | `coordinator/api/inference/dispatch.go` |
| `provider first-chunk timeout` / `provider accepted timeout` | warn · `inference_error` | `provider_id`, `attempt`, `reason:first_chunk_timeout` / `accepted_timeout` | `dispatch.go` |
| `inference failed after N attempt(s)` | error · `inference_error` | `reason:dispatch_exhausted`, `attempt`, `status_code`, `last_error` (the sanitized closed message) | `dispatch.go` |
| `warm_pool_tick` | info · `custom` | Per-model latest-state sample: `model`, `target_warm`, `warm`, `eligible_cold`, `cold_ineligible`, `warm_saturated`, `warm_foreign_blocked`, `occupancy_ramp`, `headroom_providers`, `running`, `waiting`, `queue_depth`, `oldest_queue_age_ms`, `spill_arrival_rate`, `service_time_ms`, `quality_concurrency`, `demand_concurrency`, `capacity_rejects`, `ttft_misses`, `speculative_started`, `speculative_won`, `cold_dispatches`, `load_duration_ewma_ms`, `actions`, `observe_only`, plus scalar `cold_disq_<reason>` counts. Polled every 15 s and deduplicated by controller snapshot timestamp; intermediate controller ticks can be skipped. No provider or request identity; no Postgres record. | `coordinator/api/observation/warm_pool_telemetry.go` (`StartWarmPoolTelemetryLoop`, `warmPoolTelemetryFields`) |
| `panic in handler <method> <path>: <value>` | fatal · `panic` | `handler`, `endpoint`, plus `stack` | `coordinator/internal/api/middleware/middleware.go` recovery middleware |

## Coordinator per-request records (Postgres)

| Table | Grain | Written by | Retention |
|---|---|---|---|
| `inference_routes` | one row per `(request_id, attempt)` | `recordRoutingDecisionFor` (`coordinator/api/inference/dispatch.go`) → `RecordInferenceRoute` (upsert), outcome patched by `UpdateInferenceRouteOutcome` with `COALESCE` | none |
| `request_rejections` | one row per pre-dispatch or exhausted rejection | `recordRejection` (`coordinator/api/inference/rejection_telemetry.go`); insert errors swallowed | none |
| `usage` (+ `usage_totals`) | one row per billed completion | `store.RecordUsage` | none |
| `providers`, `provider_reputation` | one row per provider | `UpsertProvider`, `UpsertReputation`, throttled to 30 s | none |
| `provider_sessions` | one row per WebSocket session | `OpenProviderSession`, `TouchProviderSession`, `CloseProviderSession` | none |
| `provider_log_reports` | one row per uploaded bundle | `StoreLogReport` | none |
| `request_profiles` | one row per `(request_id, attempt)`, sampled | profile sink (`coordinator/internal/observation/profile/profiler_sink.go`), batches of 64 or 250 ms | 14 d, hourly sweep, 5000-id windows |
| `fleet_snapshots` | one row per provider slot plus one `provider_id = "coordinator"` row | fleet sampler (`coordinator/api/observation/profiler_fleet.go`) every 60 s | 30 d, same sweep |

The retention sweep (`PruneTelemetry`, `coordinator/store/postgres/profiles.go`)
runs even when the profiler is off. Every other table grows without bound;
`DeleteExpiredDeviceCodes` exists but has no production caller. Details of the
two profiler tables: [`../architecture/system-profiler.md`](../architecture/system-profiler.md).

## Admin read surfaces

| Route | Returns | Limits |
|---|---|---|
| `GET /v1/admin/routes`, `/export` | `inference_routes` (JSON; CSV default or `?format=ndjson`) | `?since` (duration or RFC 3339, default 24 h); browse default 1000, max 50 000 (`coordinator/api/observation/admin_telemetry.go`); store cap `maxTelemetryReadRows = 50000` |
| `GET /v1/admin/rejections`, `/export` | `request_rejections` | same |
| `GET /v1/admin/profiles`, `/export`; `GET /v1/admin/snapshots`, `/export` | `request_profiles`, `fleet_snapshots` (export is NDJSON only) | same (`coordinator/api/observation/profiler_admin.go`) |
| `GET /v1/admin/metrics` | in-process registry snapshot | `?format=prom` |
| `GET /v1/admin/log-reports/{id}` | one log bundle | admin key |
| `GET /v1/stats` | usage aggregates (`coordinator/api/reporting/stats_handler.go`, `HandleStats`) | Unauthenticated; source timestamp and cache interval: [public stats contract](api-contracts.md#public-stats-and-health-5) |

## Provider-local surfaces (never leave the machine)

| Surface | Content | Cadence |
|---|---|---|
| Unified log (`ProviderLogger`, `provider-swift/Sources/ProviderCore/ProviderLogger.swift`) | free-form strings are `privacy: .private`; only the closed `ProviderOperationalMessage` enum is public. WS logger subsystem `dev.darkbloom.provider`, category `coordinator` | continuous |
| `~/.darkbloom/daemon-state.json` (`DaemonStateFile`, `provider-swift/Sources/ProviderCore/Service/DaemonStateFile.swift`; override `DARKBLOOM_STATE_FILE`) | schema `1`: pid, version, trust, current/warm/advertised models, stats, system, capacity, slots, connectivity, last model-load error | rewritten on every 2 s capacity tick |
| Local Prometheus `/metrics` (`LocalMetricsResponder`, `provider-swift/Sources/ProviderCore/Server/LocalMetricsResponder.swift`) | `mtp_enabled`, `mtp_active`, `mtp_rounds_total`, `mtp_tokens_proposed_total`, `mtp_tokens_accepted_total`, `mtp_inactive_reason{model, reason}` | on scrape |
| OOM detector (`provider-swift/Sources/ProviderCore/Diagnostics/OOMDetector.swift`) | `~/.darkbloom/oom_marker.json`, `~/.darkbloom/oom_last_scan`, scan of `DiagnosticReports`; findings become an `oom` event that `TelemetryClient.emit` discards | on launch |
| `PanicHook` (`provider-swift/Sources/ProviderCore/Telemetry/PanicHook.swift`) | one stderr line `<ISO8601> FATAL panic kind=… message=…` for `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGABRT`, `SIGFPE` and uncaught exceptions, then re-raise | on crash |

## Retired paths that emit nothing

| Component | State |
|---|---|
| `TelemetryClient.emit` (`provider-swift/Sources/ProviderCore/Telemetry/TelemetryClient.swift`) | discards the event; `configure` logs that client telemetry is disabled |
| `TelemetryOverflowQueue` (`provider-swift/Sources/ProviderCore/Telemetry/TelemetryOverflowQueue.swift`) | `purge` deletes the legacy `telemetry-queue.jsonl` |
| Console `emit`, `installGlobalHandlers` (`console-ui/src/lib/telemetry.ts`) | no-ops |
| Coordinator `POST /v1/telemetry/events` | not registered; 404 |
| Console `POST /api/telemetry` (`console-ui/src/app/api/telemetry/route.ts`) | `telemetry_ingest_disabled` (410); body never read |
| `telemetry_events` table | dropped; the migration slice in `coordinator/store/postgres/` keeps only a "Telemetry events table + indices removed" comment, and `TelemetryStore` (`coordinator/store/interface_domains.go`) has no method that writes an event |

## Related

- [`../architecture/telemetry.md`](../architecture/telemetry.md) — mechanism, invariants, failure modes
- [`telemetry-schema.md`](telemetry-schema.md) — event contract and its Go/Swift/TypeScript mirrors
- [`protocol-messages.md`](protocol-messages.md) — heartbeat and terminal field tables
- [`../architecture/system-profiler.md`](../architecture/system-profiler.md) — `profile`, `request_profiles`, `fleet_snapshots`
- [`../architecture/request-outcome-observability.md`](../architecture/request-outcome-observability.md) — outcome vocabularies behind the request metrics
- [`../architecture/scheduling.md`](../architecture/scheduling.md) — how heartbeat capacity drives admission
