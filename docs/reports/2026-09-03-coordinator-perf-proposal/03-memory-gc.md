# 03 — Memory retention and GC CPU

Grades: **M** measured · **C** computed from measurements (arithmetic shown) · **E** estimated.
Sources: `scratchpad/prodprof/{cpu,heap,allocs}.pprof` (prod, 2026-09-03 21:07Z), a second 30 s
CPU profile + MemStats brackets taken read-only from prod at 21:18–21:28Z, and source at master
`5d400cf75`. No prod writes were made.

> **Deploy note.** Prod was redeployed at **2026-09-03T21:13:11Z** (container `coordinator`, image
> `5d400cf75`, build 20:35:38Z). All three original profiles come from the *previous* container
> (`coordinator_fallback_20260903-211156`, image `4ce5c0409`, started 2026-09-01T21:12:13Z →
> **uptime 47.9 h** at profile time, not the build-date-derived 64 h). `payments/` and
> `api/provider.go` are identical in both images, so the retention analysis applies to what is
> running now; the fresh process is used below as a natural "leak removed" experiment.

## Question

What retains the 1.1 GB live heap, what drives the GC's ~40 % CPU share, and what do (a) fixing
retention, (b) the perf branch's allocation cuts and (c) GOGC/GOMEMLIMIT each buy, in what order?

## Evidence

### E1. Live heap (inuse_space, 1,121.8 MB total, M)

| Retained set | MB | Objects | Avg B | Where allocated | Who holds it |
|---|---:|---:|---:|---|---|
| `[]UsageEntry` backing arrays | 480.0 M | few, large | — | `payments.(*Ledger).RecordUsage` (payments.go:74 `append`) | `Ledger.usage[consumerID]`, never trimmed |
| `msg.RequestID` strings | 262.0 M | 5.72 M (M) | 45.8 C | `json.Unmarshal` ← `ProviderMessage.UnmarshalJSON` ← `providerReadLoop` (provider.go:315) | `UsageEntry.JobID` (provider.go:2437) |
| request `"model"` strings | 140.0 M | 5.94 M (M) | 23.6 C | `parseJSONBody` ← `parseInferencePrelude` ← `handleChatCompletions` | `UsageEntry.Model` via `consumerModel(pr)` (consumer.go:642) |
| **Ledger total** | **882 C** | | | | **78.6 % of live heap** (882/1,122) |
| in-flight dispatch closure (`dispatchOneProvider.func1`, provider body etc.) | 50.6 M | | | `dispatchWithReserver` | in-flight requests — legit |
| in-flight scan scratch (`buildCandidateWithReason` 32.0 + `providerPooledTokenBudgetWithLayout` 12.5) | 44.5 M | | | registry scan | transient; removed by perf branch §4.2 |
| `ListDueVerificationJobsPage` page buffers | 27–28 M | | | store | transient (see §5) |
| `json.Marshal` bodies (readCache), `LoadStoredProviders`, `handleStats.func1`, statsd/bufio buffers for 1,253 WS conns | ~85 M | | | | legit caches / per-connection |

The three ledger rows are one structure: `UsageEntry` is 80 B (2 string headers 32 + 3 ints 24 +
`time.Time` 24 → 480 MB / 80 B = 6.0 M slots, C); the two string pools each hold ≈5.8 M objects
= one `JobID` and one `Model` per entry (C). 262 MB / 5.72 M = 46 B is a UUID-shaped request id
in the 48 B size class; 140 MB / 5.94 M = 24 B is a model alias in the 16/24 B classes.
**Nothing else is over-retained**: whole heartbeat messages and request bodies are *not* kept —
only the two strings copied out of them into the ledger.

Consistency checks: fresh process (15 min old) shows `HeapAlloc` 181–374 MB, `NextGC` 365–454 MB
(M) → non-ledger live heap ≈ 190–280 MB, matching 1,122 − 882 = 240 MB (C).

### E2. Ledger growth

| Quantity | Value | Grade / arithmetic |
|---|---:|---|
| entries at profile time | 5.8 M | C: (5.72 M + 5.94 M)/2 strings ÷ 1 per entry |
| entries/day | 2.9 M | C: 5.8 M / 47.9 h × 24 ≈ 94 % of ~3.1 M served/day (E) — every `billingFinalized` completion records |
| bytes/entry | 151 B | C: 882 MB / 5.8 M |
| growth | **18.4 MB/h = 442 MB/day** | C: 882 MB / 47.9 h |
| readers of `Ledger.Usage` in prod | 1 | M: `handleUsage` (consumer.go:4210, `GET /v1/payments/usage`) — falls back to `store.UsageByConsumer` (`LIMIT 100` newest-first, postgres.go:1728) only when the in-memory list is empty. Reachable; call frequency in prod not measured. |
| test readers | 4 files | M: payments_test.go, billing_integration_test.go, self_route_test.go, settlement_clientgone_test.go |

So the in-memory history is an unbounded, oldest-first duplicate of a table the store already
serves (and serves *differently*: memory returns full history, DB returns 100 newest). Prod
process lifetimes are ~2 days between deploys, so RSS never explodes — it just carries ~0.9 GB
of dead weight into every GC cycle and would reach ~3.5 GB after a week without a deploy.

### E3. GC CPU — two 30 s CPU profiles, same hour (old build `4ce5c0409` vs new `5d400cf75` = +#799, #809; ledger code identical, allocation behaviour not proven identical)

| | Old process (leaky, live 1.12 GB) | Fresh process (live ≈0.2–0.28 GB) |
|---|---:|---:|
| samples / cores | 134.61 s / **4.46** (M) | 121.67 s / **4.04** (M) |
| `gcBgMarkWorker` | 52.18 s (idle 33.08, dedicated 18.57) | 38.13 s (idle 22.29, dedicated 15.35) |
| of which `markroot`/`scanstack` | 2.76 s | 13.48 s |
| `bgsweep` | 1.31 s | 1.66 s |
| `gcAssistAlloc` | 0 samples | 0 samples |
| **GC total** | **53.5 s = 39.7 % = 1.77 cores** (C) | **39.8 s = 32.7 % = 1.32 cores** (C) |
| mutator-competing GC (dedicated) | 0.62 cores | 0.51 cores |
| `mallocgc` | 7.89 s (0.26 cores) | 8.10 s (0.27 cores) |
| alloc rate in window | not bracketed; ≈860 MB/s (E, from equal `mallocgc` time) | **882 MB/s** (M: ΔTotalAlloc 27.33 GB / 31 s) |
| GC cycles in window | ≈23 (C: 0.86 GB/s ÷ 1.12 GB growth × 30 s) | **144** (M: ΔNumGC 1901→2045; 4.65/s) |
| mallocs/s | — | 3.36 M/s (M) |
| STW pauses (recent top-3) | — | 0.52 / 0.58 / 2.33 ms (M) |

Other alloc-rate windows (M): 258 MB/s (60 s at 21:19Z), 470 MB/s (196 s, 21:20–21:23Z);
48 h average of the old process 93.4 TB `alloc_space` / 172,540 s = **541 MB/s** (C). Rate is
bursty; use 541 (average) and 882 (window) as the bracket.

`GCCPUFraction` (0.0033–0.0058) **excludes idle mark workers** (`runtime/mgc.go:1132`,
`GCTotalTime−GCIdleTime`) and is unusable for totals here; the profile is the source of truth.

## Mechanism

GC cores = *f* × (H + R + S), with *f* = A / (L·GOGC/100) cycles/s (or A / (limit − L) under
`GOGC=off`+`GOMEMLIMIT`), H = heap-mark per cycle, R = root (stack/global) scan per cycle,
S = sweep per cycle.

- **Root term is fixed per cycle**: 7,080 goroutines (≈5 per provider WS × ~1,250 = 6,210, plus ~870 others; M) cost
  0.094 s/cycle (C: 13.48 s / 144) ≈ 13 µs per stack. At 4.65 cycles/s that is 0.44 cores
  of the fresh process's GC — 34 % of it. This term scales with cycle *frequency*, so a small
  heap at GOGC=100 pays it 4.6× per second; GOGC tuning attacks it directly.
- **Heap term is pointer-density-weighted**, not byte-weighted. Old: (51.65−2.76)/23 = 2.1 s
  per cycle for 1.12 GB = 1.9 ms/MB (C). Fresh: (37.64−13.48)/144 = 0.168 s for ~0.24 GB =
  0.7 ms/MB (C). Ledger marginal ≈ (2.1 − 0.17)/882 MB = **2.2 ms/MB, ~3× the rest of the heap**
  (C) — 17.5 M tiny objects (5.8 M structs + 11.7 M strings) each needing `findObject` +
  `gcBits.bitp` + `greyobject`, which is exactly the flat profile (bitp 11.3 %, findObject 11.2 %,
  mspan.base 8.8 %).
- Consequently the naive "GC CPU ∝ A, independent of live heap at fixed GOGC" model is wrong
  here in the leak's favour: removing the ledger cut GC from 1.77 → 1.32 cores at matched
  malloc activity (**−0.45 cores, −25 %**; 1.32 is M, the delta is C/E — it rests on equal
  `mallocgc` time 7.89 vs 8.10 s standing in for equal alloc rate across two builds and a
  bursty traffic hour) even though cycles went 23 → 144.
- Idle vs dedicated: on a 30-vCPU box running 4 cores of work, 60–64 % of mark work runs on
  otherwise-idle Ps. It is real host CPU (and cache/memory-bandwidth pressure) but only the
  dedicated ~0.5–0.6 cores compete with request handling today. **Under a retry storm (#799
  class) idle Ps vanish and the full 1.3–1.8 cores become mutator-competing** — that is the
  regime the perf program exists for, so cores below are quoted as host cores (all GC work).
- Assists are absent and STW pauses are ≤2.3 ms: this is a throughput cost, not a latency one.

## Proposed changes (ordered)

| # | Change | Where | Effort | Owner |
|---|---|---|---|---|
| 1 | **Bound the in-memory usage history to 100 entries/consumer** (`usageHistoryLimit = 100`, matching `UsageByConsumer`'s `LIMIT 100`): in `RecordUsage`, when `len == limit` do `copy(s, s[1:]); s[len(s)-1] = entry` in place (or a ring index) — **not** `append(s[1:], entry)`, which reslices off the front and reallocates every call once full, defeating the bound. Keeps insertion order so the 4 test readers pass; no interface change. Alternative (bigger): delete the in-memory path and always read `store.UsageByConsumer` — rejected here because it breaks the memory-store tests and changes the endpoint's shape. Follow-up: make `handleUsage` return newest-first in both paths. | `coordinator/payments/payments.go:71-89` | 0.5 d | agent PR |
| 2 | **Stop the verification-poll allocation storm**: `ListDueVerificationJobsPage` pre-sizes `make([]VerificationJob, 0, limit)` with `limit = QueueCapacity = 4096` (server_config.go:44) ≈ 4096 × ~200 B (7 strings + 2 `time.Time` + ints) = 0.8 MB **per call**, and `dispatcher()` re-runs `loadDueRows()` on the 1 ms fast path whenever any due job cannot run (mdm_scheduler_exec.go:14, :39-40) → 14.96 TB / 0.8 MB / 172,540 s ≈ **100 calls/s** (C); only ~5 % of that capacity is filled (`scanVerificationJob` 0.79 TB vs 14.96 TB). Fix: size the page by `min(limit, 256)` (or reuse a scratch slice), and only reload from the DB on the 1 s cadence, not on every 1 ms retry. | `store/postgres.go:5716`, `api/mdm_scheduler_exec.go` | 0.25 d | agent PR |
| 3 | **`GOGC=400`** (single knob) once #1 is verified live for 24 h (heap profile: `RecordUsage` inuse ≤ a few MB and `literalStore` under `providerReadLoop` ≪ 100 MB — `HeapInuse` alone swings with the cycle and is not the gate). Optional guard `GOMEMLIMIT=12GiB` — only needed if #1 cannot ship first. | deploy env (see Human-only) | 0.1 d + deploy | **HUMAN** |
| 4 | Merge the perf branch's allocation cuts (§4.2 scan arena/TPS caches, §4.6 parse-once). Already built; cost is review/merge. | `worktree-bridge-cse_…` | 2–3 d review | agent + reviewer |
| 5 | Remaining hot spots (below). | | 0.25–1 d each | agent PR |

## Estimated improvement

Host GC cores at A = 882 MB/s (window) with A = 541 MB/s (48 h avg) in brackets. Post-fix
per-cycle cost H+R+S = 0.276 s (C: 39.8 s / 144 cycles), *f* scales with 1/GOGC.

| State | GC cores | Δ vs previous row | Heap goal / RSS | Grade |
|---|---:|---:|---|---|
| Today: leaky, GOGC=100 | 1.77 [1.1] | — | 2.2 GB goal, RSS 2.6 GB, +0.9 GB/day goal growth | M |
| After #1 leak fix | 1.32 [0.81] | **−0.45** | ~0.5 GB goal, flat | 1.32 M (fresh process); Δ C/E |
| + #2 verification poll (−16 % A) | 1.11 [0.68] | −0.21 (+0.13 cores mutator CPU: `ListDue…` 3.85 s/30 s in fresh profile) | same | C |
| + #3 GOGC=200 | 0.55 | −0.56 | 0.75 GB | C |
| + #3 GOGC=**400** | **0.28** [0.17] | −0.83 from GOGC=100 | 1.25 GB goal (≈ today's RSS) | C |
| + #3 GOGC=800 | 0.14 | | 2.25 GB | C |
| + #4 perf branch (A −49 % of the *same* base, E: TPS medians 27.6 + buildCandidate 10 + tokenBudget 5.5 + versionSegments 5 + cooldown keys 1.2, plus part of json refill/growSlice/Marshal; with #2 the remaining A ≈ 1 − 0.16 − 0.49 = 0.35) at GOGC=400 | **0.12** | −0.16 GC (C: 1.32 × 0.35 / 4 = 0.12), −0.16 `mallocgc` (allocs/op 824→21 in scans) | 1.25 GB | E |
| GOGC=400 **without** #1 (for comparison) | 0.44 | | 5.6 GB goal, +2.2 GB/day → unsafe within a week | C |
| GOGC=off + GOMEMLIMIT=8GiB after #1 | 0.03 | | RSS pinned ≈8 GB; death-spiral if live ever nears the limit | C |

Total achievable on this axis: **1.77 → ~0.12 host cores (−1.65 cores, −37 % of today's total
process CPU)**; mutator-competing share 0.62 → ~0.04. The perf branch's *mutator* savings
(scanCandidatesLocked 1.2–1.3 cores) belong to the routing section and are additive.

Cores saved per engineering day: #1 0.45/0.5 d = 0.9 (plus it unlocks #3); #2 0.34/0.25 d =
1.4; #3 0.83/0.1 d = 8 (but gated on #1); #4 0.32/2.5 d = 0.13 on this axis alone.
Recommended order stays **#1 → #2 → #3 → #4**: #1 is the prerequisite (GOGC multiplies the
leak's heap goal; GOMEMLIMIT would eventually be hit by it), #2 is a one-liner, #3 is a
deploy-only 4× cut, #4 is the largest but is review-bound.

## Effort / risk / tests

| # | Risk | Tests |
|---|---|---|
| 1 | `/v1/payments/usage` returns ≤100 in-memory entries instead of the whole process lifetime (which was already ≤2 days and already 100 on the DB path). Low. | `payments_test.go`: record 1,000 for one consumer → `len(Usage)==100`, entries are #900–#999 in order, `Usage("other")` unaffected. `billing_integration_test.go`: existing assertions unchanged. Heap check: 10,000 records for one consumer keep `len(l.usage[c]) == 100` **and `cap(l.usage[c]) <= 100`** (the cap assertion is what catches the reslice pattern). |
| 2 | None functional; the scheduler already treats a short page as end-of-scan. | Existing `mdm_scheduler_test.go` (`loadDueRows` at :993/:1051); add `BenchmarkListDueVerificationJobsPage` allocs/op on the live-isolated Postgres fixture and a test that the 1 ms retry path does not call the store. |
| 3 | 4× larger heap headroom per byte live: post-fix goal 1.25 GB on a 56 GB VM. If #1 regressed, goal grows 4× faster — hence the 24 h heap-profile gate. Rollback = remove key + `docker run`. | Post-deploy: `curl -s 127.0.0.1:6060/debug/pprof/heap?debug=1 \| grep -E 'NumGC\|NextGC\|HeapAlloc'` twice 60 s apart → cycles/min ÷4, `NextGC ≈ 5 × HeapAlloc-after-GC`. |
| 4 | Covered in the branch report (identity tests, index==walk tests). | as merged |

## Human-only items

- **`GOGC=400`**: add the line to `deploy/gcp/prod/release-env-defaults` (refresh-env appends
  absent keys — `deploy/gcp/prod/refresh-env.sh:133-142` prints `ADD …`). What consumes
  `deploy/environments/prod.env` was not verified here; if it seeds the Secret Manager copy,
  mirror the key there too. It reaches the process only through
  `--env-file /etc/d-inference/env` on a **new `docker run`** (`docs/operations/coordinator-deploy.md`
  :660-668; Docker does not reread `--env-file` on restart, :151-152). The dev VM path
  (`deploy/gcp/vm-startup.sh:182-186`) reads the same file, so dev gets it on its next restart.
  Verify with the NumGC/NextGC check above. Optional guard `GOMEMLIMIT=12GiB` goes in the same
  file the same way. Both are env-only; no code change.
- Confirm the 21:13Z redeploy was intentional (image `5d400cf75`, previous `4ce5c0409` kept as
  `coordinator_fallback_20260903-211156`).

## Overlap with perf branch (`worktree-bridge-cse_01TuyfD42fkRyG4ZqSTmeN4U`)

| Item here | Branch status |
|---|---|
| Ledger bound (#1) | **Not covered** — `RecordUsage` call unchanged at branch `provider.go:2341`; `payments/` untouched. |
| Verification poll (#2) | **Not covered** — branch only adds the interface method and a test (`store/` diff). |
| GOGC (#3) | Branch §6 recommends a `GOMEMLIMIT` as human-only; this section makes it concrete (`GOGC=400` single knob, limit optional) and gates it on #1. |
| Scan allocations (§4.2), parse-once body (§4.6), SSE one-pass gate (§4.4) | Covered — accounted as "A −50 %" above; the 44.5 MB in-flight scan scratch in E1 disappears with it. |

### Next allocation hot spots the branch does not cover (alloc_space shares, M; A = 541 MB/s)

| Hot spot | Share | ≈MB/s | One-line fix | Est. |
|---|---:|---:|---|---|
| `ListDueVerificationJobsPage` page pre-size × 1 ms retry loop | 16.0 % | 87 | #2 above | −0.21 GC + −0.13 CPU cores |
| `GetAccountEarnings(accountID, 5000)` in `handleMySummary` (me_handlers.go:165) summing 7d/24h in Go | 3.4 % | 18 | SQL `SUM … WHERE created_at > now()-'7 days'` (or reuse `GetAccountEarningsSummary`) + 30 s per-account cache | −0.05 cores |
| JSON body decode/encode residue after §4.6 (`io.ReadAll` 3.0, `bytes.growSlice` 4.8, `Decoder.refill` 4.0, `Marshal` 3.8, `unquote` 1.4) | ~12 % | 65 | pool the read buffer sized from `Content-Length`; stream-marshal into a pooled `bytes.Buffer` | −0.1–0.15 cores (E; part already in branch) |
| `normalizeSSEChunk` — `json.Unmarshal` 44 % + `json.Marshal` 32 % of its 3.1 % when a chunk needs null-fixing | ~2.4 % | 13 | byte-splice the `"<key>":null` members instead of decode→encode; or fix at the provider | −0.03 cores |
| Provider WS decode (`ProviderMessage.UnmarshalJSON` 1.2 + `RawMessage` 1.3 + `websocket.Read` growth) — full heartbeat decoded every 1–5 s per provider | ~3 % | 16 | peek `"type"` first and decode heartbeats into a reused per-connection struct | −0.04 cores |
| `strings.genSplit` 3.4 % / `dispatchLoadCooldownActiveLocked` 1.2 % | 4.6 % | 25 | already removed by branch (version memo, struct keys) | — |
| Goroutine root scan: 5 goroutines per provider connection (nhooyr `timeoutLoop`, read, write, ping…) → 0.094 s/cycle | R term | — | not an allocation; folds under GOGC=400 (÷4); collapsing to 2 goroutines/conn is a larger change | −0.3 cores at GOGC=100, −0.08 at 400 |
