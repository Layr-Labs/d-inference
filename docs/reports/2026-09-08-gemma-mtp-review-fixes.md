# Gemma MTP: review findings and regression fixes

> Last updated: 2026-09-08 · commit `fce72956c`

Both automated P2 findings on native PR #144 are reproducible and warrant fixes. They concern adaptive MTP performance measurements: request-generation isolation and exact verification-shape warmup. The provider PR #872 review reported no findings at the checked revision.

## Findings and resulting behavior

| Finding | Reproduction on native `b87e2ee1b` | Fix |
|---|---|---|
| Reused request IDs retain old workload measurements | B1/B2/B4 reuse retains learned costs instead of requiring fresh chained calibration; callbacks after finish revive seed/cost state | Finish or drain invalidates the participating workload, clocks and pending seed ledger. Launch-generation stamps reject late baseline, cost, acceptance and seed-claim callbacks, including after a new same-ID workload starts. Unrelated finishes and surviving rows' carries remain intact. |
| B3/B4 share warmup despite different physical shapes | Both 3→4 and 4→3 count a simulated cold compile: a 1,105 ms window replaces the intended 105 ms steady window and selects ordinary decoding | Warmup knowledge is engine-scoped and keyed by exact physical row count and draft depth. Returning to an already warmed exact shape includes its complete seed/time/output interval. |

The request-generation token is captured at launch and preserved when a measurement is attached to the in-flight step. This matters because a chained successor can already be launched before the preceding request finishes. Dropped learning samples still retain executed verification time in cumulative telemetry. Fixed-depth and stateful policies keep their accounting.

Code: `CBv2MTPDepthController`, `CBv2MTPRoundDriver`, `EngineLoopV2+MTPMeasurement`, and `EngineLoopV2+MTPFinalize` under `libs/mlx-swift-lm/Libraries/MLXLMCommon/ContinuousBatchingV2/MTP/`.

## Validation

The shape regression failed on the reviewed native revision with four assertions across both transition directions. The original lifecycle regression failed with nineteen assertions across reused B1/B2/B4 cohorts and late callbacks; unrelated finish and fixed-depth controls passed. The original red lifecycle fixture is retained because final coverage additionally exercises launch-generation APIs introduced by the fix.

The fixed native revision `74f10136f504404ec85259facc1b2365d5d948e6` passes **179 Swift Testing tests in 20 suites and 25 XCTest cases** on the dedicated M5 Max. The strict resolved-version release test build passed. Coverage includes fresh calibration after B1/B2/B4 ID reuse, stale-generation callbacks after a new workload starts, seed-ledger isolation, drain, unrelated finish, fixed-depth accounting, both B3/B4 shape transitions and exact-shape reuse, plus the existing cache/rollback/Qwen suites. All six changed source/test files were hash-verified on the test machine.

The prior [Gemma QAT benchmark report](2026-09-08-gemma-qat-defaults.md) retains its original runtime and binary identities. This review fix changes controller bookkeeping and does not change target/assistant arithmetic, cache matching or artifact delivery. The full real-model performance matrix was not rerun for this narrow fix; its previous measurements are not relabeled as measurements of the new revision.

## Evidence

- [Shape regression failure](evidence/2026-09-08-gemma-mtp-review-fixes/pr144-shape-regression-red.log.gz)
- [Lifecycle regression failure](evidence/2026-09-08-gemma-mtp-review-fixes/pr144-lifecycle-regression-red.log.gz) and [original red fixture](evidence/2026-09-08-gemma-mtp-review-fixes/review-lifecycle-red.swift.gz)
- [Final native build](evidence/2026-09-08-gemma-mtp-review-fixes/pr144-review-green-build.log.gz) and [native test results](evidence/2026-09-08-gemma-mtp-review-fixes/pr144-review-green-tests.log.gz)
- [Changed source hashes](evidence/2026-09-08-gemma-mtp-review-fixes/pr144-review-source-manifest.json), [remote verification](evidence/2026-09-08-gemma-mtp-review-fixes/pr144-review-source-verification.json) and [commands](evidence/2026-09-08-gemma-mtp-review-fixes/run-pr144-review-green.sh.gz)
- [Evidence checksums](evidence/2026-09-08-gemma-mtp-review-fixes/SHA256SUMS)
