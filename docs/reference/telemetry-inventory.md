# Telemetry inventory — what Darkbloom records today

Status: inventory, 2026-09-02. Companion to `routing-telemetry-and-calibration.md` (plan), `request-outcome-observability.md` (taxonomy), `docs/reference/telemetry-schema.md` (allowlists) and `operations/telemetry.md` (retired ingest). This file lists every datum the system produces per request and per fleet tick, where it is produced, where it lands, its cadence, and its gaps. It contains no design.

**Provenance.** Every `file:line` refers to master `b66ee3065` (the pre-profiler baseline this inventory describes); paths are relative to `coordinator/`, `provider-swift/Sources/ProviderCore/` (Swift), or `libs/…` as written. Branch `feat/system-profiler` has already moved lines in `api/{server,consumer,dispatch,provider,route_outcome}.go`, `registry/{registry,scheduler,queue}.go`, `store/postgres.go`; reproduce a citation with `git show b66ee3065:<path>`. Claims not read in code are marked **INFERRED**.

## 1. Scope and confidentiality rules

| Rule | Where it is stated / enforced |
|---|---|
| No prompt, completion, tool-argument or media bytes, token ids, raw IPs, raw API keys, raw error prose in any persisted or emitted datum; timings, token counts, µUSD, model/version metadata allowed | `request-outcome-observability.md` §Privacy; `routing-telemetry-and-calibration.md` §8. Enforced: `cache_affinity_key` blanked by trigger `store/postgres.go:100-136`; provider `inference_error.error` never read `api/inference_error_sanitize.go:9-14`; `error_reason` closed set `api/route_outcome.go:100-136`; keys only as `consumer_key_hash` |
| Provider→coordinator free-form telemetry is **retired** | Step 1 (2026-05-28, #234 `7f3bbe4f9`): Postgres sink dropped because 60 providers × 10 s batches × 5 indexes ate ~30-40 % of the DB pool (`store/postgres.go:719-724`). Step 2 (2026-08-14, #612 `6f7960ebf`): `POST /v1/telemetry/events` returns 410 **before reading the body** because free-form `message`/`stack`/field values can carry prompt-, URL-, template- and tool-derived plaintext and a field-*name* allowlist cannot prove *values* safe (`api/telemetry_handlers.go:5-10, 264-269`; `Telemetry/TelemetryClient.swift:1-9, 69-81`; `Telemetry/TelemetryOverflowQueue.swift:28-36`; `operations/telemetry.md:145-159`) |
| Channels that DO carry structured provider data | WebSocket `heartbeat` (`protocol/messages.go:234-262`), `inference_complete.usage` (`:528-535`, `UsageInfo :438-455`), `inference_error` closed codes (`:538-570`), `prefix_cache_lookup/ready(_v2)` receipts (`:457-526`); coordinator-authored rows `inference_routes`, `request_rejections`, `usage` (§4.1). Operator-initiated `darkbloom report` upload (`api/log_report_handlers.go:16-56`) is the only other path |
| Provider-reported values are claims, not truth | Heartbeat model ids clamped to the accepted inventory (`registry/heartbeat_model_state.go:5-16`); `actual_decode_tps` clamped to `maxPlausibleDecodeTPS` (`api/provider.go:2190-2227`); `kv_backend_fallback_reason` folded to a closed class before tagging (`registry/kv_backend.go:334-350`) |
| One key, one meaning; add a key only with its producer; omission = unknown | `docs/reference/telemetry-schema.md:165-208`; `kv_backend *string,omitempty` so pre-0.8.0 providers do not book as contiguous (`messages.go:303`); DogStatsD tags emit an explicit `unknown` (`registry/kv_backend.go:334-350`); `pages_pinned`/`cow_events` were removed for lacking a producer |
| Bounded metric tags only: `model`, `class`, `kv_backend(_fallback)`, `chip_family`, `phase`, `prompt_bucket` (5 buckets `api/prompt_buckets.go:23-40`), `outcome`, `reason`, `mode`; `provider_id` only on heartbeat gauges; **never** a request id | `api/provider.go:2373-2374`; `api/terminal_cause.go:95-98`; `api/server.go:2627-2637` (path label = mux pattern) |

## 2. Per-request data

### 2.0 Identities and clocks

| Identity | Minted | Propagated to | Persisted where |
|---|---|---|---|
| HTTP request id (`X-Request-ID`) | `api/server.go:2564-2570` — client header honored **verbatim** (not unique), else `newRequestID()` `:2646-2659` | ctx `ctxKeyRequestID`; response header | slog `request` line `:2587-2596`; `trace_id` on the `inference request dispatched` log `api/dispatch.go:3091-3098`. **Never** on a row, event, or tag |
| Attempt UUID (`PendingRequest.RequestID`) | `api/consumer.go:852` (direct), `api/dispatch.go:1189` (queued), backup via `:1984` | wire `request_id` (`messages.go:596`); `X-Inference-Job-ID` (`api/sse_response.go:15`); `chatcmpl-<id>` | `inference_routes(request_id, attempt)` (`store/postgres.go:783-784`, unique `:1727`); `usage.request_id` (`api/provider.go:2167-2169`); DD Logs attr `request_id` (`datadog/datadog.go:250-252`); slog lines |
| Provider bridge id `req-<uuid12>` | `Inference/MultiModelBatchSchedulerEngine.swift:636` (`:381` vision) | bridge `active`/`idMap`, SSD receipts, bridge telemetry | never logged next to the coordinator id (`ProviderLoop+Cancellation.swift:28-31`) |
| Engine `CBv2RequestID` | `Inference/EngineV2Bridge.swift:833-838, 2037-2050` | engine scheduler/sampler | in-memory `idMap` only; ids reusable after finish (`EngineLoopV2.swift:2972-2983`) |

| Layer | Clock primitive | Where | Sleep-aware / notes |
|---|---|---|---|
| Coordinator stamps | Go `time.Now()`; durations via `Sub` (monotonic, `mach_absolute_time` base) | `registry/registry.go:718-739` | no; only relative `first_content_budget_ms` crosses the wire (`messages.go:600-603`, recomputed at writer dequeue `api/provider_wire.go:91-101`) |
| Provider transport + bridge | `ContinuousClock` (`mach_continuous_time`) | `Coordinator/CoordinatorClient+Connection.swift:374`; `Inference/EngineV2Bridge.swift:852, 1765` | yes (counts sleep) |
| Provider stream wrapper | `Date()` (wall) | `MultiModelBatchSchedulerEngine.swift:779, 811-812` | values discarded (§5) |
| Engine | `Date` (`SchedulerV2.swift:55`); `DispatchTime` uptime ns (`EngineLoopV2.swift:360`) | | mixed |
| `CBv2StepProfiler` | `CFAbsoluteTimeGetCurrent` (wall, non-monotonic) | `StepProfilerV2.swift:47-49` | opt-in only |
| Uncommitted `DiagnosticTrace` | `std::chrono::steady_clock` (`CLOCK_MONOTONIC_RAW`, counts sleep) | not in git (`libs/mlx-swift` working tree only) | diagnostics only |

### 2.1 The six "TTFT" clocks in play

| Clock | Anchor → end | Where | Includes / excludes |
|---|---|---|---|
| `actual_ttft_ms` (row; DD `inference.ttft_ms`) | `DispatchedAt` → `FirstContentAt` (first **content-bearing** chunk committed) | `api/route_outcome.go:454-475`; `api/kv_backend_metrics.go:35, 162-178` | WS transit + provider decrypt/tokenize/template + cold load + engine queue + prefill + readback. Excludes coordinator queue wait. 0 on `client_gone`/error rows. Negative clamped + `InvalidTTFT` flag |
| `dispatch_to_first_chunk_ms` (row `dispatch_ms`; header `provider_us`) | `DispatchedAt` → `FirstChunkAt` (first **byte**, role-only preamble counts) | `route_outcome.go:477-481`; `api/dispatch.go:521, 3450-3452` | first-byte diagnostic, not a prefill metric |
| Live first-content clock | `ReceivedAt` + base (5 s code default `api/consumer.go:54`; 9 s prod **INFERRED**) + 1 ms × est. prompt tokens; absolute, never reset | `api/first_token_clock.go`; `consumer.go:121-128`; budget on wire `messages.go:600-603` | the kill clock; only content satisfies it |
| OpenRouter's deadline | ≈ received + 10 s + 1 ms/token, seen as Caddy status 0 at 9.99-10.4 s | `docs/operations/coordinator-deploy.md:578-586` | **INFERRED**, never probed |
| Provider isolated cold-prefill EWMA | `submittedAt` → `firstTokenAt`, queue-excluded, cold/uncontended/text-only, α = 0.3 | `EngineV2Bridge.swift:1868-1897` | feeds deadline forecast; **not on the wire** (the load-inclusive `observed_prefill_tps` is) |
| Benchmark TTFT | submit → first output on a fresh engine | `provider-swift/Sources/ProviderBenchmark/SchedulerPrefillBenchmark.swift:181-269` | no scheduler wait, no coordinator |

### 2.2 Coordinator layer

Sinks: **hdr** = `X-Timing` field (`api/dispatch.go:3409-3456`, committed responses only); **row** = `inference_routes` column; **rej** = `request_rejections`; **DD-C/H/G** = Datadog counter/histogram/gauge; **log** = slog; **mem** = in-memory only.

| Datum | Producer | Sink | Cadence |
|---|---|---|---|
| Middleware `start` | `api/server.go:2559` | log `request{request_id,method,path,route,status,duration_ms,remote,user_id}` `:2587-2596`; in-proc `http_requests_total`/`http_request_duration_ms` `:2601-2611`; DD-C `http.requests`, DD-H `http.latency_ms{method,path,status_code}` `:2615-2623` | every HTTP request; aggregated, never per request |
| `ReceivedAt` | `api/consumer.go:1496` (handler entry — after CORS, recover, logging, body cap, drain gate, auth incl. `GetUserByAccountID` DB read `server.go:2362`, rate limits, sealed-transport decrypt) | hdr anchor; row `total_duration_ms = time.Since(ReceivedAt)` `route_outcome.go:484` | per request |
| `ParsedAt` | `consumer.go:1697` | hdr `parse_us`; row `parse_ms` (`dispatch.go:508`) | per request |
| `ReservedAt` | `consumer.go:1799` | hdr `reserve_us`; row `reserve_ms`; DD-H `store.debit.latency_ms{op:reserve}` `api/reservations.go:85`; DD-C `billing.reservations{model,mode,outcome}` | per request |
| `MediaFetchedAt` | `api/media_resolve.go:300` | hdr `media_fetch_us` (omitempty); DD-H `inference.media_fetch.duration_ms{model}` `:305`; **no column** (`dispatch.go:513-516`) | only when http(s) media inlined |
| Admission preflight verdict | `api/inference_admission.go:227-649` | DD-C `routing.decisions{model,model_type,outcome}` only; rej row on shed | per request; not joinable to the outcome |
| Sidecar plan latency | `registry/cache_route_keys.go:167-174` | DD-C `exact_cache.plan{outcome}`, DD-H `exact_cache.plan_latency_ms` (`api/exact_cache_telemetry.go:13-34`, no model/request tag) | when cache routing on |
| `QueuedAt` | `dispatch.go:1239` | hdr `queue_us`; row `queue_wait_ms` (`dispatch.go:520`); DD-C `routing.decisions{outcome:queued}`, `request_queue.timeout` `:1326`; log `request queued` `:1263` | only requests that queued (~10 %, **INFERRED** from 07-25 report) |
| Routing decision (`RoutingDecision` `registry/scheduler.go:288-352`) | `recordRoutingDecisionFor` `dispatch.go:355-480` | row: `outcome, cost_ms, state_ms, queue_ms, pending_ms, backlog_ms, this_req_ms, health_ms, ttft_ms, best_ttft_ms, effective_queue, candidate_count, {capacity,model_too_large,vision,ttft}_rejections, effective_tps, static_tps` + winner snapshot under `provider.Mu()` `:425-456` (`provider_status, trust, version, hardware_chip/family/tier, memory_gb, gpu/cpu_cores, system_*, gpu_memory_*, slot_state, backend_running/waiting, active_token_budget_used/max, queued_token_budget`) + request shape; DD-C `routing.decisions`, `routing.provider_selected{provider_id,model}` `dispatch.go:3088-3089`; log `inference request dispatched{trace_id,request_id,model,provider_id,stream,attempt}` `:3091-3098` | per attempt |
| Not persisted from the decision | `scheduler.go:298-306` (comment) | `CapacityRateMs`, `CapacityRejectRate`, `RawTTFTMs`; `Shadow*` → DD-C `routing.ttft_admission{decision,mode}`, `routing.ttft_spread` only (`api/ttft_shadow_metrics.go:53-54`); cache tier/discount → DD-C `routing.cache_evaluation` only (`dispatch.go:462-467`) | — |
| `RoutedAt` | `consumer.go:946` (direct) / `dispatch.go:1346` (**after** the queue wait) | hdr `route_us`; row `route_ms` (`dispatch.go:518`) | per attempt (overwritten on retry) |
| `EncryptedAt` | `consumer.go:1049` | hdr `encrypt_us`; row `encrypt_ms` | per attempt |
| `DispatchedAt` = writer `DequeuedAt` | `consumer.go:1067` ← `registry/provider_writer.go:419` | hdr `dispatch_us` (`EncryptedAt→DispatchedAt`, **not persisted**); row `dispatch_ms` = `DispatchedAt→FirstChunkAt` (`dispatch.go:521`) | per attempt |
| Socket write completion | `provider_writer.go:550-566` (5-30 s watchdog `:568-580`) | none — rolls into `provider_us` | — |
| `inference_accepted` | `api/provider.go:1758-1771` → `AcceptedCh`; consumer `dispatch.go:1829-1832` | **discarded, never timestamped** | — |
| Chunk ingress | `provider.go:1585, 1624` → private `chunkIngressPendingAt`/`firstContentIngressAt` (`registry.go:273-275`); `ProviderChunk.ReceivedAt` (`registry.go:72-75`) | mem | per chunk |
| `FirstChunkAt` | `api/first_token_clock.go:133` / `dispatch.go:538` → `registry.go:545-554` (consumer dequeue, first-write-wins) | hdr `provider_us`; row `dispatch_to_first_chunk_ms`; reputation latency EWMA `dispatch.go:3366` → `registry.go:4905-4919` (mem) | per request |
| `FirstContentAt` | `dispatch.go:539` → `registry.go:574-583` | row `actual_ttft_ms`; DD-H `inference.ttft_ms{model,kv_backend,kv_backend_fallback}` (`kv_backend_metrics.go:35`, via `provider.go:2258`); DD-G `routing.ttft_calibration_ratio{model}` `api/settlement.go:159`; TTFT calibrator window (`registry/ttft_calibration.go:331`) | per request |
| Speculative backup | `dispatch.go:1949` (launch), `:1989` (backup gets a fresh `RequestTiming{ReceivedAt}`), `:2179-2181` (adoption) | DD-C `inference.speculative_dispatch{model}`; row `used_backup`, `backup_won`; log `speculative_dispatch` `:2032` | per race |
| First-chunk timeout / provider error | `dispatch.go:1834-1920`, `noteInferenceError` `consumer.go:322-437` | telemetry event `inference_error{provider_id,attempt,reason,status_code}` `:1850/:1907` (DD Logs + slog); DD-C `inference.dispatches{status:timeout}` `:1917`; row outcome per failed attempt; breaker/cooldown counters `consumer.go:365-381, 444` | per failed attempt |
| Streaming relay (chunk count, bytes, inter-chunk gap, flush time, first/last byte to client) | `consumer.go:2069-2070, 2131-2265, 2209-2210` | **none** | — |
| Mid-stream error / client gone | `consumer.go:2141-2147, 2282`; `route_outcome.go:179-198` | DD-C `inference.in_band_error{model,reason}`, `routing.client_gone{model,prompt_bucket,chip_family,phase}` (`prompt_buckets.go:61-71`); row `partial_success` | per event |
| Completion ingress | `provider.go:532` → private `completionIngressAt` (`registry.go:338-350`) | mem | per request |
| Provider-reported usage + cache | `provider.go:1888-1902, 2147-2169, 2229` | `usage` row (async); row `prompt/completion/reasoning_tokens, cost_micro_usd, final_status`; DD-C `inference.completions{model}`, `inference.prompt_tokens(_total)`, `inference.completion_tokens(_total)` `:2231-2243`; DD-C `routing.cache_usage{outcome,tier}`, `routing.cache_tokens`, `routing.cache_prefill_tokens_saved`, DD-H `routing.cache_stage_ms` — **cache fields have no row column** | per completion |
| `actual_decode_tps` | `provider.go:2190-2227` = completion tokens ÷ (`FirstChunkAt` → completion), clamped | row `actual_decode_tps`; DD-H `inference.decode_tps{model,kv_backend,…}` (`kv_backend_metrics.go:39`) | per completion |
| Settlement (reputation persist, price lookups, ledger charge/credit) | `provider.go:1915-2143, 2275-2335` — synchronous **before** `CompleteCh` is signalled `:2343-2347` | DD-H `store.debit/credit.latency_ms{op}` only (aggregated); log `inference complete{request_id,provider_id,prompt_tokens,completion_tokens,cost_micro_usd,provider_payout_micro_usd}` `:2352-2359` | per completion |
| OR-uptime outcome | `api/or_uptime.go:41, 59-93` (commit time) | DD-C `inference.request_outcome{model,class,kv_backend,kv_backend_fallback}`; `/v1/completions`, `/v1/messages` excluded `:55-64` | per request |
| Pre-dispatch rejection | `recordRejection` `api/rejection_telemetry.go:66-158` (counterfactual `QuickCapacityCheck` on the sink worker `:131-157`) | rej row (`stage, reason_code, http_status, client_class, requested/resolved_model, shape, could_have_served, candidate_count, *_rejections, warm_provider_existed, best_ttft_ms, retry_after_ms`); DD-C `inference.request_outcome` `:121`. **Not recorded:** 401s (`server.go:2261-2373`), vision/tools fail-fast 503/400 (`api/inference_preprocess.go:196-287`), drain-gate 429s (`api/drain.go:80-101`) | per 4xx/5xx exit |
| Exhausted ladder | `dispatch.go:3149-3278` | telemetry event `inference failed after N attempt(s){reason,attempt,status_code,last_error,kv_backend}` `:3214`; DD-C `inference.dispatches{status:failure}` `:3226`; rej `{stage:dispatch}` `:3242-3244`; **no `X-Timing`** | per exhausted request |

### 2.3 Wire: provider → coordinator, per request

| Message | Fields carried | Coordinator sink |
|---|---|---|
| `inference_accepted` (`messages.go:422-425`) | `request_id` only — no timestamp, queue position, admission info | discarded (above) |
| `inference_response_chunk` (`:430-435`) | `request_id`, `encrypted_data` — no sequence number, no timestamp, no token count | decrypted `provider.go:1606, 1711-1744`; relayed |
| `inference_complete` (`:528-535`; `UsageInfo :438-455`; built `ProviderLoop+InferenceHandler.swift:1168-1178`) | `prompt_tokens`, `completion_tokens`, `reasoning_tokens`, `cache_outcome`, `cache_tier`, `cached_tokens`, `prefill_tokens_saved`, **`cache_stage_ms` (the only provider-side duration on the wire)**, `stop_sequence`, `se_signature`, `response_hash` | `usage` row; row outcome; DD cache counters (§2.2) |
| `inference_error` (`:538-570`) | `status_code`, `error_reason`, `failure_code` (11 values `protocol/inference_failure.go:17-29`), `terminal_cause` (8 values `api/terminal_cause.go:32-39`), `attempt_usage` (observability only `:559-565`); `error` text never read | row `error_code/class/reason`; DD-C `inference.typed_terminal{cause}` `terminal_cause.go:99-121` (**no column**); DD-C `inference.error{reason}` `route_outcome.go:13` |
| `prefix_cache_lookup/ready` (`:457-479`), `_v2` (`:490-525`) | `outcome`, `tier`, `cached_tokens`, `prefill_tokens_saved`, `stage_ms`, `ready_tokens`, anchors (v2) | DD-H `exact_cache.ssd_stage_ms{event}` (`api/exact_cache_telemetry.go:46, 61` via `provider.go:553-591`); **not on the row** |
| **Absent on every message** | any timestamp; decrypt/parse/admission/model-load-wait/engine-queue/prefill/decode durations; batch occupancy at admit; per-request MTP; `finish_reason`; frames/bytes emitted; engine ids | — |

### 2.4 Provider process (Swift) — measured, then kept in memory or discarded

| Datum | Producer | Fate |
|---|---|---|
| `receivedAt` (WS frame) | `CoordinatorClient+Connection.swift:374` | only derives `FirstContentDeadline` (`CoordinatorClientTypes.swift:14-48`); never logged |
| decrypt, JSON parse/normalize, `fastAdmissionReject` (may `MLX.Memory.clearCache()` `ProviderLoop+ModelLoading.swift:960`), `inference_accepted` send | `ProviderLoop+InferenceHandler.swift:231-246, 287-307, 357, 404` | no stamps |
| `ensureModelLoaded` | cold load timed `ProviderLoop+ModelLoading.swift:358, 644-647` → `recordModelLoadTime` → heartbeat `model_load_time_ms`; warm path `:209-210` and parked-behind-another-load waits (`:213-216, 262-277`) | cold only |
| Template render + tokenize; tool-constraint compile; vision tower | `MultiModelBatchSchedulerEngine.swift:546-551, 615-634, 281-529` | none; `promptTokens.count` known here, first recorded at terminal usage |
| SSD prefix-cache stage | `KVCacheSSD/SSDPrefixCache.swift:1271-1290` | `UsageInfo.cacheStageMs` → wire (the one duration that ships) |
| Shared-KV reserve outcome/latency | `EngineV2Bridge.swift:739-806` | none; rejection → 503 `token_budget_exhausted` |
| Engine `projectedWork` (`prefillTokens, decodeTokens, scheduledSteps, mixedSteps, serviceDuration`) | `EngineV2Bridge.swift:879` (`case .admitted(let stream, _, …)`) | **discarded** |
| `submittedAt`, `firstTokenAt`, `firstEmissionTokens`, `completionTokens` (`ActiveRequestState` `EngineV2Bridge.swift:242-253`) | set `:852, 996-1005`; `recordFirstToken :1764-1773` | mem; prefill = `firstTokenAt − submittedAt` never emitted per request |
| Per-request decode `tps` | `recordFinish :1785-1831` | folded into decode EWMA `:1811-1821` and cold-prefill sample `:1822-1829, 1868-1897` (heartbeat EWMAs); yielded as `.info(tokensPerSecond)` `:1683, 1695` then **discarded** `MultiModelBatchSchedulerEngine.swift:846` |
| `promptTime`, `generationTime` (`Date`-based) | `MultiModelBatchSchedulerEngine.swift:935-948` | **discarded** `libs/mlx-swift-lm/Libraries/MLXLMServer/Runtime/MLXOpenAIService.swift:189-196` (reads only tokens + `stopReason`) |
| Frames/bytes emitted, send completion, chunk-queue depth | `ProviderLoop+InferenceHandler.swift:845-980`; `Coordinator/ChunkFrameWriter.swift:67-73` | none |
| SE signing, terminal flush barrier | `ProviderLoop+InferenceHandler.swift:1162-1167`; `ProviderLoop.swift:54-62` | none |
| `ProviderStats` counters | `ProviderLoop+InferenceHandler.swift:1155-1156`; `ProviderLoop+Cancellation.swift:25` | heartbeat `stats` (cumulative) |
| Cancel → engine abort latency, tokens after cancel | `ProviderLoop+Cancellation.swift:20-78` | none |
| `[requestId] Complete: N prompt + M completion tokens` | `ProviderLoop+InferenceHandler.swift:1189-1191` | os_log, `privacy: .private` |
| Every `TelemetryEvent` (engine_health, oom, slot posture, prefix replay, tool constraint …) | `Telemetry/EngineHealthEvent.swift:63-76` and ~14 builders | dropped (`TelemetryClient.swift:69-81`) unless a test injects `emitTelemetry` |

### 2.5 Engine (`libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/`) and MLX

| Datum | Producer | Fate |
|---|---|---|
| `CBv2ScheduledRequest{arrivalSeq, submittedAt: Date, numComputedTokens, status, preemptionCount, prefixReusePlan}` | `SchedulerV2.swift:54-75` | mem; **no** per-request scheduled / prefill-start / prefill-end / first-token / finish stamps exist in the engine |
| `CBv2Usage` on `.finished` | `CBv2Contracts.swift:777-816` (`promptTokens, completionTokens, prefixCacheOutcome, MatchedTokens, PrefillTokensSaved, Strategy, ReplayTokens, BoundarySplits`) | bridge copies the cache fields into `UsageInfo`; replay/boundary fields dropped |
| Deadline leases (`admissionDeadline, progressDeadline, phase, safetyDeadline`) | `CBv2DeadlineLeases.swift:178-207` | `terminal_cause` on expiry/watchdog |
| Loop counters `stepCount, chainedStepCount, preemptionCount`, packed-prefill rows/groups | `EngineLoopV2.swift:687-689, 695-696` → `EngineV2.swift:149-154` | provider reads only `stepsExecuted` |
| `CBv2CapacitySnapshot{activeRequests, waitingRequests, kvBytesInUse/Capacity/BackendCapacity/Reserved, activeTokens, stepsExecuted}` | `publishGauges` after every step `EngineLoopV2.swift:3603-3649`; struct `CBv2Contracts.swift:838-886` | overwrite-only gauge → heartbeat slot (§3.1); raw KV bytes stay provider-local |
| `CBv2StepProfiler` — 12 phases (`v2.step.wall` `EngineLoopV2.swift:1762-1770`, forward/sampler build `:2265-2285`, `asyncEval.submit`/`launch.total` `:2294-2300`, `readback.wait` `:2747-2757`, MTP phases) | `StepProfilerV2.swift:15-133`; env `CBV2_STEP_PROFILE` `:19-22`; `NSLock` + string key per sample `:34-40`; wall clock `:47-49` | opt-in, aggregate `summaryTable()` `:109-132`; consumers: `BenchCBv2` profile mode, tests; **nothing in `provider-swift` reads it**; `executeMixed` has no timers |
| MTP `CBv2MTPMetrics` (rounds, proposed/accepted, per-position acceptance, cost EWMAs) | `MTP/MTPContractsV2.swift:471-530`; per-request accept counts transient (`MTP/EngineLoopV2+MTPFinalize.swift:100-125`) | cumulative per slot → 60 s posture sampler (`EngineV2Bridge+MTP.swift:31-49`, telemetry dropped), local `/metrics`, os_log `:67-79` |
| MLX `Memory.activeMemory/cacheMemory/peakMemory` | `libs/mlx-swift/Source/MLX/Memory.swift:175-251` | heartbeat `gpu_memory_*` |
| `Memory.numResources/resourceLimit` (Metal buffer count) | `Memory.swift:207-226` | env-gated `[rsrc]` log only |
| `EvalProbe.inFlight/currentEvalElapsedMs/evalsCompleted/longestEvalMs` | `libs/mlx-swift/Source/MLX/EvalProbe.swift:100-123` | **no producer** in the v2 provider (only `Protocol/Types.swift:534` declares `eval_in_flight_ms`) |
| GPU time, per-kernel time, `os_signpost` | — | none committed; `DiagnosticTrace*` is uncommitted working-tree code, diagnostics-only |

## 3. System-level data

### 3.1 Heartbeat (provider → coordinator)

Cadence: every `coordinator.heartbeat_interval_secs`, **default 5 s** (`Config/ProviderConfig.swift:323, 338` → `ProviderLoop+Serve.swift:147`; the 30 s in `CoordinatorClientTypes.swift:158` is an overridden initializer default). Capacity refresh tick = `max(1, interval/2)` = 2 s (`ProviderLoop+Capacity.swift:22-23`), so slot data is ≤ 2 s stale; `SystemMetrics` sampled at send. Built by `buildHeartbeatJSON` (`CoordinatorClient+Registration.swift:68-124`). DB persistence is throttled to once per 30 s per provider (`registry/persistence.go:201`) and overwrites (`providers` row).

| Group (`protocol/messages.go`) | Fields | Producer | Consumer |
|---|---|---|---|
| top-level `:234-262` | `status`, `active_model`, `warm_models`, `prefix_cache_protocol`, `prefix_cache_v2_models`, `prefix_cache_statuses`, `prefix_cache_donation_outcomes`, APNs token | `CoordinatorClient+Registration.swift:69-110` | `Registry.Heartbeat` `registry/registry.go:3328-3469` (status `:3435-3444`, warm models `:3425-3429`); `UpdatePrefixCacheSnapshot` `api/provider.go:484-497` |
| `stats` (`HeartbeatStats` `:405-416`) | `requests_served`, `tokens_generated`, `cancellations_received/before_output/partial_complete`, `generation_errors_after_output`, `chunk_encryption_errors`, `stream_closed_without_terminal`, `cancel_during_model_load`, `usage_gaps` (cumulative) | `AtomicProviderStats` `Coordinator/CoordinatorClientState.swift:12-132` | `applyHeartbeatStatsDelta` `registry.go:3359` → `p.Stats` → `/v1/stats`, `providers.lifetime_stats` |
| `system_metrics` (`:398-402`) | `memory_pressure` (VM used/total), `cpu_usage` (**1-min loadavg ÷ cores**, not instantaneous), `thermal_state` (4-level `ProcessInfo`) | `Hardware/SystemMetrics.swift:6-72` | `p.SystemMetrics` `registry.go:3361` → routing `healthMs`; route-row snapshot; `/v1/me/providers` |
| `backend_capacity` (`BackendCapacity` `:379-396`) | `gpu_memory_active/peak/cache_gb`, `total_memory_gb`, `free_for_load_gb`, `mlx_cache_reclaimer{cache_limit_bytes, sweep_signals, reclaims, reclaimed_bytes, last_reclaimed_bytes, last_reclaim_duration_ms}` (`:367-374`) | `ProviderLoop+Capacity.swift:127-162` | `p.BackendCapacity` `registry.go:3350-3364` (**nil until the first heartbeat**); DD-G `provider.mlx_memory.{active,peak,cache}_gb{provider_id}`, `provider.mlx_cache.*{provider_id}` `api/provider_mlx_cache_telemetry.go:18-32`; route-row snapshot |
| `backend_capacity.slots[]` (`BackendSlotCapacity` `:267-361`) | `model`, `state`, `num_running`, `num_waiting`, `max_concurrency`, `active_tokens`, `max_tokens_potential`, `observed_decode_tps` (EWMA α 0.3), `observed_prefill_tps` (cold-prefill EWMA), `active_token_budget_used/max`, **`queued_token_budget` (always 0)**, `kv_bytes_per_token`, `model_load_time_ms`, `kv_backend`, `kv_backend_fallback_reason`, `steps_executed`, `admits`, `first_tokens_emitted`, `seconds_since_last_step`, `seconds_since_last_first_token`, `wedge_suspected`, **`eval_in_flight_ms`, `idle_clear_in_flight_ms` (never populated)** | `EngineV2Bridge+Capacity.swift:42-222` (`queuedTokenBudget: 0` `:191`) ← `CBv2CapacitySnapshot` | `routingSnapshot` `registry/scheduler.go:1216-1303`; `TPSRegistry.Record/RecordSolo` `registry.go:3399-3402`; sticky `p.kvBackends` `:3371`; DD-C `provider.first_token_wedge_suspected{model}`, `provider.eval_in_flight_long` `api/provider_wedge_telemetry.go:86-98`; **`model_load_time_ms` decoded but not used by routing** (flat `slotStatePenaltyUnknown` `scheduler.go:18`) |
| Registration (once, `:183-220`) | `Hardware{chip_name, chip_family, chip_tier, memory_gb, gpu_cores, cpu_cores}` `:103-114`, `models[]`, version, keys; `prefill_tps`/`decode_tps` fields `:192-193` **never populated** (`Coordinator/CoordinatorClientCodec.swift:41-64`) | `Register` `registry.go:3100-3238` | `p.Hardware`, `p.Models`; `providers` row; route-row snapshot |

Not reported by the provider at all: GPU utilisation/power/fan, kernel memory-pressure level, per-slot KV pool bytes (`kvBytesInUse/Reserved/Capacity` read at `CBv2Contracts.swift:838-880` but only derived token budgets ship), current batch size / steps-per-second / oldest-waiting age, MTP posture (local only), isolated prefill EWMA, update phase, reconnect count.

### 3.2 Coordinator fleet gauges (`StartDDGaugeLoop`, every 15 s, `api/server.go:2003-2064`)

`providers.online`, `providers.per_model{model}`, `providers.per_version{version}`, `providers.by_trust_status{trust_level,status}`, `providers.by_mdm_failure{reason}`, `attestation.code_attested`, `attestation.code_enforced`, `coordinator.min_provider_version_set`, `request_queue.depth` (total only, `:2045`), `utilization.{network,warm,token_budget,bottleneck}`, `utilization.model{model}`, `capacity.{tps,demand_concurrency,serving_capacity,spill_arrival_rate}` — computed from `NetworkUtilizationSnapshot` (`registry/utilization.go:214-219`) = `ModelCapacitySnapshot` (`registry.go:5193-5434`, per-provider `providerCapSnap` `:5154-5176` **discarded after aggregation**) ⋈ warm-pool ⋈ fleet snapshot. Also on demand: `/v1/stats` (60 s cache, `api/stats.go:87-295`), `/v1/admin/utilization` (`api/admin_utilization.go:9-14`), `/v1/models/capacity` (`api/capacity.go:24`). Warm-pool tick every 10 s logs `warm_pool_tick` (`registry/warm_pool_controller.go:246-266`), not persisted. Throughput-anomaly sweep every 5 m → DD-C `routing.throughput_anomaly{model,chip_family}` (`api/throughput_anomaly.go:29, 161-181`).

### 3.3 Registry fault / cooldown / calibration state

| Tracker (`registry/`) | Trip counter emitted | Current state observable? |
|---|---|---|
| Dispatch-load cooldown `registry.go:1697` | DD-C `routing.load_failure_cooldowns{model}` `api/provider.go:2464` | no |
| Inference-error cooldown `registry.go:1716-1717` (`error_cooldown.go:40-48`) | DD-C `routing.cooldown_entered{model}` `api/consumer.go:365` | no |
| Capacity-reject cooldown `registry.go:1754-1756` (`capacity_cooldown.go:72-76`) | DD-C `routing.capacity_cooldown_tripped{provider_id,model}` (`consumer.go:444`) — the only fault counter with `provider_id` | accessor `CapacityCooldownActive` `capacity_cooldown.go:456` — **no non-test caller** |
| Budget clamp `registry.go:1765` (`budget_clamp.go:78`) | none | `BudgetClampActive` `budget_clamp.go:387` — no caller |
| Capacity-503 rate penalty `registry.go:1775-1776` (`capacity_rate.go:57-69`) | none (`CapacityRateMs` not persisted) | `CapacityRejectRate` `capacity_rate.go:209` — no caller |
| Node-health breaker `registry.go:1736-1738` (`provider_breaker.go:39-63`) | DD-C `routing.provider_breaker_open/closed{model}` `consumer.go:373, 510` | `ProviderBreakerOpen` `provider_breaker.go:307` — no caller |
| Health ejection `registry.go:1782-1797` (`health_ejection.go:36-64`) | DD-C `routing.provider_ejected/ejection_recovered{model}` `consumer.go:379, 516` | `HealthEjectionOpen` `health_ejection.go:539` — no caller |
| TTFT calibration (200-sample median per `(model, chip)`, clamp [0.2, 1.5]) `ttft_calibration.go:64-88, 157-173` | DD-G `routing.ttft_calibration_ratio{model}` `api/settlement.go:159` | gauge only; windows not exported |
| `TPSRegistry` fleet-median / solo samples `tps_registry.go:22-40, 61-77` | none | no |
| Reputation `reputation.go:34-47` (`RecordJobSuccess/Failure/Latency` `registry.go:4877-4936`) | none | `provider_reputation` row (30 s throttle, overwritten `persistence.go:218-230`); owner dashboard only — **not consumed by the scheduler** |
| Stable identity `serial:`→`sekey:`→`acct:` (`health_ejection.go:112-128`) | — | keys fault maps, survives reconnect; **not** on any row (rows carry the per-connection `provider_id`) |
| Provider sessions | — | `provider_sessions` row per WS connection with close reason (`store/postgres.go:763-777`; `ClassifyDisconnectReason` `registry/disconnect_classify.go:26`); DD-C `ws.disconnects{reason}` `api/provider.go:207, 225` |

### 3.4 Provider-local surfaces

| Surface | Where | Contents / caveats |
|---|---|---|
| Local `/metrics` (Prometheus text; unified `--local-endpoint` mode only) | `Server/LocalInferenceHTTP.swift:43, 93` → `Server/LocalMetricsResponder.swift:52-94` | upstream `ServerMetrics` request/token totals + per-slot `mtp_enabled`, `mtp_active`, `mtp_inactive_reason{model,reason}`, `mtp_rounds_total`, `mtp_tokens_proposed_total`, `mtp_tokens_accepted_total`. No latency histograms |
| Daemon state file `~/.darkbloom/daemon-state.json` | schema `Service/DaemonStateFile.swift:17-58`; written on the 2 s tick `ProviderLoop+Trust.swift:26-73` | `pid, version, writtenAt, startedAt, trust, currentModel, warmModels, inferenceActive, stats{requestsServed,tokensGenerated,usageGaps}, capacity{totalMemoryGb,gpuMemoryActiveGb,gpuMemoryCacheGb}, lastModelLoadError, slots[]{model,kvBackend,kvBackendRequested,kvBackendFallbackReason,mtpEnabled,mtpActive,mtpInactiveReason,loadError}, connectivity`; `system` is **nil** (`currentDaemonState` `:35-73` never sets it). Read by `darkbloom status`/`doctor` |
| macOS unified log | subsystem `dev.darkbloom.provider` categories `coordinator`, `coordinator.chunks` (`Coordinator/CoordinatorClient.swift:28, 122`), `security` (`Security/EnvironmentScrubber.swift:6`), SSE parser (`ProviderLoop+SSEParser.swift:334`), `loop`; subsystem `com.darkbloom.provider` categories `engine_v2` (`Inference/EngineV2Bridge.swift:310`), `engine_v2_mtp` (`EngineV2Bridge+MTP.swift:9-10`), `ssd_write_behind` (`KVCacheSSD/SSDWriteBehind.swift:164`), SSD cache loggers | every free-form line is `privacy: .private` (`ProviderLogger.swift:77-96`) → `<private>` in `log show`; only the closed `ProviderOperationalMessage` vocabulary (`:122-164`) is public. `darkbloom logs`/`report` read only `dev.darkbloom.provider` (`darkbloom/LogsCommand.swift:36`), so engine/MTP/SSD lines are never collected |
| 60 s per-slot MTP posture line | `EngineV2Bridge+MTP.swift:67-79` | os_log only |
| OOM marker / crash-report scan | `Diagnostics/OOMDetector.swift`; `ProviderLoop+MemoryProtection.swift:33-47` | next-launch attribution only |

There is no per-request local record of any kind (no JSONL, ring buffer, or SQLite).

## 4. Sinks

### 4.1 Postgres (`store/postgres.go`; DDL replayed on every boot `:138-147, 1043-1047`; prod = AWS RDS PostgreSQL 17.9 with a physical read replica, **INFERRED** from `reports/2026-08-11-rds-to-cloudsql-migration-plan.md`)

| Table | Grain | Writer | Retention |
|---|---|---|---|
| `inference_routes` (DDL `:781-862`, ALTERs `:891-905`, ~80 columns, no JSONB) | 1 row per **(request_id, attempt)** | INSERT `RecordInferenceRoute` `:1680-1802` (5 s timeout, `ON CONFLICT (request_id, attempt) DO UPDATE` `:1727`) from `api/dispatch.go:469`; 2-3 UPDATEs `UpdateInferenceRouteOutcome` `:1805-1853` from commit/relay/terminal goroutines (`api/route_outcome.go:138-165`); **0 is "unset"** for every numeric (`COALESCE`/`CASE WHEN <> 0` `:1815-1839`). All via the sink (§4.5). Indexes `created_at`, `(provider_id, created_at)`, `(model, created_at)`, `request_id` `:863-866` | **none** |
| `request_rejections` (`:918-961`) | 1 row per recorded 4xx/5xx exit | `RecordRejection` `:1995-2043` (**error discarded** `:2015`); `request_id` column exists, **never populated** | none |
| `usage` (`:251-268`) | 1 row per billed completion (`request_id` = attempt UUID; `request_location` JSONB coarse geo) | `RecordUsageFullWithPublicModel` `:1635-1653` (also bumps `usage_totals` `:728-733`) from `api/provider.go:2167-2169` | none |
| `provider_earnings` (`:622-635`), `ledger_entries` (`:292-307`) | 1 per paid job / per balance mutation | `CreditProviderAccount` `api/provider.go:2294`; ledger | none (~900 k rows / 443 MB by 2026-06-20 `:1016`) |
| `providers` (`:149-178`), `provider_reputation` (`:212-222`) | 1 per provider, **overwritten** (no history) | `UpsertProvider` `:4471-4510` via 30 s throttle `registry/persistence.go:200-215` | n/a |
| `provider_sessions` (`:763-777`) | 1 per WS connection (open/last_seen/close reason) | `registry.go:3218, 4277`; `api/provider.go:171` | none |
| `provider_log_reports` (`:742-756`) | 1 per operator `darkbloom report` upload (BYTEA, ≤ 10 MiB) | `api/log_report_handlers.go:16-56` | none |
| `telemetry_events` | **removed** 2026-05-28 (`:719-724`) | — | — |

No DELETE/partition exists for any of these (the only sweep is `device_codes` `:3927`). Readers cap at 50 000 rows newest-first (`store/interface.go:92-97`). `inference_routes` has exactly one reader in the repo: the admin routes handlers (§4.5); admin-ui reads `usage`/`providers`/`provider_sessions` from the replica, never `inference_routes`.

### 4.2 Datadog (`datadog/datadog.go`; namespace `d_inference.` `:117`; enabled only when `DD_API_KEY` or `DD_AGENT_HOST` is set `cmd/coordinator/main.go:364-382`)

| Family | Transport | Notes |
|---|---|---|
| Counters (`Incr/Count`), gauges | HTTPS `POST /api/v1/series` when `DD_API_KEY` is set (`:155-161, 169-180, 192-203`; `metrics_http.go`), 5 s flush, no sampling (rate 1 `:178, 188, 201`); else DogStatsD UDP `localhost:8125` | ~180 unique names across 311 call sites; tags bounded (§1) except `model` (catalog-sized) and `provider_id` on `provider.mlx_*`, `routing.provider_selected`, `routing.capacity_cooldown_tripped` |
| Histograms (`Histogram`) | **DogStatsD only** (`:182-189`; rationale `metrics_http.go:12-21` — percentiles aggregate agent-side) | ~21 names incl. `inference.ttft_ms`, `inference.decode_tps`, `http.latency_ms`, `store.*.latency_ms`, `routing.cache_stage_ms`, `exact_cache.ssd_stage_ms`, `inference.media_fetch.duration_ms`. Dev VM installs Agent 7 (`deploy/gcp/vm-startup.sh:221`); **no `DD_*` key in any prod artifact** (`deploy/gcp/prod/required-env-keys.txt`), so if prod runs API-key-only every histogram is dropped there — **INFERRED**, confirm against `/etc/d-inference/env` before trusting any DD percentile |
| APM | tracer started `main.go:367-371`; `datadog/slog.go:33-41` injects trace ids | **zero spans created** anywhere in `coordinator/`; dashboard `trace.http.request.*` widgets are dead |
| Logs API | `ForwardLog` `:237-286` (batch 100 / 5 s, attrs `request_id`, `session_id`, `version`, free `Fields`; fatal → DD Event `:283-285`) | fed only by the emitter (§4.3); no buffer cap between flushes |

### 4.3 Coordinator telemetry emitter (`telemetry/emitter.go`)

Coordinator-authored events only (`:3-8`): `Emit` mirrors every event to slog with all fields as attrs `:79-95`, bumps in-proc `telemetry_events_total` (`api/metrics.go:53`), forwards to Datadog Logs `:107-119`. Event shape `{Timestamp, Severity, Kind, Message, Fields, RequestID, Stack}` `:124-132`; **no field allowlist** on this path. Emitters: `emitRequest` (`api/server.go:857-868`, kind forced `inference_error`, carries the attempt UUID) from `api/dispatch.go:1850, 1907, 2124, 2934, 2969, 3017, 3214`; `emitPanic` `server.go:898-908`; provider connectivity/oom/registered/attestation events `api/provider.go:213, 242, 317, 1564`. Volume: zero events for a healthy request.

### 4.4 In-process registry (`api/metrics.go`; `GET /v1/admin/metrics`, `?format=prom` `api/server.go:1952, 2095-2110`)

`http_requests_total`, `http_request_duration_ms`, `inference_dispatches_total{result}`, `exact_cache_*`, `telemetry_events_total`, `FleetSnapshot{Connected, Idle, QueueDepth}` gauges (`registry.go:5099-5132`). Always on, never bridged to Datadog.

### 4.5 Admin export endpoints and the write sink

`GET /v1/admin/routes`, `/v1/admin/routes/export`, `/v1/admin/rejections`, `/v1/admin/rejections/export` (`api/server.go:1972-1976`; handlers `api/admin_telemetry.go:29-118`): `Authorization: Bearer $EIGENINFERENCE_ADMIN_KEY`; `?since=<Go duration | RFC3339>` (default 24 h `:124-140`); filters `provider`, `model`, `outcome`, `final_status`; browse limit 1000 (`:22`); export `?format=csv|ndjson` (default csv) up to the 50 000-row cap. All route/rejection writes go through `telemetrySink` (`api/telemetry_sink.go`): 4096-slot channel, **1 worker** `:32-35`, non-blocking submit that **drops on full** `:102-113`, drops logged only at powers of ten `:133-141`, **no DD counter for drops**, buffered writes discarded on shutdown `:118-126`. No on/off or sample-rate flag exists (promised in `routing-telemetry-and-calibration.md:403-405`).

## 5. Known defects and gaps (as of this inventory)

Items marked ➜ are addressed by the system profiler (see the pointer at the end).

- ➜ **Unjoined request ids.** HTTP `X-Request-ID` and the attempt UUID meet only in one log line (`api/dispatch.go:3091-3098`); no row carries both; N attempts = N rows under N `request_id`s with no parent key; `request_rejections.request_id` is never set (`api/rejection_telemetry.go:66-158` has no `RequestID` assignment; column at `store/postgres.go:918-961`). Provider `req-…`/engine ids are never logged beside the coordinator id (`ProviderLoop+Cancellation.swift:28-31`).
- ➜ **`X-Timing` mislabeling** (`api/dispatch.go:3409-3456`): (1) `parse_us` includes the client body socket read (`api/inference_preprocess.go:95`) and an uncached `GetModelRegistryRecord` (`api/consumer.go:1664`); (2) `reserve_us` includes the `KeySpendSince` DB read and the ledger debit; (3) `route_us` includes a second uncached registry read (`consumer.go:1995`), the sidecar plan HTTP call, and — for queued requests — the **entire queue wait** (`RoutedAt` stamped after `WaitForProviderContext`, `dispatch.go:1346`), so `route_us` and `queue_us` double-count (same on the row `route_ms`/`queue_wait_ms`, `dispatch.go:518-520`); (4) `encrypt_us` includes `reserveAdditionalForProvider` — up to two DB reads and a ledger write (`consumer.go:1420-1453`) — and the route-row build under `provider.Mu()` (`dispatch.go:425-455`); (5) `dispatch_us` stops at writer dequeue, so the 5-30 s socket write (`registry/provider_writer.go:550-566`) lands in `provider_us`; (6) `provider_us` is stamped at consumer dequeue, not WS ingress (`registry.go:551` vs `:273-275`); (7) row `dispatch_ms` = header `provider_us`, and header `dispatch_us` is not persisted (`dispatch.go:521` vs `:3447-3449`); (8) backup-won requests report `parse/reserve/media/route/queue = 0` (fresh `RequestTiming` `dispatch.go:1989`); (9) retried requests can report **negative** `provider_us` (first-write-wins `FirstChunkAt` `registry.go:550-552` + overwritten `DispatchedAt`; header unclamped, row clamped `route_outcome.go:479`); (10) nothing before `ReceivedAt` (middleware, auth incl. a DB read `server.go:2362`, rate limits, sealed decrypt) or after commit (streaming, `[DONE]`, settlement wait `api/provider.go:2335-2347`) is covered; no header on any rejected/exhausted response.
- **Provider measures, then discards:** `tokensPerSecond` (`MultiModelBatchSchedulerEngine.swift:846`), `promptTime`/`generationTime` (`:935-948` → `MLXOpenAIService.swift:189-196`), engine `projectedWork` (`EngineV2Bridge.swift:879`); prefill duration `firstTokenAt − submittedAt` exists per request (`EngineV2Bridge.swift:242-253`) but ships only as EWMAs.
- **`queued_token_budget` hardcoded 0** (`EngineV2Bridge+Capacity.swift:191`; persisted as a real column `store/postgres.go:781-862` and consumed by the scheduler `registry/scheduler.go:1266-1272`) — indistinguishable from a measured zero. The profiler's fleet samples carry the field as reported; the producer gap stays on the provider.
- **`eval_in_flight_ms` / `idle_clear_in_flight_ms` have no producer** (`Protocol/Types.swift:534`; `EvalProbe` never read in `provider-swift`); registration `prefill_tps`/`decode_tps` likewise (`CoordinatorClientCodec.swift:41-64`). Same note: sampled as reported, not produced, by the profiler.
- ➜ **Routing explanation is discarded:** the full candidate pool with per-candidate cost terms (`registry/scheduler.go:607-616`) is dropped by `selectBestCandidateScanLocked` (`:865-878`, winner only); no runner-up; `providerPassesRoutingGatesLockedEx` returns a bare bool over ~13 leaf checks (`:1119`); the tie-break path incl. `rand.Intn` (`:882-950, 947`) is not recorded; `crashed/reloading`, thermal-critical and admit-re-check drops carry no reason (`:1521-1530, 470-481`); nothing inside `ReserveProviderEx` (global write lock `:399-400`) is timed; `QuickCapacityCheck` calls are untimed; `logRoutingDecision` is Debug-only (`:1052-1074`).
- ➜ **No per-provider time series.** Per-heartbeat slot occupancy/budget/TPS is never sampled or stored (`providerCapSnap` discarded `registry.go:5154-5176`); only `provider.mlx_memory.*`/`provider.mlx_cache.*` are per-provider gauges; `route_ms` under lock saturation (08-31) was visible only via post-hoc SQL. Planned `provider_capacity_samples`/`inference_route_candidates` tables (`routing-telemetry-and-calibration.md`) do not exist in `store/`.
- ➜ **Telemetry sink drops are uncounted** in Datadog (`api/telemetry_sink.go:102-141`), and the counterfactual `QuickCapacityCheck` for rejections shares that single worker (`rejection_telemetry.go:140-157`).
- ➜ **Streaming phase unobserved:** no first-byte-to-client, last-byte, chunk count, bytes, inter-chunk gap, flush stall, or client-backpressure datum (`consumer.go:2131-2265`); `inference_accepted` discarded (`dispatch.go:1829-1832`); socket-write completion unstamped (`provider_writer.go:560`).
- **Provider-internal lifecycle absent from the wire** (§2.3): decrypt/parse/admission/model-load-wait/engine-queue/prefill/decode durations, batch occupancy at admit, `terminal_stage`, tokens after cancel, cancel→abort latency. `client_gone` rows therefore say nothing about provider progress.
- **`CBv2StepProfiler` opt-in only** (`StepProfilerV2.swift:19-22`), string-keyed with an `NSLock` per sample and a wall clock; no per-request or per-step identity; `executeMixed` untimed; never run against production.
- **No `os_signpost`** anywhere in `ContinuousBatchingV2/` or `provider-swift` (grep, 2026-09-02); no committed GPU-time source (`libs/mlx` completion handlers read no timestamps).
- **No stable provider identity on rows.** `provider_id` is a fresh UUID per WebSocket connection; the serial/SE-key lineage that keys fault state (`registry/health_ejection.go:112-128`) is not on `inference_routes` or any metric, so per-machine attribution needs a `providers.serial_number` dedupe by hand. Fix #3 of `docs/reports/2026-07-03-reconnect-churn-root-cause.md` never shipped.
- **Coverage holes:** `/v1/completions` and `/v1/messages` share `dispatchState.run()` but are excluded from `inference.request_outcome` (`api/or_uptime.go:55-64`); 401s, vision/tools fail-fast, and drain-gate 429s bypass `recordRejection`; cache usage (`cached_tokens`, `prefill_tokens_saved`, `cache_stage_ms`) and `terminal_cause` land only in Datadog, never on the row.

The system profiler (`docs/architecture/system-profiler.md`, in progress on branch `feat/system-profiler`) addresses the items marked ➜ above: a per-request profile record keyed by a coordinator-minted correlation id set in middleware (never the client-supplied `X-Request-ID`) plus the attempt UUID, gate-rejection reasons and the candidate/runner-up set, periodic fleet samples, counted sink drops, and writer/socket/last-chunk stamps. Provider-side discards, the missing engine/MLX producers, `os_signpost`, and stable identity remain open.

## 6. How to query what exists today

All SQL runs read-only against the replica (or via the coordinator SSH path); always bound `inference_routes` by `created_at`. Admin endpoints need `Authorization: Bearer $EIGENINFERENCE_ADMIN_KEY`.

```sql
-- p50/p95 actual_ttft_ms by model and day (committed requests only; 0 = unmeasured, so exclude it)
SELECT model, date_trunc('day', created_at) AS day, count(*) AS n,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY actual_ttft_ms) AS p50_ms,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY actual_ttft_ms) AS p95_ms
FROM inference_routes
WHERE created_at > now() - interval '7 days' AND final_status = 'success' AND actual_ttft_ms > 0
GROUP BY 1, 2 ORDER BY 2 DESC, 1;

-- Rejection reasons by hour (pre-dispatch + exhausted); could_have_served = counterfactual capacity existed
SELECT date_trunc('hour', created_at) AS hour, stage, reason_code, http_status,
       count(*) AS n, count(*) FILTER (WHERE could_have_served) AS could_have_served
FROM request_rejections
WHERE created_at > now() - interval '24 hours'
GROUP BY 1, 2, 3, 4 ORDER BY 1 DESC, 5 DESC;

-- Every attempt row for one attempt UUID (from X-Inference-Job-ID / chatcmpl-<id>); retries have other UUIDs
SELECT request_id, attempt, outcome, provider_id, final_status, error_reason,
       parse_ms, reserve_ms, route_ms, encrypt_ms, queue_wait_ms, dispatch_ms,
       actual_ttft_ms, dispatch_to_first_chunk_ms, total_duration_ms, actual_decode_tps,
       used_backup, backup_won, candidate_count, capacity_rejections, ttft_ms, best_ttft_ms
FROM inference_routes WHERE request_id = '<attempt-uuid>' ORDER BY attempt;

-- Coordinator overhead tail (the "23 ms p50 / 6,234 ms p99" question); queue_wait_ms double-counts route_ms
SELECT percentile_cont(0.99) WITHIN GROUP (ORDER BY parse_ms) AS parse_p99,
       percentile_cont(0.99) WITHIN GROUP (ORDER BY reserve_ms) AS reserve_p99,
       percentile_cont(0.99) WITHIN GROUP (ORDER BY route_ms) AS route_p99,
       percentile_cont(0.99) WITHIN GROUP (ORDER BY encrypt_ms) AS encrypt_p99
FROM inference_routes WHERE created_at > now() - interval '24 hours' AND outcome = 'selected';

-- Per-machine view: providers.id churns per connection, so group by serial_number
SELECT p.serial_number, count(*) AS attempts,
       count(*) FILTER (WHERE r.final_status = 'success') AS ok,
       percentile_cont(0.95) WITHIN GROUP (ORDER BY r.actual_ttft_ms) FILTER (WHERE r.actual_ttft_ms > 0) AS ttft_p95
FROM inference_routes r JOIN providers p ON p.id = r.provider_id
WHERE r.created_at > now() - interval '24 hours' GROUP BY 1 ORDER BY 2 DESC;
```

```bash
# X-Timing + X-Provider-* + X-Inference-Job-ID on a committed response (header is absent on 4xx/5xx)
curl -sS -D - -o /dev/null https://$COORD/v1/chat/completions \
  -H "Authorization: Bearer $API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"<model>","messages":[{"role":"user","content":"hi"}],"max_tokens":8,"stream":false}' \
  | grep -iE '^(x-timing|x-request-id|x-inference-job-id|x-provider-)'

# Route rows for the last 6 h as NDJSON (cap 50 000 rows newest-first); same shape for /v1/admin/rejections/export
curl -sS "https://$COORD/v1/admin/routes/export?since=6h&format=ndjson&model=<model>" \
  -H "Authorization: Bearer $EIGENINFERENCE_ADMIN_KEY" > routes.ndjson

# In-process counters without Datadog
curl -sS "https://$COORD/v1/admin/metrics?format=prom" -H "Authorization: Bearer $EIGENINFERENCE_ADMIN_KEY" | grep -E 'inference_dispatches_total|http_request_duration_ms'
```

Datadog names to graph (prefix `d_inference.`): `inference.ttft_ms`, `inference.decode_tps` (histograms — DogStatsD only, see §4.2), `inference.request_outcome{class}`, `inference.dispatches{status}`, `routing.decisions{outcome}`, `routing.client_gone{phase}`, `request_queue.depth`, `request_queue.timeout{model}`, `routing.ttft_calibration_ratio{model}`, `providers.online`, `providers.per_model{model}`, `provider.mlx_memory.active_gb{provider_id}`, `store.debit.latency_ms{op}`, `http.latency_ms{path}`. Dead dashboard panels with no producer: `routing.cost_ms`, `telemetry.events_ingested`, `trace.http.request.*`.
