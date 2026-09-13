# PR body draft — coordinator performance program (2026-09-02)

> Last updated: 2026-09-02 · commit `fa6abe3da`

_(Draft for the PR description. Numbers in the tables are filled from
`docs/reports/2026-09-02-coordinator-performance-program.md`.)_

## Summary

First-principles performance pass over every coordinator operation on the
inference path and at fleet scale. The 2026-09-01 collapse showed the
per-request cost is dominated by full-fleet walks; this PR removes the walks'
per-provider costs and prunes them to the providers that advertise the model,
removes the per-request database round trips, parses the request body once,
batches route telemetry, coalesces streamed chunks per flush, and caches the
public read endpoints. Every change is measured by a committed benchmark
(`registry/fleet_scale_bench_test.go`, 1,260 providers) and an end-to-end
harness (`api/perf_e2e_test.go`, real HTTP + WebSocket providers).

## Before / After — behavior

```mermaid
flowchart LR
  subgraph Before
    A1[request] --> B1["auth: API-key cache hit + users SELECT"]
    B1 --> C1["parse body once, re-marshal 6–9×"]
    C1 --> D1["model_registry SELECT ×2, called 3–4×"]
    D1 --> E1["PredictServable: walk 1,260 providers"]
    E1 --> F1["QuickCapacityCheck: walk 1,260"]
    F1 --> G1["ReserveProviderEx: walk 1,260 (time.Now + sort + concat per provider)"]
    G1 --> H1["INSERT inference_routes per attempt"]
    H1 --> I1["stream: write+flush per token"]
    I1 --> J1["settle: users SELECT + 3 txns"]
  end
  subgraph After
    A2[request] --> B2["auth: API-key + user cache hits"]
    B2 --> C2["parse once, mutate map, marshal once"]
    C2 --> D2["model record: cache hit"]
    D2 --> E2["PredictServable: walk advertisers only"]
    E2 --> F2["preflight: advertisers only, 1 alloc"]
    F2 --> G2["reserve: advertisers only, 21 allocs, clock hoisted"]
    G2 --> H2["route rows batched: 1 multi-row INSERT / 100 ms"]
    H2 --> I2["stream: queued chunks coalesced per flush"]
    I2 --> J2["settle: user cache hit"]
  end
```

## Before / After — code

```mermaid
flowchart LR
  subgraph Before
    R1[Registry.scanCandidatesLocked] --> P1["for p in r.providers (all)"]
    P1 --> S1["snapshotProviderLockedEx (time.Now, Median sort, string keys, struct copies)"]
    ST1[store.PostgresStore] --> Q1["GetUserByAccountID / GetModelRegistryRecord: SQL per call"]
    T1[telemetrySink] --> U1["RecordInferenceRoute per record"]
    V1[handleStreamingResponse] --> W1["Fprintf + Flush per chunk"]
  end
  subgraph After
    R2[Registry.scanCandidatesLocked] --> P2["providersForModelLocked (index)"]
    P2 --> S2["snapshot in place, TPS cache, struct keys, one clock"]
    ST2["store.CachedStore (NewCached)"] --> Q2["TTL + invalidation on mutators; store.As for optional capabilities"]
    T2["telemetrySink (typed, coalescing)"] --> U2["RecordInferenceRoutes / UpdateInferenceRouteOutcomes"]
    V2[handleStreamingResponse] --> W2["drain queued chunks → one buffered write → one Flush"]
  end
```

## Measurements

| Path (1,260-provider fixture) | Before | After |
|---|---|---|
| Reservation scan | 323 µs, 824 allocs | 68–73 µs, 21 allocs |
| Capacity preflight | 151 µs, 672 allocs | 47 µs, 1 alloc |
| Servability prediction | 188 µs, 672 allocs | 43 µs, 1 alloc |
| `/v1/models` aggregate | 191 µs, 1,281 allocs | 138 µs, 19 allocs |
| Heartbeat with a queued unservable model | 88 µs | 4 µs |

| End to end (same machine state) | Before | After |
|---|---|---|
| 1,000 providers, 16 KB bodies | 448 req/s, TTFB p50 44 ms | 954 req/s, TTFB p50 20 ms |
| 100 providers, 60 KB bodies | 395 req/s, TTFB p95 127 ms | 1,377 req/s, TTFB p95 11 ms |

Per request in production, additionally: 4–5 database round trips become
cache hits (user + model record), the completion settlement loses three
round trips (`Credit` as one statement), and route telemetry batches to one
multi-row insert per 100 ms. Full detail: `docs/reports/2026-09-02-coordinator-performance-program.md`.

## Notes for reviewers

- No overlap with PR #799's hunks (`consumer.go` 93–115 / 587–640 / 871–1130 /
  1426–1450, `dispatch.go` 184 / 1213 / 1652 / 1720, `inference_admission.go`
  219–340, `server.go` 27 / 492 / 793 / 1294, `main.go` 591–700 / 1048+).
- Single-process assumption for the store cache is documented in
  `store/cached.go`; manual SQL edits take up to the TTL to become visible
  (runbook row added).
