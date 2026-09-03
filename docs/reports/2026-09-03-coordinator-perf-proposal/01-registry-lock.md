# 01 — Registry.mu on the per-request path

Grades: **M** measured · **C** computed from measurements · **E** estimated (assumptions stated).
Master = `5d400cf75`. Prod build `4ce5c0409` line numbers differ (its `scheduler.go:528` is master `scheduler.go:624`; `registry.go:2477` is `:2502`); all file:line below are master unless marked *prod*.

## Question

Where does the per-request path take `Registry.mu` for writing, how long do waiters wait in prod, what is the simplest structural change that removes the global write lock from that path, and what does it buy — alone and on top of the perf branch's scan work — at 1x/2x/5x load?

## Evidence

### E1. Write-lock sites reached per request (master)

| # | When | Site | State mutated | Scope | Under the lock |
|---|---|---|---|---|---|
| 1 | every scan (incl. every rescan) | `commitProviderReservation` scheduler.go:624 | `p.pending` (via p.mu), `capacityCooldowns[key].probeAt` | global lock, per-provider effect | budget check :630, identity check :644, `snapshotProviderLockedEx` :676 (p.mu inside), `buildCandidateWithReason` :690, `applyCacheRoutingDiscount` :700, admit re-check + `addPendingLocked` + `claimCapacityProbeLocked` :712-722. **Rare full fleet walk under Lock**: breaker-bypass re-scan `selectBestCandidateScanLocked` :653-664 |
| 2 | retry via retained plan | `ReserveNextFromPlan` dispatch_plan.go:399 | same as 1 | global | Lock held across the whole plan loop (snapshot + candidate + admit per entry); **bypasses the #799 semaphore** (consumer.go:1082-1091) |
| 3 | first content chunk (TTFT path) | `RecordCapacityAccept` → `RecordCapacityAcceptOutcome(_,_,true)` capacity_cooldown.go:381,437 | `capacityRejectStrikes/Cooldowns/Trips`, `budgetClamps`, rate window, `healthEjectionCapacityStreaks/Trips/LastTripCapacity` | global | map deletes/inserts keyed by `(faultKey, model)`. Always a Lock: `PenaltyMs` default 15 000 (capacity_rate.go:58) makes `shouldRecordRate` true (:422). Runs in `commitFirstContent` dispatch.go:583-613 **before** the chunk is written to the client (`writeCommittedResponse` dispatch.go:3782). Live in prod: E3's 9 waiters enter via `RecordCapacityAccept` (*prod* capacity_cooldown.go:382) |
| 4 | clean completion | `RecordInferenceSuccess` error_cooldown.go:149-155 | `inferenceErrorStrikes/Cooldowns` | global | 2 deletes + `faultKeyLocked` |
| 5 | clean completion | `RecordCapacityAcceptOutcome(_,_,false)` consumer.go:530 | — | global | RLock probe :424-435; Lock only if state exists (usually none) |
| 6 | clean completion | `RecordProviderOutcome` provider_breaker.go:193-198 | `providerOutcomes` ring, `providerBreakerOpenUntil/Trips` | global | ring record; **map sweeps when >1024 entries** :206-220 |
| 7 | clean completion | `RecordProviderServeOutcome` health_ejection.go:456-460 | `healthEjectionWindows/Until/Trips/...` | global | `healthEjectionSweepLocked` (map walks when >2048) :556-586 |
| 8 | `handleCompleteAt` (off read loop, provider.go:611-617) | `ClearDispatchLoadCooldown` registry.go:2502-2506 | `dispatchLoadCooldowns` | global | 1 delete |
| 9 | error paths | `recordCapacityReject` capacity_cooldown.go:246-250, `RecordInferenceError` error_cooldown.go:91-97, `RecordDispatchLoadFailure` registry.go:2480-2483, plus 6/7 | same maps + budget clamp + rate window | global | sweeps when >1024 |

Success path = **6 write acquisitions per request** (1,3,4,6,7,8) + 1 per rescan/retry; 2 of them (1,3) precede the first byte to the client.
Non-request writers: `Register` registry.go:3778, `Disconnect` :4940, `evictStale` :6344 (every 30 s, **full fleet walk under Lock**), `expirePendingModelLoads`/`reservePendingModelLoads` :4418/:4583 (`TriggerModelSwaps` on heartbeat while the queue is non-empty), `markUntrusted` :5204, `releaseBudgetClampsOnHeartbeat` budget_clamp.go:375 (only when a clamp exists), `bindStableFaultKey` health_ejection.go:169, config setters, and three read-only getters that take the write lock — `ReleasePolicyEnforced`/`CodeAttestationConfigured`/`CodeAttestationEnforced` registry.go:1711/1790/1798 (stats.go:238-246, 15 s gauge loop server.go:2928). Heartbeat ingest itself is RLock + p.mu only (registry.go:3918-3947); `handleChunk` takes no registry lock per chunk (provider.go:1752-1861); `RecordLatency` is once per request (dispatch.go:3733).

### E2. Prod profile, 30 s at 14:07 PDT (M)

| Quantity | Value | Source |
|---|---|---|
| Process CPU | 134.61 s / 30.15 s = **4.47 cores** | cpu.pprof header |
| `scanProviderReservation` (RLock scan) | 29.73 s = **0.99 core** (22.1%) | `-focus` |
| `scanCandidatesLocked` all callers | 36.18 s (26.9%) | `-top` |
| Preflight walks `QuickCapacityCheck` + `PredictServable` | 3.84 + 3.03 s = 0.23 core | `-focus` |
| **CPU spent holding the write lock** | commit 0.17 s + ServeOutcome 0.03 s + CapacityAccept 0.02 s + others 0 = **0.22 s = 0.007 core** | `-focus` per function |
| GC (`gcBgMarkWorker`) | 51.55 s = **1.71 cores** (38.3%) | `-focus` |
| Alloc bytes from the scan path | Median 11.2% + SoloMedian 10.6% + buildCandidate 10.0% + SoloMedianAllChips 5.8% + pooledBudget 5.5% + versionSegments 5.0% + dispatchLoadCooldown 1.2% = **49.3%** (versionSegments cum already contains `strings.genSplit` 3.4%) | allocs.pprof `alloc_space` |
| mutex.pprof / block.pprof | **empty** (profile rates not set) | file headers |

### E3. Goroutine snapshot 14:07:57 (M, one instant)

| State | Count | Where |
|---|---|---|
| Writers queued on `r.mu` (`Mutex.lockSlow`) | **152** | commit 88 via `dispatchOneProvider` + 1 via `RefreshDispatchPlan` (*prod* scheduler.go:528), ServeOutcome 14, ClearDispatchLoadCooldown 14, InferenceSuccess 11, ProviderOutcome 10, CapacityAcceptOutcome 9, ReserveNextFromPlan 5 |
| Head writer waiting for active readers (`runtime_SemacquireRWMutex`) | 1 | commit via `ReserveProviderWithPlan` (153 writers in total) |
| Readers queued behind the pending writer | 8 | PredictServable 2, scanProviderReservation 2, budget clamp, IsModelInCatalog, GetProvider, ForgetCacheAttempt |
| **Actively scanning** (holding RLock) | **1** | `scanCandidatesLocked` |
| Waiting for a #799 scan slot (`acquireRoutingScanSlot`) | 68 | consumer.go / inference_admission.go |

Slot holders ≥ 88 + 1 + 1 = 90 while the semaphore is sized `runtime.NumCPU()` (server.go:829, :1339-1345; identical in *prod* 4ce5c0409 :822/:1328, slot held across `reserve(...)` :1079-1096) ⇒ the host reports ≥ 90 CPUs to the runtime while the container uses 4.5 cores (C — verify with `nproc` in-container; `EIGENINFERENCE_ROUTING_CONCURRENCY` may override).

### E4. Bench, M4 Max, 16 threads, `-benchtime 2s` (M; load average 14–47 during runs — treat parallel numbers as ±30%)

| Benchmark (1,260 providers, 15 models) | master | perf branch |
|---|---:|---:|
| FleetReserveProviderEx (scan+commit+release) | 365 µs, 815 allocs | **79 µs, 21 allocs** |
| FleetReserveProviderExParallel-16 | 362 µs (speed-up **1.0x**) | 96 µs (**0.8x**) |
| FleetQuickCapacityCheck (RLock walk) | 161 µs, 672 allocs | 51 µs, 1 alloc |
| Probe: RLock-only walk, 1/4/16 threads | 212 / 82 / 60 µs (**3.5x**) | 65 / 36 / 46 µs (1.4x) |
| Probe: scan+commit+5 recorders, serial | 432 µs | 91 µs |
| Probe: same, 1/4/16 threads | 469 / 387 / 352 µs (**1.3x**) | 117 / 97 / 94 µs (**1.2x**) |
| Probe: one writer at 500/s under 16 walkers — mean / max writer wait | 702 µs / 1.44 ms | 429 µs / 0.79 ms |

Probe file: `01-registry-lock-probe_test.go.txt` beside this report (drop into `coordinator/registry/` next to the perf branch's `fleet_scale_bench_test.go`, which vets clean on master).

## Mechanism

1. **The holders are cheap; the wait is structural.** Write-lock holders account for 0.007 core (E2) ≈ 18 µs per acquisition at ~400/s (C), yet 153 writers are queued (E3). `sync.RWMutex` is writer-preferring: a pending writer blocks every new reader, and each writer must drain the active reader batch before it runs. The readers are full fleet scans, so **every write acquisition costs ~one scan wall-time regardless of what the writer does**, and readers and writers alternate single-file — E3 shows exactly one scan active with 8 readers queued, and E4 shows 1.0–1.3x parallel speed-up for scan+commit versus 3.5x for an RLock-only walk on the same box.
2. **Demand ≈ supply.** λ_w = 1 per scan (incl. rescans) + 5 per completion ≈ 280/s (no rescans) to ~530/s (rescan multiplier ~6) (E). Supply = 1/T_batch. A persistent 150-deep queue means ρ ≈ 1 ⇒ T_batch ≈ 1/λ_w ≈ **1.9–3.6 ms per scan in prod** (C), 5–10x the M4 number — consistent with a GCE vCPU, 38% GC and 90+ runnable goroutines (E). Cross-check: 0.99 core of scan CPU ÷ 2–3.6 ms ≈ 280–500 scans/s ≈ 6–10 scans per attempt at ~50 attempts/s ⇒ a **rescan storm**: queued commits that scanned the same fleet state pick the same winner; each successful commit invalidates the rest (`reservationNeedsRescan` scheduler.go:705-709) and sends them through RLock-wait → scan → Lock-wait again (E).
3. **Wait per acquisition (Little's law):** W = L/λ_w = 153 / (280–530) ≈ **0.29–0.55 s** (E, single snapshot). Per request: 2 acquisitions before the first byte (commit + first-content accept) ≈ 0.6–1.1 s added TTFT; 4 more after ≈ 1.2–2.2 s of goroutine hold (E). The lock queue eats the first-content budget before dispatch: `commitProviderReservation` re-checks the budget only *after* acquiring the lock (scheduler.go:630; expiry there is a routing failure), and a request that does get dispatched hands the provider a remaining budget it cannot meet — the provider-reported `deadline_unreachable` (dispatch.go:729/877/910). Slot waiters (68 at ~50 admits/s ≈ 1.4 s average slot wait, E) exit as `routing_saturated` (579K/day). The utilization research's two dominant rejection classes share this one queue (E).
4. **#799 interaction.** The semaphore is meant to bound scan CPU, but its slots are held across the write-lock wait (consumer.go:1095-1114), so ≥ 90 slot holders are parked on `r.mu` while 68 wait for slots and one goroutine scans. It currently bounds the commit queue depth at NumCPU and converts the overflow to 429s; it bounds no CPU.

## Proposed change

### Recommended: (a) per-identity gate state + (a′) commit without the global write lock — both are required

**(a) Gate state off `r.mu`.** Move breaker, health-ejection, inference-error cooldown, capacity cooldown/rate/clamp and dispatch-load cooldown into a `gateState` per fault key: `r.gates map[string]*gateState` plus the two session-keyed maps `faultKeyBySession`/`disconnectedStableIDs`, all under an insert-only `r.gatesMu` (RLock lookup). Connected providers use a `p.gate` pointer cached at `Register`/`bindStableFaultKey`; the disconnected trailing-flush path does one `gatesMu.RLock` lookup. Recorders (E1 #3-#9) resolve `p.gate`, take `gate.mu`, mutate, release — never `r.mu`. The scan's per-provider reads (`providerRoutingGateReasonLockedEx` scheduler.go:1625-1700, `budgetClampActiveLocked`, `claimCapacityProbeLocked`) take `gate.mu` briefly per provider.
*Pitfall to design out:* a walk-wide `gates.RLock` with per-completion `gates.Lock` rebuilds the identical convoy on the new lock. Sections must be per-identity and short.

**(a′) Commit under `r.mu.RLock` + `p.mu`.** Identity check `r.providers[p.ID]` under RLock; snapshot under RLock + p.mu (as today); probe claim under `gate.mu`; admit re-check + `addPendingLocked` under p.mu (as today). The "winner unchanged since scan" compare (scheduler.go:705-709) moves inside p.mu: re-read the provider's own pending counters there and compare to `selected.snapshot` before debiting. Same for `ReserveNextFromPlan`'s loop. The breaker-bypass re-scan becomes an RLock read.

| Invariant `r.mu.Lock()` protects today | After |
|---|---|
| No double-booking of a provider | Already `providerCanAdmitLockedEx` + `addPendingLocked` under **p.mu** (scheduler.go:712-721), unchanged |
| Probe claim atomic w.r.t. other commits | `gate.mu` (per identity) |
| Fleet-wide serialization makes the "unchanged since scan" compare exact (herd avoidance) | compare under p.mu — only the winner's own counters are compared, so p.mu suffices |
| Stale gate state seen by a scan | already tolerated between scan RUnlock and commit Lock; commit re-checks under p.mu/gate.mu |

Lock order: `r.mu` → `p.mu` → `gate.mu`; never acquire `r.mu` while holding `gate.mu`. After the change the remaining `r.mu` writers are Register/Disconnect/evictStale/swap planner/config (tens per second at most, E); the #799 semaphore stays but should be sized to the container's CPU quota, not host `NumCPU`, so it bounds CPU as designed.

Why not (a) alone: commits are still 50–500 Lock/s (one per scan incl. rescans) — the convoy persists. Why not (a′) alone: 5 recorders per completion ≈ 230+/s writers remain.

### Alternatives

| Option | What | Effort | Verdict |
|---|---|---|---|
| (b) batched async recorders | one worker drains a channel and applies N outcome updates under a single Lock | ~1 day | cuts λ_w ~5x, leaves the commit convoy, delays gate state by the batch interval; acceptable stopgap only |
| (c) copy-on-write fleet snapshot, lock-free scan | immutable per-provider views republished on heartbeat/registration; commit locks only the winner | 2–3 weeks | unnecessary once writers are off the path — RLock readers already parallelize (3.5x, E4); heartbeat republish at 125–250/s adds its own cost |
| (d) sharded `r.mu` | shard by provider id | ~1 week | the contended state is global maps keyed by fault key; this is (a) with more complexity |

## Estimated improvement

Baseline 4.47 cores, ~50 attempts/s, 46 completions/s.

| Lever | CPU | Write-lock wait | Grade |
|---|---|---|---|
| Perf branch alone | scan 0.99 → 0.99 × 79/365 = **0.21 core**; preflight 0.23 → 0.07; GC 1.71 × 0.49 (scan-path alloc share) ≈ **−0.84 core** (GC cycles ∝ alloc rate, live heap unchanged); total ≈ **−1.8 core → ~2.6 cores** | T_batch ÷ 4.6 ⇒ supply ≈ 1.3–2.4k/s vs demand 280–530/s ⇒ ρ ≈ 0.2, W ≈ T_batch·ρ/(1−ρ) ≈ **0.1–0.2 ms** (M/M/1); 2x: ρ ≈ 0.45, W ≈ 0.5 ms; **5x: ρ ≈ 1.1 — saturates again** (rescan storm returns) | C / E |
| Lock removal alone (on master) | holders were 0.007 core ⇒ direct saving ≈ 0; rescans (E, 6–10 scans/attempt) collapse to ~1 ⇒ scan CPU 0.99 → 0.1–0.17 core (E); slot/lock spin (`futex`+`usleep` 2.0%) mostly gone | `r.mu` writers → <10/s ⇒ readers essentially never blocked; per-request wait → ~0 (only p.mu/gate.mu, µs) | E |
| **Both** | scan ≈ 0.21 × (1/6–1/10 rescans) ≈ **0.03 core** + preflight 0.07 + GC ≈ 0.87 ⇒ process ≈ **2.4 cores** at 1x; ≈ 3.3 at 2x; ≈ 6.0 at 5x, scan+preflight ≈ 0.5 core at 5x (prod T_scan 0.45–0.8 ms × 250/s) | ~0 at 1x/2x/5x; 68 slot waiters → 0, `routing_saturated` → ~0, lock-aged `deadline_unreachable` share removed | C / E |

Headroom: perf branch alone ≈ 3x (the queue re-forms between 3x and 5x); both ≈ >5x with CPU as the only limiter. Verification hooks: #809 (master) persists `LockWaitUS/ScanUS/AdmitUS` per attempt (store/profile_records.go:130-132) — the first deploy of #809 turns every E above into M; set `runtime.SetMutexProfileFraction`/`SetBlockProfileRate` behind the #799 pprof listener so mutex.pprof/block.pprof stop coming back empty.

## Effort / risk / tests

| Item | Estimate |
|---|---|
| (a) gateState + 7 recorders + ~8 `*Locked` readers + faultKey plumbing | 2–3 days |
| (a′) commit + `ReserveNextFromPlan` re-lock, compare-under-p.mu | 1 day |
| Tests | existing per-feature recorder tests adapted (unchanged semantics); `-race` test: N goroutines commit on one provider, assert admitted ≤ cap; recorder/scan interleave under `-race`; regression bench asserting `ProbeRequestPathParallel` speed-up ≥ 4x at 16 threads; index/gate equivalence fixture from the perf branch reused | 1–2 days |
| Risk | medium: lock-order discipline; a walk-wide gates lock would silently reintroduce the convoy (guard with the parallel-speed-up bench); semaphore resize is a separate one-line deploy knob |

## Conflicts

| With | Overlap | Handling |
|---|---|---|
| Perf branch `worktree-bridge-cse_01TuyfD42fkRyG4ZqSTmeN4U` (68 registry files, +4.5k/−0.5k; rewrites scheduler.go snapshot/candidate path, all five recorder files, `evictStale` → RLock, write-lock getters → RLock, per-model index) | same functions the lock work edits | sequence the lock change **on top of** the perf branch; do not develop in parallel |
| `.claude/worktrees/sysopt-0903` (`feat/system-optimization-2026-09-03`) | only an untracked report scaffold, no code yet | none today; coordinate if it starts touching `registry/` |
| `refactor/coordinator-modularization` (file-splitting, 14 commits, −4.3k lines, last commit 2026-06-01) | moves registry code between files | stale by three months; this section cites functions, so it survives either layout |
| PR #809 system profiler (master) | adds `LockWaitUS/ScanUS/AdmitUS` and the attempt profile stamps around scan/commit (scheduler.go:565-602) | keep the stamps; they become the acceptance metric |
| Prod build 4ce5c0409 (fix/routing-overload-hardening) | not on master; #799 is its rebased equivalent | line numbers differ as noted; semantics identical for the semaphore and the commit |
