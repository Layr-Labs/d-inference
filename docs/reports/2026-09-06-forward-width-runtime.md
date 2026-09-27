# Actual forward-width runtime build and native validation

> Last updated: 2026-09-06 · commit `2f7e4dd06`

The instrumented runtime builds on M5 and passes the four requested native suites. It observes actual target-call row and sequence dimensions, so queued concurrency, speculative columns and padded compiled components cannot stand in for batched target execution. This milestone does not certify real-model B2/B4 throughput or the six-artifact matrix.

| Native suite | Test functions | Result |
| --- | ---: | --- |
| `CBv2ForwardShapeTests` | 8 | Pass |
| `CBv2ForwardShapeEngineTests` | 3, with 5 executed cases | Pass |
| `GPTOSSCompiledExpertsTests` | 5 | Pass |
| `CBv2MTPRoundSmokeTests` | 11 | Pass |

All suites use `--no-parallel` and locked dependency resolution, with no skipped tests. The engine tests exercise packed versus split leaves, refusal before and after dispatch, and first-scope refusal while a discarded chained successor awaits readback. Compiled and MTP tests cover their real native paths. Entered calls remain distinct from completed readbacks; these counts are not Metal kernel-launch geometry.

Two test-fixture failures remain preserved. The original zero-layer model supplied no row-storage anchor; adding a layer alone still left KV offsets unchanged and made rollback invalid. The final fixture performs actual cache update and attention inside each observed leaf, preserves token-1 output and the prior assertions/barriers/timeouts, and adds offset-progression assertions. Only `CBv2ForwardShapeEngineTests.swift` differs between native runtime `ff1aab108da0d575258ba9425d5b763c0045ba66` and tested fixture successor `f2d79145e040bbc28c6e0e355a19bc8923a70434`; their runtime Library trees are identical.

The runtime parent is `682e268ed3ab54f85371d079204f8091f911afd8`, native `ff1aab108da0d575258ba9425d5b763c0045ba66`, Swift `9561227d55a07db29f70a78aadc5d6b5aaeb10bf`, core `fab0f39f69140393b454c32d6f4bf7a9b32f9dcc`, and C `d4328f2d8d54d711d5419e07ab9fa2f07b512a48`. The parent adds the tracked executable lockfile without changing the reviewed provider's 36 dependency pins. Native tests use the corresponding 31 external pins after the reviewed local Swift edit. Missing-lock, unavailable-revision, source-graph rejection and interrupted-build attempts are retained.

ROOT independently checked 1,045 benchmark, 1,302 provider and 796 native-test source-graph entries, including 12 Git-bound source aliases. The official JIT generator reproduces both quantized host sources. The freshly built metallib remains bound across lock and test-only repairs. All eight remote artifact files match their hashes and modes; both executables pass strict ad-hoc signature verification. This is not Developer ID signing or persistent-key restart validation.

Artifact manifest SHA-256: `77e029d8e05cf5a34ad7300b19b6a7db8e506a93ae1854162765a73f7781c351`. The benchmark executable is `45902130972c52365db3b1278236f9322a617feab9ab369124f305b11e5fc2d2`; provider CLI is `21c258a024b9218db74d4a50ad05e0d71706c8f96ea36fcec1b2e2a6250f5428`; metallib is `22497b094bbae98a07db9b088bddfe825ea1150d61fd77ac35592a29528abbaa`. All 49 recorded successor process IDs retired, and final host inspection found no unexpected workers.

The [evidence manifest](evidence/forward-width-runtime-2026-09-06/manifest.json) binds raw build/test logs, every failed attempt, source/dependency graphs, fixture patches, resource/signature proofs and independent ROOT checks. Binary and model-weight payloads are excluded; their identities are recorded. The [benchmark procedure](../developer/test.md#prefix-cache-benchmark-validation) defines the next real-model gates. Full matrix execution, numerical closure, physical two-host behavior, signed persistence and release activation remain open.
