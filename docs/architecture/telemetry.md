# Telemetry

> Last updated: 2026-09-05 · commit `055a76364`

How operational data leaves a provider, what the coordinator does with it, and
why nothing on that path can carry a prompt or slow a request. The heartbeat is
the diagnostic channel; Datadog is the sink; the coordinator is the only
process that emits telemetry *events*. The field-by-field catalogue is in
[`../reference/telemetry-inventory.md`](../reference/telemetry-inventory.md)
and the event contract in [`../reference/telemetry-schema.md`](../reference/telemetry-schema.md).

## Context

Providers run on machines the project does not own, next to prompts the
project must never see. The first telemetry design gave every client (Swift
provider, console, app) a free-form event API posted to
`POST /v1/telemetry/events`, sanitized and stored by the coordinator.
That path is retired: the route answers `telemetry_ingest_disabled` without reading the body ([api-contracts](../reference/api-contracts.md#telemetry-1)), the Swift
`TelemetryClient` and console `telemetry.ts` are no-op facades, and the
`telemetry_events` table is gone. What replaced it is narrower and structural:

- the **heartbeat** already carries every operational fact the coordinator
  needs (status, slot capacity, engine health, GPU memory, allocator counters),
  in a typed shape with no free-text fields except the bounded
  `kv_backend_fallback_reason`;
- the **coordinator** emits its own events about provider connections and
  dispatch failures, from code the project controls;
- **per-request rows** (`inference_routes`, `request_rejections`,
  `request_profiles`) and the profiler's `profile` object hold request-level
  timing without any request content.

The event shape and allowlist survive because they still bound the coordinator
emitter and both client-side filters, and because reviving ingestion would have
to start from them.

## Mechanism

### Heartbeat telemetry

```
provider (every heartbeat_interval_secs, event heartbeats ≤ 2/s)
  → GET /ws/provider frame `heartbeat`
  → providerReadLoop            validate prefix-cache telemetry; reject → routing.cache_telemetry_rejected
  → Registry.Heartbeat          clamp system_metrics to [0,1]; canonicalHeartbeatModelState → clampBackendCapacity;
                                 drop stale capacity_seq (only LastHeartbeat advances); delta-merge stats
  → BackendCapacitySnapshot     the accepted, clamped copy
  → recordBackendWedgeTelemetry provider.first_token_wedge_suspected{model}, provider.eval_in_flight_long
  → recordMLXCacheTelemetry     provider.mlx_memory.*{chip_family,provider_version}, provider.mlx_cache.*{chip_family,provider_version}
  → PersistProviderThrottled    providers / provider_reputation rows, at most every 30 s
```

The baseline cadence is the provider's `heartbeat_interval_secs` ([CLI reference](../provider/cli-reference.md#providertoml-keys-read-by-the-cli)).

Metrics are emitted only from the accepted registry snapshot, never from the
raw frame: values have been clamped (`maxDecodeTPS = 500`, `maxPrefillTPS =
5000`, `maxReportedMaxConcurrency = 24`, …) and slot model IDs constrained to
the connection's coordinator-known inventory. Every 60 s the fleet sampler
(`StartProfilerLoops`) turns the same snapshots into `fleet_snapshots` rows
through the real routing gates; every 15 s `StartDDGaugeLoop` pushes the
platform gauges (`providers.online`, `utilization.*`, `capacity.*`,
`request_queue.depth`). How the scheduler reads the capacity fields:
[`scheduling.md`](scheduling.md); the gate vocabulary: [`routing.md`](routing.md).

`recordMLXCacheTelemetry` emits allocator snapshots as histograms with a
DogStatsD-only client, or as latest-value gauges through HTTPS when
`DD_API_KEY` is configured (`coordinator/datadog/metrics_snapshot.go`,
`HistogramOrGauge`). HTTPS gauges preserve snapshot visibility without
claiming fleet percentiles. It emits
cumulative reclaimer counters as nonnegative deltas from the previous accepted
heartbeat. The first observation has no counter baseline; a reset contributes
no negative delta (`coordinator/api/provider_mlx_cache_telemetry.go`).
`applyProviderHeartbeat` (`coordinator/api/provider_heartbeat.go`) emits only
when `Registry.Heartbeat` accepts the snapshot; stale sequence-stamped frames
still prove liveness but emit no repeated allocator or wedge samples. Tags
never include a provider session id. `sanitizeChipFamilyTag` uses the fixed
M1–M5 family/tier vocabulary plus `unknown`/`other`; client-cancellation metrics
use the same helper (`coordinator/api/chip_family_tags.go`).
`sanitizeVersionTag` maps strict semver to `0.6.x`, `0.7.x`, `0.8.x`, `0.9.x`,
`other_release`, or `prerelease`; missing values are `unknown`, invalid values
are `other` (`coordinator/api/unknown_frame_metrics.go`). Arbitrary patch
numbers and prerelease counters cannot create new series. Exact versions
remain in provider metadata.

### Durable prefix-cache observations

`startSSDPrefixCacheStatsLogger`
(`provider-swift/Sources/ProviderCore/KVCacheSSD/EngineV2Bridge+SSDPrefixCache.swift`)
selects the store actually accepted by the bridge, captures one typed numeric
snapshot immediately, then refreshes at the existing stats cadence. The
`SSDPrefixCacheTelemetryBox` retains only that observation and its monotonic
capture time; capacity refresh attaches it as `slots[].prefix_cache` with an
updated age. Whole-root maintenance contributes three process counters through
`ProviderLoop+Capacity.swift`, including removals from unloaded models. The
[wire reference](../reference/protocol-messages.md#slotsprefix_cache) defines the
fields; no free-form client event transport is used.

`applyProviderHeartbeat` feeds only registry-accepted snapshots to
`recordPrefixCacheTelemetry` (`coordinator/api/provider_prefix_cache_telemetry.go`).
The existing live slot snapshot is the entire counter baseline: a new cache
generation seeds it, removal or missing telemetry clears it, and disconnect
ends the provider lifetime. Repeated sample sequences cannot contribute another
observation or delta; their age still advances, including on the coordinator's
clock. Samples older than five minutes emit age/freshness diagnostics only.
Counters that move backwards contribute no negative delta. Cumulative stage
and write microseconds become counter deltas, while per-request `cache_stage_ms`
remains the latency measurement. Tags are closed cache kind plus existing
bounded chip/version classes; model, generation, prompt and cache identities
never become new metric labels.

Complete-checkpoint donations now settle the existing bounded
`prefix_cache_donation_outcomes` counter once per exported endpoint, including
synchronous refusal, queue overflow, shutdown, write failure and already-durable
success (`SSDHybridCheckpointStore+Write.swift`, `PrefixCacheDonationTelemetry.swift`).
The complete-store `donation_drops_total` counter covers queued-write
`writesDropped` only; prequeue refusals are counted by the donation outcome
snapshot. Maintenance publishes its cumulative result under a separate short
stats lock, so heartbeat reads cannot wait behind filesystem traversal.
The write-job settlement releases its source before the callback. The engine's
later donor-release fence still governs READY; telemetry never manufactures a
holder receipt. Whole-root removal counters and active-store budget evictions
have separate scopes and must not be interpreted as two measurements of the
same sweep.

### Paged allocator observations

The optional [paged-storage wire object](../reference/protocol-messages.md#slotspaged_storage)
keeps native ownership and allocator refusals separate from SSD storage and
request timing. `PagedKVPool.segmentStorageSnapshot` captures ownership, native
refusal counters, pool identity and a monotonic timestamp on the engine queue.
`PagedStorageTelemetryAdapter` copies this immutable value into the heartbeat,
without allocator traversal or refreshing its age. Grant-only point updates
change the separate live capacity fields and leave the allocator capture intact. `reconcileCapacitySamples`
(`coordinator/registry/capacity_sample_freshness.go`) shares the prefix-cache
age/replay rule, so a continuing heartbeat cannot freshen a stalled producer.
Only the current live slot snapshot holds the baseline; no pool-generation
history grows across reloads. A separate coordinator timestamp advances only
with accepted capacity replacements; rejected capacity frames can prove
liveness without erasing elapsed sample age.

`recordPagedStorageTelemetry` (`coordinator/api/provider_paged_storage_telemetry.go`)
publishes bounded chip/version-tagged observations after registry acceptance.
Actual segment ownership includes allocator padding. The optional padding
gauge identifies bytes that cannot hold KV pages; usable slack excludes them.
The optional last-allocation allowance gauge records conservative reservation
bytes released after a successful preparation, rather than retained memory
(`PagedStorageTelemetryCapture`,
`provider-swift/Sources/ProviderCore/Inference/PagedStorageTelemetryAdapter.swift`).
Ownership gauges overlap and must not be summed. Failure/refusal totals become
positive deltas within one generation; the first sample and reload seed a
baseline. Stale samples expose their age instead of new ownership measurements.
These fields are available in backend snapshots and Datadog; they are not new
`fleet_snapshots` columns, admission inputs, or durable-cache holder evidence.

### Process memory observations

`ProcessMemoryTelemetrySampler` captures the process ledger's coherent
ownership and allocator snapshot during the provider capacity refresh
(`provider-swift/Sources/ProviderCore/Inference/ProcessMemoryTelemetrySampler.swift`).
The [wire object](../reference/protocol-messages.md#backend_capacitytelemetryprocess_memory)
reports outstanding promises as charged bytes minus covered materialized bytes.
Operators can distinguish active allocations, reserved future memory, and debt
without adding overlapping ownership gauges together.

Heartbeat stamping ages this immutable observation without advancing its producer
sequence (`CoordinatorClientState.stampAndPublishHeartbeatCapacity`). Registry
reconciliation preserves age across repeated captures even with zero loaded slots.
`recordProcessMemoryTelemetry` (`coordinator/api/provider_process_memory_telemetry.go`)
emits fresh observations with bounded chip/version tags; stale observations emit
age and freshness only. No owner IDs, model names, request contents, or generation
values become metric labels. The object remains diagnostic: process admission
continues to use its local ledger, and cache routing consumes durable checkpoint
evidence and service cost.

### Datadog transport

`datadog.Client` (`coordinator/datadog/datadog.go`) is constructed in
`coordinator/cmd/coordinator/main.go` only when `DD_API_KEY` or `DD_AGENT_HOST`
is set; otherwise `s.dd` is nil and every `ddIncr`/`ddGauge`/`ddHistogram`
(`coordinator/api/server.go`) is a no-op. Configuration is environment only —
`DD_API_KEY`, `DD_AGENT_HOST`, `DD_DOGSTATSD_URL`, `DD_SITE`, `DD_ENV`, `DD_SERVICE`,
`DD_HOSTNAME` — with defaults under [configuration](../reference/configuration.md#telemetry-datadog-and-profiling).
`DD_API_KEY` enables the HTTPS paths (series, logs, events); `DD_AGENT_HOST` alone still
constructs the client and starts the tracer.

Metric names in this page omit the Datadog namespace prefix (`statsd.WithNamespace`;
owner: [telemetry-inventory](../reference/telemetry-inventory.md#coordinator-derived-datadog-metrics)).
Which leg carries a metric depends on kind and on whether an API key is set
(`httpMetrics`):

| Kind | `DD_API_KEY` unset | `DD_API_KEY` set |
|---|---|---|
| counter, gauge | DogStatsD UDP, best effort | buffered in `seriesBuffer` and POSTed to `https://api.<site>/api/v1/series` every 5 s (`metrics_http.go`); the DogStatsD leg is skipped so an agent appearing later cannot double-count |
| histogram | DogStatsD UDP | DogStatsD UDP only — percentiles are aggregated agent-side and the HTTPS path does not replicate them |
| telemetry event log | dropped | batched (100 or 5 s) to `https://http-intake.logs.<site>/api/v2/logs`; `fatal` also posts a Datadog Event (`emitDDEvent`) for monitors |

The HTTPS series path is therefore a **replacement** for the UDP leg when a key
is present, not a fallback behind it.

### Coordinator events and logs

`Emitter.Emit` (`coordinator/telemetry/emitter.go`) forces `source =
coordinator`, defaults `kind` to `custom` and `severity` to `info`, then writes
to three sinks in order: `slog` (`telemetry: <message>` with every field as an
attribute), the in-process counter `telemetry_events_total{source, severity,
kind}` (`GET /v1/admin/metrics`), and the Datadog Logs API. The call sites
(`s.emit`, `s.emitRequest`, `s.emitPanic`) are enumerated in the
[inventory](../reference/telemetry-inventory.md#coordinator-emitted-events).

Logging is JSON to stdout (`slog.NewJSONHandler`). When Datadog is configured
the handler is wrapped in `datadog.TraceHandler` (`coordinator/datadog/slog.go`),
which adds `dd.trace_id` and `dd.span_id` to any record whose context carries
an active APM span, and `ddtracer.Start` runs for the process lifetime. No
coordinator code creates spans at this commit, so those attributes never
appear; request correlation uses `request_id` (`X-Request-ID`) instead.

### Request-level sinks

Two bounded, non-blocking sinks (`telemetrySink`, `coordinator/api/telemetry_sink.go`;
`profileSink`, `coordinator/api/profiler_sink.go`) carry `inference_routes`
outcome writes and `request_profiles` rows off the request path. Each has a
4096-slot channel and a single worker; a full channel drops the write and
counts it (`telemetry.sink_dropped{sink:profile}`, or the route sink's atomic
surfaced as `fleet_snapshots.route_sink_dropped_total`). The `X-Timing` header
([`../reference/api-contracts.md#headers`](../reference/api-contracts.md#headers))
and the `inference.timing.*` histograms are built from the same
`RequestTimingDetails`. The profiler's own path is described in
[`system-profiler.md`](system-profiler.md); the outcome vocabularies behind
`inference.request_outcome` and `inference.error` in
[`request-outcome-observability.md`](request-outcome-observability.md).

## Invariants

1. **No prompt or completion text on any telemetry path.** The field allowlist
   (`telemetryFieldAllowlist`, `coordinator/api/telemetry_handlers.go`) admits
   only bounded enums, counters, byte counts and durations; media, prompt,
   token and cache-key content are excluded by construction and the comments
   at each group say so. `sanitizeProviderInferenceError`
   (`coordinator/api/inference_error_sanitize.go`) never reads the provider's
   `error` string. The `profile` object is length-checked opaque bytes on the
   read loop and decoded only on the sink worker. Swift free-form log strings
   are `privacy: .private`.
2. **Three mirrors, one set.** The Go allowlist, Swift
   `TelemetryFieldFilter.allowed` and TS `TELEMETRY_ALLOWED_FIELDS` are parsed
   from source and compared by `TestTelemetryAllowlistThreeWayParity`
   (`coordinator/api/telemetry_allowlist_parity_test.go`); the enums and JSON
   encoding by `coordinator/protocol/telemetry_symmetry_test.go` and
   `provider-swift/Tests/ProviderCoreTests/TelemetrySymmetryTests.swift`. The
   five shipped gaps are enumerated in `telemetryKnownMirrorGaps` and a stale
   entry fails the build.
3. **Telemetry never changes control flow.** Nil emitter, nil Datadog client,
   full sink and unreachable intake are all silent no-ops or counted drops.
   Engine-health, `kv_backend` and `telemetry` heartbeat fields are
   measurement only; the scheduler does not gate on them.
4. **Tags come from the accepted snapshot and closed folds.** `SlotStateFold`,
   `ThermalStateFold`, `ProviderVersionFold` (`coordinator/registry/gate_reason.go`)
   and `KVBackendFallbackTag` (`coordinator/registry/kv_backend.go`) bound
   every provider-supplied string before it becomes a tag; `provider_id`
   appears only on the per-provider memory gauges.
5. **Client ingestion is off, and stays off without reading a byte.**
   `handleTelemetryIngest` answers `telemetry_ingest_disabled` before touching the body
   (`TestTelemetryIngestIsGoneWithoutReadingOrForwardingBody`).

## Failure modes

| Condition | Effect | Where to look |
|---|---|---|
| Neither `DD_API_KEY` nor `DD_AGENT_HOST` set | no Datadog client; every metric and forwarded event is dropped; `slog` mirror and in-process counters still work | startup log lacks `datadog integration enabled` |
| `DD_API_KEY` set, no local agent | counters and gauges arrive via HTTPS; **histograms** (`inference.ttft_ms`, `http.latency_ms`, `inference.timing.*`) are lost | `datadog: DogStatsD client init failed` or silent UDP drops |
| Series or Logs intake returns ≥ 400 or times out (10 s) | batch dropped; one `Warn` per batch | `datadog: series API returned error`, `datadog: logs API request failed` |
| Profile or route sink full | write dropped and counted; request unaffected | `telemetry.sink_dropped{sink:profile}`, `route_sink_dropped_total` in `fleet_snapshots` |
| Stale or reordered `capacity_seq` | frame ignored except `LastHeartbeat`; metrics not re-emitted | registry debug log |
| Heartbeat prefix-cache telemetry fails validation | dropped for that frame | `routing.cache_telemetry_rejected{source:heartbeat}` |
| Provider older than the profiler slice | `slots[].telemetry` absent; wedge metrics silent for all-zero slots; `fleet_snapshots` telemetry columns zero | `provider_version` column |
| Abrupt disconnect at high memory pressure | classified OOM (`≥ 0.90`, or `≥ 0.80` with in-flight work) | `provider.oom_suspected`, `ws.disconnects`, `provider_sessions.disconnect_reason` |
| Allowlist edited in one mirror only | CI fails | `TestTelemetryAllowlistThreeWayParity` |
| Expecting trace correlation | `dd.trace_id` never present (no spans) | use `request_id` |

## Code map

| Concern | Path |
|---|---|
| Heartbeat ingest and metric emission | `coordinator/api/provider.go` (`providerReadLoop`), `coordinator/api/provider_wedge_telemetry.go`, `coordinator/api/provider_mlx_cache_telemetry.go` |
| Clamping and canonical snapshot | `coordinator/registry/heartbeat.go` (`Registry.Heartbeat`, `clampBackendCapacity`), `coordinator/registry/heartbeat.go` |
| Persistence throttle | `coordinator/registry/persistence.go` |
| Datadog client, HTTPS series, trace-aware slog | `coordinator/datadog/datadog.go`, `coordinator/datadog/metrics_http.go`, `coordinator/datadog/slog.go` |
| Wiring and env | `coordinator/cmd/coordinator/main.go` |
| Coordinator event emitter | `coordinator/telemetry/emitter.go`; helpers and gauge loop in `coordinator/api/server.go` |
| In-process metrics registry | `coordinator/api/metrics.go`; `handleAdminMetrics` in `coordinator/api/server.go` |
| Event shape, allowlist, retired ingest | `coordinator/protocol/telemetry.go`, `coordinator/api/telemetry_handlers.go` |
| Sinks | `coordinator/api/telemetry_sink.go`, `coordinator/api/profiler_sink.go`, `coordinator/api/profiler_fleet.go` |
| Disconnect classification | `coordinator/registry/disconnect_classify.go` |
| Provider side | `provider-swift/Sources/ProviderCore/Coordinator/CoordinatorClient+Registration.swift` (`buildHeartbeatJSON`), `provider-swift/Sources/ProviderCore/CapacityEventHeartbeats.swift`, `provider-swift/Sources/ProviderCore/Inference/EngineV2Bridge+Capacity.swift`, `provider-swift/Sources/ProviderCore/Telemetry/TelemetryClient.swift` (no-op facade) |
| Tests | `coordinator/api/telemetry_allowlist_parity_test.go`, `coordinator/api/telemetry_handlers_test.go`, `coordinator/protocol/telemetry_symmetry_test.go`, `coordinator/datadog/datadog_test.go`, `coordinator/datadog/metrics_http_test.go`, `provider-swift/Tests/ProviderCoreTests/TelemetrySymmetryTests.swift` |

## Related

- [`../reference/telemetry-inventory.md`](../reference/telemetry-inventory.md) — every datum, metric name, tag, cadence and retention
- [`../reference/telemetry-schema.md`](../reference/telemetry-schema.md) — event fields, enums, allowlist, symmetry tests
- [`../reference/protocol-messages.md`](../reference/protocol-messages.md) — heartbeat wire shape
- [`system-profiler.md`](system-profiler.md) — per-attempt `profile`, `request_profiles`, `fleet_snapshots`
- [`request-outcome-observability.md`](request-outcome-observability.md) — outcome taxonomy behind the request metrics
- [`scheduling.md`](scheduling.md), [`routing.md`](routing.md) — what the heartbeat fields decide
