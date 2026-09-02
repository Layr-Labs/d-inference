# Coordinator performance program — 2026-09-02

Status: complete, awaiting review/push (branch `worktree-bridge-cse_01TuyfD42fkRyG4ZqSTmeN4U`, based on master `a1f51ea4c`).

This report is the first-principles pass over every coordinator operation with a
measurable cost: the inference hot path (auth → parse → admit → route → dispatch →
stream → settle), the fleet-scale paths (heartbeats, eviction, aggregates), and
the store layer. Each finding names the mechanism, the measured cost, and the
change made. Numbers are from `coordinator/registry/fleet_scale_bench_test.go`
(1,260 providers, 15 models, live heartbeats, in-flight pending requests) on an
Apple M4 Max unless stated otherwise.

## 1. Why now

The 2026-09-01 congestion collapse (PR #799) showed the coordinator's per-request
CPU cost is dominated by full-fleet walks: every request scans all ~1,260
providers at least twice (capacity preflight + reservation scan), and the failure
path re-scans up to 64 times. PR #799 bounds the retry ladder and adds a scan
semaphore; this program attacks the cost of each scan and of everything else on
the request path.

## 2. Baseline (before)

| Benchmark | ns/op | B/op | allocs/op |
|---|---:|---:|---:|
| FleetReserveProviderEx (scan + commit + release) | 403,844 | 186,309 | 824 |
| FleetReserveProviderExParallel (GOMAXPROCS=16) | 355,349 | 231,610 | 1,027 |
| FleetQuickCapacityCheck (preflight) | 151,308 | 80,976 | 672 |
| FleetHeartbeat (ingest) | 529 | 449 | 6 |
| FleetListModels (`/v1/models` aggregate) | 180,489 | 249,272 | 1,281 |

CPU profile of the reservation scan (top of `pprof -top`):

| Share | Where | Mechanism |
|---:|---|---|
| 35% | `runtime.walltime` | `time.Now()` per provider — `snapshotProviderLockedEx` calls it before any gate, so all 1,260 providers pay it even though ~90% do not advertise the model |
| 8.5% | `runtime.duffcopy` | `routingSnapshot` (large struct) copied by value through snapshot → candidate → discount |
| 3% | `healthEjectionEnabled` | `os.Getenv` + `ToLower`/`TrimSpace` per provider per scan |
| 3.5% | `prefixCacheV2CapabilitiesForModel` | second full fleet walk per request, `p.mu` on every provider, run even with cache routing off |
| ~2% | `slices.pdqsort` | `TPSRegistry.Median` copies + sorts up to 50 samples per provider |
| ~2% | `runtime.concatstrings` | `providerID + ":" + model` map keys for every cooldown/breaker/clamp gate |
| ~4% (alloc) | `versionSegments` / `strings.Split` | semver re-parsed per provider per scan |

Allocation profile: `buildCandidateWithReason` 44% (one heap candidate with an
embedded snapshot copy per eligible provider), `TPSRegistry.Median` 23%,
`providerPooledTokenBudgetWithLayout` 11% (a map per provider per snapshot).

End-to-end (`EIGENINFERENCE_PERF_E2E=1 go test ./api/ -run TestPerfE2E`; real HTTP,
in-process WebSocket fake providers answering instantly, memory store, 16 KB
bodies, 40 streamed chunks):

| Fleet | Concurrency | Throughput | TTFB p50 / p95 | Total p50 / p95 |
|---|---:|---:|---|---|
| 100 providers | 16 | 1,523 req/s | 6.8 ms / 9.7 ms | 10.2 ms / 14.0 ms |
| 1,000 providers | 32 | 524 req/s | 42.3 ms / 54.7 ms | 62.1 ms / 83.0 ms |

Ten times the fleet costs six times the first-byte latency with providers that
respond instantly: the per-request fleet walk is the coordinator's dominant
cost at production scale.

## 3. Hot-path inventory (per chat completion, success path)

| Stage | Cost mechanism | Finding |
|---|---|---|
| `requireAuth` | API key cached (60s) but `GetUserByAccountID` is a Postgres round trip on every request | uncached |
| `parseInferencePrelude` + `handleChatCompletions` | body parsed once, then re-marshalled/re-parsed 6–9× (tool-constraint validation re-parses the original body; alias/reasoning/defaults/max_tokens each re-marshal; `providerBodyForModel` recomputed for the same model) | CPU + allocs proportional to body size, up to MBs with inline media |
| `GetModelRegistryRecord` | two queries per call, called 3–4× per request | uncached |
| `reserveInferenceBalance` | one round trip | necessary |
| `runInferenceAdmission` | `QuickCapacityCheck` full fleet walk | see §2 |
| `ReserveProviderEx` | full fleet walk + global write-lock commit | see §2 |
| `recordRoutingDecisionFor` | one INSERT per attempt through a 1-worker, 4096-deep sink | write amplification, drops under a slow DB |
| streaming relay | one `Fprintf` + `Flush` (syscall) per token; seven `strings.Contains` per chunk | per-token syscalls |
| `handleCompleteAt` | `GetUserByAccountID` again, three separate credit transactions, usage insert | 4–6 round trips per completion |

Fleet-scale: `Registry.Heartbeat` is cheap (0.5 µs); the API-side heartbeat
branch adds capacity deep-copies and telemetry; `ListModels` re-aggregates the
fleet on every `/v1/models`; `/v1/stats` is cached, other public endpoints are
not.

## 4. Changes

_(per worker, in merge order)_

### 4.1 Store read-through cache (`store/cached.go`, `store/cached_domain.go`, `store/cached_clone.go`)

`store.NewCached` wraps both backends at construction in `cmd/coordinator/main.go`.
It overrides only the hot-path lookups and the mutators that can change them:

| Cached lookup | TTL | Invalidated by |
|---|---|---|
| `GetUserByAccountID`, `GetUserByPrivyID` | 30 s | `CreateUser`, `SetUserRole`, `SetUserPlatformFeePercent`, `SetUserStripeAccount` (whole user domain) |
| `GetModelRegistryRecord`, `GetModelManifest` | 10 s | every model-registry writer (whole model domain) |
| "not found" results | 5 s | same |

Reads return deep copies, a generation counter drops loads that raced a
write, domains are bounded (10k users, 1k models) with random eviction, and
transient DB errors are never cached. Effect: the per-request `requireAuth`
user lookup and the 3–4 registry-record lookups (two queries each) become
in-memory hits after the first request per key/model. Single-process
assumption documented in the file header; TTLs bound staleness from
out-of-band SQL edits.

Decorating the store hides backend-only capabilities that callers discover by
type assertion (`codeAttestPushBudgetStore`, `verificationDuePageStore`), which
would have silently downgraded APNs push-budget durability and verification-job
pagination. `store.As[T]` walks `Unwrap()` through decorators and the four
assertion sites use it; tests pin that both capabilities survive the wrap.
Cache counters are emitted as `store.cache.*` gauges per domain.


### 4.2 Routing scan (`registry/`)

Ten commits, all inside `registry/`, each measured on the fleet benchmark:

| Step | Mechanism | Reserve ns/op (min) |
|---|---|---:|
| baseline | | 372k |
| clock hoist | one `time.Now()` per walk (scan, preflight, `PredictServable`, commit) | 262k |
| TPS caches | `Median`/`SoloMedian`/`SoloMedianAllChips` maintained on `Record` (≤50 samples), O(1) zero-alloc reads | 221k |
| kill switch + hint skip | health-ejection env read once at init (test hook); cache-capability walk skipped when hints are impossible (tracker nil / mode off / no plan) | 202k |
| version memo + struct keys | semver segments memoized (bounded 256, reset-on-full); `{providerID, model}` keys for dispatch-load cooldowns and pending loads | 176k |
| in-place snapshots | snapshot filled in place, `buildCandidateInto`, chunked `candidateArena`, pointer-passing (no `duffcopy`) | 135k |
| per-model index | `providersForModelLocked`: advertised model → providers, maintained at every `p.Models` mutation and removal site; used by the reservation scan, preflight, `PredictServable`, cache-capability lookup, and the alias probes (2–8 walks per aliased request) | 103k |
| calibrator bound | TTFT calibrator no longer re-sweeps its pending map on every reservation at capacity | 68k |

Eligibility gates are unchanged; the index only prunes providers that cannot
advertise the model. Review follow-ups landed with it: the health-ejection
test hook moved out of the production file; the calibrator prefers expired
entries at capacity (bounded probe plus a 5 s capacity sweep); a fault-state
fixture pins index equivalence with breaker-open, health-ejected and
capacity-cooled providers; the TPS median cache is safe for a zero-value
registry; the version memo skips oversized keys and the accepted provider
version is capped at 64 bytes at registration (provider-controlled input must
not be retained unbounded). Tests pin index == brute-force walk after every mutation
type and identical routing results with/without the index on the 1,260-provider
fixture for plain/tools/vision/TTFT-ceiling shapes.

### 4.3 Route telemetry batching (`api/telemetry_sink*.go`, `store/*route_telemetry*.go`)

The routing-telemetry sink now queues typed operations (route record, outcome
update, closure) and one worker gathers up to 256 ops or 100 ms, writing the
group's records with one multi-row `INSERT … ON CONFLICT`
(`RecordInferenceRoutes`) and each run of outcome updates with one pgx batch
pipeline (`UpdateInferenceRouteOutcomes`). A tracer-backed Postgres test shows
50 records + 50 updates go from 100 statements to 1 statement + 1 pipeline.
Per-key insert → update order is preserved by opening a new group whenever a
record's key already appears in the current group; the non-blocking
drop-and-count contract, single worker (now enforced), panic isolation per
row, transient-error classification (`store.IsTransientWriteError`: no
per-row replay on deadline/connection errors), post-close rejection, and a
bounded 2 s flush in `Server.Close` before the pool closes are all covered by
tests on both backends.

Settlement consolidation (one transaction for the consumer refund, provider
earning and platform fee) was evaluated and **not shipped**: the three writes
fail independently today, `CreditProviderAccount` is idempotent on job id
while `Credit` is not, and a single transaction over three balance rows adds a
deadlock cycle between concurrent settlements. Instead, `Credit` and
`CreditWithdrawable` were collapsed from five round trips (BEGIN, upsert,
SELECT, INSERT, COMMIT) to one data-modifying CTE statement, the shape `Debit`
already used; the transactional callers (`CreditWithdrawableOnce`,
`CreditProviderWallet`) reuse the same statement inside their transactions. A
tracer-backed test replays the legacy five-statement sequence against the new
path and asserts byte-identical ledger rows and balances for unknown, existing,
zero and negative amounts; a 32-goroutine mixed Credit/Debit test asserts the
ledger running sums.

### 4.4 Streaming relay and public read endpoints (`api/stream_coalesce.go`, `api/chat_stream_relay.go`, `api/sse_normalize_gate.go`, `api/models_cache.go`)

All three relays (chat, Responses, generic completions/messages) now drain the
chunks already queued in `ChunkCh` after each receive (bounded by the channel
capacity, never waiting), apply the identical per-chunk transforms and holds
in order, and flush once. Goldens pinned against the pre-change byte stream:

| Relay | flushes/op (200-chunk burst) | bytes/op |
|---|---:|---:|
| chat | 203 → 9 | identical |
| responses | 208 → 9 | identical |
| completions | 202 → 8 | identical |
| messages | 205 → 9 | identical |

The relay also fixed two latent ordering bugs the reviewers surfaced: queued
chunks now always precede a concurrently-ready in-band error, and the
Responses/generic close paths report a buffered provider error instead of
"provider ended without completion".

`normalizeSSEChunk` decides with one pass instead of nine `strings.Contains`
scans: content delta 915 → 191 ns, usage chunk 1.1 µs → 155 ns, byte-identical
output over a 36-case differential corpus.

Public read endpoints newly served from the TTL read cache: `/v1/models` and
`/v1/models/{id}` (2 s, shared entry memo keyed by include_builds; self-route
views stay live), `/v1/models/openrouter` (5 s), `/v1/providers/attestation`
(2 s). Admin alias/registry mutations invalidate the catalog-derived entries
through `SyncModelCatalog`/`SyncModelAliases`, so the TTLs only bound
out-of-band edits.

### 4.5 Fleet-scale aggregate and periodic paths (`registry/registry.go` ListModels/evictStale, `registry/provider_snapshot.go`)

| Path | Before | After |
|---|---:|---:|
| `ListModels` (`/v1/models` aggregate) | 182 µs, 1,281 allocs | 115 µs, 19 allocs |
| `PublicProviderModels` (`/v1/stats`, `/v1/providers/attestation`) | 181 µs, 1,266 allocs | 144 µs, 7 allocs |
| `evictStale` (every 30 s) | full fleet walk under the registry **write** lock (~85 µs, stalls routing readers) | walk under the read lock; write lock only to install a changed strike map |

New benchmarks cover every aggregate and periodic walk (`fleet_scale_aggregate_bench_test.go`,
`provider_heartbeat_bench_test.go`). Findings left for follow-up: the
model-swap planner runs a fleet walk on every heartbeat while the queue is
non-empty (~350 µs per heartbeat from a provider advertising a queued model,
~9% of a core at 250 heartbeats/s per queued model). Fixed in the registry
follow-up (`registry/model_swap_coalesce.go`): heartbeats now admit at most
one swap plan per 250 ms fleet-wide (the api cold-dispatch kick still plans
immediately), the planner's two walks iterate the per-model index, and the
per-heartbeat drain is unchanged — a direct plan with a queued unservable
model went from 82 µs to 0.2 µs and the full heartbeat ingest in that state
from 88 µs to 4 µs. Three read-only getters that took the write lock
(`CodeAttestationEnforced` in the 15 s gauge loop) now take the read lock;
`recordMLXCacheTelemetry` emits nine `provider_id`-tagged gauges per heartbeat
(~11k Datadog series per flush — an observability cardinality decision, not
changed here); throttled provider persistence is ~126 DB writes/s fleet-wide
(a product freshness choice, not changed).

### 4.6 Request body pipeline (`api/inference_preprocess.go`, `api/provider_body_*.go`, `api/toolschema_parsed.go`, `api/json_encoded_len.go`)

The chat handler now parses the body once, mutates the map (alias, stop
normalization, runtime defaults, max_tokens bound, reasoning policy, metadata
strip) behind a dirty flag, and serializes once at the first byte consumer.
Tool-schema normalization and tool-constraint validation run on the parsed
map (the legacy `"tools"` byte gate is preserved so escaped keys still pass
verbatim); the five message-tree walks are fused into one; billing bytes are
counted with a JSON-encoded-length routine instead of a full marshal; the
per-model provider body is memoized per request; and the legacy cache-bust
size/seal is computed by arithmetic splice on already-canonical bodies.

Full-body operations per request (chat, alias + runtime defaults, no
`max_tokens`): parses 5 → 1, marshals 10 → 1. With tools on the Responses
surface: parses 11 → 4, marshals up to 16 → 3.

| Body | Helper-level ns/op | HTTP end-to-end ns/op | allocs (HTTP) |
|---|---:|---:|---:|
| 2 KB chat | 99,418 → 22,360 | 492,662 → 445,907 | 1,290 → 801 |
| 60 KB history | 2,744,618 → 542,521 | 4,306,086 → 1,724,408 | 3,482 → 1,412 |
| 60 KB history + tools | 3,454,648 → 652,058 | 4,825,177 → 1,857,896 | 7,047 → 2,189 |
| 3 MB inline image | 147,274,823 → 19,902,326 | 193,711,639 → 53,986,076 | 1,854 → 972 |

Provider-visible bytes are pinned by identity tests against independent
oracles for every rewrite (verbatim passthrough, alias, stop, max_tokens,
runtime defaults, reasoning on/off, stripped fields, tool normalization,
Responses lowering, protocol-0 seal, alias-capacity fallback on both
surfaces, media inlining), plus property tests for the encoded-length and
splice routines against the decode → re-encode reference.

## 5. After

Registry benchmarks (1,260 providers; baseline and after measured back to back
in the same machine state, load average ~13):

| Benchmark | Before ns/op | After ns/op | allocs/op before → after |
|---|---:|---:|---|
| FleetReserveProviderEx | 322,881 | 67,933–73,309 | 824 → 21 |
| FleetReserveProviderExParallel | 355,349 (quiet baseline) | 84,749–87,103 | 1,027 → 20 |
| FleetQuickCapacityCheck | 151,054 | 47,347–47,922 | 672 → 1 |
| FleetPredictServable (new) | 187,760 (worker A/B) | 43,302–43,530 | 672 → 1 |
| FleetListModels | 191,167 | 138,012–139,786 | 1,281 → 19 |
| FleetHeartbeat | 529 | 641–662 | 6 → 6 (TPS caches now maintained on write) |
| FleetTickTriggerModelSwapsUnservableQueued | 82,390 | 216 | 3 → 3 |
| FleetTickHeartbeatQueuedColdAdvertised | 87,884 | 4,047 | 12 → 9 |

End-to-end (real HTTP, in-process WebSocket fake providers, memory store;
baseline and after measured back to back, same machine state):

| Scenario | Before | After |
|---|---|---|
| 100 providers, 16 KB, 16 concurrent | 1,435 req/s, TTFB p50 7.3 ms / p95 10.1 ms | 1,871 req/s, TTFB p50 4.3 ms / p95 7.5 ms |
| 1,000 providers, 16 KB, 32 concurrent | 448 req/s, TTFB p50 44.3 ms / p95 64.5 ms | 954 req/s, TTFB p50 20.4 ms / p95 29.1 ms |
| 100 providers, 60 KB, 16 concurrent | 395 req/s, TTFB p50 16.1 ms / p95 126.6 ms | 1,377 req/s, TTFB p50 7.6 ms / p95 10.8 ms |
| 1,000 providers, 60 KB, 32 concurrent | 410 req/s, TTFB p50 56.9 ms / p95 86.5 ms | 717 req/s, TTFB p50 28.5 ms / p95 46.5 ms |

The memory store hides the database wins: in production each request also
loses one `users` round trip and three to four two-query `model_registry`
round trips (now cache hits), each completion loses three round trips in the
`Credit` collapse, and route telemetry goes from one statement per attempt to
one multi-row insert per 100 ms.

Request preprocessing alone (helper-level benchmark, `-benchtime 2s`): 2 KB
body 99 µs → 22 µs; 60 KB history 2.74 ms → 0.54 ms; 3 MB inline image
147 ms → 20 ms.

## 6. Not done / recommendations

- **Settlement consolidation** (one transaction for refund + provider earning +
  platform fee) was evaluated and not shipped — see §4.3. The `Credit`
  round-trip collapse captures most of the DB win without changing failure
  semantics.
- **`/v1/pricing`** is still uncached (handler lives in `billing_handlers.go`);
  wrap it in the read cache with a 2 s TTL like the other public endpoints.
- **Datadog cardinality**: `recordMLXCacheTelemetry` emits nine gauges tagged
  by `provider_id` on every heartbeat (~11k series per flush at fleet scale).
  Aggregating by chip family, or sampling, is an observability decision worth
  making before the fleet grows further.
- **Provider persistence**: throttled `UpsertProvider`/`TouchProviderSession`/
  `UpsertReputation` writes are ~126 statements/s fleet-wide at 30 s freshness.
  Batching them (multi-row upserts on a 5 s cadence) would cut DB write load
  without changing the freshness contract.
- **Container GC settings**: the container runs with no `GOMEMLIMIT`/`GOGC`
  (deploy/gcp/vm-startup.sh); a soft memory limit tuned to the VM would let
  the GC run less often under the allocation rates measured here. Deploy-side
  change, human-only.
- **pprof listener**: PR #799 adds `EIGENINFERENCE_PPROF_ADDR`; not
  duplicated here. The generic completions/messages handlers still call
  `resolveRequestedModel` (inside #799's hunks) and can be folded onto the
  parse-once path after #799 merges.
- **Swap-planner coalescing window**: a request enqueued right after a plan
  waits up to 250 ms for the next heartbeat-triggered plan (the api
  cold-dispatch kick still plans immediately); on a fleet with no heartbeats at
  all no plan runs, which only matters for single-provider dev setups.
