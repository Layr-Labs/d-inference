# perf(registry): take the global write lock off the per-request path (Tier 3)

> Last updated: 2026-09-04 · commit `6a1d1eb27`

Stacks on `perf/coordinator-registry-scan-2026-09-03` (PR B: per-model index, arena snapshots,
cached medians). **Merge after it and after PR #818** (`perf/coordinator-tier1-2026-09-03`, the
`lockWrite(site)` observer and `ScanCount` stamp); this branch is rebased onto #818 once it lands —
the six recorder bodies #818 instruments are rewritten wholesale here, so the conflicts resolve
to this branch. Two things to do **at that rebase**:

- #818's `TestRegistryLockWaitHistogramTaggedBySite` (api) drives a `registry.mu.write_wait_ms`
  sample through `reg.ClearDispatchLoadCooldown` behind `HoldWriteLockForTest`. On this branch that
  recorder never touches `r.mu`, so the test must be retargeted at a remaining `r.mu` writer (a
  config setter, or the commit in `global` mode) or it hangs.
- Route `commitLock.lock()` in `global` mode through `r.lockWrite("commit")` /
  `("commit_plan")` so the kill switch keeps its write-wait histogram; in `shared` mode the commit
  takes `r.mu.RLock` and has no write wait to report.

Design and evidence: `docs/reports/2026-09-03-coordinator-perf-proposal/01-registry-lock.md`
(E1–E4), README §3 Tier 3 and §6.

## What was wrong

`Registry.mu` is a writer-preferring `sync.RWMutex`. Every served request took it for **writing six
times** — the reservation commit, the first-content capacity accept, and at completion
`RecordInferenceSuccess`, `RecordProviderOutcome`, `RecordProviderServeOutcome`,
`ClearDispatchLoadCooldown` — plus `ReserveNextFromPlan` held it across its whole loop. Each
holder ran for microseconds (0.007 core in total), but a pending writer blocks every new reader
and must drain the active batch of fleet scans first: **≈190 ms per acquisition in prod**, 152
writers queued behind one scanning reader, two of the six acquisitions before the first byte.
Commits that lost the race rescanned the fleet (10–14 iterations per reservation). Coordinator-caused
TTFB at the median: ≈2.4 s.

## What changed

Two halves, shipped together (neither helps alone — see 01 "Why not (a) alone"):

**(a) Per-identity gate state.** The node-health breaker, stable-identity health ejection, the
shape-keyed inference-error cooldown, the capacity cooldown / rate window / budget clamp and the
dispatch-load cooldown moved out of the global maps into one `gateState` per fault key
(`registry/gate_state.go` — the struct and its lock-free view; the index, migration, sweep, recorder lock
and commit-mode switch live in `gate_index.go`, `gate_migrate.go`, `gate_sweep.go`, `gate_lock.go`,
`gate_commit_mode.go`), each with its own `sync.Mutex`. Recorders resolve the gate, take
`gate.mu`, mutate, release — **they never touch `r.mu`**. Connected providers cache their gate
(`p.gate`, atomic); the disconnected trailing-flush path does one `gatesMu.RLock` lookup. The scan
reads the two hot booleans (breaker open, ejected) from atomics and a per-gate flag word says which
per-model trackers hold state, so a provider with no fault state costs the scan a few atomic loads and
no lock section. The size-triggered map sweeps (>1024 / >2048 walks under the write lock) became a
periodic per-gate sweep from the eviction loop. Identity rebinds migrate a gate's state and forward the
orphan, so a recorder holding a stale pointer still lands on the live state; and because a recorder
resolves its gate under `gatesMu.RLock` but locks it only after letting go of `gatesMu`, it re-validates
the gate under `gate.mu` once acquired (not retired by the sweep, still the session's cached gate) and
re-resolves through the index otherwise. The routing READS are covered two ways: the identity bind runs under the session's `p.mu`
(third review pass), so the scan's gate chain, the commit through its debit and the alias resolver — all under
`p.mu` — never see `p.gate` move mid-section; and every read that feeds a dispatch decision also confirms its
verdict against `p.gate` afterwards and re-reads from the session's new gate when it moved (`gateView`; see
"Review follow-ups"), which is what covers the candidate cost read the scan makes after releasing `p.mu`.

**(a′) Commit without the global write lock.** `commitProviderReservation` and
`ReserveNextFromPlan` hold `r.mu` for **reading** (identity, catalog and cache-routing config only)
and do everything that decides the reservation — fresh snapshot, cost rebuild, the "winner unchanged
since scan" compare, admit re-check, probe claim, pending debit — inside **one `p.mu` section** on the
winner. The half-open capacity probe is check-and-claim under `gate.mu`. The breaker-bypass re-scan is
a read.

Lock order: `r.mu → p.mu → gatesMu → gate.mu`. Never `r.mu` or `p.mu` while holding `gatesMu` or a
`gate.mu`. There is deliberately **no walk-wide gates lock** on the scan; the parallel speed-up guard
below is what keeps it out.

## Before / after

### Behaviour

```mermaid
flowchart LR
  subgraph Before["Before (master / PR B)"]
    A1[attempt] --> S1["scan under r.mu.RLock<br/>(whole fleet)"]
    S1 --> W1["wait for r.mu.Lock<br/>≈190 ms: drain the reader batch"]
    W1 --> C1["commit: re-snapshot + compare"]
    C1 -->|winner changed| S1
    C1 -->|ok| D1[dispatch]
    D1 --> F1["first content:<br/>RecordCapacityAccept → r.mu.Lock (≈190 ms)"]
    F1 --> B1[first byte to client]
    B1 --> E1["completion: 4 × r.mu.Lock<br/>(success, outcome, serve outcome, cooldown clear)"]
  end
  subgraph After["After (this branch, shared mode)"]
    A2[attempt] --> S2["scan under r.mu.RLock<br/>(gate reads: atomics + flag word)"]
    S2 --> C2["commit under r.mu.RLock + p.mu:<br/>snapshot · cost · compare · admit · probe claim (gate.mu) · debit"]
    C2 -->|winner changed on this provider| S2
    C2 -->|ok| D2[dispatch]
    D2 --> F2["first content:<br/>RecordCapacityAccept → gate.mu (µs)"]
    F2 --> B2[first byte to client]
    B2 --> E2["completion: 4 recorders → gate.mu (µs each)<br/>r.mu never taken"]
  end
```

### Code

```mermaid
flowchart TB
  subgraph Before["Before"]
    direction TB
    RB["Registry.mu (RWMutex)"]
    RB --- M1["providerOutcomes / providerBreakerOpenUntil / providerBreakerTrips"]
    RB --- M2["healthEjection* (5 maps)"]
    RB --- M3["inferenceErrorStrikes / inferenceErrorCooldowns"]
    RB --- M4["capacityRejectStrikes / capacityCooldowns / capacityCooldownTrips"]
    RB --- M5["budgetClamps · capacityRateRejects / Accepts"]
    RB --- M6["dispatchLoadCooldowns · faultKeyBySession · disconnectedStableIDs"]
    RecB["RecordProviderOutcome · RecordProviderServeOutcome · RecordInferenceError/Success<br/>recordCapacityReject · RecordCapacityAcceptOutcome · RecordDispatchLoadFailure · ClearDispatchLoadCooldown"] -- "r.mu.Lock()" --> RB
    ComB["commitProviderReservation · ReserveNextFromPlan"] -- "r.mu.Lock()" --> RB
    ScanB["providerRoutingGateReasonLockedEx · snapshot · buildCandidateInto"] -- "r.mu.RLock() + map reads" --> RB
  end
  subgraph After["After"]
    direction TB
    RA["Registry.mu (RWMutex)<br/>writers: Register · Disconnect · evictStale · swap planner · config"]
    GI["gatesMu (RWMutex, insert-only)<br/>gates map[faultKey]*gateState · sessions · disconnectedStableIDs"]
    G["gateState (one per identity, own mutex)<br/>breaker · ejection · error cooldown · capacity cooldown/rate/clamp · dispatch-load<br/>atomics: breakerOpenUntilNS · ejectionUntilNS · pairFlags · newestRateRejectNS"]
    GI --> G
    P["Provider.gate (atomic.Pointer)"] --> G
    RecA["same 8 recorders"] -- "gateForSession → lockGate(site) → gate.mu" --> G
    ComA["commitProviderReservation · ReserveNextFromPlan<br/>(commitLock: RLock in shared, Lock in global)"] -- "r.mu.RLock()" --> RA
    ComA -- "p.mu: snapshotProviderIntoPLockedEx · buildCandidate · compare · canAdmit · tryClaimCapacityProbe · addPendingLocked" --> P
    ScanA["providerRoutingGateReasonLockedEx · snapshotProviderIntoLockedEx · buildCandidateInto"] -- "gateOf(p): atomic loads; gate.mu only for pairs with state" --> P
    Sweep["evictStale → sweepGates"] -- "gatesMu.Lock (periodic, off the request path)" --> GI
  end
```

## Invariants (from 01, with how each is protected now)

| Invariant `r.mu.Lock()` protected before | Now |
|---|---|
| No double-booking of a provider | `providerCanAdmitLockedEx` + `addPendingLocked` under **`p.mu`** — unchanged, and now in the same `p.mu` section as the fresh snapshot (`snapshotProviderIntoPLockedEx`), so nothing on the provider changes between the check and the debit. Test: N goroutines vs one capped provider admit exactly the serial capacity, both modes, `-race`. |
| Probe claim atomic w.r.t. other commits | `gateState.tryClaimCapacityProbe`: check **and** claim in one `gate.mu` section, per identity; a closed gate rejects the reservation instead of leaking a second probe. Test: two sessions of one identity racing → exactly one claim. |
| Fleet-wide serialization makes the "unchanged since scan" compare exact (herd avoidance) | The four-field compare runs against a snapshot taken under the **same `p.mu` hold that debits**; only the winner's own counters are compared, so `p.mu` suffices. A concurrent commit on the same provider is either fully before (visible → rescan) or fully after. |
| Stale gate state seen by a scan | Already tolerated between scan RUnlock and commit; the commit re-checks under `p.mu`/`gate.mu`. A gate being migrated is read two ways. An ORPHANED source (its last session left) is forwarded before it is reset and never republished, so lock-free readers see its intact pre-merge view or the forward, never zeros. A SHARED source (a sibling session still bound to it) IS reset and republished — the state moved with the rebinding session — so every read that feeds a dispatch decision (the five routing gates in `gateStateReasonLocked`: scan, commit admit re-check and preflight; the snapshot's budget clamp on both snapshot paths; the candidate's capacity-rate penalty) confirms its verdict against `p.gate` after the read and re-reads from the session's new gate when it moved (`gateView`, bounded like `lockGate`'s re-resolve). Sound without a lock because the migration repoints `p.gate` BEFORE it resets and republishes the source, and Go's atomics are sequentially consistent. Tallies, classification counts, fleet_sample rows and warm-pool planning read unconfirmed: a stale sample there miscounts once and dispatches nothing. Test: a scan that loaded the shared gate before the rebind is gated on the new gate (breaker — atomic path — and dispatch-load cooldown — locked per-model path; both modes), an unconfirmed read of the stale gate says clean, the sibling's view reads not gated, and the end-to-end reservation never lands on the rebound session; a `-race` stress variant with a flapping session carrying a permanent cooldown. |
| Identity rebind moves accumulated fault state | `bindStableFaultKey` migrates `gateState` → `gateState` under the session's `p.mu` and `gatesMu.Lock` (the only place two gate locks nest); stale pointers follow `forwardTo`; a recorder holding a stale pointer re-validates under `gate.mu` (not retired, still the session's cached gate) and re-resolves through the index otherwise; the session is repointed inside the migration's two-gate locked section, so a recorder holding the source either wrote before the merge (its outcome travels) or sees the pointer moved. A shared identity gate with other live sessions is emptied, not orphaned — the repointed `p.gate` is what tells a stale holder its outcome now belongs to the new gate. The lock-free "no per-model state" fast paths (probe claim, the clear recorders) trust a cleared flag only while `p.gate` still points at the gate it was read from (`refHasPairState`). **Semantics (written down in `gate_migrate.go`): the state MOVES, it is not copied.** The source identity — and a sibling session still bound to it (the same machine connected twice: one SE key, two sessions) — starts from nothing, exactly as the map-keyed `migrateFaultStateLocked` left the old key; the sibling lands on the moved state at its own enrichment. A copy was rejected: the merge does not deduplicate histories, so it would double-count every fault (strike lists, health rings, consecutive-fault streaks) the moment the sibling enriches to the same serial. |
| Fault state survives Disconnect; identity-less residue is dropped | `detachSessionGate`: caches the stable id for the trailing flush and keeps the identity's gate; a session-keyed gate (no identity) is dropped at Disconnect. |
| Bounded maps | Periodic `sweepGates` from the eviction loop (plus a rate-limited inline sweep past 4096 gates): prunes dead per-model entries; drops gates with no live session once idle for 10 min, marking them `retired` under `gate.mu` before the index delete so a recorder that resolved the gate before the walk re-resolves instead of writing into it. A gate's **creation counts as activity** for the idle grace, so a gate filed for a disconnected identity (the trailing flush's first fault, a serve outcome by stable id) cannot be swept before the recorder that created it takes the lock — an untouched disconnected identity therefore lingers ≤ 10 min instead of dropping on the first sweep (negligible: one empty `gateState`). Half-open trip memory of a **live** gate is never pruned (the old size-triggered sweeps only ran past 1024 entries). |

## Mode flag

`EIGENINFERENCE_RESERVE_COMMIT_MODE` = `shared` (default) | `global`, read once at construction.

- `shared`: commit and plan consumption hold `r.mu.RLock` + `p.mu` (this change).
- `global`: they take `r.mu.Lock()` — the previous fleet-wide serialization, kept as the **kill
  switch** for (a′). The recorders stay on their per-identity gates in **both** modes: that half is
  safe on its own, and the flag exists for a defect in the shared commit.

The request-path suites run in both modes (`forEachCommitMode`).

## Observability

- `registry.gate.wait_ms` — DogStatsD histogram tagged `site:` (`breaker`, `health_ejection`,
  `inference_error`, `inference_success`, `capacity_reject`, `capacity_accept`,
  `dispatch_load_failure`, `dispatch_load_clear`, `clamp_heartbeat`), emitted only when a `gate.mu`
  wait exceeds 1 ms (uncontended path: one `TryLock`, no clock reads). Distinct from #818's
  `registry.mu.write_wait_ms`. The commit-path probe claim (`capacity_probe` site) takes the same
  gate lock but does not report its wait: it runs under `p.mu` (and `r.mu` in `global` mode), where the
  emit must not happen; the recorders' waits on the same gates cover it.
- The #809 per-attempt stamps (`lock_wait_us`, `scan_us`, `admit_us`) are the acceptance metric.

## Bench (this box: M-series, 16 threads, `-benchtime 2s -count 2`; load average 330–380 on 16 cores during both runs — treat absolute numbers as ±30%, ratios within a run as the signal)

| Benchmark | PR B (base) | this branch |
|---|---:|---:|
| RequestPathWalkParallel-16 (RLock-only fleet walk) | 158–176 µs/op | 100–109 µs/op |
| RequestPathWalkParallelWithWriter-16 — one recorder at 500/s under 16 walkers: **writer wait mean** | **1.7–2.6 ms** | **39–72 µs** |
| … writer wait max | 18–100 ms | 31–68 ms (scheduler noise at this load) |
| RequestPathSerial (scan+commit+5 recorders+release) | 424–537 µs/op | 346–351 µs/op |
| RequestPathParallel-16 (same, 16 threads) | 353–386 µs/op | 145–157 µs/op |
| **parallel speed-up (serial ÷ parallel)** | **≈1.2×** | **≈2.3×** (read-only walk ceiling on this box at that moment: 2.6×) |
| FleetReserveProviderExParallel-16 | 311–351 µs/op | 312 µs/op (fixture herds every goroutine onto model 0 with colliding request ids → rescans dominate; not a lock signal) |

`TestRequestPathParallelSpeedup` pins the guard. **Deviation from the proposal's "asserts ≥ 4× at
16 threads":** the absolute 4× is asserted only when the box's own read-only fleet walk (RLock, no
writers) reaches 4× — an unloaded machine; on a busy box it asserts the relative property instead
(request path ≥ 60% of the read-only walk's speed-up; the base branch sits at ≈45%), and above a
1-minute load of 2×GOMAXPROCS it skips with the numbers logged, because lock-holder preemption
defeats every locking scheme there. Each quantity is the best of three interleaved fixed-work runs.
On the development box (load 449–459 on 16 cores) it therefore **skipped**, measuring read-only
4.75× vs request path 3.50× (74%). The request path's ceiling sits below the read-only walk's
because of three pre-existing global write locks the read walk does not pay: `ttftCalibration.
notePrediction` per warm commit, the warm-pool `recordEvent` per cold dispatch, and the cache
tracker on `RemovePending`. None of them is `r.mu`.

## Acceptance metrics (prod, via #809 stamps)

- `admit_us` p99 < 10 ms; attempt-start → first-lock p90 < 50 ms, for 24 h.
- `registry.mu.write_wait_ms` (#818) collapses to the non-request writers (Register/Disconnect/
  evictStale/swap planner/config: tens per second); `registry.gate.wait_ms` stays empty or
  single-digit ms.
- Rescans per attempt (`ScanCount`, #818) → ~1.

## Rollout

1. Deploy with the default (`shared`). Kill switch: `EIGENINFERENCE_RESERVE_COMMIT_MODE=global`
   restores the fleet-wide commit serialization without touching the recorders.
2. **Not in this branch (deploy knob):** the #799 routing semaphore is still sized to host
   `runtime.NumCPU()` and its slots were held across the write-lock wait. With the wait gone, re-size
   `EIGENINFERENCE_ROUTING_CONCURRENCY` to the container's CPU quota so it bounds scan CPU as
   designed.
3. Re-profile 30 s after landing and diff against 00.

## Behaviour-neutral changes worth knowing about

- `ClearDispatchLoadCooldown` returns without taking any lock when the identity has no dispatch-load
  state (one flag load) — the common completion case.
- `RecordCapacityAcceptOutcome(_, _, false)` lost its read-only no-state probe; every accept now takes
  one uncontended `gate.mu` (microseconds, per identity) instead of an `r.mu.RLock` probe.
- `Disconnect` of an identity-less session drops **all** of that session's fault residue (capacity
  trackers included); before, only breaker / inference-error / dispatch-load residue was dropped.
- `TestReserveProviderWithPlanPrimarySelectionUnchanged` compared candidate summaries including
  their wall-clock `HBAgeMs`; it flaked 4/40 under `-race` on the loaded box (0/40 on base at that
  moment). The summaries' heartbeat ages are now zeroed like the decision's own `SnapshotAgeMs`.
  Test-only; revert if preferred.
- `ReserveNextFromPlan` is exercised concurrently with one plan per goroutine (the plan itself is
  single-consumer); the existing sequential plan suite covers the rest under `-race`.

## Remaining `r.mu` writers

Register, Disconnect, `evictStale` (strike map install), the swap planner
(`expirePendingModelLoads`/`reservePendingModelLoads`), `markUntrusted`, config setters, hook
setters. **No `r.mu.Lock()` remains on any request path.** The recorders take `r.mu` in no mode; the
only read-side touch left near a recorder is the budget snapshot for the clamp
(`providerReportsTokenBudget`/`providerBudgetSnapshot`), which reads `p.BackendCapacity` under
`p.mu` via the `sessions` index — no `r.mu` at all.

## Review follow-ups

### Third pass

Codex's third review left five findings; all legitimate.

- **F1 [P1] — a landed report was edited.** The "Follow-on" cross-link added to the PR-B body (landed on
  the parent branch; reports are frozen) is removed; the Tier 3 body is indexed in `docs/reports/README.md`
  instead. Commit `6a64f71a8`.
- **F2 [P1] — `EIGENINFERENCE_RESERVE_COMMIT_MODE` documented only here.** Row added to
  `docs/reference/configuration.md` (values, default, read-once at construction, what each mode holds).
  Commit `9d2138db3`.
- **F3 [P2] — a rebind could land between the commit's final gate check and its debit.**
  `bindStableFaultKey` ran after `SetAttestationResult` / `RebindStableFaultKey` had released `p.mu`, while
  the commit reads `p.gate` (the admit re-check) and debits inside one `p.mu` section in both modes;
  `gateView` closes a rebind that lands during the reads, not one after `moved()` has confirmed them, so a
  commit could accept a clean source gate and dispatch to a session whose destination identity already
  carried a breaker or cooldown. The map-keyed code had no window (bind and commit shared `r.mu.Lock`).
  Both entry points now derive the identity and bind while `p.mu` is still held; lock order unchanged
  (`r.mu → p.mu → gatesMu → gate.mu` — the bind takes the last two, and no recorder takes `p.mu` under a
  gate lock). `gateView` stays for the capacity-rate read the scan makes after releasing `p.mu`. Test:
  `p.gate` never changes under a `p.mu` holder while the session flaps identities through either entry
  point (`-race`; 2000+ moves per run without the fix, zero with it). Commit `dd936c097`.
- **F4 [P2] — the alias resolver's cooldown read was unconfirmed.** `providerCanRouteBuildLocked`
  (`ResolveModel` → `anyProviderCanRouteBuildLocked`) read `gateOf(p).dispatchLoadCooled` with no
  confirmation, so a shared source reset by this session's own rebind could read "not cooled" and resolve
  the alias to a Desired build whose only provider was cooled. Closed by F3: the read runs under `p.mu`,
  which the bind now holds; said so at the read site. Test: a Desired-only session flapping identities with
  a travelling cooldown while every concurrent `ResolveModel` must pick Previous (`-race`; ~2400 wrong
  resolutions per run without the fix, zero with it). Commit `d789d1723`.
- **F5 [P1] — the locking model was documented only here.** `docs/architecture/routing.md` gains
  "Concurrency: scan, commit and fault-state gates" (lock table and order, two-phase reservation, the
  per-identity gates and recorders, rebinds, sweep, observability), four invariants and the code-map rows
  for the `gate_*.go` files; `scheduling.md` carries the double-booking invariant with a link. This commit.

### Second pass

Codex's second review left two findings; both legitimate.

- **F1 [P1] — split the gate implementation** (`gate_state.go` had grown to 1,013 lines across six
  concerns; repo policy asks for small single-responsibility files and a modular pass after large work).
  Split by concern: `gate_state.go` (design header with lock order and file map, the `gateState` struct,
  `publishLocked` and the atomic readers), `gate_index.go` (`r.gates` / `r.sessions` under `gatesMu`,
  `gateRef` resolution, `gateOf`, attach/detach), `gate_migrate.go` (`resolve`, merge and reset policy,
  `bindStableFaultKey`, `migrateGateLocked`), `gate_sweep.go` (`pruneLocked`, `sweepGates`),
  `gate_lock.go` (`lockResolved`, `lockGate`, `refHasPairState`, the wait observer),
  `gate_commit_mode.go` (the kill switch). Tests split the same way (`gate_index_test.go`,
  `gate_migrate_test.go`, `gate_sweep_test.go`, `gate_lock_test.go`, `gate_stress_test.go`). Pure
  moves — verified by a sorted-line diff of the old file against the concatenated new ones (only each
  file's header and the file map are new). Commit `829849ee9`.
- **F2 [P2] — the routing read path trusted an emptied shared source** (the residual the first pass
  documented). The scan loads `p.gate` and reads it holding no lock a rebind respects; a rebind landing
  in between moves the session's state and, for a SHARED source, resets and republishes it as zeros, so
  the scan — and the commit's admit re-check, which reads the same way — admitted a session whose
  breaker or cooldown had just moved. Closed by confirming every dispatch-deciding read against `p.gate`
  after the read (`gateView`, details in the invariants table). Also settled the semantics question the
  reset raised — move, not copy — and wrote it into `gate_migrate.go`. Commit `4001286bf`.

### First pass

Codex left two P2 findings on the gate index; both were legitimate and share one root cause — a
recorder resolves its gate under `gatesMu.RLock` but locks it only after releasing `gatesMu`, a
window the map-keyed code never had (key resolution and the write shared one `r.mu.Lock` section
with the bind). Fixed by re-validating the gate under `gate.mu` after acquiring it and re-resolving
through the index otherwise (`gateRef` / `lockGate`, `retired`, the repoint inside the migration's
locked section, creation-counts-as-touched):

- **F1 — recorders racing a shared-identity rebind** (`migrateGateLocked(..., false)` reset the shared
  gate without a forward; a recorder holding the old pointer wrote into the emptied gate that now
  belonged to the other session — a success left the migrated clamp/cooldown unreleased, a fault
  poisoned the other identity's breaker). The removed comment claiming parity with the map-keyed
  implementation was wrong. Commit `d21e0d48f`.
- **F2 — the sweep dropping in-flight recorder updates** (the sweep decided under `gate.mu`, unlocked,
  deleted; a trailing-flush recorder that had already resolved the pointer wrote the disconnect 502
  into a gate no lookup would find — `evictStale` runs `Disconnect` then `sweepGates` in the same
  pass, and a gate created for a disconnected identity had `touched == 0`). Commit `d21e0d48f`.
- **Adjacent gap found while fixing F1 — the commit-path probe claim** (`tryClaimCapacityProbe` via
  `gateOf(p).lockResolved()` mutated `probeAt` with no session check, so a rebind racing a commit could
  leak one probe through a cooled pair; the lock-free "no state" fast path had the same hole one layer
  up — an emptied source gate's flag says "nothing" because the state moved). Now claimed through the
  same validated lock, both commit modes, with `refHasPairState` confirming a cleared flag against
  `p.gate`. Commit `020fac64f`.

Deliberately unchanged: `detachSessionGate` does not retire the session-keyed gate it drops at
Disconnect — a recorder racing it writes into residue that is dropped by design (see "Disconnect of
an identity-less session drops all of that session's fault residue" above).

## Tests

- `reserve_commit_test.go`: exact-capacity concurrent commit through `ReserveProviderEx` AND through
  `ReserveNextFromPlan` (both modes, `-race`); the half-open probe race end to end — two sessions of
  one identity, N concurrent reservations, exactly one admitted (both modes); identical routing walks
  and per-provider gate outcomes across modes before/after concurrent scans + recorders over the
  fault-state fixture (breaker-open, ejected, capacity-cooled, dispatch-load-cooled, error-cooled,
  budget-clamped — the recorders in the concurrent phase target healthy providers, so this is
  `-race` interleaving coverage plus "faulted stay excluded", not a decision-changing script); the
  parallel speed-up guard; the mode-flag parser (unknown values fall back to `shared` and are logged).
- `gate_migrate_test.go` / `gate_sweep_test.go` / `gate_index_test.go` / `gate_lock_test.go` /
  `gate_stress_test.go` (split from `gate_state_test.go`): stale-pointer migration, no empty-gate
  window for lock-free readers during a live re-attestation, shared-identity rebind, sweep liveness
  rule, trailing-flush resolution, exclusive probe claim, nil-safety, wait observer, recorders never
  block behind `r.mu.Lock`; from the first review pass: a stale ref across a shared-identity rebind
  lands on the session's new gate and leaves the other identity untouched; a stale ref across a sweep
  of a disconnected gate lands on the gate a fresh lookup finds (by session and by stable id); a clear
  keeps the retired gate and files nothing; a fresh gate survives the first sweep; a rebind between
  the probe's resolution and its claim lands the claim on the new gate in both commit modes; the
  lock-free fast path follows the rebind; from the second pass:
  `TestScanRevalidatesGateAcrossSharedRebind` (a scan that loaded the shared gate before the rebind is
  gated on the session's new gate — breaker and dispatch-load cooldown, both commit modes — while an
  unconfirmed read of the stale gate says clean, the sibling's view reads not gated, and the
  end-to-end reservation never lands on the rebound session; fails with the confirmation stubbed out);
  `TestGateRecordersRaceRebindsAndSweeps` now also runs routing reads against a session flapping
  between a shared and an enriched identity with a permanent dispatch-load cooldown and asserts no read
  ever admits it, alongside the recorders and probe claims racing rebinds and sweeps under `-race`.
- `request_path_probe_test.go`: the probe benches from 01.
- Existing tracker suites adapted to the gate API (helpers only; assertions unchanged); index ==
  brute-force, routing_context, fleet_sample and gate-tally suites untouched and green.
- `api`: `TestRegistryGateWaitHistogramTaggedBySite`; full `go test ./api/` green against the new
  registry.
