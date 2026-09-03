# Coordinator performance and quality proposal — 2026-09-03

**Status:** proposal only. No product code was changed. Everything here was measured read-only
against production on 2026-09-03 (build `4ce5c0409` at 21:07 UTC, then master `5d400cf75`
after the human redeploy at 21:13 UTC) and against master `5d400cf75` in the repo.

**Grades used throughout:** **M** measured in prod or on a benchmark · **C** computed from
measurements (arithmetic shown in the section) · **E** estimated, assumptions stated.

Sections: [00 baseline](00-prod-baseline.md) · [01 registry lock](01-registry-lock.md) ·
[02 database](02-db-analytics-and-writes.md) · [03 memory & GC](03-memory-gc.md) ·
[04 request hot path](04-request-hot-path.md) · [05 landing the perf branch](05-port-feasibility.md) ·
[06 served-rate levers](06-served-rate-levers.md).

## 1. The answer in four numbers

| What | Today (M) | After this program | How sure |
|---|---:|---:|---|
| Coordinator CPU at today's load (≈46 chat/s, 1,250 providers) | 4.4 cores (3.4 fresh-process) | **≈1.4–1.8 cores** (−60…−70 %) | C for each step; the largest step (perf branch) is already benchmarked |
| Primary database busy CPU | ≈11 of 32 vCPU | **≈1.5 vCPU** (−85 %) | C: ≈90 % of busy samples are five analytics statements |
| Client time-to-first-byte, median (attempt 0) | 6.5 s, of which **2.6 s is coordinator queueing** (measured in the post-redeploy window; the pre-deploy steady state shows the routing stage alone at 2.4 s p50) | **≈3.9 s** (coordinator share → ≈0.1 s) | M for the decomposition; C for the removal |
| Client requests served | 79 % (23 % rejected/failed at the coordinator) | **≈90 %** after the lock restructure, ≈93 % with the provider-side fixes | C from the 09-02 research, netted for overlap |

Headroom moves from "the convoy re-forms at ≈3× today's load" to ">5× with CPU the only limiter"
(01 §Estimated). The database tier can drop after the analytics fix; a second, orphaned Cloud SQL
instance (`d-inference-prod`, PG 16, RUNNABLE, idle) is costing money for nothing (00 §Database).

## 2. Where the time goes (first principles)

Five mechanisms explain almost all of the measured cost. None of them is "the code is slow";
each is a structural choice whose cost scales with fleet size or request rate.

### 2.1 One global writer-preferring lock sits on the request path (01)

`Registry.mu` is a `sync.RWMutex`. Every dispatch attempt scans the fleet under `RLock`, then
takes `Lock` to commit the reservation; every **completion** takes `Lock` five more times to
record outcomes (breaker, error cooldown, capacity accept, health ejection, dispatch-load
cooldown). Six write acquisitions per successful request, two of them before the first byte
reaches the client (01 E1).

Go's `RWMutex` blocks *new readers* whenever a writer is waiting, so each write acquisition costs
one full reader-batch drain, and readers and writers alternate single-file. The holders are
cheap (0.007 core of CPU under the write lock, M) — the **wait** is the cost:

| Measured on master `5d400cf75`, last 45 min, attempt 0 (M, #809 stamps) | p50 | p90 | p99 |
|---|---:|---:|---:|
| Preflight, incl. wait for a routing-scan permit (cap 1 s) | 518 ms | 895 ms | 1,004 ms |
| Attempt start → first scan lock acquired (permit wait at dispatch) | **1,714 ms** | 7,303 ms | 11,898 ms |
| Commit phase (`admit_us`: write-lock wait + re-check) | **189 ms** | 231 ms | 274 ms |
| Provider first content → client first byte (relay incl. the capacity-accept write lock) | **201 ms** | 243 ms | 302 ms |
| Completion → finalized (includes four more write-lock acquisitions; the p90/p99 tail is unexplained — §8) | 909 ms | 10,404 ms | 36,220 ms |
| Client time-to-first-byte, this attempt | 6,487 ms | 9,686 ms | 15,594 ms |

The commit wait is remarkably flat at ≈190 ms ≈ (≈90 queued writers) × (≈2 ms reader batch) — there is no timer, sleep or backoff anywhere in the reserve/commit path (checked), so the band is a queue bounded by the permit count, not a fixed delay:
the #799 semaphore (`EIGENINFERENCE_ROUTING_CONCURRENCY=96`) caps how many writers can queue, so
it bounds the *wait per commit* while turning the overflow into `routing_saturated` 429s
(5.3/s now, 22,045/h earlier today) and a 1.7 s median permit wait at dispatch. At the profile
instant ≈150 goroutines were queued on the write lock and 66 on the semaphore (00).

Net: the coordinator adds **≈2.6 s to the median first byte** (0.5 + 1.7 + 0.19 + 0.2) on a
request whose provider needs 2.7 s. The provider is not the bottleneck; the lock is.

*Caveat and cross-check.* The stamp table above was measured 21:25–22:10 UTC, inside the
25–30 min recovery window after the 21:13 UTC redeploy, so its absolute values may be inflated.
The pre-deploy steady state says the same thing: `inference_routes.route_ms` (reserved →
routed, all attempts) for 20:00–21:00 UTC was **p50 2,393 ms / p90 9,384 ms** with 30,743
`routing_saturated` rejections in that hour (M); a re-measure at 21:19–21:54 UTC gave p50
2,900 ms / p90 10,179 ms and 23,115/h. The convoy is episodic — 0 goroutines were waiting on
the lock or the semaphore at 21:54 UTC versus ≈150 + 66 at 21:07 — which is why the medians
over a window are the right acceptance metric, not an instantaneous dump.

### 2.2 Every attempt walks the whole fleet, allocating as it goes (01, 04)

`scanCandidatesLocked` builds a snapshot of every advertising provider per attempt: three
median sorts, a token-budget map, semver parsing and a large struct copy per provider. It is
27–40 % of process CPU (1.2–1.4 cores, M) and **49 % of all allocated bytes** (M). The unmerged
perf branch already fixes this (per-model index, TPS caches maintained on write, in-place
snapshots): reserve 365 µs/815 allocs → 79 µs/21 allocs on this machine (01 E4, M).

*Open measurement question:* the profile charges ≈22 ms of CPU per attempt to the scan while
the #809 stamp records ≈1.8 ms wall per scan and no rescans (residual p99 = 0 ms). One of the
two instruments is not measuring what its name says; the first change in Tier 1 adds a scan
counter so the acceptance metric is unambiguous.

### 2.3 GC is 22–40 % of CPU, and a leak is doubling it (03)

The process allocates 540–880 MB/s (M). At default `GOGC` that is 1.8–4.7 GC cycles per second.
An in-memory usage ledger (`payments.Ledger.RecordUsage`) appends one entry per completion and
is never trimmed: **882 MB of a 1.12 GB live heap, +442 MB/day** (M/C). Its 17.5 M tiny objects
cost ≈3× the marking work of the rest of the heap. Natural experiment, same hour: the leaky
48-hour-old process spent 1.77 cores in GC; the fresh process after the redeploy spent 1.32
(M). The only reader is `GET /v1/payments/usage`, which already falls back to the database.

### 2.4 The public stats page owns the database (02)

`/v1/stats` runs two 7–8 s statements (`UsageLocationBuckets`, `UsageFlowBuckets`: sort ≈2.9 M
rows at `work_mem=4 MB`, spilling 1.4 GB + 1 GB of temp per run) behind a 60 s cache — but
`attachProviderLocation` **invalidates that cache on every provider registration**, 1,378
times an hour (M), and there is no singleflight. Result: ≈1,950 pipelines/h instead of 60,
≈7 concurrent copies at every instant, **795 TB of temp I/O** since the stats reset and ≈75 %
of the primary's CPU (C). `NetworkTotals`/`Leaderboard` add three full scans of the 38 GB
`provider_earnings` table per execution (no `created_at` index) for another ≈15 %.

Two correctness side effects found on the way: `/v1/me/summary` sums the last 24 h/7 d from a
5,000-row page and **is wrong for 669 of 958 weekly-active accounts** (02 E1/M6); on the 10 s
timeout, `/v1/stats` caches an empty `request_locations` for a minute.

### 2.5 Chatty persistence and a spinning poller (02, 04)

Per successful request the coordinator issues **23 SQL statements** (four `GetUserByAccountID`,
four two-query registry lookups, route INSERT + UPDATE, a ten-statement settle path); fleet
persistence adds 176 statements/s; the MDM verification scheduler re-queries a 2,000-row table
**34 times a second** on its 1 ms retry path, pre-allocating a 4,096-row page each time
(16 % of all allocated bytes, M). `#809`, now live, adds 50–63 `request_profiles` rows/s
(≈53 % of successes are recorded, not the intended 10 %; ≈9 GB/day) and eight new indexes,
roughly the index work the recommended index drops remove.

## 3. The proposal

Ordered by expected gain per engineering day, with dependencies. Human-only items are deploy
or database mutations and are listed separately in §5.

### Tier 0 — environment and operations (day 0–1, no code)

| # | Change | Gain | Grade |
|---|---|---|---|
| 0.1 | `EIGENINFERENCE_MIN_PROVIDER_VERSION` 0.7.5 → 0.8.12 → 0.8.15 (4 % of fleet, a large share of `first_chunk_timeout`) | +19–39 K served/day | C (06 k) |
| 0.2 | Evict the wedged gpt-oss session identified in the research (28.6 % of first dispatches, 0 served) | +5–20 K/day | E (06 i) |
| 0.3 | `EIGENINFERENCE_MODEL_FIRST_CONTENT_BASES=qwen3-vl-30b-a3b-instruct=off` — #787's 4 s cutoff is still hardcoded; ≈0 today, prevents a repeat of 08-31 if qwen3-vl is listed | risk removal | M (06 f) |
| 0.4 | Fix the stale `deploy/environments/prod.env:99` (`TTFT_HARD_REJECT=true` vs live `false`); CLAUDE.md says AWS RDS, prod is Cloud SQL PG 17 | hygiene | M |
| 0.5 | Decide the `#809` sample rate (`EIGENINFERENCE_PROFILE_SAMPLE_RATE`) — today ≈53 % of successes | −5 GB/day, −150 index ops/s | M/C (02 P8) |
| 0.6 | Delete or stop the orphaned `d-inference-prod` (PG 16) Cloud SQL instance after confirming nothing points at it | cost | M |

### Tier 1 — one-day fixes with outsized effect (days 1–4, ≈3 eng-days)

| # | Change | Where | Gain | Grade |
|---|---|---|---|---|
| 1.1 | **Bound the in-memory usage ledger** to 100 entries/consumer (in-place ring, not `append(s[1:])`); regression test asserts `len==100 && cap<=100` | `payments/payments.go:71` | −0.45 core GC; unlocks 1.2 | M/C (03 #1) |
| 1.2 | **`GOGC=400`** once 1.1 is live for 24 h (human-only env line; see §5) | deploy env | −0.8 core GC (1.32 → 0.28 with 1.1+1.3) | C (03 #3) |
| 1.3 | **Stats refresher**: one background goroutine owns `stats:v1`/`network_totals:*`, serves stale-while-refreshing, `SET LOCAL work_mem='1GB'` inside its read-only tx; delete the two `Invalidate("stats:v1")` calls; drop the `$1 IS NULL OR` form | `api/stats.go`, `api/server.go`, `api/provider.go:923` | **−73 % DB CPU, −95 % temp I/O**; no more empty-locations cache poisoning | C (02 P1) |
| 1.4 | **Verification poller**: load rows on the 1 s tick only; page sized `min(limit,256)` | `api/mdm_scheduler_exec.go`, `store/postgres.go:5716` | −34 seq scans/s; −16 % of alloc bytes (−0.3 core GC+CPU) | M/C (02 P5, 03 #2) |
| 1.5 | `/v1/me/summary`: one `FILTER` aggregate instead of 5,000 rows + Go loop (fixes the truncation bug); `/v1/me/providers`: batch `GetReputations` (N+1 → 2 statements) | `api/me_handlers.go` | −20 K rows/s, −73 statements/s; correct numbers | C (02 P3/P4) |
| 1.6 | Capacity-accept recorder off the first-byte path (record after the first client write or asynchronously) | `api/dispatch.go:594-626` | −≈190 ms on every TTFT after content exists (the 504 risk, not a 429) | M for the wait, E for the served effect (06 N1) |
| 1.7 | `RecordJobSuccess` → throttled reputation persist; decode provider frames once (`msg.UnmarshalJSON` directly); skip `sendProviderCancel` on settled completions; run the shed-path counterfactual walk behind the semaphore instead of on the telemetry worker | `registry.go:5736`, `provider.go:315`, `dispatch.go:3776`, `rejection_telemetry.go:141` | −46 statements/s; −930 µs/request; −46 WS writes/s; no fleet walk on the sink under saturation | C (04 O1/O2/O6/O8) |
| 1.8 | Instrumentation: `registry.mu` wait histogram by call site, scan counter, `SetMutexProfileFraction`/`SetBlockProfileRate` behind the pprof listener | `registry/`, `api/server.go` | turns the E-grade waits into M; acceptance metric for Tier 3 | — |

### Tier 2 — land the 2026-09-02 performance program (≈7 eng-days, 05)

The 75-commit branch is complete, twice-reviewed and benchmarked; nothing from it is on GitHub.
Landing it is the single largest CPU step (−1.8 core, C): scan 0.99 → 0.21 core, preflight
0.23 → 0.07, GC −0.84 from removing 49 % of allocated bytes, 23 → 5 statements per request.

| PR | Contents | Effort |
|---|---|---|
| A — `store/` + `api/` | read-through user/model cache, route-telemetry batching, `Credit` CTE collapse, relay coalescing + endpoint caches, parse-once body pipeline, gated perf e2e | 1.5 d (hand-merge `consumer.go`/`generic_endpoint_stream.go` #809 stamps into the relay; restore `strconv`/`isPowerOfTen` — hazards H10/H11) |
| B — `registry/` | per-model index, TPS caches, arena snapshots, version memo, planner coalescing, fleet bench | 2 d (re-derive `scheduler.go` so the arena variants return `GateReason`, stamp `hbAgeMs`, set `calibrationRatio` — hazards H1–H3; document H4) |
| re-measure | fleet benchmarks + `EIGENINFERENCE_PERF_E2E=1` e2e on the merged tree; re-calibrate the #799 shed threshold (H5) | 0.5 d |
| C, D | the provider-optimization branch's coordinator commits **minus** its duplicate scan/index/sink slices (they re-implement PR B; only one can land); Retry-After policy is an owner decision (H6) | 3 d |

Master is squash-only, so merge master into a copy of the branch once, then PR. The concurrent
`sysopt-0903` session had **0 commits** as of 21:45 UTC and plans to hand-port the same work;
coordinate before it writes `registry/` code (05 §sysopt).

### Tier 3 — take the global write lock off the request path (4–6 eng-days, on top of Tier 2; 01)

Two changes, shipped as one unit behind a flag:

- **(a)** per-identity `gateState` (own mutex) for breaker, health-ejection, error/capacity
  cooldown, budget clamp and dispatch-load cooldown — recorders never touch `r.mu`;
- **(a′)** commit under `r.mu.RLock` + `p.mu`: the "winner unchanged since scan" check moves
  under `p.mu` (double-booking is already prevented there).

Remaining `r.mu` writers: register, disconnect, `evictStale`, swap planner, config — tens per
second. Lock order `r.mu → p.mu → gate.mu`. Then size the #799 semaphore to the container's CPU
quota so it bounds CPU as designed, and re-scope the preflight shed (06 a1/4c).

| Effect | Value | Grade |
|---|---|---|
| Per-request lock wait | ≈1.2 s (6 × 190 ms) → ≈0 | M today / C after |
| Coordinator-caused TTFB | ≈2.6 s → ≈0.1 s at the median | C |
| `routing_saturated` rejections (14.6 % of offered) | → <5 % of today | C (06 a2, 08 §4) |
| Served fraction | 79 % → ≈86–93 %, point ≈90 % | C |
| Headroom | convoy re-forms at ≈3× (perf branch alone) → >5× | C/E |

Alternatives considered and rejected: batched async recorders (stopgap, leaves the commit
convoy), copy-on-write fleet snapshot (2–3 weeks; unnecessary once writers are gone), sharded
`r.mu` (same as (a) with more complexity). Do **not** ship (a) without (a′) or vice versa.

### Tier 4 — database write path and settle (≈1 week, 02, 04)

| # | Change | Gain | Grade |
|---|---|---|---|
| 4.1 | `provider_earnings_daily` rollup maintained inside the existing settlement CTE; `NetworkTotals`/`Leaderboard` read ≤48 K rows; one-time backfill (human-run) | −15 % DB CPU; fallback is a `created_at` index (24 h window only) | C (02 P2) |
| 4.2 | Provider persistence batching: 5 s buffer, three multi-row upserts | 176 → 0.6 statements/s | C (02 P6) |
| 4.3 | Settle pipeline: one pooled connection, `StartPipeline` with a `Sync` after **each** statement (keeps per-statement atomicity; not `pgx.Batch`, which would re-couple the three ledger writes) | 5 → 1–2 round trips and −4 goroutines per completion | C (04 O7) |
| 4.4 | Route telemetry insert-on-outcome (hold ≤60 s, one write instead of INSERT+UPDATE) — optional | −78 statements/s, no dead tuples | C/E (02 P7) |
| 4.5 | Per-chunk allocation cleanup: pooled read buffers, per-request shared key instead of the global `chunkKeys` mutex, `strings.Replacer`, two `Write`s instead of `Fprintf` | −1.4 ms CPU/request | C (04 O3/O4) |

### Tier 5 — served-rate semantics (after Tier 3; 06)

| # | Lever | Gain | Grade |
|---|---|---|---|
| 5.1 | Rank on expected completion instead of the injected `max_tokens=32,768` (rebase `773bee1b3`), then per-model cap 8,192 | +15–40 K/day; un-herds the fastest boxes | E |
| 5.2 | Semaphore never gates the preflight; shed on measured wait; retries shed before fresh | folds into Tier 3's number; only after wait p99 < 50 ms for days | C |
| 5.3 | Queue-drain O(fleet × queue) fix (rebase) — ≈0 today, load-bearing once the shed is admitted | prerequisite for 5.2 | M |
| 5.4 | Provider side (cite only): honest deadline projection (¼ of capability today), think-parser streaming, 256 KiB WS frames | +60–130 K/day → ≈93 % | C (06 d) |

Deliberately **not** proposed: cache-routing flip, raising `ROUTING_CONCURRENCY` or vCPUs
(moves 429s into `deadline_unreachable`), TTFT hard-reject or a deadline-refusal retry cap before
the provider projection fix (converts recoveries into 429s), a 4,096 `max_tokens` cap, hedging or
warm-pool changes as served-rate levers, a walk-wide gates lock (rebuilds the convoy), one big
settlement transaction (changes failure semantics; the perf branch already rejected it).

## 4. Expected trajectory

| After | Coordinator cores (1× load) | DB busy vCPU | TTFB p50 (attempt 0) | Served | Effort |
|---|---:|---:|---:|---:|---:|
| Today | 4.4 (3.4 fresh) | ≈11 | 6.5 s | 79 % | — |
| Tier 0 + 1 | ≈2.9 (GC 1.77 → 0.6 with `GOGC=400`; poller −0.3; frame decode −0.05) | **≈2.5** | ≈6.3 s (−0.2 s accept lock) | ≈80 % | 3–4 d |
| + Tier 2 | **≈1.9** (scan −0.8, GC −0.3 more, body −0.15) | ≈2.0 (statements −70 %) | ≈6.0 s (shorter reader batches shrink the 190 ms commit wait) | ≈80 % | +7 d |
| + Tier 3 | ≈1.7 (lock spin/rescans gone) | ≈2.0 | **≈3.9 s** | **≈90 %** | +5 d |
| + Tier 4 | ≈1.5 | **≈1.5** | ≈3.8 s | ≈90 % | +5 d |
| + Tier 5 + provider train | ≈1.4 | ≈1.5 | ≈3.5 s | ≈93 % | +4 d + release |

The cores column is C and rounded conservatively upward between rows (the per-section deltas sum to slightly less than shown); each step's arithmetic is in its section (03 §Estimated, 01 §Estimated,
04 §Estimated). The first three rows are the ones with M-grade inputs at every step; rows 4–6
inherit E-grade assumptions from the served-rate research.

## 5. Human-only items (prepare as PRs/runbook entries; execute with per-action approval)

| Item | Where | Note |
|---|---|---|
| `GOGC=400` | `deploy/gcp/prod/release-env-defaults` → `/etc/d-inference/env` → new `docker run` | only after 1.1 is verified live 24 h (heap profile: `RecordUsage` ≤ a few MB); verify NumGC rate ÷4 |
| `DROP INDEX CONCURRENTLY` | `idx_inference_routes_model` (8.5 GB), `_provider` (12.4 GB), `_request` (8.5 GB); `request_rejections` model/status/servable/reason (4.2 GB); `provider_sessions` serial/key, `idx_floor_draws_account` | never the PKs (ACCESS EXCLUSIVE = the 07-03 outage class) |
| `providers` HOT updates | swap `idx_providers_account` for a partial index without `last_seen` | 0 of 43.9 M updates are HOT today |
| `pg_stat_statements` + `track_io_timing` | Cloud SQL flags (restart for the first) | this analysis had to infer execution counts from tuple counters |
| `provider_earnings_daily` backfill | one off-peak 38 GB scan, chunked by month | Tier 4.1 |
| Env knobs | `MIN_PROVIDER_VERSION`, `MODEL_FIRST_CONTENT_BASES`, `PROFILE_SAMPLE_RATE`, `ROUTING_CONCURRENCY` re-size after Tier 3 | Tier 0 |
| Orphan Cloud SQL instance | `d-inference-prod` (PG 16) | confirm unused, then stop/delete |
| Docker log rotation | no Docker-level rotation (`LogConfig: {}`); 4.6 MB/min; six concurrent `docker logs --since 2h` readers cost dockerd 1.8 cores + journalctl 1 core on the host | verify the hourly host archival truncates the json-file log; add `max-size`/`max-file`; point log readers at the archived files |

## 6. Validation plan

- **Acceptance metrics already exist**: #809 persists `lock_wait_us`, `scan_us`, `admit_us`,
  `preflight_us` and the per-stage stamps per attempt. The Tier 3 exit criterion is
  `admit_us` p99 < 10 ms and attempt-start → first-lock p90 < 50 ms for 24 h.
- **Benchmarks**: `registry/fleet_scale_bench_test.go` (1,260 providers) and the gated
  `api/perf_e2e_test.go` from the perf branch; the lock probe bench beside section 01 asserts
  parallel speed-up ≥ 4× at 16 threads so a walk-wide lock cannot sneak back.
- **Tests per change** are listed in each section (live-isolated Postgres, tracer-backed
  statement counts, `-race` double-booking test, ledger-equivalence replays, byte-identical
  stream goldens).
- **Re-profile** prod 30 s after each tier lands and diff `-top -cum` against 00.

## 7. Coordination notes

- Prod was redeployed to master `5d400cf75` at 21:13 UTC during this analysis (previous
  container kept as `coordinator_fallback_20260903-211156`). All Tier 1+ numbers are against
  master; the 4ce5c0409 profile is retained for the before/after GC comparison.
- `.claude/worktrees/sysopt-0903` (`feat/system-optimization-2026-09-03`) is the active
  concurrent session: 0 commits, one untracked report, intends to port the same six branches.
  `.claude/worktrees/refactor` (`refactor/coordinator-modularization`) is from May 30, 301
  commits behind master, and is not the active refactor.
- The main checkout's `git status` shows `.github/workflows/ci.yml`, `Makefile`,
  `docs/AGENTS.md` modified at 14:15–14:18 PDT by another process; not from this work.
- The repo has 490 registered worktrees; `git worktree prune` and a cleanup of `/private/tmp`
  worktrees is overdue.
- Nothing from the three `worktree-bridge-cse_*` branches has been pushed; pushing needs an
  explicit go-ahead.

## 8. Open questions

1. Scan CPU (≈22 ms/attempt from the profile) vs scan wall (1.8 ms from the #809 stamp, no
   rescans): resolve with the Tier 1.8 scan counter before treating either as the baseline.
2. `ROUTING_CONCURRENCY=96` on a 30-vCPU host: after Tier 3 the right value is the CPU quota,
   not a queue-depth bound.
3. `#809` sample rate: is ≈53 % of successes intended?
4. `/v1/me/summary` truncation: fix in Tier 1.5 or as a hotfix?
5. Completion → finalized has a 10 s p90 / 35 s p99 tail; the four post-stream write-lock acquisitions
   explain the ≈0.9 s median but not the tail (client drain? backup cancellation?) — attribute with the
   #809 stamps before touching it.
