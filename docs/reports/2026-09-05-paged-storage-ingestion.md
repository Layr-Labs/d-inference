# Paged-storage heartbeat ingestion

> Last updated: 2026-09-05 · commit `544cfa5ee`

The coordinator accepts optional paged allocator observations, preserves their
capture age, and emits bounded memory gauges and counter deltas. This milestone
covers Go ingestion and the console TypeScript mirror. Native capture provenance
and the Swift heartbeat producer remain pending; no live provider, model latency,
memory improvement, or deployment result is claimed.

## Change and boundaries

`BackendSlotCapacity.paged_storage` carries the original nine storage gauges,
optional nominal-KV/physical-floor observations, and four optional cumulative
failure/refusal counters. Missing instrumentation is distinct from zero. The
coordinator accepts only the closed `segmented` kind and bounds numeric values.
The fields neither change admission nor assert durable cache readiness.

`reconcileCapacitySamples` shares prefix-cache and paged-storage age handling.
Repeated or regressed capture sequences retain the previous sample and increase
its age using coordinator elapsed time. A changed generation starts a baseline;
missing slots/samples and reconnects discard it. Bookkeeping remains bounded by
the live slot set. No allocator walk occurs on the coordinator heartbeat path.
The accepted-sample timestamp is separate from provider liveness, so rejected
capacity frames cannot hide elapsed sample age.

`recordPagedStorageTelemetry` emits ownership only for new fresh samples and
counter deltas only within one observed generation. Counters moving backwards
contribute no negative delta. Labels are existing bounded chip/version classes;
pool, model, prompt and generation identifiers do not create metric series.
The byte gauges overlap and must not be summed. They reach live backend
snapshots and Datadog, without new Postgres columns or event-ingestion fields.

## Validation

The final source is captured over base `544cfa5ee`: 16 Go/TypeScript paths and
six current documentation files in the [owned-path manifest](evidence/paged-storage-ingestion-2026-09-05/source-manifest.json),
plus hashes for all 878 Go source/module inputs in the
[Go manifest](evidence/paged-storage-ingestion-2026-09-05/go-source-manifest.json.gz).
All captured source hashes were checked again after testing. The full package
runs below preceded the final accepted-sample clock correction; their exact
[source manifest](evidence/paged-storage-ingestion-2026-09-05/source-before-clock-fix.json)
is retained separately. The final correction was checked by the affected normal
and race runs below. The
[evidence manifest](evidence/paged-storage-ingestion-2026-09-05/manifest.json)
records stored and uncompressed hashes and sizes; no binary is included.

| Check before clock isolation | Passed top-level tests | Passed subtests | Package elapsed |
|---|---:|---:|---:|
| Full `coordinator/protocol` | 101 | 147 | 0.225 s |
| Full `coordinator/registry` | 953 | 493 | 18.175 s |
| Full `coordinator/registry/routingsim` | 14 | 2 | 0.591 s |
| Focused API telemetry | 2 | 0 | 5.408 s |
| Focused protocol race | 3 | 0 | 1.228 s |
| Focused registry race | 7 | 11 | 1.350 s |
| Focused API race | 2 | 0 | 6.441 s |

| Final clock correction check | Passed top-level tests | Passed subtests | Package elapsed |
|---|---:|---:|---:|
| Focused registry | 8 | 11 | 0.354 s |
| Focused API | 2 | 0 | 5.354 s |
| Focused registry race | 8 | 11 | 1.353 s |
| Focused API race | 2 | 0 | 6.528 s |

All listed runs had zero failures and skips. The focused pattern was
`Test(PagedStorageTelemetry|CapacitySamplesAge|PrefixCacheTelemetry)`, with
`-count=1`; all Go commands used `GOTOOLCHAIN=go1.25.0`. Exact commands and counts
are in [results.json](evidence/paged-storage-ingestion-2026-09-05/results.json),
with full package, focused API and race output linked there. These are package
verification times, not performance measurements. Touched TypeScript ESLint,
Go formatting, diff whitespace and documentation checks also passed.

The regressions exercise optional wire fields, deep snapshot ownership,
untrusted bounds, known-model filtering, generation/removal/reconnect reset,
stopped-producer age, and the actual accepted-heartbeat-to-UDP metric path.
They also preserve existing prefix-cache telemetry behavior through the shared
freshness helper.

Review found that rejected `capacity_seq` frames advanced `LastHeartbeat`,
undercounting sample age when it shared that clock. The final regression puts
the accepted sample six minutes in the past, sends three rejected frames that
keep liveness current, then accepts a repeated sample. Both paged and prefix
observations retain the full stale age. Initialization, reload, slot removal
and nil capacity are covered without sleeping.

The [initial focused attempt](evidence/paged-storage-ingestion-2026-09-05/initial-focused-failure.log.gz)
failed because a reused assertion helper expected `provider_version:0.8.x`
while the new fixture correctly emitted `0.9.x`. The test now checks its actual
chip/version classes. No production fix was needed for that failure. The final
race linker emitted the existing Darwin `LC_DYSYMTAB` warning and completed
successfully; the JSON build-output record and stderr are retained.

## Current implementation map

| Concern | Source |
|---|---|
| Optional wire and deep clone | `coordinator/protocol/paged_storage_telemetry.go` (`PagedStorageTelemetry`, `Clone`) |
| Bounds and shared freshness | `coordinator/registry/paged_storage_telemetry.go` (`clampPagedStorageTelemetry`), `coordinator/registry/capacity_sample_freshness.go` (`reconcileCapacitySamples`) |
| Accepted snapshot and metrics | `coordinator/api/provider_heartbeat.go` (`applyProviderHeartbeat`), `coordinator/api/provider_paged_storage_telemetry.go` (`recordPagedStorageTelemetry`) |
| Console mirror | `console-ui/src/app/providers/types.ts` (`PagedStorageTelemetry`) |

Current semantics and producer status belong in the
[wire reference](../reference/protocol-messages.md#slotspaged_storage) and
[telemetry architecture](../architecture/telemetry.md#paged-allocator-observations).
