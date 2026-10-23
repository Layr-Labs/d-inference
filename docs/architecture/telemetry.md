# Provider telemetry

> Last updated: 2026-10-23

Provider diagnostics travel on typed heartbeats and terminal profiles. The Swift event-emitter facade is inert; do not add prompt or completion content to heartbeats or profiles. The [wire schema](../reference/telemetry-schema.md) and [protocol reference](../reference/protocol-messages.md) define the boundary.

## Mechanism

### Heartbeat telemetry

The provider sends typed `heartbeat` frames at the configured
`heartbeat_interval_secs`, with event heartbeats bounded to two per second.
The [platform heartbeat pipeline](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/telemetry.md#heartbeat-telemetry)
owns validation, clamping, persistence and fleet metrics. Its implementation
and live configuration are external to this repository.

Optional per-engine performance observations carry an epoch, sample count and
age independently of heartbeat cadence. Prompt measurements are published before
terminal accounting, and engine decode capacity stays separate from delivered
streaming/end-to-end rates. See the exact [capacity protocol](../reference/protocol-messages.md#slotsperformance_measurements)
and [platform performance validation](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/internal/registry/capacityvalue/performance_measurements.go)
(`ClampPerformanceMeasurements`, `ValidPerformanceObservation`). These fields belong to
in-memory routing observations and are excluded from persisted numeric-only
provider telemetry; they add no client telemetry-ingestion endpoint.
The first-content design includes coarse numeric workload buckets for
routing: these reveal bounded workload-size metadata to the coordinator, which
already processes the request, but contain no prompt text, completion text,
token IDs, media or cache keys. The protocol accepts only six fixed numeric
bucket ceilings and closed phase/cache/contention values, with at most 32
engine-local aggregate buckets. Warm-pool planning retains numeric work means
in memory; process logs and event emitters omit the measured prompt/output
means and work rates.

### Autopilot busy reasons and stalled transitions

With saved Autopilot consent, the heartbeat's `model_autopilot` state names why
the provider would refuse a residency operation (`busy_reason`, `busy_reasons`,
`busy_since_ms`) and counts stuck-transition watchdog stalls per process
(`transition_stalls`). These are typed heartbeat fields, not event emissions;
the provider log also records each `transition_stalled`. The closed
vocabularies are in the [state object](../reference/protocol-messages.md#model_autopilot-state)
and the watchdog's rules in the
[Autopilot architecture](model-autopilot.md#busy-reasons-and-stalled-transitions).

### KV storage and precision attribution

`EngineV2Factory.makeBridge` constructs a once-per-build INFO `engine_health`
notification with `operation = engine_v2_kv_backend` after successful engine
construction (`provider-swift/Sources/ProviderCore/Inference/Engine/Factory/EngineV2Config.swift`,
`emitKVBackendTelemetry`). `fields.backend` names the inference engine,
`fields.kv_backend` names its storage, and `fields.kv_quantization` names the
resolved live attention-cache profile rather than checkpoint or model-weight
precision. The closed values and operation-specific presence
rules are in the [canonical field contract](../reference/telemetry-schema.md#provider-kv-backend-and-precision-selection).

This event is available to an injected sink, but the production client facade
discards it. It is not a live coordinator datum or a fleet inventory: older
records, refusal/posture operations and direct Diffusion bridge assembly can
omit the precision observation, and absence never implies `native` precision.
The recurring posture and heartbeat expose storage backend separately; doctor
checks explicit live-backend requests and does not certify this precision profile
(`provider-swift/Sources/darkbloom/Diagnostics/KVBackendPosture.swift`,
`KVBackendPosture.backendCheck`).
The local daemon snapshot separately records effective live/checkpoint
precision and the active complete-store layout for `status` and `doctor`.
Those fields are not added to this event or the coordinator heartbeat; see
[local diagnostics](../provider/cli-reference.md#darkbloom-doctor).

### Slot posture sampler lifecycle

`EngineV2Bridge.configureMTPStatus` in
`provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+MTP.swift` emits
the opening slot-posture sample synchronously and starts a periodic task. Periodic delivery rechecks task
cancellation inside the bridge actor, after the scheduling hop; cancellation
while queued cannot emit a stale sample. `EngineV2Bridge.shutdown` cancels and
joins the sampler before returning
(`provider-swift/Sources/ProviderCore/Inference/Engine/Bridge/EngineV2Bridge+Lifecycle.swift`). This preserves the opening observation while
preventing the periodic producer from emitting after teardown.

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
fields; no free-form client event transport is used. One counter originates in
the engine rather than the store: when a packed prefill cohort disarms a
recurrent donor's checkpoint capture, `EngineLoopV2` reports it once per
request through `CBv2CompletePrefixCache.recordRecurrentCaptureDisarmed(packedAt:)`,
`SSDHybridCheckpointStore` counts it in its stats, and the snapshot carries it
as `recurrent_capture_disarmed_packed_total` (complete-checkpoint stores only).

`applyProviderHeartbeat` feeds only registry-accepted snapshots to
`recordPrefixCacheTelemetry` ([coordinator/internal/provider/heartbeat/provider_prefix_cache_telemetry.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/internal/provider/heartbeat/provider_prefix_cache_telemetry.go)),
which emits the store-lifetime counters as positive deltas
(`provider.prefix_cache.recurrent_capture_disarmed_packed` among them; a
provider that omits the optional field contributes no delta and seeds a
baseline when the field first appears).
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
Complete-checkpoint outcomes distinguish host-memory refusal, stale epoch,
maintenance contention, low disk space, unsafe root, fresh-write I/O error,
unreadable existing file and post-write eviction. Error descriptions and paths
never become metric labels. The legacy `write_failed` still covers unclassified
producer errors and older providers, so it must not be interpreted as a count
of physical disk errors.

The complete-checkpoint writer also distinguishes novel-share exhaustion
(`write_priority_limited`) from total-budget exhaustion (`write_rate_limited`)
through `SSDWriteRateLimiter.decision`. Ahead of both, the demand gate settles
`skipped_novel` for a checkpoint with no coordinator-observed or local repeat
demand, spending no bytes or budget (`SSDCheckpointDemand.admitsWrite`). All
three settle the same typed heartbeat counter; none creates a new event field. The [protocol reference](../reference/protocol-messages.md)
owns the closed outcome vocabulary, and the [SSD reference](../reference/ssd-kv-cache.md#size-and-eviction-rules)
defines the write policy.

A failed atomic creation that never entered the index does not revoke unrelated
checkpoints: the next donation can retry after the failure clears. Failure to
reauthenticate an indexed file still removes that file under an epoch change
before any ready receipt can be published. Cancellation and stale-epoch work
publish no receipt and do not revoke a newer epoch's evidence
(`SSDHybridCheckpointStore.performWrite`). There is no unbounded retry loop or
retained failed tensor job.
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
([coordinator/registry/capacity_sample_freshness.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/registry/capacity_sample_freshness.go)) shares the prefix-cache
age/replay rule, so a continuing heartbeat cannot freshen a stalled producer.
Only the current live slot snapshot holds the baseline; no pool-generation
history grows across reloads. A separate coordinator timestamp advances only
with accepted capacity replacements; rejected capacity frames can prove
liveness without erasing elapsed sample age.

`recordPagedStorageTelemetry` ([coordinator/internal/provider/heartbeat/provider_paged_storage_telemetry.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/internal/provider/heartbeat/provider_paged_storage_telemetry.go))
publishes bounded chip/version-tagged observations after registry acceptance.
Actual segment ownership includes allocator padding. The optional padding
gauge identifies bytes that cannot hold KV pages; usable slack excludes them.
The optional last-allocation allowance gauge records conservative reservation
bytes released after a successful preparation, rather than retained memory
(`PagedStorageTelemetryCapture`,
`provider-swift/Sources/ProviderCore/Inference/Memory/PagedStorageTelemetryAdapter.swift`).
Ownership gauges overlap and must not be summed. Failure/refusal totals become
positive deltas within one generation; the first sample and reload seed a
baseline. Stale samples expose their age instead of new ownership measurements.
These fields are available in backend snapshots and Datadog; they are not new
`fleet_snapshots` columns, admission inputs, or durable-cache holder evidence.

### Process memory observations

`ProcessMemoryTelemetrySampler` captures the process ledger's coherent
ownership and allocator snapshot during the provider capacity refresh
(`provider-swift/Sources/ProviderCore/Inference/Memory/ProcessMemoryTelemetrySampler.swift`).
The [wire object](../reference/protocol-messages.md#backend_capacitytelemetryprocess_memory)
reports outstanding promises as charged bytes minus covered materialized bytes.
Operators can distinguish active allocations, reserved future memory, and debt
without adding overlapping ownership gauges together.

Heartbeat stamping ages this immutable observation without advancing its producer
sequence (`CoordinatorClientState.stampAndPublishHeartbeatCapacity`). Registry
reconciliation preserves age across repeated captures even with zero loaded slots.
`recordProcessMemoryTelemetry` ([coordinator/internal/provider/heartbeat/provider_process_memory_telemetry.go](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/coordinator/internal/provider/heartbeat/provider_process_memory_telemetry.go))
emits fresh observations with bounded chip/version tags; stale observations emit
age and freshness only. No owner IDs, model names, request contents, or generation
values become metric labels. The object remains diagnostic: process admission
continues to use its local ledger, and cache routing consumes durable checkpoint
evidence and service cost.


## External processing

Coordinator validation, persistence, Datadog transport and retention are owned by [platform telemetry](https://github.com/Layr-Labs/darkbloom-platform/blob/48a198c71a2d30feec5597bacf1101120f7f955d/docs/architecture/telemetry.md). A provider observation does not prove admission, delivery, billing, or a successful fleet rollout.

## Related

- [Prediction and deadline observations](../reference/prediction-decision-telemetry.md)
- [Privacy model](security/encryption.md)
- [Provider component](components/provider.md)
