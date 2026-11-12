# Final-only prefill comparison draft

The source-only entry point is:

```swift
compareQwenLayerStagePrefillCompute(
    baseline: QwenLayerStageBaselineEvidence,
    stages: [LoadedQwenLayerStage],
    plan: QwenLayerStagePlan,
    check: () throws -> Void
) throws -> QwenLayerStagePrefillComparisonResult
```

The caller independently records and releases the complete baseline model before
loading the stages. The helper takes only CPU baseline evidence plus the two
verified compact stages. It cannot prove that an unrelated caller still does not
retain a baseline model; the existing coordinator's weak-module release check
owns that boundary. Source admission binds the artifact, original configuration,
full-model layout, model bytes, plan, native transformation and common stage
storage commitment to the baseline. Each unchanged StageSession then performs
its existing compact-model admission.

The initial scope is prompt 1...128, chunk 1...32, one output, no teacher tokens.
For the proposed 65/32 request it executes exactly three complete prompt frames
at frontiers 32, 64 and 65. Each frame runs stage zero, makes the existing explicit
owned native boundary copy, then runs stage one. An autorelease scope returns
only the two CPU commit records. No frame state snapshot or full-vocabulary copy
is performed during this loop. There is no transport, clock or overlap here.

After complete prefill, the helper selects the first token using the context's
existing native argmax/finite guard and compares it with a CPU scan of the new
baseline's finite Float32 values. It then captures exactly one final native logit
row and exactly two final state snapshots with `includeBytes: false`. Logits must
match the baseline's private native Data byte-for-byte through the now-integrated
`QwenRecordedLogits.requireExactNativeBytes` hook. Final state joins by global
layer/component, requires complete disjoint coverage, and compares every entry's
shape, dtype, byte count and SHA plus the complete-state fingerprint. This does
not compare intermediate state numerically; earlier captured qualification owns
that evidence.

The token policy is finite maximum with the lowest vocabulary index on a tie.
Pinned `libs/mlx-swift/Source/Cmlx/mlx/mlx/backend/metal/kernels/arg_reduce.metal`
lines 42–64 implement that choice explicitly; the ascending CPU scan in
`backend/cpu/arg_reduce.cpp` lines 24–29 and 52–59 uses strict-greater updates.
`mlx/ops.cpp` lines 2676–2710 flattens the all-axis input and returns UInt32.
Float16/BFloat16 widening to the stored Float32 baseline values is exact, so it
preserves finite ordering and equal maxima. Signed-zero ties choose the lowest
index too; the separate native-byte check still distinguishes their bit patterns.
The report records the actual maximum and its tie count. It derives the expected
token from this baseline and does not use a frozen teacher token as a greedy
target.

`QwenLayerStagePrefillComparisonResult` is CPU-only. The parent places it once
under `comparison`. It contains baseline/request/source identity, stage identities,
per-frame host commits, the native token receipt and CPU comparison, final logit
metadata/SHA, merged final state metadata/SHA, exact-equality flags, explicit
capture counts, and successful request retirement. It retains neither MLXArray
nor full-vocabulary JSON values nor the final copied native Data. Reported capture
counts concern this helper's explicit diagnostic calls only.

The unchanged checks, output and all-state evaluation, commit work, source and
consumer residual hashing, explicit boundary copy and its byte comparison all
remain. Token selection includes its extra finite reduction, evaluation and
scalar reads. Final captures and close/cancel perform native synchronization and
host work. This helper excludes none of those costs from a timer because it has
no timer. The existing compute-context handoff lists these retained costs in
detail. This is a sequential one-process correctness control, not a throughput
measurement, wire protocol, two-machine result or proof of GPU overlap.

An outer MLX error scope covers context creation, copies, final observations and
cleanup. Every error cancels every constructed context, including failures after
a stage committed or after one stage closed successfully. Primary and cleanup
errors are preserved together. Success requires complete frontiers and clean
retirement with no final native logit root remaining in either context. The
caller continues to own and eventually release the loaded stage models.

Files are split into the thin native comparison, host validation, and result
types. No existing source or frozen context file was changed. Review checked the
current integrated APIs and pinned native argmax source; no Swift compilation,
native/GPU/model execution, timing, protocol or CLI work was performed here.
