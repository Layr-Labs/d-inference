# Retired Client Telemetry Compatibility Schema

This document records the inactive client-telemetry wire format retained for
source and mixed-version compatibility. The coordinator and console endpoints
return `410 Gone` before reading a body, while the production Swift and
TypeScript facades drop events in process. Nothing on this page authorizes
provider, app, or browser telemetry transmission.

The compatibility event type has protocol mirrors in
[Go](../../coordinator/protocol/telemetry.go),
[Swift](../../provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift),
and [TypeScript](../../console-ui/src/lib/telemetry-types.ts). Their shared
wire corpus is
[`fixtures/telemetry/v1/events.json`](../../fixtures/telemetry/v1/events.json),
consumed by [Go](../../coordinator/protocol/telemetry_symmetry_test.go),
[Swift](../../provider-swift/Tests/ProviderCoreTests/TelemetrySymmetryTests.swift),
and [TypeScript](../../console-ui/__tests__/telemetry.test.ts) tests.

The disabled coordinator route and fixed handler are
[`server.go`](../../coordinator/api/server.go) and
[`handleTelemetryIngest`](../../coordinator/api/telemetry_handlers.go). The
disabled clients are
[`TelemetryClient.swift`](../../provider-swift/Sources/ProviderCore/Telemetry/TelemetryClient.swift)
and [`telemetry.ts`](../../console-ui/src/lib/telemetry.ts).

## Ingestion endpoint

```
POST /v1/telemetry/events
HTTP/1.1 410 Gone
```

Ingestion is disabled. The coordinator and console proxy reject requests before
reading or forwarding their bodies; production Swift and TypeScript clients
drop events before disk or network I/O. The remaining wire definitions are
historical compatibility types, not an active data path.

## Compatibility contract

The shared fixture pins the source, severity, and kind vocabularies; JSON field
names; required versus optional fields; representative values; and
optional-field omission. A compatibility type change must update the Go, Swift,
and TypeScript mirrors together with the fixture. Each language consumes that
same fixture rather than maintaining a separate expected payload.

The fixture describes only the retained wire type. It does not describe an
ingestion parser or authorize transport, and it does not define which keys may
appear inside the free-form `fields` object.

## Batch envelope

Go and Swift retain a `TelemetryBatch` containing an `events` array. The
TypeScript compatibility shape is `{ events: TelemetryEvent[] }`.

## `TelemetryEvent`

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | string | yes | UUID string supplied by the compatibility caller |
| `timestamp` | string | yes | ISO 8601 timestamp |
| `source` | string | yes | `coordinator`, `provider`, `app`, `console`, `bridge` |
| `severity` | string | yes | `debug`, `info`, `warn`, `error`, `fatal` |
| `kind` | string | yes | `panic`, `http_error`, `protocol_error`, `backend_crash`, `attestation_failure`, `inference_error`, `runtime_mismatch`, `connectivity`, `oom`, `engine_health`, `log`, `custom` |
| `version` | string | no | Component version |
| `machine_id` | string | no | Stable per-machine identifier |
| `account_id` | string | no | Account identifier |
| `request_id` | string | no | Correlation identifier |
| `session_id` | string | no | Per-process identifier |
| `message` | string | yes | Free-form compatibility value |
| `fields` | object | no | Free-form structured compatibility values |
| `stack` | string | no | Free-form compatibility value |

## Inactive client-side field filters

The Swift `TelemetryFieldFilter` and TypeScript
`TELEMETRY_ALLOWED_FIELDS` set remain for source compatibility with local
callers. There is no Go field allowlist, sanitizer, size limiter, or rate
limiter on the fixed coordinator route: it returns `410` without reading the
body. The client-side filters are not confidentiality controls and are not part
of the three-language fixture contract.

The retained event shape includes free-form `message`, `stack`, and `fields`
values. A field-name filter cannot prove those values safe. Re-enabling client
ingestion would require a new closed, per-kind value schema, new parsing and
storage code, and a new confidentiality review.

## Structured diagnostic key semantics

Even though the production facades discard events, retained producer and test
sinks still use the structured keys below. Keep one key bound to one meaning.
Distinct `operation` values do not partition a key, and raw numerator and
denominator values remain more composable than a precomputed ratio.

## `backend` key semantics

`backend` was overloaded. Across producer sites it carried **three unrelated value
vocabularies**, so any `group by backend` dashboard mis-buckets:

| Meaning | Values | Producer sites |
|---|---|---|
| Engine identity | `engine_v2` | `EngineV2Bridge+Capacity.swift:220`, `EngineV2Bridge.swift:1207,1231`, `EngineV2Config.swift:215,255`, `EngineV2VisionPrefill.swift:468`, `MultiModelBatchSchedulerEngine.swift:854` |
| Process runtime identity | `mlx-swift` | `darkbloom/StartCommand+Modes.swift:209` |
| KV storage kind | `paged`, `contiguous` | `EngineV2Bridge+PrefixCache.swift:197,252` |
| Prefix-reuse row identity | `contiguousUnquantized`, `contiguousQuantized`, `pagedFP16`, `unknown` | `EngineV2SlotFactory.swift:479` |

**Ruling.** `backend` keeps the majority meaning — the engine or process runtime
executing inference (`engine_v2`, `mlx-swift`). It is also the meaning that matches
`RegisterMessage.backend` on the wire, so telemetry and registration stay joinable.
The other two axes move to their own keys:

* `kv_backend` — the KV storage kind, `paged` | `contiguous`. This is **not a new
  name**: it is deliberately the same key and the same two-value vocabulary as
  [`BackendSlotCapacity.KVBackend`](../../coordinator/protocol/messages.go) on the
  heartbeat wire (`messages.go:303`) and `kvBackend` in
  [`Types.swift:518`](../../provider-swift/Sources/ProviderCore/Protocol/Types.swift).
  Telemetry and per-slot capacity therefore group identically, which is the whole
  point of the v0.8.0 rollout dashboard.
* `prefix_reuse_backend` — the finer `CBv2PrefixReuseBackend` row identity. It gets
  its own key rather than being folded into `kv_backend` because
  `contiguousQuantized` vs `contiguousUnquantized` is a real distinction that
  `contiguous` cannot express; collapsing it would be a silent data loss.

**Producer sites — landed.** All four now emit the split keys:

1. `EngineV2Bridge+PrefixCache.swift` (`prefix_cache_replay`, both the cold-fallback
   and the resolved-outcome event) — `backend` is `engine_v2`, and the KV storage
   kind moved to `kv_backend`.
2. `EngineV2SlotFactory.swift` (`prefix_cache_construction`) — `backend` is
   `engine_v2`, `kv_backend` carries the resolved `EngineV2KVBackendKind`, and the
   `CBv2PrefixReuseBackend` row identity moved to `prefix_reuse_backend`.
   **Correction to an earlier note here:** those raw values are *not* camelCase.
   `PrefixReusePlan.swift:14-17` already spells them `contiguous_unquantized`,
   `contiguous_quantized`, `paged_fp16`, `unknown`, so `.rawValue` is emitted
   directly and no mapping layer exists (or should be added).
3. `EngineV2Config.swift` (`engine_v2_kv_backend`) — the kind was previously legible
   only inside the free-form `reason` string, where `fallback:kill_switch` hides it
   from any `group by`. It now also rides `kv_backend`; `reason` keeps the
   fallback detail.
4. `EngineV2Bridge+MTP.swift` (`engine_v2_slot_posture`) — new recurring per-slot
   sample, described under [MTP](#mtp-speculative-decode) below.

`kv_backend` is **omitted** rather than guessed when a slot's backend was never
resolved (`EngineV2SlotFactory`'s no-prepared-backend branch). Absent means
UNKNOWN, matching `BackendSlotCapacity.KVBackend`'s `*string` + `omitempty`
contract on the heartbeat wire. Never substitute a third vocabulary value such as
`"unknown"`: omission has to stay distinguishable from an observation.

**`kv_backend` has a heartbeat-only companion: `kv_backend_fallback_reason`.**
It is deliberately **not** a telemetry-event field. It rides
`BackendSlotCapacity` on the heartbeat
([`messages.go`](../../coordinator/protocol/messages.go),
[`Types.swift`](../../provider-swift/Sources/ProviderCore/Protocol/Types.swift)),
the same channel as `kv_backend` itself. Heartbeat protocol changes remain a
two-way Go/Swift sync; the three-language telemetry event fixture does not
contain or require this key. It is recorded here because this page is where the
`kv_backend` semantics live and a reader must not infer the wrong omission rule.

It carries the provider's degrade reason verbatim — `kill_switch`,
`crash_loop_guard`, `kernel_preflight: …`, `physical_capacity: …`,
`ineligible: …`, `pool_construction_capacity: …`, `invalid_dtype: …` — when a
slot resolved to a backend other than the one it was configured for. The
resolved kind alone cannot separate an operator who chose contiguous from a
paged slot that fell back, and those are opposite signals: a choice and a
regression. `.auto` resolves **contiguous** as of v0.8.1 (it resolved paged
for v0.8.0 only), which inverts how to read this field: the default fleet now
reports contiguous with this key **absent**, so a present value marks a box
carrying an explicit `engine_v2_kv_backend = "paged"`. Every class stays on
the wire — v0.8.0 providers coexist during rollout, and the paged classes
stay live on explicitly-paged boxes. `kernel_preflight`, `physical_capacity`,
`ineligible` and `pool_construction_capacity` mean the box could not serve
paged and degraded;
`crash_loop_guard` means the box's watchdog counted 3 consecutive
crash-loop-shaped restarts and flipped `.auto` to contiguous itself (an
INCIDENT marker — the box was crash-looping minutes earlier; it also emits
an ERROR `engine_health` event, `operation=engine_v2_crash_loop_guard`, at
the trip); `invalid_dtype` means a typo'd `DARKBLOOM_CBV2_PAGED_KV_DTYPE`
(operator-fixable config error, the typo verbatim in the tail); and
`kill_switch` means `DARKBLOOM_CBV2_PAGED_KV=0` and is a deliberate
override. Nothing else on the wire separates them, and they should not be
alerted on the same way.

**Its omission rule is the INVERSE of `kv_backend`'s, and the two must be read
as a pair.** Absent `kv_backend` is UNKNOWN; absent `kv_backend_fallback_reason`
on a slot that DID name a `kv_backend` is an authoritative "this slot did not
degrade". Both keys ship in v0.8.0, so there is no build that reports one and
not the other. The reason is untrusted free text and never reaches a metric tag
verbatim: `registry.KVBackendFallbackTag` folds it onto the bounded class
vocabulary (`none`, the seven producer classes, `other`, `unknown`), which is
what the `kv_backend_fallback:` tag on `inference.ttft_ms`,
`inference.decode_tps` and `inference.request_outcome` carries.

## v0.8.0 field semantics

### Paged KV pool

| Field | Type | Meaning | Producer |
|---|---|---|---|
| `pages_pinned` | int | Pages currently pinned in the paged pool and therefore not evictable. | **none — see below** |
| `cow_events` | int | Cumulative copy-on-write page splits (shared prefix page diverged and had to be duplicated). | **none — see below** |
| `pool_utilization` | float | Occupied pool **bytes** / total pool bytes, `[0,1]`. | `engine_v2_slot_posture` |

Aggregate counters only — never page contents, block hashes, or token ids.

> **`pool_utilization` briefly had two producers with two meanings; resolved.**
> `EngineV2Bridge+MTP.swift` (`operation=engine_v2_slot_posture`) emits the
> occupancy defined in the table above. `EngineV2Bridge.swift`
> (`operation=paged_pool_resize_clamped`, Wave 1 track W15) also emitted the key,
> as `min(requestedBytes, poolBytes) / poolBytes` — a slot's re-sliced fair share
> as a fraction of its committed pool, explicitly *not* occupancy. Distinct
> `operation` values did not contain it: both events are paged slots tagged
> `kv_backend=paged`, so `avg(pool_utilization) by kv_backend` — the rollout
> dashboard's natural query — blended two unrelated populations.
>
> **Ruling:** `pool_utilization` keeps the documented occupancy meaning. The
> grant-vs-pool relationship is emitted as **raw bytes, not a second ratio**, and
> must include its denominator so share-of-pool stays derivable without guessing.
> A second `*_utilization` key was rejected: it sits next to this one in every
> dropdown, and `min(a, b) / b` discards the overflow magnitude at exactly the
> point co-residency diagnosis needs it. See
> [one key, one meaning](#adding-a-field-one-key-one-meaning).

#### Paged pool re-slice residue

| Field | Type | Meaning | Producer |
|---|---|---|---|
| `pool_bytes` | int | The slot's committed paged pool, `PagedKVPool.bytesCapacity`. The **denominator**: always emitted with the deltas below so share-of-pool is derivable. |
| `pool_deferred_growth_bytes` | int | Grant growth the pool could not absorb — the re-sliced fair share exceeds the construction-fixed pool. |
| `pool_stranded_bytes` | int | Pool bytes committed to this slot that its current fair share cannot use. |

Producer: `paged_pool_resize_clamped` (`EngineV2Bridge.swift`), edge-triggered on a
change in the residue — WARN while a residue exists, INFO on the edge back to
exact. All three ship together; a delta without its denominator is not
interpretable.

**Querying these for the co-residency admission defect (D1) — read this before
building the panel.** Paged commits slabs per slot at construction, so on a
memory-tight box a later model can measure too little headroom against the load
minimum and 503 where an all-contiguous configuration would have served.

The intuitive query is wrong. At the instant of the 503 the failure lands on the
SECOND model, while the committed slabs that ate the headroom belong to the
FIRST — and that first slot's `pool_stranded_bytes` may still be **zero**, because
residue only becomes non-zero once a re-slice cuts a slot's share below its own
pool. A panel keyed on "stranded > 0 at the time of the error" will show nothing
during exactly the incident it was built for.

* **`pool_bytes` is the term that is always present.** `Σ pool_bytes by provider`
  against the box's KV budget is what exposes the commitment that consumed the
  headroom, and it is emitted on every one of these events regardless of residue.
* **`pool_stranded_bytes` is the sharper signal once co-residency settles** — it
  names bytes a slot holds and cannot use — but it is a follow-on diagnostic, not
  the trigger condition.

**`pool_utilization` is a byte ratio, not a page ratio.** `PagedKVPool` exposes only
`bytesInUse` / `bytesReserved` / `bytesCapacity`; its page counters are per-group and
internal, and `pageBytes` differs per `(kvHeads, headDim)` group, so a page ratio
would weight a small group equally with a large one. The byte ratio is that same
ratio weighted by page size. It is derived from
`CBv2CapacitySnapshot.kvBytesInUse / .kvBytesBackendCapacity`, which on the paged
backend are exactly `PagedKVPool.bytesInUse` / `.bytesCapacity`
(`EngineLoopV2.swift:2295-2297`). In-use, not reserved: reserved is the worst-case
admission charge and would report a pool as full while its pages are still cold.
A zero backend capacity means UNKNOWN, so the key is omitted rather than sent as `0`.

**`pages_pinned` and `cow_events` have no producer, and cannot yet.** Neither
mechanism exists in the engine: `PagedKVPool` has no pin concept (only
reserve / in-use), and copy-on-write page splitting is unimplemented — "today every
page has refcount 0 or 1" (`PagedKVPool.swift` header). They are blocked on the
prefix-sharing work, not on plumbing, and emitting a hardcoded `0` would be
indistinguishable from a measured zero. Unblocking them needs, in the engine repo:

```swift
// MLXLMCommon/ContinuousBatchingV2/Paged/PagedKVPool.swift
public struct PagedKVPoolStats: Sendable, Equatable {
    public var pageCount: Int      // Σ over groups
    public var pagesInUse: Int     // Σ pages actually touched
    public var pagesReserved: Int  // Σ worst-case admission charges
    public var pagesPinned: Int    // Σ pages with refcount > 1  — NEEDS the mechanism
    public var cowEvents: Int      // cumulative page duplications — NEEDS the mechanism
}
extension PagedKVPool { public var stats: PagedKVPoolStats { /* Σ over groups */ } }

// MLXLMCommon/ContinuousBatchingV2/CBv2Contracts.swift — CBv2Engine
func pagedPoolStats() -> PagedKVPoolStats?   // nil on contiguous backends
```

plus a one-line provider forwarder on `EngineV2Bridge`. The first three fields are
pure plumbing over counters `PagedKVGroup` already keeps; `pagesPinned` and
`cowEvents` additionally need refcount sharing and a duplication counter to exist.
Once `pagedPoolStats()` lands, `pool_utilization` should switch to the exact page
ratio and this section's byte-ratio caveat can be dropped.

### MTP (speculative decode)

MTP is otherwise **invisible** to the coordinator: before this change, `mtp`,
`speculat`, and `draft` matched nothing in `coordinator/protocol/`,
`coordinator/api/`, the provider `Protocol/` and `Telemetry/` trees, or
`console-ui/src/lib/`. That matters beyond diagnostics: MTP inflates
`observed_decode_tps` with no discriminator, so a partially-MTP fleet biases
coordinator routing on a metric the coordinator believes is homogeneous.

| Field | Type | Meaning |
|---|---|---|
| `mtp_enabled` | bool | `ProviderMTPStatusSnapshot.configured` — MTP is configured and the kill switch is off. |
| `mtp_active` | bool | `ProviderMTPStatusSnapshot.active` — the drafter is loaded, the engine reports itself active, **and the slot is not inert** (see `inert_kv_unsupported`). A slot executing zero rounds is not active. |
| `mtp_inactive_reason` | string | Bounded enum, present whenever MTP is not *productively* running. |
| `mtp_acceptance_rate` | float | `acceptedDraftTokens / proposedTokens`, cumulative over the slot's lifetime, `[0,1]`; omitted when `proposedTokens == 0`. |
| `mtp_proposed_tokens` | int | Cumulative `proposedTokens` — the acceptance ratio's denominator, and the **weight** a fleet roll-up must apply per sample. Token count, never token contents. Omitted with the ratio when zero. |
| `mtp_accepted_tokens` | int | Cumulative `acceptedDraftTokens` — the ratio's numerator. Same omission rule. |

A roll-up over samples captured by an injected sink must never average the bare
per-slot ratios: the producer constructs one sample per slot per minute with
cumulative history, so an unweighted mean both over-counts old history and weighs
a 1/1 slot equally with a 10,000/10,000 slot. Sum `mtp_accepted_tokens` / sum
`mtp_proposed_tokens` (latest sample per slot, or differenced between two samples
of the same slot) instead. The counters remain cumulative rather than per-interval
deltas, preserving a differenceable wire shape across any two samples captured by
an injected test sink. `TelemetryClient.shared`, used in production, drops every
event before buffering, disk, or network I/O; the producer cadence therefore does
not imply production delivery.

All of these fields are assembled into `engine_v2_slot_posture`, an INFO
`engine_health` event, by a per-bridge sampler on the same 60 s cadence as the MTP
metrics log (`EngineV2Bridge+MTP.swift`). An injected test sink observes one event
per slot on that cadence; without one, the production path reaches
`TelemetryClient.shared` and is discarded before buffering or I/O. The sampler
runs for **every** slot, MTP or not: `mtp_enabled: false` is itself the observation
that resolves a partially-MTP fleet, and the paged-pool fields do not depend on
MTP. The periodic producer is deliberate in the retained event model: a
once-per-engine-construction event (like `engine_v2_kv_backend`) is a notification,
not an inventory; a per-request event makes idle slots vanish; and an edge-triggered
event (like `step_wedge`) never reports a healthy slot. The live per-slot
every-heartbeat channel is `BackendSlotCapacity`, which already carries
`kv_backend`; `engine_v2_slot_posture` is its retained telemetry-schema counterpart
for injected sinks.

`mtp_inactive_reason` values are
[`MTPFallbackReason`](../../provider-swift/Sources/ProviderCore/SpecDec/SpecDecTypes.swift)
raw values (`config_disabled`, `kill_switch_disabled`, `target_unsupported`, …,
`engine_inactive`), plus one that names a state the enum could not previously
express:

* `inert_kv_unsupported` — **enabled but doing nothing.** On a paged
  `gemma-4-26b-qat-4bit` slot the drafter loads, the engine reports MTP active, and
  every planned row is refused by the storage-eligibility guard
  ([`EngineLoopV2+MTPPlanning.swift:47`](../../libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/MTP/EngineLoopV2+MTPPlanning.swift)),
  so not one round runs while ~236 MB of drafter residency is charged. It is
  distinct from `engine_inactive`, where the engine says it is OFF; here the engine
  says it is ON and produces nothing, which is exactly why the state stayed
  invisible.

  Derived in `ProviderMTPStatusSnapshot.init` when the drafter activated, the engine
  reports active, `rounds == 0`, and `skippedRows["kv_unsupported"] > 0`. **`active`
  is false in this state.** Reporting it active is what hid the bug, and it also
  inverted the field's purpose: an inert slot does not inflate
  `observed_decode_tps`, so discounting its throughput is wrong in the opposite
  direction.

  `rounds` counts only rounds that drafted *and* verified, and the skip is recorded
  per scheduled row, so the state can only be reached after real traffic has been
  planned and refused — never on a freshly built engine. That bounds the blast
  radius of the `active` change: the post-build MTP teardown gate
  (`ProviderLoop+ModelLoading`, `ProviderLoop+EngineV2Liveness`, `StandaloneServer`)
  reads `active` on a zero-traffic engine, where `rounds == 0` **and** the skip count
  is `0`, so it cannot mis-fire there. Post-load nothing else consults the snapshot,
  so the inert slot's residency is reported, not reclaimed.

`mtp_acceptance_rate` is a per-event ratio and therefore **not** re-aggregatable by a
plain average. The counters that make weighted aggregation possible ship alongside
it: weight each sample by `mtp_proposed_tokens`, i.e. compute
`sum(mtp_accepted_tokens) / sum(mtp_proposed_tokens)` across slots (latest sample
per slot for a point-in-time fleet rate). For a windowed rate, difference the
cumulative counters between two samples of the same slot —
`Δaccepted / Δproposed` — before summing across slots; treat a counter that went
*down* as a slot rebuild (engine reconstruction resets the lifetime counters) and
start the window at the new sample. Never post-process the bare ratios: an
unweighted mean over-counts old history and weighs a 1/1 slot equally with a
10,000/10,000 slot.
