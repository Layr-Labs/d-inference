# Proposed internal API and integration order

2026-09-14. Signatures below are an implementation plan, not compiled Swift.
No API accepts a Boolean permission, caller byte ceiling, arbitrary model or
loaded-model continuation.

```swift
// Pure: exact registered metadata, default Plan, raw pinned 3-token prompt and
// 1-token teacher; constructs a real legacy 3/2/2 request once with fresh UUID.
QwenDenseShortParityAdmission.admit(
    model: QwenRegisteredDenseModel,
    configuration: Data, manifest: Data,
    promptData: Data, promptSHA256: String,
    teacherData: Data, teacherSHA256: String
) throws -> QwenDenseShortParityAdmission

// CPU result only. onBaseline receives evidence only after full model release.
runQwenDenseShortParity(
    directory: URL, admission: QwenDenseShortParityAdmission,
    onBaseline: (QwenDenseShortBaselineCheckpoint) throws -> Void,
    check: () throws -> Void
) throws -> QwenDenseShortParityReport
```

The entry's exact eight pairs are `--mode qwen-dense-short-parity-check`,
`--model-dir`, `--registered-dense-profile`, `--tokens-file`,
`--tokens-sha256`, `--teacher-tokens-file`, `--teacher-tokens-sha256`, and
`--timeout-seconds`. Every pair is mandatory once; profile values are the existing
two enum strings, timeout is canonical 1...300, paths are absolute. Fixed 3/2/2
geometry, native arithmetic, seed7, batch1 and no repeats/warmups are not flags.
Read each token file with a 4 KiB regular-file bound, exact SHA and existing strict
integer scanner, then keep captured bytes/IDs immutable. No ordinary Options
clone or legacy mode gate is changed.

Implement in this order:

1. `QwenDenseShortParityAdmission.swift` and pure `...Budget.swift`: reuse actual
   metadata/Plan/request constructors and checked byte estimator; derive full
   and pair identities plus short allocation/fusion/evidence terms.
2. Extract the existing full diagnostic materialization tail and full-baseline
   LoadedModel finishing code with exact source comparisons. Legacy wrappers
   preserve nil hooks, caps, error strings and native operation order.
3. Add a private registered full-reference owner and private pair owner. Each
   derives its own actual-descriptor-bound live resource gate. Factor the selected
   stage's common private setup without changing its load-only return or exposing
   a generic Loaded-returning capability. Keep two stage models private until
   `compareQwenLayerStageRecordedRequest` returns CPU evidence.
4. Add the thin strict CLI/entry and outer report DTOs only after the gate and
   owner cleanup checks are reviewed. The full baseline record must precede the
   pair attempt, and final success follows all release/file/resource checks.
5. Add pure admission and fake owner/error tests, then root-owned compile/legacy
   regression and guarded 9B control; prospective 27B oracle precedes its run.

Required unchanged dependencies are the recorded request/state/logit types,
recorder/comparator, `QwenSequentialStagePair`, both CBv2 request loops, model
operators and legacy/long/profile/transport admission. The proposed entry names
are distinct; existing JSON DTOs stay nested unchanged in the new outer records.
Each exact encoded record is capped at 32 MiB and the two-record output at 64 MiB,
with a deadline check immediately before the throwing write. These are proposed
IO caps, to be tested against synthetic maximal rows before any native candidate.
