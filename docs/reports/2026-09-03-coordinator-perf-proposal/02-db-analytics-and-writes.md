# 02 — DB analytics and write path

Read-only analysis against master `5d400cf75` and prod Cloud SQL (PostgreSQL 17.10, 282 GB) on 2026-09-03 21:27–21:32 UTC. Grades: **M** measured (pg_stat / logs / profile), **C** computed from measurements, **E** estimate. Stats window: `pg_stat_database.stats_reset` 2026-08-24 14:32 UTC → 10.29 days = 889 ks. Prod probe scripts and raw output: scratchpad `prod_ro_batch1.sh/.out`, `prod_ro_batch2.sh/.out` (plain `EXPLAIN`, catalog reads, bounded ≤1 h data reads only).

## Question

Why do the analytics queries run continuously despite a 1-minute read cache; what is the cheapest design that takes analytics and polling reads off the primary's request path; and what does the write side cost (per-attempt insert+update, unused indexes, settlement rows, provider upserts, verification polling, #809's new tables)?

## Evidence

### E1. Who runs what (handler → cache → store → plan)

| Store call (postgres.go) | Handler | Cache key / TTL | Singleflight | Callers & rate | Plan (prod EXPLAIN) |
|---|---|---|---|---|---|
| `UsageLocationBuckets(24h)` :2214 | `/v1/stats` (stats.go:451) | `stats:v1` / 60 s | **no** | console `/stats` page every 15 s per visible tab (via Next proxy, s-maxage 10); landing page on load; 2.5K/h at coordinator | Parallel Index Scan `idx_usage_request_location_notnull` → **Sort (width 488) → GroupAggregate** (COUNT(DISTINCT) forces sort) |
| `UsageFlowBuckets(24h)` :2270 | `/v1/stats` (stats.go:588) | same | no | same | Index scan → Sort (width 328) → Nested Loop + Memoize on `providers_pkey` → Incremental Sort → GroupAggregate |
| `UsageTotalsSince(24h)` :2382, `UsageCountSince(24h)` :2353, `UsageTimeSeries(30m)` :2401, `UsageTotals()` :2369 | `/v1/stats` | same | no | same | index scans on `idx_usage_created`; `usage_totals` PK lookup |
| `NetworkTotals(window)` :2551 | `/v1/network/totals` (leaderboard.go:137) | `network_totals:<window>` / 60 s, 4 keys | no | console stats page (`?window=24h`), 1.7K/h | **3 × Parallel Seq Scan of `provider_earnings` (38 GB)** for every window incl. 24h — no `created_at` index exists |
| `Leaderboard(metric,window,limit)` :2464 | `/v1/leaderboard` | `leaderboard:<m>:<w>:<n>` / 5 min, up to 12 keys | no | console leaderboard, 406/h | 2 × Parallel Seq Scan of `provider_earnings` + `idx_ledger_reward` |
| `GetAccountEarnings(id, 5000)` :4313 | `/v1/me/summary` (me_handlers.go:165) | **none** | — | console dashboard `useFleetData` every 15 s per tab; 18.0K/h = 5.0/s | Index Scan `idx_provider_earnings_account`, LIMIT 5000, 203 B/row |
| `ListProvidersByAccount` + `GetReputation` × N | `/v1/me/providers` (me_handlers.go:337) | none | — | same hook, 18.2K/h = 5.05/s | index scans; **N+1**: 77.9 reputation reads/s (M) ⇒ N≈14 per call |
| `GetAccountEarnings(id, ≤1000)` + summary + balance | `/v1/provider/account-earnings` (billing_handlers.go:822) | `account-earnings:<id>:<limit>` / 20 s | no | 10.8K/h = 3/s; console earnings page polls 30 s/tab; other caller unidentified (not the Swift provider) | index scan, bounded |
| `ListDueVerificationJobsPage(now, 4096, off)` :5692 | `mdmVerificationScheduler.dispatcher` (mdm_scheduler_exec.go:14) | — | — | every dispatcher wake; **34.2 scans/s (M)** | Seq Scan of 1,991-row table (partial index unusable: OR with `running`), Sort, LIMIT 4096 |

### E2. What the DB is doing (pg_stat, 10.29 d unless noted)

| Metric | Value | Grade | Reading |
|---|---|---|---|
| Active client backends (2 samples) | 12/13 and 10/11 were the location/flow queries | M | consistent with parent's 40-sample count: ~90% of active samples are analytics |
| `usage.idx_tup_fetch` | 2.72 T rows → **3.06 M rows/s** | M/C | ≈3 heap-fetching scans × ~2.9 M rows per stats pipeline |
| `providers_pkey.idx_scan` | 1.077 B → 1,211/s | M/C | flow query's Memoize probes ≈2,200 distinct providers per exec ⇒ **≈0.55 stats pipelines/s ≈ 1,980/h** |
| `provider_earnings.seq_tup_read` | 11.80 T rows = 166 K full-table reads; ÷3 scans/exec = 55 K execs = **224/h** | M/C | ≈ 4 window keys × 60/h ⇒ NetworkTotals/Leaderboard cache works; the cost is per execution (114 GB of buffer reads, ~7 s, 2 parallel workers) |
| `provider_earnings.seq_scan` | 466,767 | M | inflated ×3 by parallel workers; do not use for exec counts |
| `pg_stat_database.temp_bytes` | 795.3 TB, 5.53 M temp files → **895 MB/s** | M/C | external sorts at `work_mem=4 MB`: 1.4 GB (location) + 0.95 GB (flow) per pipeline × 0.55/s ≈ 1.3 GB/s (E, same order) |
| `provider_verification_jobs` | seq_scan 30.39 M = 34.2/s; 1,826 rows read/scan; 73 rows due | M | DB cost ≈2% core; Go cost 16.0% of all allocated bytes (`make([]VerificationJob,0,4096)` per call) |
| `provider_earnings.idx_tup_fetch` | 17.6 B → 19.9 K rows/s | M/C | ≈ 5/s × ~4,000 rows from `/v1/me/summary`'s LIMIT-5000 fetch |
| Coordinator pool (postgres.go:64–70) | MaxConns 80, MinConns 10, MaxConnLifetime 30 min, MaxConnIdleTime 5 min, HealthCheckPeriod 30 s; no `DefaultQueryExecMode` set ⇒ pgx default `cache_statement` (per-conn prepared statements, 512 cap); 74 conns open during the stampede, 22 later | M | pool is sized for the stampede, not the workload |
| Generic-plan probe (`SET plan_cache_mode=force_generic_plan; PREPARE …($1 IS NULL OR created_at >= $1)`) | `UsageCountSince` shape: Parallel Index Only Scan cost 1.8 M; location shape: **Parallel Seq Scan on `usage`, cost 10.2 M**; custom plans cost ~32 K | M | with `auto` the custom plan wins today (`usage.seq_scan` = 0); the nullable-OR form is the only thing standing between prepared statements and a 64 GB seq scan |
| `pg_stat_statements` | available 1.11, **not installed**; `track_io_timing=off`; `plan_cache_mode=auto` | M | human-only to enable |

Docker log, last hour: `provider registered` 2,757; **`provider location resolved` 1,378** (→ `readCache.Invalidate("stats:v1")` at provider.go:923 each time).

### E3. Write side (rates = pg_stat counters ÷ 889 ks; last-hour rates where noted)

| Table | ins/s | upd/s | HOT % | Row bytes (M, 5-min sample) | Indexes (GB) | Per-unit statements |
|---|---|---|---|---|---|---|
| inference_routes | 59.9 (50 last h) | 90.7 | 30 | 662 | 6 idx, 48.3 GB; 3 with ≤25 scans (29.4 GB) | per request: 1.09 INSERT + 1.66 UPDATE = **2.8 statements** (37% of rows are retries) |
| request_rejections | 4.7 (11.2 last h) | 0 | — | 364 | 6 idx, 5.4 GB; 4 with ≤45 scans (4.2 GB) | 1 INSERT per rejection (goroutine) |
| usage (+usage_totals) | 30.1 | 30.1 (usage_totals id=1) | 99 | 558 (request_location 286) | 6 idx, 29 GB | 1 CTE statement per completion; **single-row hot spot** |
| provider_earnings | 31.6 | 0 | — | ~200 | 4 idx, 22.7 GB; **no created_at index** | inside CreditProviderAccount CTE |
| ledger_entries | 61.7 | 0 | — | — | pkey 3.2 GB (0 scans), idx_ledger_account 13.8 GB | 2.05 rows/completion |
| balances | 0 | 61.7 | 98 | — | — | 2.05 upd/completion; `platform` row touched by every fee credit |
| earnings_summary | 0 | 63.1 | 99.9 | — | — | 2 upserts/completion (account + provider) |
| providers | 1.6 | **49.4** | **0** | 3,901 | 3 idx | throttled 30 s/provider upsert; `last_seen` is in `idx_providers_account` ⇒ never HOT |
| provider_sessions | 1.6 | 52.6 | 90 | — | 6 idx; 3 with 0 scans | TouchProviderSession per heartbeat persist |
| provider_reputation | 1.5 | 73.9 | 99.9 | — | — | UpsertReputation throttled 30 s |
| provider_trust_reuse | — | 10.9 | 83 | — | — | — |
| **request_profiles (#809, live since ~21:14 UTC)** | **50–63** | 0 | — | **1,433** (1,775 incl. 5 idx) | 5 idx | batched 64 rows/250 ms; 14 d retention |
| **fleet_snapshots (#809)** | 28.5 (1,712 rows/min) | 0 | — | 531 (660 incl. 3 idx) | 3 idx | one batch/min; 30 d retention |

Completion round trips on master (provider.go:1969 `handleCompleteAt`): `Debit` reserve (1 CTE, at request start) + usage CTE (1) + `CreditProviderAccount` (1 CTE) + refund `Credit` (BEGIN+upsert+SELECT+INSERT+COMMIT = 5) + platform-fee `Credit` (5, when fee>0) + `GetUserByAccountID` (1) + `GetModelPrice` (1–2). Measured average is 2.05 ledger rows and 2.05 balance updates per completion, which fits either (reserve + provider credit) or (provider credit + platform fee under service-reservation mode, where reserve/refund stay in memory); pg_stat cannot distinguish the legs without `pg_stat_statements`.

## Mechanism

1. **The 60-second TTL on `stats:v1` is effectively ~2.6 s.** `attachProviderLocation` (provider.go:923) invalidates `stats:v1` on every provider registration that resolves a geo location: 1,378×/h (M) ⇒ mean gap 2.6 s. `/v1/stats` arrives every ~1.4 s. Nearly every request finds the key gone.
2. **No singleflight, serial 15–25 s pipeline.** `handleStats` runs six store calls serially (location ≈7–8 s and flow ≈7–8.5 s under contention). The key is only `Set` at the end, so every `/v1/stats` request that lands in that window also misses and starts its own pipeline. Result (C): ≈1,900–2,000 pipelines/h vs 60/h designed, ≈4.3 concurrent copies of each of the two big queries at any instant, ≈0.55 exec/s each.
3. **Each copy is expensive by construction.** `COUNT(DISTINCT provider_id)` forces a full Sort of all 24 h located rows (100% of usage rows carry `request_location`; 121,509 rows/h ⇒ ~2.9 M rows/24 h) at `work_mem=4 MB` ⇒ external merge sort ⇒ 1.4 GB temp per location query and ~1 GB per flow query. That is the 795 TB of temp I/O and the `IO`-wait backends.
4. **Correctness side effect:** the store calls swallow errors and the 10 s context timeout; on timeout `UsageLocationBuckets` returns nil, `handleStats` caches a response with empty `request_locations` for 60 s.
5. **NetworkTotals/Leaderboard are not stampeding** (224 execs/h ≈ the cache design), but every execution does 3 (totals) or 2 (leaderboard) full parallel seq scans of `provider_earnings` because there is no `created_at` index and `window=all` has no predicate at all. A refresher cannot help these; only a rollup or an index can.
6. **`/v1/me/summary` fetches up to 5,000 rows per call to sum two numbers**, and the LIMIT truncates: fleet average is ~2,400 earnings rows/day/account (28.06 M rows ÷ 10.29 d ÷ ~1,120 active accounts), 669 of 958 accounts active this week have >5,000 lifetime rows, so `last_7d_*` (and `last_24h_*` for busy accounts) are **wrong today** for most active accounts.
7. **Verification scheduler spins at DB round-trip speed.** `nextDispatchDelay` returns 1 ms whenever any queued pending/backoff job is due but cannot dispatch (12 workers busy; 73 rows due at sample time), and `dispatcher()` calls `loadDueRows()` on every wake ⇒ one seq scan per ~29 ms.
8. **`providers` upserts are never HOT** (0 of 43.9 M) because `last_seen` is a column of `idx_providers_account`; each 30 s heartbeat persist rewrites a 3.9 KB row and maintains three indexes.
9. **#809 sampling is not 10% in effect.** 17,186 successes recorded in 18 min ≈ 15.9/s vs ≈30/s completions ⇒ ≈53% of successes recorded (always-record rules or a non-default `EIGENINFERENCE_PROFILE_SAMPLE_RATE`). With 75% of attempts non-success, `request_profiles` ingests ~all attempts: 8–10 GB/day (C) ⇒ ~115–135 GB at the 14-day plateau (E); `fleet_snapshots` 1.6 GB/day ⇒ ~49 GB at 30 d (E).

## Proposed changes

| # | Change | Where | Mechanism removed | Knobs |
|---|---|---|---|---|
| P1 | **One background refresher owns `stats:v1`** (and `network_totals:*`, `network_series:*`): a goroutine on the existing readCache janitor cadence (server.go:2983) recomputes each key every 60 s, `Set`s with a 5-min safety TTL, serves stale while refreshing; handlers only `Get`. Delete the `Invalidate("stats:v1")` at provider.go:923 and server.go:1274. Run the two big queries inside one read-only tx with `SET LOCAL work_mem = '1GB'` (code-side, no Cloud SQL flag). Drop the `$1 IS NULL OR` form (always non-null): the forced-generic EXPLAIN in E2 shows that shape planning as a Parallel Seq Scan of `usage` (cost 10.2 M), so it must never win. | api/stats.go, api/server.go, store/postgres.go | 1, 2, 3, 4 | 0 |
| P2 | **`provider_earnings_daily(day, account_id, work_micro, reward_micro, tokens, jobs)`** maintained by one extra upsert inside the existing `CreditProviderAccount` / base-reward CTEs (the `earnings_summary` pattern, no extra round trip). `NetworkTotals`/`Leaderboard` for 24h/7d/30d read ≤30 × ~1.6 K rows; `all` reads `earnings_summary(key_type='account')` + `idx_ledger_reward` sum. One-time backfill by hand (one 38 GB scan, off-peak). Weaker fallback: `CREATE INDEX CONCURRENTLY … provider_earnings(created_at DESC)` (fixes 24h only). | store/postgres.go, postgres_base_rewards.go | 5 | 0 (1 table) |
| P3 | **`/v1/me/summary`**: replace `GetAccountEarnings(id,5000)` + Go loop with one aggregate: `SELECT count(*) FILTER (WHERE created_at>=$2), sum(amount) FILTER (…), count(*), sum(amount) FROM provider_earnings WHERE account_id=$1 AND created_at>=$3` (7 d bound; walks `idx_provider_earnings_account`). Fixes the truncation bug. Add a 15 s per-account readCache entry (dashboard polls at 15 s). | api/me_handlers.go, store | 6 | 0 |
| P4 | **`/v1/me/providers`**: `GetReputations(ctx, ids []string)` (one `WHERE provider_id = ANY($1)`) instead of N × `GetReputation`. | api/me_handlers.go:337, store | N+1 | 0 |
| P5 | **Verification scheduler**: call `loadDueRows` only on the 1 s tick (or when the in-memory queue is empty), never on every wake; floor `nextDispatchDelay` at 250 ms when no worker is free; `make([]VerificationJob, 0, min(limit, 256))`. | api/mdm_scheduler_exec.go, store/postgres.go:5716 | 7 | 0 |
| P6 | **Provider persistence batching**: buffer `UpsertProvider` / `TouchProviderSession` / `UpsertReputation` records for 5 s and write three multi-row `INSERT … ON CONFLICT` statements (same 30 s freshness contract). Perf branch §6 recommends this but did not build it. | registry/persistence.go, store | heartbeat write amplification | 1 (flush interval) |
| P7 | **Route telemetry: insert-on-outcome.** Extend the perf branch's sink so a route record is held in memory until its outcome arrives (or 60 s), then written once. Halves `inference_routes` statements and removes the non-HOT UPDATE (dead tuples, index churn). Trade-off: in-flight rows invisible until outcome; crash loses ≤60 s. Optional; P1–P6 do not depend on it. | api/telemetry_sink*.go (perf branch) | per-attempt insert+update | 1 (hold timeout) |
| P8 | **#809 knobs (config only)**: set `EIGENINFERENCE_PROFILE_SAMPLE_RATE` as intended and verify the always-record rules; consider dropping `idx_request_profiles_coord` / `_provider` (0 scans so far) if `admin_telemetry.go` exports by `created_at` only. | deploy env; store DDL | 9 | 0 |

## Estimated improvement (arithmetic)

| Item | Before | After | Δ | Grade |
|---|---|---|---|---|
| Stats pipelines | ≈1,950/h (0.55/s) | 60/h | −97% | C |
| DB CPU, stats share | ≈84% of analytics samples ≈ **75% of all active-backend samples** (360/430) | 60/h × ~16 s ≈ 0.27 backend-s/s | **−73% of total DB CPU** | C |
| Temp I/O | 895 MB/s (M) | at 60/h without work_mem: 2.4 GB/min = 40 MB/s (−95%); with `SET LOCAL work_mem='1GB'`: sorts fit in memory ⇒ ≈0 | −95…−100% | C/E |
| NetworkTotals/Leaderboard | 224 execs/h × 3 seq scans × 38 GB ≈ 25 TB/h buffer reads, ≈16% of analytics ≈ **15% of total DB CPU** | rollup: 224/h × ≤48 K rows ≈ 0; created_at-index fallback: 24h window only ≈ −25% of this item | −15% total DB CPU (P2) / −4% (index only) | C/E |
| Total DB CPU removed by P1+P2 | ≈10 busy backends (parent sample: 384 analytics samples / 40) | ≈1 | **≈ −88%** | C/E |
| `/v1/me/summary` rows from DB | 19.9 K rows/s (M) ≈ 4 MB/s wire | 5/s × 1 row; a 15 s per-account cache helps only if accounts have several open tabs (5/s could be 75 distinct accounts) | −99.9% rows (C); statements −0…−60% (E) | C/E |
| `/v1/me/providers` statements | 5.05 + 77.9 = 83/s | 2 × 5.05 = 10/s | −73/s | C |
| Verification poll | 34.2 scans/s; 16% of coordinator alloc bytes | ≤1/s; ≈0.5% alloc | −33/s; −15.5 pts of GC alloc pressure (GC is ~36% of coordinator CPU per cpu.pprof `scanobject`) | M/C |
| Provider persistence | 49.4 + 52.6 + 73.9 = 176 statements/s (M) | 3 statements / 5 s = 0.6/s | −175 statements/s, −175 commits/s | C |
| Index maintenance, inference_routes | 6 idx × (59.9 ins + 63.5 non-HOT upd) = 740 index ops/s | 3 idx: 370 | −370 ops/s, −29.4 GB | C (drops human-only) |
| Index maintenance, request_rejections | 6 × 11.2 = 67 ops/s | 2 × 11.2 = 22 | −45 ops/s, −4.2 GB | C |
| Route statements (P7, optional) | 2.8/request = 128/s (last h) | 1.09/request = 50/s | −78 statements/s; dead tuples 7.1 M → ~0 | C/E |
| Coordinator DB round trips per request (master) | auth user 1 + registry 6–8 + reserve 1 + route ins 1.1 + route upd 1.7 + completion (user 1 + price 1–2 + usage 1 + provider credit 1 + refund ≤5 + fee ≤5) ≈ **21–28** | perf branch: user/registry cached, routes batched (statements same, RTs ≈0.02), Credit 5→1 ⇒ ≈ **6–8**; this doc adds nothing per request (all changes are off-request-path or per-poll) | −70% (perf branch) | C |
| #809 when deployed (now live) | — | +50–63 rows/s request_profiles (≈1–4 batched statements/s, 5 index maintenances/row ≈ 300 index ops/s), +28.5 rows/s fleet_snapshots (1 batch/min, ≈85 index ops/s); +8–10 GB/day + 1.6 GB/day disk ⇒ ≈165–185 GB at plateau | adds about as much index work as the human-only drops remove | M/C/E |

Net statements/s on the primary (excluding index ops): before ≈ 128 routes + 11 rejections + ~150 settlement + 176 persistence + 83 me/* + 34 vjobs + 3.2 analytics ≈ **585/s**; after P1–P6 ≈ 128 + 11 + 150 + 0.6 + 10 + 1 + 0.1 ≈ **300/s** (−49%), and the remaining CPU is dominated by settlement and route writes rather than analytics.

## Effort / risk / tests

| # | Effort | Risk | Tests (live-isolated Postgres, no mocks) |
|---|---|---|---|
| P1 | 1 day | Stale-by-60 s stats (already the contract); refresher must survive DB errors (keep last good value, log). `SET LOCAL work_mem` is per-tx; verify with `EXPLAIN (ANALYZE, BUFFERS)` on a dev copy only. | refresher sets key once per tick under 50 concurrent `/v1/stats` (tracer counts 1 query set per tick); provider registration no longer evicts; timeout leaves previous value in place |
| P2 | 2 days + backfill | Rollup drift if a settlement CTE fails mid-way (it is one statement, so no); base-reward path must bump the same table; backfill must be idempotent (`ON CONFLICT DO UPDATE` from a bounded scan). Leaderboard `jobs` for `all` includes base-reward rows if served from `earnings_summary` (tokens exact, jobs +2.4%). | replay N settlements, assert rollup == direct aggregate for each window; backfill twice ⇒ identical |
| P3 | 0.5 day | None (strictly more correct) | account with 6,000 rows in 7 d: old path truncates, new path exact |
| P4 | 0.5 day | None | fleet of 20 providers ⇒ exactly 2 queries (tracer) |
| P5 | 0.5 day | Slower pickup of newly-due rows by ≤1 s | scheduler test: 100 due rows, 12 busy workers ⇒ ≤2 loads/s |
| P6 | 1–2 days | Loses ≤5 s of persistence on crash; multi-row upsert ordering per provider (last write wins within batch) | batch of 500 providers ⇒ 3 statements; freshness ≤35 s |
| P7 | 2 days (on top of perf branch sink) | In-flight rows invisible; crash loss ≤60 s; changes `request_waterfall` LEFT JOIN semantics timing | sink test: record+outcome within hold ⇒ 1 INSERT, no UPDATE; outcome after hold ⇒ INSERT then UPDATE |

## Human-only items

| Item | Command / flag | Size | Risk |
|---|---|---|---|
| Drop unused inference_routes indexes | `DROP INDEX CONCURRENTLY idx_inference_routes_model;` (8.51 GB, 20 scans) `… idx_inference_routes_provider;` (12.35 GB, 25 scans) `… idx_inference_routes_request;` (8.47 GB, 38 K scans — redundant with unique `(request_id, attempt)` leading column) | 29.4 GB | Only reader in code is `InferenceRouteRecordsSince` (created_at). The 20–25 scans are ad-hoc psql; analysts can use `request_waterfall`/created_at. **Do not drop `inference_routes_pkey`** (PK; ALTER TABLE takes ACCESS EXCLUSIVE — the 2026-07-03 outage class). |
| Drop unused request_rejections indexes | `DROP INDEX CONCURRENTLY idx_request_rejections_model; …_status; …_servable; …_reason;` | 4.2 GB | Only reader is `RejectionRecordsSince` (created_at). Keep `_created` and pkey. |
| Drop unused small indexes | `idx_provider_sessions_serial` (0.19 GB), `idx_provider_sessions_key` (0.26 GB), `idx_floor_draws_account` (0.40 GB) | 0.85 GB | Readers use `session_id`, `connected_at`/`disconnected_at`, `epoch_id`, `(provider_key, epoch_id)`; all 0 scans. |
| Make `providers` upserts HOT | `CREATE INDEX CONCURRENTLY idx_providers_account2 ON providers(account_id) WHERE account_id<>''; DROP INDEX CONCURRENTLY idx_providers_account;` | swap 0.78 GB | `ListProvidersByAccount` sorts ≤~220 rows in memory; removes `last_seen` from the index so 49/s updates can be HOT (also consider `fillfactor=80` on `providers`: `relpages` 505,789 × 8 KB ≈ 4.1 GB in-heap for 1.95 M tuples ≈ 2.1 KB/row in-heap, rest TOASTed ⇒ ~4 rows/page). |
| Backfill `provider_earnings_daily` (P2) | one off-peak `INSERT … SELECT date_trunc('day',created_at), account_id, … GROUP BY 1,2 ON CONFLICT DO UPDATE`, chunked by month | one 38 GB scan | run under `statement_timeout` off, low priority |
| Enable `pg_stat_statements` | Cloud SQL flag `shared_preload_libraries=pg_stat_statements` (**instance restart**), then `CREATE EXTENSION pg_stat_statements` | — | strongly recommended: this analysis had to infer execution counts from tuple counters |
| `track_io_timing=on` | Cloud SQL flag, no restart | — | negligible overhead on Linux; makes temp/IO attribution direct |
| `work_mem` | leave at 4 MB globally; P1 uses `SET LOCAL` | — | a global raise multiplies by ≈70 pool conns × parallel workers |
| #809 sample rate | verify `EIGENINFERENCE_PROFILE_SAMPLE_RATE` in the prod container env; decide whether ~all attempts at 1.4 KB/row is intended | — | disk growth ≈10 GB/day |
| Read replica (optional) | if 1 stats pipeline/min on the primary is still unwelcome, the P1 refresher is the single place a replica DSN plugs in (one extra env var; handlers never touch the DB) | — | replica lag only affects a page that already tolerates 60 s staleness |
| `inference_routes` fillfactor | not recommended: at 662 B/row (~11 rows/page) fillfactor 90 buys ~1 HOT update per page against ~16 updates/page | — | index drops and P7 are the real levers |

## Conflicts / overlap with the perf branch (`worktree-bridge-cse_01TuyfD42fkRyG4ZqSTmeN4U`)

| Perf-branch item | Status here | Estimated DB effect (from its §3/§4 and our rates) |
|---|---|---|
| §4.1 store read-through cache (users 30 s, model registry 10 s) | **covered by perf branch** | −(1 user + 6–8 registry + 1 user-at-completion) ≈ 8–10 round trips/request ≈ 45.8/s × 9 ≈ **−410 statements/s** (C) |
| §4.3 route telemetry batching (multi-row INSERT, pgx batch UPDATE) | covered; P7 builds on it | statements unchanged (128/s), network RTs 128/s → ≈10 batches/s; DB index work unchanged |
| §4.3 `Credit`/`CreditWithdrawable` collapsed to one CTE | covered | refund + fee legs 5→1 RT each; **0–120 statements/s** depending on which legs actually fire (E — see E3; needs `pg_stat_statements` to pin) |
| §4.4 `/v1/models`, `/v1/models/openrouter`, `/v1/providers/attestation` caches | covered (attestation 6.6K/h, models catalog 1.3K/h) | small (registry-only reads) |
| §6 "Provider persistence batching" | recommended there, **not built** — proposed here as P6 | −175 statements/s |
| §6 `/v1/pricing` cache (755/h) | not built; trivial, include with P1 | ≈ −0.2 statements/s |
| Nothing in the perf branch touches `handleStats`, NetworkTotals/Leaderboard, `/v1/me/*`, the verification scheduler, or indexes | P1–P5 are additive; P1's refresher should be wired in `server.go` next to the readCache janitor, which the perf branch does not modify | — |

Incidental (not DB): `payments.Ledger.RecordUsage` (payments.go:71) appends every completion to an in-memory per-consumer slice that is never trimmed — unbounded growth at 30/s.
