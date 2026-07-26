# Telemetry Schema

This document describes the telemetry wire format shared by the coordinator, provider, macOS app, and console UI. The canonical Go definitions are in [`coordinator/protocol/telemetry.go`](../../coordinator/protocol/telemetry.go). Ingestion is handled by [`coordinator/api/telemetry_handlers.go`](../../coordinator/api/telemetry_handlers.go). Mirrors: Swift [`provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift`](../../provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift) and TypeScript [`console-ui/src/lib/telemetry-types.ts`](../../console-ui/src/lib/telemetry-types.ts).

## Ingestion endpoint

```
POST /v1/telemetry/events
Authorization: optional Bearer <token>
```

Authentication modes (resolved inside the handler):

| Token type | Identity used | Rate-limit bucket |
|---|---|---|
| Provider device token | `machine_id` derived from token hash | per machine |
| Privy JWT | account id | per account |
| API key | account id | per account |
| Anonymous | none | stricter anonymous bucket |

See [`resolveTelemetryAuth`](../../coordinator/api/telemetry_handlers.go).

## Batch envelope

Go: [`TelemetryBatch`](../../coordinator/protocol/telemetry.go); Swift: `TelemetryBatch`; TS: `TelemetryEvent[]` wrapped as `{ events: ... }`.

| Field | Type | Notes |
|---|---|---|
| `events` | array | [`TelemetryEvent`](#telemetryevent) records |

Server-enforced caps:

| Limit | Value |
|---|---|
| Max body size | 64 KB |
| Max events per batch | 100 |
| Max message length | 4,096 chars |
| Max stack length | 32 KB |
| Max fields JSON size | 8 KB |
| Authenticated rate | 200 burst, 100 events/min refill |
| Anonymous rate | 30 burst, 10 events/min refill |

See [`telemetry_handlers.go:35-41`](../../coordinator/api/telemetry_handlers.go) and [`telemetry_handlers.go:108-116`](../../coordinator/api/telemetry_handlers.go).

## `TelemetryEvent`

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | string | yes | UUIDv4, client-supplied |
| `timestamp` | string | yes | ISO 8601 (RFC 3339 with fractional seconds in Swift) |
| `source` | string | yes | `coordinator`, `provider`, `app`, `console`, `bridge` |
| `severity` | string | yes | `debug`, `info`, `warn`, `error`, `fatal` |
| `kind` | string | yes | `panic`, `http_error`, `protocol_error`, `backend_crash`, `attestation_failure`, `inference_error`, `runtime_mismatch`, `connectivity`, `log`, `custom` |
| `version` | string | no | Component version |
| `machine_id` | string | no | Stable per-machine identifier |
| `account_id` | string | no | Server-stamped from auth when present |
| `request_id` | string | no | Correlation id |
| `session_id` | string | no | Per-process UUID |
| `message` | string | yes | Human-readable developer string |
| `fields` | object | no | Allowlisted structured fields |
| `stack` | string | no | Backtrace / formatted stack |

Unknown `source`, `severity`, and `kind` values are coerced server-side to `custom` / `info` / `custom`. Timestamps are clamped to `[now-7d, now+5min]`. See [`sanitizeTelemetryEvent`](../../coordinator/api/telemetry_handlers.go).

## Field allowlist

The coordinator silently drops any `fields` key not in this set. Keys must be kept in sync across Go, Swift, and TypeScript.

| Field | Allowed in |
|---|---|
| `component` | Go, Swift, TS |
| `operation` | Go, Swift, TS |
| `duration_ms` | Go, Swift, TS |
| `attempt` | Go, Swift, TS |
| `endpoint` | Go, Swift, TS |
| `status_code` | Go, Swift, TS |
| `error_class` | Go, Swift, TS |
| `error` | Go, Swift, TS |
| `target` | Go, Swift, TS |
| `model` | Go, Swift, TS |
| `backend` | Go, Swift, TS |
| `exit_code` | Go, Swift, TS |
| `signal` | Go, Swift, TS |
| `hardware_chip` | Go, Swift, TS |
| `memory_gb` | Go, Swift, TS |
| `macos_version` | Go, Swift, TS |
| `handler` | Go, Swift, TS |
| `provider_id` | Go, Swift, TS |
| `trust_level` | Go, Swift, TS |
| `queue_depth` | Go, Swift, TS |
| `reason` | Go, Swift, TS |
| `runtime_component` | Go, Swift, TS |
| `reconnect_count` | Go, Swift, TS |
| `last_error` | Go, Swift, TS |
| `ws_state` | Go, Swift, TS |
| `network_reachable` | Go only |
| `coordinator_url` | Go only |
| `billing_method` | Go, Swift, TS |
| `payment_failed` | Go, Swift, TS |
| `url` | Go, TS |
| `user_agent` | Go, TS |
| `route` | Go, TS |
| `kv_backend` | Go, Swift, TS |
| `prefix_reuse_backend` | Go, Swift, TS |
| `pages_pinned` | **none** — deliberately excluded from all three mirrors (`coordinator/api/telemetry_handlers.go:153`, `provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift:285`, `console-ui/src/lib/telemetry-types.ts:150`); see "no producer" below |
| `cow_events` | **none** — deliberately excluded from all three mirrors (`coordinator/api/telemetry_handlers.go:153`, `provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift:285`, `console-ui/src/lib/telemetry-types.ts:150`); see "no producer" below |
| `pool_utilization` | Go, Swift, TS |
| `pool_bytes` | Go, Swift, TS |
| `pool_deferred_growth_bytes` | Go, Swift, TS |
| `pool_stranded_bytes` | Go, Swift, TS |
| `mtp_enabled` | Go, Swift, TS |
| `mtp_active` | Go, Swift, TS |
| `mtp_inactive_reason` | Go, Swift, TS |
| `mtp_acceptance_rate` | Go, Swift, TS |

This table is not exhaustive: the OOM / memory-pressure, engine-health (first-token
wedge), eval-in-flight, KV-budget audit, media, and exact-prefix-replay cohorts are
allowlisted in all three mirrors but have never been transcribed here. Absence from
this table does **not** mean a key is rejected — the Go map is the authority, and
`TestTelemetryAllowlistThreeWayParity` is what keeps the three mirrors honest.

**Important:** No prompt or response content is ever placed in telemetry. The allowlist contains only non-sensitive operational metadata.

Canonical server allowlist: [`telemetry_handlers.go:48-171`](../../coordinator/api/telemetry_handlers.go). Swift client-side filter: [`TelemetryFieldFilter.allowed`](../../provider-swift/Sources/ProviderCore/Telemetry/TelemetryEvent.swift) (`TelemetryEvent.swift:238-294`). TS client-side set: [`TELEMETRY_ALLOWED_FIELDS`](../../console-ui/src/lib/telemetry-types.ts) (`telemetry-types.ts:58-160`).

## Discrepancies

- The TypeScript allowlist in [`console-ui/src/lib/telemetry-types.ts`](../../console-ui/src/lib/telemetry-types.ts) currently omits `network_reachable` and `coordinator_url`, which the Go server accepts. Swift's client-side filter also omits `network_reachable`, `coordinator_url`, `url`, `user_agent`, and `route`. Unknown keys are dropped server-side without error, so this is a client-side completeness gap, not a wire incompatibility.

## Adding a field: one key, one meaning

**One key, one meaning. Before adding a metric, grep the allowlist for the
concept, not just the name. Prefer raw quantities to ratios at the emission
point — ratios clamp, hide their denominator, and collide semantically far
more easily than counts do.**

This has now been paid for twice. `backend` carried three unrelated value
vocabularies across its producer sites (below), and within a single wave of
fixing that, `pool_utilization` acquired two producers meaning two different
things — pool occupancy and a slot's grant-as-fraction-of-pool. Both collisions
passed every review that checked *names*, because both were spelled correctly.
Neither would have survived a reviewer asking "is this concept already emitted
under some other spelling?"

Three corollaries worth stating, since each one is what actually went wrong:

* **Distinct `operation` values do not partition a field.** A dashboard grouping
  by `kv_backend` or `model` sees every event that carries the key, whatever
  operation produced it. If two operations disagree about what a key means, the
  aggregate is noise.
* **A near-miss name is not a fix.** Two keys both ending `_utilization`, both on
  paged slots, is the same trap with an extra word. Rename the *concept* or emit
  the raw terms; do not park a second meaning next to the first in a dropdown.
* **Raw quantities compose; ratios do not.** A consumer can derive a ratio from
  numerator and denominator, then also sum, diff and threshold them. It cannot
  recover either term from a ratio — and a clamped ratio (`min(a, b) / b`) throws
  away exactly the overflow case the metric existed to expose.

A new key must land in **all three** allowlist mirrors. `TelemetryFieldFilter`
drops unmirrored keys silently, so a half-applied rename deletes the value rather
than moving it, and the producer still looks healthy.

**The tempting reuse is the dangerous one.** When the paged re-slice residue
needed byte fields, every existing byte key in the allowlist belonged to another
cohort: `peak_memory_bytes`, `available_bytes`, `mlx_active_bytes`,
`mlx_cache_bytes` and `system_available_bytes` are OOM / memory-snapshot terms,
and `reserved_bytes` / `reservations` are the KV budget's outstanding
reservations. `reserved_bytes` is the one that looks right — a paged pool does
reserve bytes — and reusing it would have been the same collision one level down:
two unrelated reservation concepts under one key, discovered later by whoever
summed them. Three new keys (`pool_bytes`, `pool_deferred_growth_bytes`,
`pool_stranded_bytes`) and a three-mirror change was the cheaper answer, because
a metric you cannot interpret is worse than a metric that cost three file edits.

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
| `mtp_acceptance_rate` | float | `acceptedDraftTokens / proposedTokens` for the reporting window, `[0,1]`; omitted when `proposedTokens == 0`. |

All four are produced by `engine_v2_slot_posture`, an INFO `engine_health` event
emitted by a per-bridge sampler on the same 60 s cadence as the MTP metrics log
(`EngineV2Bridge+MTP.swift`). The sampler runs for **every** slot, MTP or not:
`mtp_enabled: false` is itself the observation that resolves a partially-MTP fleet,
and the paged-pool fields do not depend on MTP. The emission point is deliberate —
a once-per-engine-construction event (like `engine_v2_kv_backend`) rides a sink that
drops on full behind a 100/min limit and is a notification, not an inventory; a
per-request event makes idle slots vanish; an edge-triggered event (like
`step_wedge`) never reports a healthy slot. The per-slot every-heartbeat channel is
`BackendSlotCapacity`, which already carries `kv_backend`; this is its
telemetry-side counterpart.

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
plain average — a fleet roll-up must weight each sample by its proposed-token count.
If weighted aggregation is needed server-side, add `mtp_proposed_tokens` and
`mtp_accepted_tokens` rather than post-processing the ratio.
