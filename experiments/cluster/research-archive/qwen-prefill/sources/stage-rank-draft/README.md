# Serialized stage-rank request wrapper

Source-only draft around the integrated `QwenLayerStageSession` and
`QwenLayerStageBoundaryTransport`. No inference-target build, native execution,
GPU operation, source integration, or launcher run was performed for this draft.

## API

```swift
let rank = try QwenLayerStageRankSession(
    stage: verifiedLocalStage, plan: admittedPlan,
    request: sharedFreshCohortTimeline, transport: boundaryTransport)

for _ in sharedFreshCohortTimeline.steps {
    let completion = try rank.runNextFrame(
        observe: { capture in /* CPU capture/validation only */ }, check: check)
    try emitJSON(completion)
}
try rank.close()
```

The wrapper owns one existing stage request session. The caller supplies a
verified compact loaded stage, its exact source plan, a bounded immutable
`QwenLayerStageRecordedRequest` timeline, and a transport already belonging to
the admitted two-rank cohort. It also owns the loaded model, collective,
model-memory admission, per-process alarm and parent process-group deadline.
The coordinator must assign the local stage index to the actual collective
rank; the transport independently rejects a wrong sender/receiver rank.

`identity`, `request`, `committedTokens`, `completedFrames`, `isClosed`, and
`isFailed` expose the request's local state. `runNextFrame(observe:check:)` takes
the next exact recorded prompt chunk or supplied teacher token. It accepts no
alternate tokens, offset, frame, dtype, hidden width or scheduling policy from
the caller. `close()` succeeds only after all frame handshakes completed and
the existing stage session retired cleanly. `cancel()` invalidates and retires
that local request. A thrown operation never permits retry or reuse.

## Per-frame order and records

Rank zero executes the existing stage-zero forward, which evaluates and commits
the complete raw residual plus request roots. It then snapshots its own committed
state, verifies complete local/global layer and component coverage, and invokes
the throwing CPU observer. Only after the observer succeeds does it call the
boundary transport's actual-header/native-payload send. It waits for the matching
consumed ACK before returning the completion record and advancing its next-frame
ordinal.

Rank one receives into the transport's admitted owned compact native array.
Inside `receive.consume`, it executes the existing residual-input stage forward,
captures the committed state and final-prefill/decode full-vocabulary logits,
then invokes its throwing CPU observer. The callback returns only after native
error checks and an unchanged open committed frontier check. The transport sends
its consumed ACK afterward. Intermediate chunks preserve the existing
evaluation-handle path; their discarded scalar values are not promoted to logits.

The observer must only capture or validate CPU data. It must not recursively
drive the wrapper, mutate the stage or perform MLX/transport work. Native checks
and request-frontier guards run after it. Every frame has an autorelease scope;
stage-zero residuals live through the complete send/ACK handshake, and received
arrays/logit conversion temporaries do not escape in a returned record.

`QwenLayerStageRankFrameCapture` contains the existing pure session identity,
frame, committed frontier and stage source range; global state metadata/digests;
logical state byte count and partial-stage state fingerprint; the actual boundary
payload hash/shape/dtype; output kind/shape/dtype; and rank-one finite full-vocabulary
Float32 logit values with native logical byte count/dtype/hash. State capture
checks each entry's local/global mapping before discarding the redundant local
index in the emitted record. Kernel-size-one empty convolution history follows
the existing admitted `[1,0,channels]` rule; other state components stay strict.
The capture contains no native array, model, request state, closure, or raw state
byte history. Candidate native logit bytes are copied and hashed by the existing
capture helper, then discarded; the emitted values and native hash remain CPU
data.

`QwenLayerStageRankFrameCompletion` adds the actual returned wire-header SHA and
an explicit transport phase:

- Rank zero: `consumed_ack_received_and_validated`.
- Rank one: `consumed_ack_send_completed`.

These distinctions prevent an ACK send completion from claiming that its peer
validated the ACK. A capture observed before a handshake fails is diagnostic
evidence only; the parent requires all completion records and a clean final
retirement record before declaring the whole run complete.

## Baseline and cohort comparison

No worker loads or decodes a full-model baseline. The parent holds the separately
frozen baseline CPU evidence and compares complete frame coverage, actual
prompt/teacher IDs, source artifact/configuration/plan/conversion, native output
metadata and full-vocabulary logits, and the joined global rank-state entries.
It must verify native logit hashes against their finite encoded vectors when
reconstructing logical byte comparisons; a bare hash comparison is not reported
as an independent raw-byte check by this wrapper.

The prior baseline has a different request UUID. Its request/header fingerprints
must not be compared for equality with this fresh cohort's request fingerprint.
Inside the current cohort the two ranks must share requestFingerprint,
artifactAggregateSHA256, storageCommitmentSHA256, bf16ConversionEnabled,
sourceConfigurationSHA256, planFingerprint and activationDType. Stage index,
construction-configuration hash and stage fingerprint are stage-specific. Header
hash and boundary payload identity must agree between matching rank completions.

The outer coordinator owns ready/final report schemas, weak model-release
proofs, stage load receipts and report emission. It may pass a no-op observer
and emit each returned completion once; no duplicate capture log is required.
Full-vocabulary JSON lines can exceed the old worker protocol's 2 MiB line limit,
so the new one-shot launcher needs its own bounded complete report-file policy.

## Failure and current limits

Any stage, snapshot, observer, wire, ACK or final-frontier error sets the wrapper
failed, marks the transport retired, and cancels the local stage session,
retaining retirement errors alongside the primary error. The root-owned pure
`BoundaryTransport.retire()` hook sets its existing failed flag without native
work. This also fences an observer failure before the first transport call;
abandoning an unclosed wrapper retires transport and session in deinitialization.
A wire failure can leave stage zero locally committed ahead
of stage one; that state is discarded, never replayed. Local cleanup can itself
wait on native work, so the parent must fence/terminate the whole cohort under
its independent deadline and never reuse the transport/group after failure.

The wrapper is single-caller and strictly sequential: one residual in flight,
no prepared next output, no asynchronous MLX execution, and no overlap. It does
not spawn processes, read model/token files, load weights, allocate a baseline,
alter public forwarding or attach MTP. Observer snapshots and CPU logit capture
make these diagnostic records unsuitable for throughput qualification.
