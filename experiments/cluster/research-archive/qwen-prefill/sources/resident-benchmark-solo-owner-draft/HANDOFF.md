# Resident solo owner draft

This adds one full-model resident owner for one through four already-admitted registered 9B `8192/512/B1/output1` requests. The worker fixes its study cohort to four requests and one excluded warmup. It owns early process arithmetic admission, actual OS/resource checks, deadlines, command IO and output publication. No worker CLI, resource limit, provider eligibility or model arithmetic is changed here.

The four runtime sources are `QwenLongPrefillResidentRequestStep.swift`, `QwenLongPrefillResidentSoloAdmission.swift`, `QwenLongPrefillResidentSoloReport.swift` and `QwenLongPrefillResidentSoloOwner.swift`. All existing request, loader and gate sources are dependencies, not replacement files.

## API

```swift
runQwenLongPrefillResidentSoloCohort(
    options: Options,
    requests: [QwenRegistered9BLongPrefillReferenceAdmission],
    warmupCount: Int,
    onModelReady: (QwenLongPrefillResidentSoloReady) throws -> Void,
    beforeRequest: (QwenLongPrefillResidentRequestStep) throws -> Void,
    onRequestResult: (QwenLongPrefillResidentRequestStep,
                      QwenLongPrefillSoloRequestResult) throws -> Void,
    check: () throws -> Void
) throws -> QwenLongPrefillResidentSoloReport
```

All callbacks are required and synchronous. `onModelReady` follows verified loading and actual source admission, with no request state alive. The worker can publish loaded-ready there. `beforeRequest` receives the exact step and must return only after the matching command is permitted. It runs before the unchanged solo function and its timer. The shared step contains `ordinal`, `excludedWarmup`, `requestID`, `recordedRequestFingerprint` and `promptFileSHA256`; it can also drive a rank wrapper. The generic step sequencer directly drives this owner loop and has no IO or native ownership.

The private request method returns only the existing CPU result after the unchanged request function, its autorelease pool and the lifecycle lease have all returned. Only then does `onRequestResult` run. The new owner does not emit the old one-shot per-request ready JSON; the unchanged request's default `onReady` is used. Any callback/request/check failure stops without retry and triggers cleanup. A publication failure after retirement still fails the cohort, retaining earlier external output as partial evidence.

`onModelReady` fields are `kind`, `schemaVersion`, `source`, `sourceLoad`, `arithmeticEnvironment`, `arithmeticEnvironmentSHA256`, `resourceAdmission`, `requestCount`, `warmupCount`, plus explicit loaded/no-state/qualification flags. `source` is the existing `QwenLongPrefillReferenceSource`. The final report contains the original source-load receipt, arithmetic/resource metadata, warmup count, `{step, execution, weightsRemainResident}` request entries, memory samples and release/scope flags. Its `modelReleased` flag is constructed only after actual weak-model release and cache clearing. After this function returns, the worker can await its exact shutdown command with model weights already released.

## Preserved boundaries

- `QwenLongPrefillSoloCLI.referenceOptions` and the original registered admission enforce existing source/profile/Options gates. New resident admission rejects traces, duplicate UUIDs, more than four requests, all-warmup cohorts, initial pin disagreement and cross-request source/Plan/arithmetic/resource changes. Default Plan binding is repeated for every request. Different valid prompt histories remain permitted by the owner; the worker's exact cohort input contract remains separate.
- The owner calls `loadVerifiedQwenLayerStageBaseline` once and `admitQwenLongPrefillReferenceSource` before loaded-ready. Every request then calls the original `runQwenLongPrefillSoloRequest` without modification, including its own source recheck, fresh state, 16 frame checks, final state/logit capture, timer boundaries and close/cancel behavior.
- Full `LoadedModel` is held only by the private owner after the loading autorelease pool exits. Release synchronizes native streams, checks native errors, drops the strong loaded value, checks the weak model and clears MLX cache. Failure cleanup follows the existing resident-rank pattern, preserving a primary failure with any cleanup diagnostics; no request or release is retried.
- The shared lifecycle's epoch slot uses the solo request UUID as a local uniqueness key only. Solo performs no wire epoch exchange. Callbacks receive no model, module, array, session or state owner. The generic sequencer cannot itself enforce CPU-only return types; the private owner fixes its return type and body accordingly.
- Native fusion in `Qwen35.swift` replaces checkpoint-facing projection names with same-shaped/dtyped views. Existing `modelParameterLayout` checks names/dtypes/shapes, not allocation identity. This draft leaves that check intact and claims no physical fusion allocation lineage or repeated-request qualification.

## Source-only validation handoff

Two focused fixture sources are included. Root can invoke `checkQwenLongPrefillResidentSteps()` and `checkQwenLongPrefillResidentSoloAdmission()` and encode their returned records in its isolated harness. Expected source-derived counts: step fixture 2 accepted / 9 rejected / 7 interruption cases; admission fixture 3 accepted / 23 rejected. They reuse the existing retained `QwenLongPrefillResidentRankFixture`; no metadata data file is duplicated.

The step fixture covers callback order, all four check boundaries, permission/request/publication failure and pre-callback refusal. The admission fixture uses actual Options and registered constructors for identity, size, warmup, source/cut and legacy-option refusals. No Swift compilation, native execution, model loading or actual resource observation was performed by the author. These fixtures do not qualify real native retirement, release or model reuse. Root owns build and guarded execution.
