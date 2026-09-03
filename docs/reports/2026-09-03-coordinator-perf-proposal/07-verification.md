# 07 — Blind verification of the M-graded claims

Method: two fresh agents were given only the raw sources (the downloaded prod profiles, the
read-only prod recipe, Datadog/Cloud SQL read access, and master `5d400cf75`) and a list of
*measurement questions with no target values*. They were instructed not to open this directory
or any prior conclusions. Their results are compared here against the numbers the proposal
relies on. Verdicts: **agrees** (within rounding / the same window), **agrees within 2×** (same
conclusion, different window or population), **differs** (conclusion at risk), **unresolved**.

Blind outputs (not committed): scratchpad `verify/V1-process-lock-latency.md`,
`verify/V2-database-traffic.md`.

## A. Process, lock, latency (V1)

| # | Claim in the proposal | Proposal value (section) | Blind re-derivation | Verdict |
|---|---|---|---|---|
| A1 | Old-build CPU / GC / scan cores | 4.46 cores; GC 1.77 (39.7 %); `scanCandidatesLocked` 1.21 (26.9 %); `scanProviderReservation` 0.99 (00, 01, 03) | 4.465 cores; GC 1.779 (39.8 %); `scanCandidatesLocked` 1.200; `scanProviderReservation` 1.156; chat 1.889; readLoop 0.233; relay 0.223; Syscall6 0.242 | **agrees** |
| A2 | Fresh-build CPU / GC | 3.43 cores, GC 0.75 (00 addendum, `prodprof2`) — note 03 measured a *different* fresh-process profile at 4.04 cores / GC 1.32 | `prodprof2`: 3.432 cores; GC 0.797 (23.2 %); scan 1.387; chat 2.002 — verifier notes the two processes are not like-for-like (heap 1.12 GB vs fresh). The 1.32-core figure in 03 is from a third profile of the fresh process at 4.04 cores; the fresh-process GC range is therefore **0.8–1.3 cores** and the leak's effect **0.45–1.0 core** | agrees within 2× (range now stated) |
| A3 | Top allocation sites | `ListDueVerificationJobsPage` 16 %; TPS medians 27.6 %; `buildCandidateWithReason` 10 %; token budget 5.5 %; `versionSegments` 5 %; `GetAccountEarnings` 3.4 % (00, 03) | ListDue 16.0 %, Median 11.2 %, SoloMedian 10.6 %, buildCandidate 10.0 %, SoloMedianAllChips 5.8 %, tokenBudget 5.5 %, growSlice 4.8 %, Decoder.refill 4.0 % | **agrees** |
| A4 | Live heap and its top retainer | 1,122 MB; `Ledger.RecordUsage` 480 MB flat, 882 MB with its strings; unbounded append; single reader `handleUsage` (03) | 1,121.83 MB; `RecordUsage` 480.02 MB (42.8 %) via `Ledger.usage` append at `payments.go:74`, unbounded (≈6 M entries); only reader `handleUsage` (`consumer.go:4212`); `literalStore` 403 MB / 11.7 M objects inferred to be the entries' JobID/Model strings | **agrees** |
| A5 | Goroutine waiters at 21:07 UTC | 7,080 total; 88 at commit + ≈63 in recorders on `r.mu`; 66 in `acquireRoutingScanSlot` (00, 01) | 7,080; 152 on the write lock (commit 89, ServeOutcome 14, ClearDispatchLoadCooldown 14, InferenceSuccess 11, ProviderOutcome 10, CapacityAccept 9, ReserveNextFromPlan 5) + 8 RLock waiters; 68 in `acquireRoutingScanSlot`. Fresh build: 7,714; 127 on the write lock (commit 92); 79 in the slot wait; **96 goroutines inside `reserveProvider` = `ROUTING_CONCURRENCY`, 93 of them at the commit lock, 1 scanning** | **agrees** |
| A6 | Write-lock acquisitions per successful request | 6 (commit, capacity-accept at first content, error-cooldown, breaker, health-ejection, dispatch-load cooldown); accept takes `Lock` when `PenaltyMs` > 0 (default 15,000); no timer/sleep in the reserve path (01, 04-corrected, README §2.1) | 6 unconditional write locks per success + 1 per rescan; first-content accept takes **Lock** (`countRateOutcome && PenaltyMs>0`, default 15,000 at `capacity_rate.go:58`); no sleep/timer in the reserve/commit path (only the bounded `NewTimer` in the slot wait); 43 genuine `r.mu.Lock()` sites in `registry/` | **agrees** |
| A7 | Stage waterfall, attempt 0 (ms, p50/p90/p99) | preflight 518/895/1,004; permit wait 1,714/7,303/11,898; scan+commit 191/234/277; provider TTFT 2,731/5,838/11,822; relay 201/243/302; settle 909/10,404/36,220; TTFB 6,487/9,686/15,594; `admit_us` 189/231/274; residual ≈0 (README §2.1, window 21:25–22:10 UTC) | 22:38–23:18 UTC, n≈39.5 K: preflight 500/907/1,012; (b) 2,244/8,781/11,974; scan+commit 283/365/444; provider TTFT 2,166/6,835/21,901; relay 297/374/471 (bracketing the first-content write lock); settle 1,296/8,492/55,006; TTFB 6,509/10,320/31,562; lock_wait 4.4/13.6/26.2; scan 3.6/5.2/7.9; admit 279/361/441; scanned p50 1,229 of 1,235–1,241 | agrees within 2× (later window; same shape, commit and relay waits ≈1.4× higher) |
| A8 | Steady-state routing stage | `route_ms` 20:00–21:00 UTC p50 2,393 / p90 9,384, n = 170,282 (README §2.1) | 20:00–21:00 UTC: n 179,557, p50 2,393 / p90 9,384; last 40 min: n 105,436, p50 2,006 / p90 10,263 | **agrees** |
| A9 | Scan CPU vs scan wall | ≈22 ms CPU per attempt vs 1.8 ms `scan_us`; unresolved (README §8) | **Resolved.** `reserve_lock_acquired_us` is *derived* as `reserve_done − ScanUS − AdmitUS` of the **last** loop iteration (`attempt_profile.go:108-112`), so the residual is identically −lock_wait and says nothing about rescans. Scan CPU per route row 24.0–24.5 ms vs scan wall 2.3–3.7 ms (6–10×). The 96 slot holders split 93 at commit : 1 scanning : 2 at RLock, matching admit : scan : lock_wait = 182 : 2.3 : 4.6 ms; Little's law ⇒ ≈509 iterations/s ≈ **14 scans per reservation** (≥6 at admit p99); reconciled per-scan CPU 2.58 ms vs wall 2.31 ms. Derived, not counted — no counter exists | **differs from the proposal's earlier text** ("no rescans") → proposal corrected; conclusion strengthened |
| A10 | Runtime env | `GOGC`/`GOMEMLIMIT` unset; `ROUTING_CONCURRENCY=96`; 30 vCPU (00) | GOGC unset; GOMEMLIMIT unset; `ROUTING_CONCURRENCY=96`; nproc 30; container 350–452 % CPU, 0.98–1.12 GiB (23:18–23:24 UTC) | **agrees** |

## B. Database and traffic (V2)

| # | Claim in the proposal | Proposal value (section) | Blind re-derivation | Verdict |
|---|---|---|---|---|
| B1 | Active-backend mix | two location/flow statements ≈70 % of samples, totals/leaderboard ≈14 %, hot-path writes ≤1 % each (00, 02) | _pending_ | |
| B2 | Why the stats cache misses | `stats:v1` 60 s TTL; invalidated by `attachProviderLocation` (`provider.go:923`) 1,378×/h and `server.go:1274`; no singleflight; ≈1,950 pipelines/h (02) | _pending_ | |
| B3 | DB counters | temp_bytes ≈795 TB since 2026-08-24 14:32 UTC; `work_mem` 4 MB; `pg_stat_statements` available, not installed (00, 02) | _pending_ | |
| B4 | `/v1/me/summary` truncation | `GetAccountEarnings(id, 5000)` at `me_handlers.go:165`; 669 of 958 weekly-active accounts exceed 5,000 rows/7 d (02) | _pending_ | |
| B5 | Statements per successful request | 23 (04) | _pending_ | |
| B6 | #809 write rates | `request_profiles` 50–63 rows/s ≈ 1.4 KB/row; `fleet_snapshots` 28.5 rows/s; default sample 10 % + always-record rules; observed ≈53 % of successes (02, 04) | _pending_ | |
| B7 | Never-read indexes and table churn | ≈34 GB of indexes with ≤ 25 scans; `inference_routes` ins 53 M / upd 80 M, 30 % HOT; `providers` 0 % HOT (00, 02) | _pending_ | |
| B8 | Traffic | chat 46/s; me/providers 5/s; me/summary 5/s; account-earnings 3/s; stats 0.7/s; routing decisions selected ≈52/s, `routing_saturated` ≈5/s; dispatch success ≈31/s, retry ≈19/s (00) | _pending_ | |
| B9 | Cloud SQL | primary `d-inference-prod-pg17` db-c4a-highmem-32 REGIONAL, CPU 34.5 % mean / 40 % max over 6 h; replica 5 %; orphan `d-inference-prod` PG 16 running (00 addendum) | _pending_ | |

## C. Discrepancies and what changed in the proposal

_pending_
