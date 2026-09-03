# 05 — Port feasibility: landing the 2026-09-02 coordinator branches on master `5d400cf75`

## Question

What does it take to land the 75-commit perf branch (`worktree-bridge-cse_01TuyfD42fkRyG4ZqSTmeN4U`,
tip `5508b4f84`) and the two coordinator commits of the provider-optimization branch
(`worktree-bridge-cse_01SAkmgZHFsFMVXijYt6Czjp`: `773bee1b3`, `58d7792da`) on master `5d400cf75` —
exact conflicts, semantic conflicts with #799/#791/#809 that a textual merge will not flag, what the
concurrent sysopt-0903 session has already ported, and the recommended plan with effort.

Method (read-only): `git merge --no-commit --no-ff` / `git cherry-pick --no-commit` dry runs in a
detached scratch worktree of master (removed afterwards); hunk counts are `<<<<<<<` markers; every
auto-merged file was grepped for calls into symbols the other side removed or re-signatured. All three
branches are based on `a1f51ea4c`, 4 commits behind master (#799 routing hardening, #791 activation
floors, #812, #809 system profiler). The perf branch at its own base: `go build ./... && go vet ./...`
clean in 7.4 s; `golangci-lint v2.1.6 run ./coordinator/...` 0 issues.

## Conflict inventory

### A. Perf branch (75 commits) → master: 6 files / 18 hunks / 468 conflict lines; 146 files auto-merge (+15,962 / −1,026)

| File | Hunks | Lines | master side | perf side | Resolution |
|---|---:|---:|---|---|---|
| `registry/scheduler.go` | 10 | 235 | #809: `scan.scanned++`, `scan.tallyGate(GateReason)`, `scan.noteBestIdle`, `snapshotProviderReasonLockedEx` (returns `GateReason`, stamps `hbAgeMs`), `buildCandidateGateLocked` (returns `GateReason`), `heartbeatAgeMs`, `calibrationRatio` on the candidate | per-model index loop (`providers := r.providersForModelLocked(model)`), `candidateArena`, `snapshotProviderIntoLockedEx(dst, …, now)`, `buildCandidateInto(c, pr, now)`, value→pointer `routingSnapshot` helpers | Re-derive by hand: the arena variants must return `GateReason`, stamp `hbAgeMs` from the threaded `now`, and set `c.calibrationRatio` (~½ day) |
| `api/consumer.go` | 3 | 166 | #809 `rs.wrote`/`rs.done` relay-stat stamps and `profileClientGone`; #799 `writeChatStreamProviderError` + in-band error select | `chatStreamRelay.handleChunk` and a `finishStream()` closure (`chat_stream_relay.go`, `stream_coalesce.go`) absorb the whole per-chunk path | Move the #809/#799 stamps into `chatStreamRelay`/`finishStream` (~½ day, shared with next row) |
| `api/generic_endpoint_stream.go` | 1 | 25 | #809 `profileClientGone(pr, phaseAfterCommit)` in the completion select | `finishStream()` | Same as consumer.go |
| `registry/ttft_calibration.go` | 1 | 11 | #809 `calibratedTTFTMsWithRatio(snap routingSnapshot, …)` | `calibratedTTFTMs(snap *routingSnapshot, …)` | Keep both, pointer-typed (trivial) |
| `registry/routing_eligibility.go` | 1 | 7 | #809 `providerSupportsPrivateTextLocked` → `GatePrivateText` | `providerSupportsPrivateTextAtLocked(p, now)` | Combine `now` + reason (trivial) |
| `registry/servability_test.go` | 2 | 24 | #791 `coldTokenBudgetEstimate` gained a 5th arg (`modelID`) | `snapPtr(routingSnapshot{…})` pointer form | Take both (trivial); all three remaining 4-arg callers in the merged tree sit inside these hunks |

The merged tree does **not** compile after resolving the six files. Measured (`go build -gcflags=all=-e`
on the scratch merge, with the `strconv` import of H11 restored so `store/` compiles):

| Resolution of the 6 files | Build errors visible | Where | Meaning |
|---|---:|---|---|
| all six → master side | 12 | `registry/`: `scheduler.go` 5, `ttft_shadow.go` 3, `dispatch_plan.go` 3, `servability.go` 1 (`cannot use snap` ×5, `snapshotProviderIntoLockedEx` missing, `kvBytesPerToken` field missing, 3-arg `buildCandidateWithReason`) | perf's auto-merged pointer-typed callers need perf's `scheduler.go` |
| all six → perf side | 15 | `registry/`: `registry.go` 5 (`drainQueuedRequestsForModelsWithReason` ×4 from #809, `reportedFreeForLoadAdmits` arity ×3 from #791), `fleet_sample.go` 4 (H1), `gate_reason.go` 2, `attempt_profile.go` 2 (`ScanUS`/`AdmitUS`), `cold_dispatch.go` 1, `warm_pool_controller.go` 1 | #791/#809's auto-merged code needs master's `scheduler.go` |

`api/` is not type-checked in either row (it sits behind the failing `registry/` package), so both counts are
floors. Neither side can be taken wholesale: `scheduler.go` must be re-derived (hazards H1–H3).

### B. Provider-optimization coordinator commits → master

| Pick | Conflicted files (hunks/lines) | Auto-merged |
|---|---|---|
| `cherry-pick 773bee1b3` alone | 5: `consumer.go` 1/42, `dispatch.go` 4/50, `provider.go` 3/30, `registry.go` 1/9, `scheduler.go` 2/17 | 61 files, +7,176 / −74 |
| `cherry-pick 58d7792da` alone (unstacked) | 21 — of which 12 are modify/delete artifacts (files `773bee1b3` added: `retry_after.go`, `attempt_outcome_metrics.go`, `drain_state.go`, `completion_calibration.go`, `version_reset.go`, `queue_drain_suppress.go`, `eligibility_snapshot.go` + tests). This is the "21" in sysopt-0903's table | 47 files |
| `merge 58d7792da` (stacked — the real number) | 5 coordinator: `scheduler.go` 18/305, `dispatch.go` 5/60, `consumer.go` 3/53, `provider.go` 3/46, `registry.go` 1/9; plus 4 provider-swift: `EngineV2Bridge` 6/159, `MultiModelBatchSchedulerEngine` 3/23, `ProviderLoop+Cancellation` 1/43, `ProviderLoop+InferenceHandler` 2/15 | — |

### C. Perf branch × provider-optimization: the two branches collide with each other

`merge 58d7792da` onto the perf tip → 15 coordinator files: `registry/model_index.go` 3/332 (**both branches add this
file**), `model_index_test.go` 2/613, `scheduler.go` 19/242, `registry.go` 12/105, `tps_registry.go` 5/81,
`solo_tps.go` 3/93, `api/telemetry_sink.go` 10/235, `telemetry_sink_test.go` 1/679, `route_outcome.go` 1/19,
`dispatch.go` 1/17, `consumer.go` 1/12, `dispatch_plan.go` 1/5, `health_ejection.go` 1/13, two test helpers.
`58d7792da`'s "routing scan" bullet (TPS medians memoized at record time, pooled candidate arena, struct-keyed
cooldown map, scan clock passed down, per-model provider index) is a second implementation of perf §4.2; its
four-lane telemetry sink is a second rewrite of perf §4.3. Exactly one implementation per feature can land.
Recommendation: perf's — measured on the 1,260-provider fixture, index == brute-force equivalence tests under
fault state, two reviews per slice (perf report §6).

## Semantic hazards (a textual merge does not flag these)

| # | master (#) | perf branch | Hazard | Class |
|---|---|---|---|---|
| H1 | #809 `registry/fleet_sample.go` (new file, auto-merges) L296/L300 calls `snapshotProviderReasonLockedEx` and `buildCandidateGateLocked`, which exist only on the HEAD side of the `scheduler.go` hunks | replaces them with `snapshotProviderIntoLockedEx` / `buildCandidateInto` | Compile break after resolution unless the arena variants keep a `GateReason`-returning form and the fleet sampler is switched to it | compile |
| H2 | #809 `buildCandidateGateLocked` computes `calibrationRatio` and calls `calibratedTTFTMsWithRatio(snap, …)` by value (auto-merged lines) | `buildCandidateInto` holds `snap := &c.snapshot`; its assignment list predates `calibrationRatio` | Compile break on value/pointer; if the assignment is dropped, the profiler's `TTFTCalibrationRatio` silently reads 0 | compile + silent |
| H3 | #809 stamps `hbAgeMs` inside `snapshotProviderReasonLockedEx` via `heartbeatAgeMs(now, p.LastHeartbeat)` | `snapshotProviderIntoLockedEx` already receives `now` but its field list predates `hbAgeMs` | Forgotten stamp → profiler heartbeat age reads 0; `routing_context_test.go` L723 pins `hbAgeMs: 42` only on the record path | silent |
| H4 | #809 record `Scanned = scan.scanned`; `candidateSetSize = scanned − gateRejections[GateNotServingModel]` | per-model index: the walk only visits providers advertising the model | `Scanned` becomes "advertising count", not fleet size; `GateNotServingModel` tally → 0. Not a bug — a profiler-semantics change to document | semantics |
| H5 | #799 `routingScanSem` in `api/server.go` (`NumCPU` = 30 in prod) around the scan; `routing_scan_limit_test.go` holds slots with `time.Sleep` fakes | reserve scan 323 → 68 µs, preflight 151 → 47 µs | Textually orthogonal (the sem lives in `api/`, the index in `registry/`). The shed threshold was calibrated against the old scan cost — re-measure `errRoutingScanSaturated` after landing; tests unaffected | calibration |
| H6 | #799 Retry-After under distress (`estimateRetryAfter`, `inference_admission.go`, `retry_after_distress_test.go`) | `773bee1b3` adds `api/retry_after.go` (Little's-law, single [1, 60] band, trace-id jitter) | Two Retry-After policies; an owner decision, not a merge task | policy |
| H7 | #809 adds six methods to the `store.Store` interface (`RecordRequestProfiles`, `RequestProfilesSince[Filtered]`, `RecordFleetSnapshots`, `FleetSnapshotsSince`, `PruneTelemetry`), all reached as `s.store.X`; no type assertions on the store in api/registry/cmd | `CachedStore` embeds `Store` (`cached.go` L31–32); `NewCached` wraps at `main.go` L136; optional capabilities go through `store.As[T]` | None — embedding forwards the new methods. `profiler_sink.go` is its own goroutine, not `submitTelemetry`, so perf's post-close rejection in `telemetry_sink.go` cannot drop profile writes | none |
| H8 | #791 `coldTokenBudgetEstimate(…, providerVersion, modelID)`; 16 lines in `scheduler.go`, 179 in `servability.go` | pointer-ifies `freeMemoryAdmits`, `snapshotStructuralBudget`, `providerBudgetFits`, `liveRemainingBudget` | Auto-merges; activation floors untouched by the perf branch | none |
| H9 | #809 `dispatch.go` attempt-profile stamps (`queuedExitOutcome`, `stampClientGone`, +62 lines from #799) | perf `dispatch.go`: 14 lines (`submitRouteRecord` replaces `submitTelemetry(RecordInferenceRoute)`) | Auto-merges; the batched route sink and the profile sink are two independent flush-on-Close paths — order them in `Server.Close` | low |
| H10 | #809 `api/profiler_sink.go` L68 calls `isPowerOfTen` (defined in `telemetry_sink.go` L145) | perf's sink rewrite deletes `maybeLogDrop`/`isPowerOfTen` | Auto-merged file fails to compile (`undefined: isPowerOfTen`); re-add the helper | compile |
| H11 | #809 adds four `strconv.` uses to `store/memory.go` | perf moves route telemetry out of `memory.go` and drops the now-unused `strconv` import | Auto-merge keeps #809's one surviving use and perf's import block → `undefined: strconv`; the whole `store/` package (and everything above it) fails until the import is restored | compile |

## sysopt-0903 overlap

| Item | State at 2026-09-03 ~14:30 PDT |
|---|---|
| Branch `feat/system-optimization-2026-09-03` | 0 commits ahead of `5d400cf75`; `git status --short` = one untracked file (its report). **No code changes.** |
| `docs/reports/2026-09-03-system-optimization-pass.md` | §0 scope + a conflict table; §1–§6 all "_(pending)_". States the intent to port the six 09-02 branches ("reimplement selectively" for wave-2) but names nothing ported or skipped yet. |
| Its conflict table | wave-1 coordinator 5 (matches); wave-2 "21" is the unstacked cherry-pick artifact (real stacked set: 5 coordinator + 4 Swift); perf program 6 (matches). Says `go build/vet` is clean on master and that the perf bench harness vets clean against master. |
| Feature presence (worktree == master) | `NewCached`, `providersForModelLocked`, `candidateArena`, `RecordInferenceRoutes`, `stream_coalesce`, `fleet_scale_bench_test`, `perf_e2e_test`, `model_swap_coalesce`, `chatStreamRelay`, `snapshotProviderIntoLockedEx`: all absent. (`inference_preprocess.go` and `telemetry_sink.go` pre-exist on master; the perf branch modifies them.) |
| Risk | Its plan is to hand-port the same work while the perf branch is a complete, reviewed, benchmarked implementation. Two sessions porting the same code into different branches = a third `model_index.go`. Coordinate before it writes `registry/` code. |

Overlap by perf-report section:

| Perf § | Files | Conflicts vs master | Semantic hazard | In sysopt-0903? | Recommendation |
|---|---|---|---|---|---|
| 4.1 store read-through cache (`store/cached*.go`, `as.go`, `cmd/main.go`) | 22 store files + main.go | none | H7 none | no | land as-is (PR A) |
| 4.3 route-telemetry batching (`api/telemetry_sink*.go`, `route_telemetry_submit.go`, `store/*route_telemetry*.go`) | api + store | none vs master; collides with `58d7792da`'s sink lanes | H9 low | no | land perf's (PR A); drop `58d7792da`'s sink rewrite |
| 4.3 Credit CTE collapse (`store/postgres.go`) | store | none | none | no | land (PR A) |
| 4.4 streaming relay + read-cache endpoints (`chat_stream_relay.go`, `stream_coalesce.go`, `sse_normalize_gate.go`, `models_cache.go`) | api | `consumer.go` 3/166, `generic_endpoint_stream.go` 1/25 | #809/#799 stamps must move into the relay | no | land (PR A) after hand-merge |
| 4.6 request-body pipeline (`inference_preprocess.go`, `provider_body_*.go`, `toolschema_parsed.go`, `request_introspection.go`) | api | none (the consumer.go hunks are relay, not body) | none; §6 notes the generic handlers' `resolveRequestedModel` could fold onto parse-once after #799 — optional | no | land (PR A) |
| 4.2 routing scan (clock hoist, TPS caches, kill-switch/hint skip, version memo + struct keys, in-place snapshots + arena, per-model index, calibrator bound) | registry | `scheduler.go` 10/235, `routing_eligibility.go`, `ttft_calibration.go`, `servability_test.go` | H1–H5 | no | land perf's (PR B) with the `GateReason` re-derivation; drop `58d7792da`'s duplicate |
| 4.5 aggregate/periodic paths (`ListModels`/`evictStale`/`PublicProviderModels` walks) + swap-planner coalescing | registry | none | none | no | land (PR B) |
| bench + gated e2e (`registry/fleet_scale_bench_test.go`, `api/perf_e2e_test.go`) | registry, api | none | none | no (sysopt reports they vet clean on master) | land with PR B / PR A |
| `773bee1b3` non-scan parts: WS fragmentation > 256 KiB, queue-drain dominance skip + 20 ms suppression, drain-neutral faults, prompt-token/completion-length calibration, cascade metrics | api, registry | 5 files vs master (§B) | H6 Retry-After; its queue drain runs on the provider read loop, outside #799's semaphore by design — confirm | no | port as PR C after A+B; Retry-After = owner decision |
| `58d7792da` non-scan parts: cancel hygiene (`cancel_lifecycle.go`, `zombie_stream.go`), `protocol/chunk_scan.go` relay decode, MLX-cache telemetry re-key | api, protocol | `dispatch.go`, `consumer.go`, `provider.go` hunks | #809 cancel-path stamps need a re-check | no | port as PR D after C; drop its scan/index/sink slices |

## Landing plan + effort

Shape: master is squash-only, so "one merge commit vs. a 75-commit rebase" is moot on GitHub — the
resolution happens once by merging master into a copy of the branch, then PR + squash. The six worker
slices interleave inside `scanCandidatesLocked` and `consumer.go`, so six PRs by slice do not split
cleanly; two PRs by file ownership do. **Verified**: perf's `api/`+`store/`+`cmd/` on master's `registry/`
(scratch merge, `registry/` reset to master, the two `api/` conflicts taken from the perf side) builds with
7 errors, every one attributable to the `consumer.go` hand-merge (#799's `maxFirstChunkTimeoutRetries`,
`errRoutingScanSaturated`, `errClientGoneBeforeScan`, `dispatchOneProvider`/`dispatchWithReserver` arity —
i.e. keep #799's lines) plus H10/H11. Perf's `api/` does not depend on perf's `registry/` changes.

| Step | What | Effort |
|---|---|---|
| 0 | Push `worktree-bridge-cse_01TuyfD42fkRyG4ZqSTmeN4U` (never pushed — nothing is on GitHub); tag `5508b4f84` as the measured baseline | 0.1 d (needs explicit user go-ahead) |
| 1 | **PR A — `store/` + `api/`** (§4.1, 4.3, 4.4, 4.6, e2e harness): branch from the perf tip with the `registry/` changes reverted, merge master, resolve `consumer.go` / `generic_endpoint_stream.go` by moving `rs.wrote`/`rs.done`, `profileClientGone`, `writeChatStreamProviderError` into `chatStreamRelay`/`finishStream`; restore the `strconv` import in `store/memory.go` (H11) and `isPowerOfTen` for `profiler_sink.go` (H10); run `stream_burst_test`, `store_cache_http_test`, `telemetry_sink_*`, `EIGENINFERENCE_PERF_E2E=1 go test -run PerfE2E ./coordinator/api/`, lint | 1.5 d |
| 2 | **PR B — `registry/`** (§4.2, 4.5, fleet bench): merge master, resolve `scheduler.go` by re-deriving `snapshotProviderIntoLockedEx`/`buildCandidateInto` to return `GateReason`, stamp `hbAgeMs`, set `calibrationRatio`; switch `fleet_sample.go` to them (H1); document H4 in the profiler docs; run `routing_context_test`, `fleet_sample_test`, the index-equivalence and fault-state fixtures, `reserve_bench_test` | 2 d |
| 3 | Re-measure on the merged tree: `BenchmarkFleetReserveProviderEx[Parallel]`, `BenchmarkFleetQuickCapacityCheck`, `BenchmarkFleetHeartbeat`, `BenchmarkFleetListModels` against master (perf tip: reserve 68–73 µs / 21 allocs vs 323 µs / 824; e2e 954 vs 448 req/s at 1,000 providers) plus the gated e2e; `errRoutingScanSaturated` rate under `routing_scan_limit_test`'s burst | 0.5 d |
| 4 | **PR C** — `773bee1b3` minus the Retry-After decision, rebased on A+B (its 5 conflict files re-resolve against the relay/arena shapes) | 1.5 d |
| 5 | **PR D** — `58d7792da` non-scan parts, rebased on A+B+C | 1.5 d |
| CI | golangci-lint v2.1.6 (`unused`/`ineffassign` — the perf branch already fixed two: `02e1da8d5`, `1d0eea84d`); the `promptcontract` supervisor test flakes under load — rerun, do not "fix" in these PRs; GitHub Codex PR review is the reviewer | — |
| **Total** | A + B + re-measure ≈ 4 d; C + D ≈ 3 d | **~7 eng-days** |

Alternative (not recommended): sysopt-0903 hand-ports piecemeal onto its branch — same conflict set,
no benchmarks or reviews carried across, and a third `model_index.go`.

## Process notes

- Nothing from the three `worktree-bridge-cse_*` branches is on GitHub; none was pushed (memory: every
  push needs explicit user go-ahead). The perf PR body draft is at
  `<branch>:docs/reports/2026-09-02-coordinator-performance-pr-body.md`; the program report at
  `<branch>:docs/reports/2026-09-02-coordinator-performance-program.md` (§4.2 has the per-step ns/op table).
- `.claude/worktrees/refactor` (`refactor/coordinator-modularization`, tip `69f1367c9`, base `331c1a620`,
  14 ahead / 301 behind master, May 30) is stale: it splits api/store/registry into per-domain files and
  would conflict with every file above. Not analyzed further.
- `773bee1b3`'s message calls #799 "proposed"; #799 has since landed. Its queue-drain change runs on the
  provider read loop, outside the routing semaphore by design.
- Scratch worktrees (`wt-merge`, `wt-perf`, `wt-split`, `wt-merge2..4`) were created under this session's scratchpad for the dry runs and compile scenarios, and all removed;
  `git worktree list | grep 0b9e953f` is empty at the end (a sibling agent's `wt-bench-master`/`wt-bench-perf`
  came and went during the run, untouched); the two remaining `scratchpad/` worktrees (`…/7d931d31…/portcheck`,
  `…/e8539310…/pr801`) belong to other sessions. The main checkout at `5d400cf75` was not modified by this
  analysis; its `git status` shows `.github/workflows/ci.yml`, `Makefile`, `docs/AGENTS.md` modified at
  14:15–14:18 PDT by another process (not in the session-start snapshot, not from this work).
