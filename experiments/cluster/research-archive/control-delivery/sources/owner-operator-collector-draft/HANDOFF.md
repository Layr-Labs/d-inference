# Fixed selected-chunk owner collector

Source-only Foundation draft. No compiler, Swift fixture, native inference,
GPU, SSH, model payload or candidate trace was used by this agent. Existing
owner seam and old41/204/235-event phase traces remain unchanged.

API:

```swift
let identity = try QwenPrefillOwnerIdentity(
    requestFingerprint: recordedRequestFingerprint,
    profile: "long_prefill_8k_v1", role: .solo) // or .rank0 / .rank1
let recorder = QwenPrefillOwnerRecorder(identity: identity)
let observer: CBv2OwnerPhaseObserver = { try recorder.observe($0) }
// Root installs observer only on the admitted local frame7.
// After the complete outer request/model owner and native checks succeed:
try recorder.sealAfterOuterSuccess()
let trace = try recorder.successfulTrace()
// Every failure, including file/publication failure: recorder.fail()
```

The recorder does not choose a frame. Root's one-shot factory must compare the
actual local recorded frame and request/profile/role with `recorder.identity`
before returning its callback. The identity initializer requires lowercase
64-hex recorded request fingerprint, the exact profile, and a closed role enum.
It stores fixed explicit selection fields `frameSequence:7`, `tokenOffset:3584`,
`tokenCount:512`, `committedFrontier:4096`. No MLX or QwenLayerStageFrame type is
imported by the collector. Pipeline's separate request-wiring factory supplies
that boundary and was reviewed for compatibility without code execution.

The first correct observation activates a fresh collector. It requires exactly
these eight phases, in order: graphConstruction.begin/end, rootStaging.begin/end,
evaluation.begin/end and validationCommit.begin/end. Every observation has
width512; the first seven have frontier3584 and only the last has4096. All
metadata is checked before the clock. UInt64 clocks must be nondecreasing;
equality, zero and UInt64.max are valid. No clock is read on initialization,
seal, failure or trace retrieval. Capacity is fixed8, with no widening option.

`init(testIdentity:clock:)` is a visibly separate injected-clock initializer.
Its traces carry `injected_test_clock`; normal construction carries
`DispatchTime.uptimeNanoseconds`. The production initializer is not configurable
with an injected clock. The pure fixture never observes with the production
clock.

Bad order/frontier/width, a ninth event, clock reversal/exception, invalid seal
or retrieval and caught reentrant calls poison the recorder, clear event/result
storage and prevent later publication. The recursive lock permits detecting
same-thread reentry without deadlock; state is rechecked after an injected
clock returns, even if that clock caught an inner rejection. No callback/model
or native array exists in the returned trace. The recorder retains its clock
closure only; production's closure captures no request or native owner.

`sealAfterOuterSuccess` is one-shot, requires all eight events, and reads no
clock. It cannot independently verify outer success. Root must invoke it only
after complete outer model release and error checks, and fail it on every error.
`successfulTrace` before sealing poisons rather than exposing a partial result.
Repeated retrieval after a valid seal is allowed. Calling fail after seal hides
future retrieval; a CPU value already returned cannot be revoked. No caller
should retrieve or publish before the outer-success gate.

The separate output contract is kind `qwen_prefill_selected_owner_trace`,
schemaVersion1. It encodes identity, clockSource, maximumEvents8, events
(ordinal/phase/tokenCount/committedTokens/localUptimeNanoseconds), first/last
uptime and exact last-minus-first span. Flags are diagnosticOnly and
includesRecorderOverhead true; evaluationIntervalIncludesExistingErrorCheck
true; crossProcessClockAlignmentAsserted, gpuKernelTimeAsserted,
gpuOverlapAsserted, modelReleaseAsserted and
recorderIndependentlyVerifiesOuterSuccess false. These CPU-observed intervals
include original synchronization, checks and observer cost. They are not
per-operator GPU timings. No alignment between processes is implied.

The source-contract checker passed14 CPU checks including13 deliberate bad
source mutations. Its pinned dependency is the frozen eight-marker owner seam
manifest0062f80e… and core074cd6d2…. The unexecuted Foundation fixture is
`checkQwenPrefillOwnerRecorder()` in QwenPrefillOwnerRecorderCheck.swift:
prospectively six complete synthetic traces and90 rejected calls, including
phase/frontier failures at each position, incomplete/duplicate/post-failure
seal, malformed identity, width extremes, repeated/maximal clock values,
reversal/throw, premature retrieval and four caught reentrant operations.
Compilation and those behavioral results remain pending root execution.
