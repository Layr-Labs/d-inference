# Uncaptured stage prefill context

Source-only draft, 2026-09-14. No timer, new protocol, native build, model run,
transport run or GPU execution was added or performed. Existing captured
contexts/sessions and frozen v2 sources are unchanged.

`QwenLayerStagePrefillComputeContext(loaded:plan:request:)` admits the existing
prompt1...128 / chunk1...32 limits, outputCount1, no teachers and batch one. Root's
first planned comparison is the frozen natural65 / chunk32 final-prefill evidence
before teacher decode. No existing context, wire, frame or memory cap is raised.

The new API wraps the current `QwenLayerStageSession`:

```swift
expectation(for: step) -> QwenLayerStageBoundaryWireExpectation
prepare(step, check:) -> QwenLayerStagePrefillPrepared
consume(step, boundary:, check:) -> QwenLayerStagePrefillCommit
selectFirstToken(check:) -> QwenLayerStagePrefillTokenReceipt
captureFinalLogitsForDiagnostics(check:) -> QwenLayerStagePrefillLogitReceipt
captureFinalStateForDiagnostics(includeBytes: false, check:) -> CBv2OwnedStateSnapshot
close()
cancel()
```

`identity` is the existing source/config/artifact/storage/plan/stage/request
identity. `request` is the immutable RecordedRequest, and every frame must equal
its exact next prompt slice and full-model token frontier. `committedFrames`,
`committedTokens`, `isPrefillComplete`, `isClosed` and `isFailed` expose scalar
lifecycle state. There is no decode method or cached token-selection result.

Prepare returns the native residual, existing wire expectation and small CPU
commit metadata. The caller owns and releases that boundary; the context retains
none of it. Consume returns only small CPU commit metadata, releases intermediate
evaluation handles and retains one private final native `[1,V]` logits row until
close/cancel. It does not copy/cache the incoming boundary. Neither method calls
the full-state CPU snapshot/hash helper or copies a full vocabulary to CPU/JSON.

The underlying whole-layer widths, quantization and arithmetic are unchanged:
stage zero uses the existing pre-final-norm hidden return with no evaluated
discarded head; stage one preserves `.evaluationOnly` intermediate chunks and
`.lastPositionLogits` on the final chunk. Output, recurrent, KV and device-position
roots are still evaluated and checked before commit. Native faults and later
metadata/selection/capture errors fail and retire the entire local request.
Parent orchestration must also retire transport and fence the peer on any throw.

## Actual costs and future clock placement

| Operation | Costs retained by this API |
| --- | --- |
| Constructor | Loaded-model identity/layout/frozen checks, geometry validation, fresh KV and recurrent request-state creation. Start the proposed request timer before construction, not after a ready event containing an already constructed context. |
| Prepare | Existing native forward and all roots, state ownership/shape checks, device offset readbacks, commit, residual `asData()` copy plus SHA, token/expectation metadata. All remain part of actual compute work. |
| Consume | Existing incoming owned-buffer metadata validation, residual `asData()` copy plus SHA, native forward/root completion, state checks/readbacks and commit. None is subtracted. |
| External transport or local copy | Existing sender/receiver payload hash/copy checks, any Send contiguous temporary, Recv allocation, CPU/GPU stream fences, ACKs and pipeline fill/drain. This context does not remove them. `Boundary.ownedCopy` adds its own physical copy and exact-byte comparisons if a local adapter uses it. |
| Token selection | Native uncast `argMax`, an explicitly additional all-finite reduction, evaluation and two scalar CPU reads. Include them and eventual checked token return in first-token time. |
| Explicit diagnostic captures | Final state snapshot/hash and optional raw bytes; or final full-row native-byte copy/hash plus finite check. Caller may exclude them only by performing them after the request timer has actually stopped on every rank. The context owns no clock and cannot prove that placement. |
| Close/cancel | Final-logit release and existing GPU/CPU synchronization plus KV/recurrent retirement. Record teardown separately after a successful interval, and finish it before any new request. |

Pinned paths behind those costs are `QwenLayerStageSession.swift:119–153,163–173`,
`QwenLayerStageBoundary.swift:29–65`, `CBv2OwnedRequestState.swift:55–78,86–107,115–133`,
and `libs/mlx-swift/Source/MLX/MLXArray+Bytes.swift:210–215`: default `asData()`
evaluates and copies into contiguous CPU Data. Internal shallow state metadata
inspection remains; this draft removes the separate per-frame CPU state-byte
snapshot/hash path, not required ownership checks.

## Optional final evidence

`selectFirstToken` is stage-one-only, after full prompt commit, and one-shot.
Its selection policy is `mlx_argmax_all_axes_with_finite_guard_v1`: same native
uncast all-axes argMax as `Benchmark.swift:68–72`, plus an explicit finite guard.
It records source/request/frame/frontier, vocabulary, ordinal0, selected token,
native logit dtype/shape and selection dtype in a small CPU value. This is a local
receipt, not a wire message. It does not claim rank zero received a token, establish
an epoch protocol or provide first-token timing by itself. Consumed ACK still
contains no token; root owns that separately admitted protocol and final timer.

`captureFinalLogitsForDiagnostics` copies exact logical native bytes without a
Float32 conversion. The receipt privately retains at most 1 MiB of CPU Data for
V<=262144 with float16/bfloat16/float32. Its encoding includes metadata/SHA only,
not raw bytes or a vocabulary vector. `requireExactLogicalMatch` compares shape,
dtype and all bytes including signed zeros; callers separately bind common source
and prompt identity when comparing runs with different UUIDs. Final state capture
reuses the existing bounded snapshot helper and is unavailable before full prefill.

## Resident reuse evidence

This context is a one-shot request owner: a new request needs fresh state. It does
not imply the verified loaded weights must be discarded. Pinned Qwen35 fusion
keeps `fusedInProj` private/unregistered (`Qwen35.swift:244–248`) and replaces the
same qkv/z/b/a module names with same-shape/dtype views (`:453–482`). The current
layout fingerprint hashes only path/dtype/shape (`ModelPartition.swift:47–49`).
No actual9B-specific layout-changing fusion path was established here, so there
is no source basis for claiming fusion inherently breaks reuse. The existing
tiny same-resident lifecycle test is consistent with that design. Repeated real9B
requests/warmup timing still need their own controlled qualification; no guard
was bypassed or weakened for this draft.

Next proof is a root-reviewed build and captured-versus-uncaptured final evidence
on the same source and65/32 schedule, followed by final-token receipt/lifecycle
validation. A timer/transport implementation, matched uncaptured solo and serial
controls, and actual multi-machine measurements remain separate work. No speedup,
TPS or simultaneous GPU execution is inferred from this context.
