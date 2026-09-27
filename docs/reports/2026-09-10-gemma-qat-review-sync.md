# Gemma QAT: September 10 merge, review fixes and validation

> Last updated: 2026-09-10 · commit `b4b8797ae`

**Review fixes and 799 selected Swift tests pass; qualification of the new runtime remains incomplete.** Repeated M5 contention interrupted the matching ordinary-decode attempts and prevented the new B4/HTTP checks. Both PRs are ready for review and mergeable at the recorded snapshot, but the outstanding model/serving evidence still blocks a claim that the September 10 runtime is fully qualified for release.

Scope is `gemma-4-26b-qat-4bit` with paged attention, SSD prefix caching and automatic MTP. Gemma 8-bit is excluded. Earlier measurements remain in the frozen [September 8 defaults report](2026-09-08-gemma-qat-defaults.md) and [native review-fix report](2026-09-08-gemma-mtp-review-fixes.md); they are not relabeled as measurements of this runtime.

## Merged source and review fixes

Parent master was integrated through `403b6c73c`, and native main through `753f8a3`. The later parent merge `b4b8797ae` adds coordinator warm-pool/headroom changes; `provider-swift`, `libs` and `scripts/benchmarks` remain byte-identical to runtime export `fe423c033`. The source comparison is retained in the [common evidence archive](evidence/2026-09-10-gemma-qat-review-sync/common.tar.gz).

| Finding or merge concern | Resulting behavior and evidence |
|---|---|
| Retained targets were counted as evictable during optional assistant preparation | `MTPStagingReservations` pins identity before the first catalog suspension. Cold admission, memory/slot eviction and idle eviction exclude retained targets, with a final post-await check before removal. Explicit retirement retains the corresponding memory charge until the actual owner is released. |
| Discarded or failed preparation left survivor KV grants reduced | Network cleanup releases actual prepared/staged references, removes accounting and regrows survivors under the reslice gate. Standalone cleanup joins its load gate before release/regrowth, including cancellation. Weak-owner and real-grant tests cover stale unload/reload, failure and queued discard. |
| Staging changed load headroom without promptly changing the capacity quote | Retention/reservation changes refresh capacity immediately. A strict staging-generation guard rejects stale suspended snapshots. Regressions verify pre-lookup publication, staged quote reduction and restoration without waiting for a heartbeat. |
| Native merge could lose request-generation identity when excluding assistant prefill | Launch-generation identity survives filtering. Both prefill-present/absent cases execute, alongside reused-ID widths 1/2/4, stale in-flight completion, drain and unrelated-finish controls. |
| Previous native review fixes must survive the merge | Exact verification-row warmup runs both 3→4 and 4→3 directions; whole-window warmup runs widths 1/2/4. Existing request-generation and accounting regressions remain selected. |

Provider fixes are in `213b8c2b6`; the native merge and prefill regression are in `753f8a3`. Network implementation is in `ProviderLoop+MTPUpgrade.swift`, `ProviderLoop+ModelLoading.swift` and `ProviderLoop+Capacity.swift`; standalone implementation is in `StandaloneServer+MTPUpgrade.swift` and `StandaloneServer.swift`, under `provider-swift/Sources/ProviderCore/`.

## Runtime identity

| Component | Revision or SHA256 |
|---|---|
| Provider runtime export | `fe423c033a4c06151bbda157ed87ec58db898778` |
| Current parent, same provider/native runtime source | `b4b8797ae00aca878d8ead54bd33faa53339b9ed` |
| mlx-swift-lm | `753f8a3f96cb216afc93f5f7e8561038a3ad9b7d` |
| mlx-swift | `6d6796d7a81b656d2749d39067e0a6bea2bc2986` |
| MLX core | `3fa8f25e6451174d7b06be372c3a24272b77d88e` |
| mlx-c | `02cf6f4d099023e4e0c0357248b8b3f83110e29d` |
| `radix-engine` | `a0f953b83ef8bd65d0dbbd3d442557cb0b35fff80ce63281d436d33ea64d0bf1` |
| `darkbloom` | `b4bb26b39e1e361170091ce567efcec731dc162897851e39264b14d2edca97c9` |
| `mlx.metallib` | `20972c37e53fe6db3b3191a0434f6604c4ffc4f5ac62b370574f9922585b0fdb` |

All 2,827 native manifest files matched independently on M5 and the pinned local checkout. The complete provider export manifest is retained with SHA256 `90e8e4a52899eddfa4833059a5d9c4497a9da031f6e49b81d8ad42cf35e84af4`. The rebuilt metallib is byte-identical to the earlier artifact; the new binary and reported loaded-metallib identities are checked separately.

The target download verified all ten files, totaling 15,641,239,295 bytes, against aggregate `2468a0cb3049a871f42052f4d9f9380bf12a0792f64c7a29f768559fc7d28785`. Existing partial files were resumed and hashes checked before publication. These receipt details are in the common archive. The assistant remains pinned to HF revision `bb94eae1b70a80dac16cbf959bb4b7d56bd1fb8c`; its prior verified-byte evidence and rollout catalog patch remain in the September 8 report. The native model cell uses a verified local assistant override, so it does not establish public HF-first download behavior.

## Completed builds and tests

The counts below come from actual terminal summaries and individual pass lines, without counting package aggregate lines twice.

| Run | Swift Testing | XCTest | Result |
|---|---:|---:|---|
| Native, selected merged-source suites | 315 tests / 34 suites | 106 tests / 18 suites | PASS, no recorded skips or failures |
| Provider, expanded selected filter | 345 tests / 32 suites | 0 | PASS, no recorded skips or failures |
| Benchmark package | 31 tests / 9 suites | 2 tests / 1 suite | PASS, no recorded skips or failures |
| Total | 691 | 108 | **799 tests passed** |

Native tests include synthetic Nemotron, shared paged attention, recurrent rollback, checkpoint ownership, mutable input and parser coverage. No real Nemotron artifact suites were run. The provider filter explicitly selects all 11 intended suites whose names differed from their files, plus all 47 top-level tests in the selected budget/admission/standalone preparation files. Each has an actual pass event. The unmatched legacy `BenchmarkPromptContractTests` filter token is retained but not claimed as coverage.

The initial `77df6e438` provider test build failed at three exhaustive switches after upstream added `MLXServerGenerationEvent.parsed`. Test-only commit `fe423c033` preserves parsed output in the wiring comparison, appends visible Gemma content and records Qwen visible/reasoning content. The three errors and raw failed log remain in the provider archive. The corrected test build passed without removing assertions. Live Gemma/Qwen canary files compiled, but their real-model suites were not selected. Compiler warnings remain visible in the raw logs.

Separately, all **87 Python benchmark tests** pass; they are not included in the 799 Swift total. Full Go tests, Go formatting, console TypeScript lint and the Next.js build passed under repository-pinned Go 1.25.0. A separate run under unpinned Go 1.27.1 failed JSON-encoding compatibility assertions; its raw log and five reported test failures remain retained. They are not passing results or a reason to change this release's pinned toolchain. [Native evidence](evidence/2026-09-10-gemma-qat-review-sync/native.tar.gz), [provider/benchmark evidence](evidence/2026-09-10-gemma-qat-review-sync/provider.tar.gz), [Go/console evidence](evidence/2026-09-10-gemma-qat-review-sync/common.tar.gz).

## Completed new model arm: B1 automatic MTP on2

The cache-on, adaptive-MTP B1 arm completes all six 1,024-token-capped requests and passes structural tenant, cancellation, cache and retirement checks. Each repeated request consumes one staged SSD checkpoint, reads two files and replays zero tokens. All measured MTP rounds are rectangular.

| Request | Decode tokens/s | TTFT ms | Saved prefix tokens | MTP rounds / seeds |
|---|---:|---:|---:|---:|
| Code first | 126.49 | 1816.0 | 0 | 525 / 3 |
| Code repeat | 123.35 | 206.3 | 8192 | 426 / 9 |
| Prose first | 117.55 | 992.2 | 0 | 120 / 8 |
| Prose repeat | 117.60 | 257.6 | 4096 | 120 / 8 |
| Extraction first | 135.39 | 1343.6 | 0 | 511 / 1 |
| Extraction repeat | 136.23 | 180.8 | 6144 | 511 / 1 |

These are absolute on-arm measurements. **No new speed gain is claimed until the matching off arm completes.** All six outputs finish at the length cap, so this cell does not test natural-stop HTTP shaping. Final retirement records zero process owners/charges and zero live paged/staging/write-host usage. [On2 report, identity, synthetic input and independent semantic probes](evidence/2026-09-10-gemma-qat-review-sync/b1-on2.tar.gz).

Both completed code prefixes reproduce the known source-ID defect: equal event IDs from two different sources are treated as globally duplicated, producing aggregate 10 where the requested `(source,event_id)` identity requires 20. Both also accept timezone-naive timestamps. These errors occur before truncation. They remain generated-answer defects, not proof of cache corruption or a general quality rate. The later interrupted off2 attempt supplies a limited completed-code comparison below; it does not supply a passing matched validation run.

Prose preserves the five district concerns and the distinction between suggestions and approved funding, with minor unsupported framing/attribution and a truncated recommendation. Extraction's eight completed objects match all 72 source fields, but the Markdown fence and unfinished ninth object violate whole-output JSON formatting/completion. Coherent variation is allowed; concrete completed-prefix mistakes are still retained.

Three attempts—on1, off1 and off2—were interrupted when another ranked job appeared. Their metadata and structural verdicts explicitly record `aborted`; none contributes a passing speed comparison. Off2 reached six main requests before interruption, but its remaining lifecycle/cache checks did not complete. Its two completed code prefixes are text-identical and pass source isolation (aggregate 20), while still accepting naive timestamps and silently ignoring a changed-quality retry. This preserves a concrete answer-level difference from on2; it does not establish a quality rate or identify cache corruption. [Interrupted attempts](evidence/2026-09-10-gemma-qat-review-sync/interrupted-b1-attempts.tar.gz).

## Outstanding qualification at this snapshot

No further model or GPU work was run after the third interruption. Continuous use of the dedicated M5 by other ranked work prevented completion of the following checks. The September 8 report remains the authority for its earlier complete model/HTTP measurements.

| Check | Current status |
|---|---|
| Matched B1 cache-on ordinary decode | **INCOMPLETE:** no completed off arm. A new pair must use identical binary, input and model with matched SSD configuration, recording each arm’s distinct cache numerics identity before comparing throughput and answer semantics. |
| B4 repeated-prefix and changed-question branches | **NOT RUN on new artifacts:** actual target-forward width, answers, SSD counters and clean retirement remain unverified by a new model run. |
| Default-auto HTTP delayed assistant activation | **NOT RUN on new artifacts:** natural SSE stops, activation exposure, TTFT and content-gap observations remain pending. |
| HTTP assistant download failure | **NOT RUN on new artifacts:** target-only availability and cleanup under injected download failure remain pending. |
| Same-process vision and tool capability checks | **NOT RUN on new artifacts:** exact outputs, MTP exposure and format caveats remain pending. |

## Review and operational status

At **2026-09-10 22:59:36 UTC**, [provider PR #872](https://github.com/Layr-Labs/d-inference/pull/872) and [native PR #144](https://github.com/Layr-Labs/mlx-swift-lm/pull/144) are non-draft and GitHub reports `MERGEABLE`. All three provider and both native review threads are resolved. The common archive retains the timestamped PR/check snapshot, resolution responses and final review-thread inventory; no additional finding was present in that review snapshot.

Provider Tests, Coordinator Tests, lint, console build, prompt-sidecar tests, release integrity, docs lint and CodeQL checks are green at that snapshot. E2E Integration is running; E2E Benchmarks is waiting. Threat Model Review fails with an external HTTP 401/invalid API key. These states are recorded as observed; ready/mergeable does not mean every CI check has passed. Refresh them before the actual merge.

Merge native first, update the provider pin to the merged native revision, then verify the resulting dependency/check state before provider merge. Production catalog activation and release publication remain separate actions. The local measurements and simulated provider fixtures do not establish physical fleet equivalence, public HF availability, signed-app Keychain persistence or an OS-process restart guarantee.

The cleanup receipt confirms removal of all ten task-owned scanner links and four empty scanner directories. The verified downloaded model remains in the task-owned validation directory; other jobs are preserved. The receipt is included in the common archive.

## Evidence inventory

The five linked archives contain raw logs, summaries, exact filters/test names, manifests and hashes; their internal Markdown stays inside archives to avoid introducing unindexed documentation pages. [Archive inventory](evidence/2026-09-10-gemma-qat-review-sync/INVENTORY.json) and [SHA256 checksums](evidence/2026-09-10-gemma-qat-review-sync/SHA256SUMS) cover this frozen status snapshot. Any later qualification run requires a new dated record with its own artifact identity and outcomes.
