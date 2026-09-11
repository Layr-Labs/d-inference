# GPT-OSS 20B default SSD prefix-cache qualification

> Last updated: 2026-09-11 · commit `6938e8547`

Exact `gpt-oss-20b` passes the bounded runtime qualification for default encrypted SSD prefix caching on the measured M5 Max: optimized selected tests, real-checkpoint reconstruction, concurrent different suffixes, B1/B2/B4 cache comparisons and five standalone HTTP requests. Across the benchmark matrix, all 84 workload answers and 30 isolation/recovery control answers pass; median paired warm-hit TTFT reductions are 86.25%, 88.79% and 91.28% at B1, B2 and B4.

These results qualify the measured artifact and scopes below. They do not establish broad model-quality equivalence, production Keychain recovery, coordinator routing or a fleet release. Standalone HTTP still exposes raw Harmony framing and omits cached-token usage; its passing result covers serving, extracted final answers, MTP posture and encrypted persistence. Direct cache-hit proof comes from the native and benchmark tests. The [machine-readable summary](evidence/2026-09-11-gptoss-default-prefix-cache/summary.json) retains these distinctions.

## Implementation and provenance

`PrefixCachePolicy.isEnabled` now enables SSD caching for exact `gpt-oss-20b`. The existing loaded historical-attention capability restores full-attention rows and sliding-window state together at a complete checkpoint boundary. It does not pay the older attention-only replay path's 1,536-token recomputation bound.

Fresh load hashes, prompt/runtime identity, authenticated payloads and tenant scope still gate reuse. A miss, explicit `DARKBLOOM_PREFIX_CACHE=0`, or resolved contiguous backend computes cold. Other GPT-OSS IDs and resident retention remain opt-in. Automatic GPT-OSS MTP stays inactive. No native production change, dependency bump, provider version bump or catalog mutation is included.

The [final source binding](evidence/2026-09-11-gptoss-default-prefix-cache/final-source-binding.json) verifies all compiled inputs against `6938e8547963739f17f2b18fcbe2057aef20250f`. The export inventories 5,063 files; only `docs/consumer/models.md` and `docs/developer/test.md` differ from that revision. Production source is unchanged since implementation commit `0b0a3304ff009f2cd1a5902349fab50371bd8bea`; subsequent changes strengthen tests and correct their scope. Individual earlier runs retain their original identities.

| Component | Identity |
|---|---|
| Fresh master base / version | `ef7b5a9aa69e62374c83d8f2baddb2957e38c9a8` / v0.9.2 |
| Validated compiled inputs | `6938e8547963739f17f2b18fcbe2057aef20250f` |
| MLX core, top-level and Swift nested | `3fa8f25e6451174d7b06be372c3a24272b77d88e` |
| MLX C | `02cf6f4d099023e4e0c0357248b8b3f83110e29d` |
| MLX Swift | `6d6796d7a81b656d2749d39067e0a6bea2bc2986` |
| MLX Swift LM | `ce446cc5f76e013855fe0bde9002b6db1ac091b7` |
| Provider binary SHA-256 | `089d95b1f57de8dd78aa331c67aa6dc875c4af38759dcda6a04c6af2d6ec6ff4` |
| Benchmark binary SHA-256 | `acc680482724b1016ab1734ab3b7378fbe96954861200d2251ba28e7a7e5b60b` |
| Source-matched metallib SHA-256 | `20972c37e53fe6db3b3191a0434f6604c4ffc4f5ac62b370574f9922585b0fdb` |
| Exact model / catalog version | `gpt-oss-20b` / `2026-05-25-r1` |
| Model aggregate SHA-256 | `61bfc04e4016a7fa487eb10e29f79360047e302487229f298da3681984aec512` |
| Model files | Ten files, 12,104,215,835 bytes; all sizes and SHA-256 values verified |
| Host | Apple M5 Max, arm64, 128 GiB; macOS 26.5.2 build 25F84 |
| Toolchain | Apple Swift 6.3.1 (`swiftlang-6.3.1.1.2`, `clang-2100.0.123.102`); Xcode 26.4.1 build 17E202 |

## Optimized tests and numerical controls

The final optimized rebuild completed in 204.59 seconds. Its selected Swift Testing aggregate reports **347 tests in 50 suites, passing in 18.423 seconds, with eight explicit live skips**; XCTest separately passes **13 tests** in 0.268 seconds. These are selected suites, not a full-provider-suite claim. The checkpoint and mixed-suffix live gates were then explicitly enabled and passed separately.

`GPTOSSPrefillOutputTests` and `CBv2Gemma4ScheduledPrefillTests` run as separate strict FP32 controls: **13 tests in two suites passed in 3.403 seconds, no skips**, with `MLX_ENABLE_TF32=0` in a fresh process and unchanged assertions/tolerances. MLX's own `libs/mlx-swift/Source/Cmlx/mlx/python/tests/run.py` uses this setting for regular FP32 tests; `libs/mlx-swift/Source/Cmlx/mlx/mlx/utils.h` (`env::enable_tf32`) otherwise defaults it on and caches the value per process. The measured M5 default TF32 path explains the isolated strict-unit discrepancy. Production model, cache and HTTP runs leave the flag unset.

The final HTTP helper's 16 CPU tests and semantic validator's 11 CPU tests pass. Targeted Go 1.25 default-selection/capability/provider-launch tests also passed. Raw commands, counts, skips and failures are retained; overlapping runs are not summed into a larger pass count. See [test instructions](../developer/test.md#gpt-oss-complete-checkpoint-reconstruction).

## Complete-checkpoint reconstruction

The final strict fixture **passes one live test in 28.507 seconds, with no skips**. It donates an authenticated historical checkpoint, shuts down the engine/store, reconstructs both and asks a different suffix as the new engine's first request.

| Observation | Final result |
|---|---|
| Branch prompt / restored boundary / hit tokens | 6,413 / 6,144 / 6,144 |
| Bytes read for restoration | 308,110,124 |
| Restored / cache-off branch answer | `BRONZE-913` / `BRONZE-913` |
| Changed-prefix / its cache-off answer | `CEDAR-682` / `CEDAR-682` |
| Wrong tenant, changed prefix and cache-off controls | Zero hits; each returns its expected answer |
| Restored / cache-off branch TTFT | 0.2288105 / 1.696873333 seconds |
| Complete branch output equality | `sameText=true` |
| Learned attention sinks, 128-token windows, stage/write retirement | Assertions pass |

This uses a temporary cache root, one ephemeral key retained across reconstruction and test runtime identity. It qualifies engine/store reconstruction, not provider-process restart, production Keychain recovery or cross-binary reuse. The earlier `checkpoint-live-1` also passed; its separate timing pair remains in the capsule and is not substituted for the final rerun.

## B1/B2/B4 cache benefit and task correctness

Each arm contains six cohorts: two record-extraction tasks and one computation, each followed by a repeat. Prompts contain 4,259–4,266 tokens and share an inventory prefix; answers reside in a separate oracle. Date, temperature zero, low reasoning effort, 512-token maximum, paged backend, MTP off and a 107,860,842,572-byte production KV grant are held fixed. Each cache-on cell starts with a fresh ephemeral store.

| Width | Warm TTFT median on / off (seconds) | Median paired warm-hit reduction | Workload answers / authenticated warm pairs | Complete token vectors equal |
|---|---|---|---|---|
| B1 | 0.1519695 / 1.106678458 | **86.25%** | 12/12 answers; 5 hits | 6/6 pairs |
| B2 | 0.215397375 / 1.9288143125 | **88.79%** | 24/24 answers; 10 hits | 10/12 pairs |
| B4 | 0.320586 / 3.528612 | **91.28%** | 48/48 answers; 20 hits | 18/24 pairs |

All **84 workload answers plus 30 naturally completed isolation/recovery control answers pass**. The **35 authenticated warm pairs** restore/save 4,096 tokens each with zero replay; first cohorts miss. Every main B2/B4 cohort in both arms contains completed native target-decode calls at its requested width. Submission count is not the concurrency proof. The [B1](evidence/2026-09-11-gptoss-default-prefix-cache/b1-validation.json), [B2](evidence/2026-09-11-gptoss-default-prefix-cache/b2-validation.json) and [B4](evidence/2026-09-11-gptoss-default-prefix-cache/b4-validation.json) projections preserve paired observations and semantic checks.

The percentage is the median of per-row reductions, which need not equal the reduction computed from the two displayed medians. Cold-first costs are excluded. These few cohorts do not establish statistical significance or fleet-wide performance. Concurrent per-row decode rates include interference from sibling prompt prefills; reducing that interference is not an isolated decode-kernel speedup. B1 decode remains close to 130 tokens/s.

All final JSON answers match across paired arms: 6/6 at B1, 12/12 at B2 and 24/24 at B4. Complete token vectors differ in two B2 and six B4 pairs; the native audit confirms the six B4 differences are analysis-only. These token differences remain recorded. Passing bounded task answers does not prove general answer-quality equivalence or exact numerical state equality.

The matrix duplicates one prompt per simultaneous cohort; different suffixes occur in successive cohorts. Concurrent different suffixes are qualified separately below. The existing harness also checks tenant isolation and cancellation after restoration followed by recovery.

## Concurrent different suffixes

The final mixed-suffix fixture **passes one live test in 49.100 seconds, with no skips**. It submits through the production bridge, compares cold controls against restored branches, reverses B2 ordering, and combines matches with another tenant and a changed early prefix.

All **23 request answers pass**; ten requests each restore **6,144 tokens**. Completed native decode peaks are:

| Cohort | Submitted requests | Observed native decode peak |
|---|---:|---:|
| Cache off, B2 | 2 | 2 |
| Cache off, four submitted | 4 | 3 |
| Cache off, mixed four | 4 | 3 |
| Cache on, B2 / reversed B2 | 2 / 2 | 2 / 2 |
| Cache on, B4 | 4 | 4 |
| Cache on, mixed four | 4 | 4 |

The cold four-submitted control requires at least width two; it does not claim cold width four or matched width-four performance. Cache-on B4 requires actual width four. Each request must return its own answer and correct hit/miss accounting; safe cold misses remain allowed when concurrent staging cannot admit every candidate, with consumption checked against actual hits. Stage reads, consumption and drained admission/KV reservations pass. First-observed chunk times can include buffered output and are not benchmark TTFT.

## Standalone default HTTP serving

The third standalone attempt **passes all five requests** with HTTP 200, SSE DONE, usage and natural finish. Cache, resident, backend, MTP and assistant selection overrides are absent; the helper supplies isolated test paths, an ephemeral key and a one-second cache-stat observation cadence. Actual metrics show GPT-OSS MTP inactive, encrypted checkpoint files exist, and all ten owned scanner links are removed with no guard or cleanup errors.

| Request | Extracted final answer | TTFT (seconds) |
|---|---|---:|
| Cold | `ALDER-427` | 19.028032 |
| Repeat | `ALDER-427` | 0.446297 |
| Different suffix | `BRONZE-913` | 0.432129 |
| Different-suffix repeat | `BRONZE-913` | 0.429993 |
| Changed early prefix | `CEDAR-682` | 1.407096 |

Cold HTTP TTFT includes fresh model hashing and model load; it is not an isolated prefill baseline. **Cached-token usage is absent in all five responses**, and the standalone metric surface exposes neither a KV-backend metric nor an observed activation log in this run. Missing fields are not interpreted as zero hits, and the HTTP result makes no direct cache-hit or timing-speedup claim. Native and radix results provide direct restoration/backend evidence.

All five raw responses contain Harmony analysis/final framing in `content`. The oracle extracts the canonical final answer while retaining raw SSE/text unchanged. This existing transport limitation is not fixed or hidden by the cache qualification; no clean-presentation claim is made. The default 900-second TTL is left unchanged, but expiration is not tested. A connected coordinator/provider live run is outside this report; its Go helper expectations are updated and CPU-tested only.

## Retained failures and corrections

| Attempt | Retained result and bounded correction |
|---|---|
| Initial optimized selected run | Failed: 360 reported Swift tests/51 suites, 133 issues and seven explicit live skips; XCTest 13 passed. Of the issues, 128 were strict GPT prefill comparisons, one was the strict Gemma scheduled-prefill control, and four were an obsolete GPT cache-disabled expectation. Separate TF32-disabled controls resolve the 129 numerical-control issues without assertion changes; `ec3b0e65e` corrects the requested cache-default expectation. The original failed log remains unchanged |
| Revision-two selected run | Passing aggregate: 346 Swift tests/49 suites, seven live skips, plus 13 XCTest. Superseded for final counts by the retained revision-four run; not added to it |
| Initial B1 semantic parser | Failed because canonical `<\|return\|>` framing produced `observed: null`. The final-channel parser recognizes that terminal marker while rejecting trailing prose. The corrected validator passes over the same unchanged model reports; no model rerun was used to correct this parser result |
| Initial B4 cache-on launch | Thermal guard refused before model execution: 42.5588 °C exceeded the 42 °C ceiling. Measured B4 uses `b4-on-2`, not the refused `b4-on-1` |
| Initial mixed-suffix run | Failed one cold-width assertion: four submitted cold requests reached native width three, not the expected four. All 23 answers and ten 6,144-token hits passed; cache-on B4 actually reached four. `49b62bfe6` corrects the cold control's scope; the fresh final mixed run passes. The first run remains failed |
| HTTP attempt one | Aborted before a completed report row: the ownership guard mistook the provider's own separate-process-group `runtime-smoke` child for a foreign job. Raw disconnection, guard and cleanup `PermissionError` remain retained. All links were removed; an independent retirement receipt confirms both owned PIDs gone and scanner absent. The corrected guard tracks owned descendants and rejects unrelated jobs |
| HTTP attempt two | Failed the response oracle on raw Harmony framing despite the correct final marker. The final oracle extracts the canonical final channel and retains raw content; attempt three is a separate passing run. This is a helper correction, not a transport fix |
| Intervening rebuild launch | Guard refused before build because a foreign `Runner.Worker` occupied the M5. The foreign job was left running; final build and model checks ran after the lane became available |

The [September 6 B2 failed pilot](2026-09-06-gptoss-b2-cache-divergence.md) is untouched. It remains a failed strict token-parity record: cached repeat b0 differed at 123 of 128 positions despite reporting 5,120 saved tokens. Scheduling-dependent numerics was an inference, not an established cause. This work neither retroactively passes that pilot nor attributes it to TF32 without separate evidence. Exact token equality, task correctness and authenticated cache-state correctness remain distinct; coherent text alone is not a correctness oracle.

## Evidence and reproduction

The [runtime capsule](evidence/2026-09-11-gptoss-default-prefix-cache/runtime.tar.gz) contains **215 regular files** and has SHA-256 `617b68dd991940d5f611cc5c9014f0e41d502f6d7c1d87896c216e6fff7a5a0d`. The [runtime inventory](evidence/2026-09-11-gptoss-default-prefix-cache/INVENTORY.json) records each member's SHA-256; all members were verified against it. The [local-check capsule](evidence/2026-09-11-gptoss-default-prefix-cache/local-checks.tar.gz) contains 11 files, including host/toolchain, helper tests, parser receipts and independent retirement; its [inventory](evidence/2026-09-11-gptoss-default-prefix-cache/LOCAL-INVENTORY.json) binds those files. [SHA256SUMS](evidence/2026-09-11-gptoss-default-prefix-cache/SHA256SUMS) binds the published projections and archives.

Paths below are archive members, not additional repository files:

| Evidence | Location |
|---|---|
| Initial and final selected tests / final build | Runtime: `logs/provider-tests.log`, `logs/provider-tests-revision2.log`, `logs/provider-tests-revision4.log`, `logs/provider-test-build-revision4.log`; `job-logs/provider-final-1.json` |
| Strict numerical controls | Runtime: `job-logs/native-fp32-controls.log` and `.json` |
| Checkpoint first/final runs | Runtime: `job-logs/checkpoint-live-1.log` / `.json`, `job-logs/checkpoint-live-2.log` / `.json` |
| Mixed initial/final runs | Runtime: `job-logs/mixed-live-1.log` / `.json`, `job-logs/mixed-live-2.log` / `.json` |
| Matrix raw reports | Runtime: `results/b1-on-1/report.json`, `results/b1-off-1/report.json`, `results/b2-on-1/report.json`, `results/b2-off-1/report.json`, `results/b4-on-2/report.json`, `results/b4-off-1/report.json` |
| Thermal and occupied-host refusals | Runtime: `job-logs/matrix-b4-on-1.json`, `job-logs/provider-revision4.json` |
| HTTP three attempts, raw SSE, requests, answers, metrics and cleanup | Runtime: `results/http-default-cache-1/`, `results/http-default-cache-2/`, `results/http-default-cache-3/` |
| Final and earlier helper versions | Runtime: `http/`, `http-before-owned-child-fix/`, `http-before-final-channel-fix/`, `validation/`, `validation-before-harmony-fix/` |
| Host, toolchain, helper tests and independent HTTP retirement | Local checks: `receipts/host.txt`, `receipts/toolchain.txt`, `receipts/http-helper-final-tests.log`, `receipts/validator-final-tests.log`, `receipts/http-attempt1-retirement.json` |
| Initial/fixed B1 parser receipts | Local checks: `results/b1-validation-initial.json`, `results/b1-validation-harmony-fixed.json`; final accepted projection also published as `b1-validation.json` |

Runs use one owned M5 lane, sequential process ownership and guards that refuse competing work. Test keys are ephemeral; no production deployment, release publication, model-catalog change or routing activation is recorded. This frozen report binds implementation `6938e8547` and its evidence, not a future report-containing commit. Live CI, mergeability, comments and Codex review belong in [PR #894](https://github.com/Layr-Labs/d-inference/pull/894).
