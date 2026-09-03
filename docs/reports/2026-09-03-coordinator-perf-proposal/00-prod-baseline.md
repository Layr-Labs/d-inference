# 00 — Production baseline (measured 2026-09-03, 14:05–14:20 PDT)

All numbers below are **M** (measured) unless marked. Source: read-only IAP SSH into
`darkbloom-coordinator`, `pprof` on the coordinator's loopback listener
(`EIGENINFERENCE_PPROF_ADDR=127.0.0.1:6060`, added by #799), read-only `psql` with
`default_transaction_read_only=on`, and the Datadog metrics API. Raw profile files are
kept out of the repo (scratchpad `prodprof/`: `cpu.pprof` 30 s, `heap.pprof`,
`allocs.pprof`, `goroutine.txt`).

Prod runs build `4ce5c0409` (branch `fix/routing-overload-hardening`, deployed
2026-09-01 04:53 UTC). It is **not** an ancestor of master; #799 is its rebased
equivalent. #809 (system profiler) is not deployed: `request_profiles` and
`fleet_snapshots` do not exist in prod yet.

## Host and process

| Item | Value |
|---|---|
| VM | 30 vCPU, 56 GB RAM, load average 12.4 (78 days up) |
| Container limits | none (`NanoCpus=0`, `Memory=0`, host network) |
| Coordinator CPU | **435 %** of one core (≈4.4 cores) at ≈46 chat completions/s |
| RSS | 2.58 GB; Go live heap 1.12 GB |
| OS threads / goroutines | 51 / **7,080** (≈5.6 per provider: nhooyr `timeoutLoop`, `providerWriter.run`, `challengeLoop`, read loop, writer watcher) |
| Go runtime env | **no `GOGC`, `GOMEMLIMIT`, or `GOMAXPROCS`** set |
| Routing scan permits (#799) | `DefaultRoutingConcurrency()` = `NumCPU` = 30 |
| Sockets | 7,120 established TCP (1,261 provider WebSockets + consumer HTTP) |
| Providers connected | 1,261 (`/health`) |

## Where the 4.4 cores go (30 s CPU profile, 134.6 s of samples)

| Share of CPU | Where | Mechanism |
|---:|---|---|
| **~40 %** | GC mark: `runtime.scanobject` 36 % cum, `greyobject` 22 %, `gcBits.bitp` 11 % flat, `findObject` 11 %, `mspan.base` 9 % | live heap 1.1 GB scanned every cycle; allocation rate set by the routing scan and store reads |
| **26.9 %** | `registry.(*Registry).scanCandidatesLocked` (cum) | per-attempt full-fleet walk under `Registry.mu.RLock`: `snapshotProviderLockedEx` 22.6 %, routing gates 6.6 %, concurrency-cap resolution 6.2 %, `TPSRegistry.Median`/`SoloMedian` sorts 8.6 % (`slices.pdqsortOrdered` 7.2 %), `duffcopy` 2.1 %, `time.Now` 1.4 % |
| 6.3 % | `runInferenceAdmission` → `quickCapacityCheck` 3.2 % | second full-fleet walk per request (preflight) |
| 5.4 % | `syscall.Syscall6` (flat) | network reads/writes (WS + HTTP + DB) |
| 5.2 % | `providerReadLoop` | heartbeat/chunk decode for 1,261 providers |
| 5.0 % | `handleStreamingResponseWithFirstChunkAndError` | per-chunk decrypt + SSE normalize + write + flush |
| 3.6 % | `encoding/json.Unmarshal` | request bodies + provider frames |
| 3.3 % | `mdmVerificationScheduler.dispatcher` | polls `provider_verification_jobs` (see DB) |
| 42.3 % | `handleChatCompletions` (cum, overlaps the rows above) | the request path end to end |

## Allocation profile (bytes, cumulative since start) — what feeds the GC

| Share | Site | Note |
|---:|---|---|
| 16.0 % | `store.(*PostgresStore).ListDueVerificationJobsPage` | 1,990-row table, seq-scanned ≈35×/s |
| 27.6 % | `TPSRegistry.Median` 11.2 % + `SoloMedian` 10.6 % + `SoloMedianAllChips` 5.8 % | copy+sort per provider per scan |
| 10.0 % | `buildCandidateWithReason` | one heap candidate per eligible provider per scan |
| 5.5 % | `providerPooledTokenBudgetWithLayout` | a map per provider per snapshot |
| 5.0 % | `versionSegments` | semver re-parsed per provider per scan |
| ~12 % | `encoding/json` decode/encode (`Decoder.refill` 4 %, `Marshal` 3.8 %, `unquote`, `RawMessage`) | bodies and frames |
| 3.4 % | `store.(*PostgresStore).GetAccountEarnings` | 5,000 rows per call, ≈3 calls/s |
| 3.1 % | `normalizeSSEChunk` | per chunk |
| 39.5 % | `scanCandidatesLocked` (cum) | ≈half of all bytes allocated by the process |

## Live heap (1,122 MB in use)

| Size | Retainer |
|---:|---|
| **480 MB** | `payments.(*Ledger).RecordUsage` — `l.usage[consumerID] = append(...)` per completion, never trimmed (`payments/payments.go:71`) |
| 403 MB | `encoding/json.(*decodeState).literalStore` — 262 MB reached via `protocol.(*ProviderMessage).UnmarshalJSON` ← `providerReadLoop`; 208 MB under `handleChatCompletions` |
| 32 MB | `buildCandidateWithReason` (transient) |
| 27 MB | `ListDueVerificationJobsPage` (transient) |
| 20 MB | `LoadStoredProviders` |

## Lock and semaphore waiters at the profile instant (goroutine dump)

| Waiting goroutines | Where | Lock |
|---:|---|---|
| **88** | `registry.(*Registry).commitProviderReservation` `scheduler.go:528` | `Registry.mu` write |
| 14 | `ClearDispatchLoadCooldown` `registry.go:2477` | `Registry.mu` write |
| 14 | `RecordProviderServeOutcome` `health_ejection.go:456` | `Registry.mu` write |
| 11 | `RecordInferenceSuccess` `error_cooldown.go:149` | `Registry.mu` write |
| 10 | `RecordProviderOutcome` `provider_breaker.go:193` | `Registry.mu` write |
| 9 | `RecordCapacityAcceptOutcome` `capacity_cooldown.go:421` | `Registry.mu` write |
| 5 | `ReserveNextFromPlan` `dispatch_plan.go:399` | `Registry.mu` write |
| **66** | `api.(*Server).acquireRoutingScanSlot` `server.go:1392` | #799 scan semaphore (30 permits) |
| 75 / 59 / 19 | streaming relay / `waitFirstChunk` / `waitNoBackup` | (legitimately in flight) |

≈150 goroutines are queued on the single registry write lock and 66 on the scan
semaphore at an instant when the offered load is ≈50 attempts/s.

## Request latency decomposition (inference_routes, last hour, 183,679 attempts)

| Stage (ms) | p50 | p90 | p99 | What it spans |
|---|---:|---:|---:|---|
| `parse_ms` | 7 | 25 | 230 | body parse + preprocess |
| `reserve_ms` | 1 | 2 | 10 | balance reservation (one DB round trip) |
| **`route_ms`** | **2,034** | **9,103** | **24,132** | `ReservedAt → RoutedAt`: preflight capacity walk (+ up to 1 s scan-slot wait), reservation scan, write-lock commit, retries |
| `encrypt_ms` | 4 | 9 | 20 | seal for provider |
| `dispatch_to_first_chunk_ms` | 194 | 567 | 1,695 | provider first frame (boilerplate) |
| `actual_ttft_ms` | 1,617 | 4,009 | 9,473 | first content token (prefill) |
| `total_duration_ms` | 5,587 | 14,249 | 36,362 | end to end |
| `queue_wait_ms` (n=355) | 231 | 1,315 | 3,332 | only 0.2 % of attempts queue |

The coordinator's own routing stage adds **2.0 s at the median and 9.1 s at p90** to
every request, more than the provider's actual time to first token (1.6 s p50).
The CPU cost of a scan is only ≈25 ms (1.2 cores ÷ 50 attempts/s), so the 2 s is
queueing: readers pile up behind writers on `Registry.mu` (Go `RWMutex` blocks new
readers once a writer waits), and the scan semaphore queues behind that.

Cost-model inputs recorded per attempt: `cost_ms` p50 35,776 (the routing cost term,
dominated by the injected `max_tokens=32,768`), `health_ms` p50 3,284, `best_ttft_ms`
p50 696 vs `actual_ttft_ms` p50 1,617.

## Outcomes and rejections (last hour)

| Attempt outcome | Count |
|---|---:|
| selected / success | 119,677 |
| selected / error | 54,000 |
| selected / timeout | 3,600 |
| selected / cancelled | 2,716 |
| error (no dispatch) | 2,215 |
| no_provider | 1,078 |

Attempt-0 rows: 135,754 (client requests). Attempt tail: 1→16,941, 2→9,034, 3→3,887,
…, 11→526 and continuing.

| Rejection (client-visible 4xx) | Count / h | could_have_served |
|---|---:|---|
| preflight `routing_saturated` | **22,045** | true |
| dispatch `first_chunk_timeout` | 8,854 | true |
| dispatch `deadline_unreachable` | 1,060 | false |
| dispatch `routing_saturated` | 393 | false |
| other | < 350 | |

Per model, attempt 0, last hour: gemma-4-26b 100,178 requests, 90 % served, TTFT p50 1.5 s;
gpt-oss-20b 24,417, **50 % served**, TTFT p50 5.7 s; qwen3.6-35b 5,787, 94 %; qwen3.5-35b 742, 90 %.

## Database (Cloud SQL PostgreSQL 17.10 — CLAUDE.md still says AWS RDS)

| Setting | Value |
|---|---|
| Size | 282 GB; heap hit ratio 100 %, index hit 99.9 % (fits in shared_buffers ≈ 84 GB) |
| `max_connections` / `work_mem` | 1000 / 4 MB; `track_io_timing=off`; **no `pg_stat_statements`** |
| Since stats reset 2026-08-24 | tup_returned **14.7 T rows**, tup_inserted 244 M, tup_updated 385 M, **temp_bytes 794 TB**, deadlocks 9 |
| Coordinator connections | 14 active + 10 idle at sample time |

Active-backend samples (40 samples over 30 s, normalized):

| Samples | Statement | Duration seen |
|---:|---|---|
| 173 | `UsageLocationBuckets` (`request_location->>'city'…` over `usage`) | 2–8 s |
| 172 | `UsageFlowBuckets` (same, joined to `users`) | 7–8.5 s |
| 69 | `NetworkTotals` / `Leaderboard` (`WITH work AS … FROM provider_earnings`) | 7 s |
| 13 | `UsageTotalsSince` / `COUNT(*) FROM usage` | — |
| 5 | `UsageTimeSeries` | — |
| ≤5 each | hot-path writes (`inference_routes` INSERT/UPDATE, `provider_earnings`, `usage`, `balances` CTE, `provider_reputation`, `providers`, `provider_sessions`), several in `LWLock` wait | ms |

≈90 % of the database's busy time is five analytics statements re-run continuously
(≈7 concurrent at every instant) even though the stats handler has a 1-minute read cache.

| Table | Size | Live rows | Writes since 08-24 | Scans |
|---|---:|---:|---|---|
| inference_routes | 121 GB | 105 M | ins 53 M, **upd 80 M** (insert then outcome update per attempt; 180 K rows/h now) | idx 134 M |
| usage | 64 GB | 68 M | ins 26.7 M | idx 3.3 M |
| provider_earnings | 38 GB | 71 M | ins 28 M | **seq 466 K**, idx 36.8 M |
| ledger_entries | 36 GB | 140 M | ins 54.8 M | idx 44 K |
| request_rejections | 13 GB | 21.6 M | ins 4.15 M (40 K/h) | idx 219 |
| providers | 7 GB | 1.95 M | upd 43.9 M | idx 1.08 B |
| provider_sessions / provider_reputation / earnings_summary / balances | ≤1.2 GB | — | upd 46.7 M / 65.6 M / 56 M / 54.8 M | — |
| provider_verification_jobs | 1.4 MB | 1,990 | upd 296 K | **seq 30.2 M (≈35/s)** |

Indexes with ≤ 25 scans in 10 days: `inference_routes_pkey` 3.8 GB (0), `idx_inference_routes_model`
8.1 GB (19), `idx_inference_routes_provider` 11 GB (25), `request_rejections` pkey/model/status/servable
4.5 GB total (0), `usage_pkey` 1.5 GB (5), `ledger_entries_pkey` 3 GB (0), `provider_earnings_pkey`
1.5 GB (0), `provider_sessions` key/serial/pkey 0.5 GB (0), `provider_floor_draws` pkey/account 0.5 GB (0).
≈34 GB of indexes are maintained on every write and never read.

## HTTP traffic (Datadog `d_inference.http.requests`, last hour)

| Path | Requests / h |
|---|---:|
| POST /v1/chat/completions | 165,363 |
| GET /v1/me/providers | 18,180 |
| GET /v1/me/summary | 17,967 |
| GET /api/version | 10,827 |
| GET /v1/provider/account-earnings | 10,774 (→ `GetAccountEarnings(id, 5000)`) |
| GET /v1/providers/attestation | 6,568 |
| GET /v1/models/capacity | 4,175 |
| GET /health | 3,944 |
| GET /v1/releases/latest | 3,117 |
| GET /v1/stats | 2,537 |
| POST /v1/mdm/webhook | 2,081 |
| GET /v1/network/totals | 1,730 |
| GET /v1/models/catalog | 1,315 |
| GET /v1/pricing | 755 |
| GET /v1/leaderboard | 406 |

Datadog on this build has no per-stage latency metrics (the #723 X-Timing histograms
are not emitted by 4ce5c0409); `inference_routes` is the only source for the stage table above.

## Addendum — prod redeployed to master `5d400cf75` (#809) at 21:13 UTC, re-measured 21:24 UTC

The container restarted 11 minutes before the second profile, so the live heap is the
fresh-process baseline (leak reset). Same offered load (≈62 attempts/s).

| Metric | Build 4ce5c0409 (48-hour-old process, heap 1.12 GB; VM up 78 days) | Build 5d400cf75 (11 min old, heap 0.16 GB) |
|---|---:|---:|
| Coordinator CPU (30 s profile) | 4.46 cores | **3.43 cores** |
| GC (`gcBgMarkWorker` cum) | 1.74 cores (38.8 %) | **0.75 cores (21.8 %)** |
| `scanCandidatesLocked` cum | 1.21 cores (26.9 %) | 1.39 cores (40.4 %) |
| `handleChatCompletions` cum | 1.90 cores | 2.01 cores |
| `providerReadLoop` cum | 0.23 cores | 0.22 cores |
| streaming relay cum | 0.22 cores | 0.22 cores |
| `Syscall6` flat | 0.24 cores | 0.23 cores |
| goroutines | 7,080 | 7,714 |
| Go MemStats (new build, 11 min): `TotalAlloc` 185.9 GB → **281 MB/s allocation rate**; `NumGC` 1,162 → 1.76 GC cycles/s; `HeapAlloc` 256 MB, `NextGC` 415 MB | | |

The one-core difference in GC between the two processes is the cost of the retained
heap (the `Ledger.RecordUsage` growth plus retained provider frames): same allocation
rate, four to seven times more live bytes to mark per cycle. **M: ≈1.0 core.**

#809 write rates, first 10 minutes after deploy (Postgres, read-only):

| Table | Rows in 10 min | Rate | Growth |
|---|---:|---:|---|
| `request_profiles` | 39,327 | **65 rows/s** (one INSERT per dispatched attempt) | 65 MB / 10 min ≈ **9.4 GB/day** |
| `fleet_snapshots` | 15,381 | 25 rows/s (one row per provider per 60 s) | 10 MB / 10 min ≈ 1.4 GB/day |
| `inference_routes` (for scale) | 37,511 | 62 rows/s (+62 UPDATEs/s) | ≈ 12 GB/day |

## Database instance (corrected: the coordinator talks to `d-inference-prod-pg17` via cloud-sql-proxy)

| Instance | Tier | Role | CPU (6 h mean) | Backends | Disk writes | Tx/min |
|---|---|---|---:|---:|---:|---:|
| `d-inference-prod-pg17` | `db-c4a-highmem-32` (32 vCPU, 256 GB), REGIONAL, 600 GB | primary | **34.5 % ≈ 11 vCPU busy** (peak 40 %) | 25–56 | 55.8 K ops/min | 99.5 K (≈1,660 tx/s) |
| `d-inference-prod-pg17-ro` | `db-c4a-highmem-16` | read replica (admin-ui) | 5 % | 3 | (replay) | 208 |
| `d-inference-prod` | `db-custom-1-3840`, PG 16, 10 GB | **orphan, still RUNNABLE** | 9 % | 2 | 0 | — |

Roughly 90 % of the primary's busy samples are the five analytics statements, i.e.
≈10 of the 11 busy vCPUs on a 32-vCPU regional instance are spent recomputing the
public stats page. The hot path itself (≈1,660 tx/s of short writes) is the other ≈1 vCPU.

## Host CPU outside the coordinator process (`ps`, 21:24 UTC)

| Process | CPU | Note |
|---|---:|---|
| coordinator | 206 % (instant; 343 % over the 30 s profile) | |
| dockerd | **180 %** | json-file log driver + six concurrent `docker logs --since 2h --tail 50000`-style readers |
| journalctl | **100 %** | operator/agent log tailing |
| caddy | 45 % | TLS termination |
| cloud-sql-proxy | 8 % | |

Coordinator log volume: **18,955 lines / 4.6 MB per minute** (≈316 lines/s, ≈6.6 GB/day)
through Docker's json-file driver with **no rotation configured** (`LogConfig: {}`); the
container's log file was 85 MB twelve minutes after start. Per request the coordinator
emits four to six INFO lines (`request`, `inference request dispatched`, `dispatch_pool`,
`inference complete`/`inference error`, `speculative_dispatch_*`); "error for unknown
request" (the post-cancel zombie frames) still logs 142 lines/min.
