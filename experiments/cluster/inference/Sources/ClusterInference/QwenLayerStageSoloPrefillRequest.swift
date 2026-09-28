import Foundation
import Dispatch
import MLX

/// One request only. Weights and the pinned CPU reference are ready on entry;
/// fresh native state construction is inside the interval. No warmup, record
/// replay, teacher decode, transport or full-row serialization is hidden here.
func runQwenLayerStageSoloPrefillRequest(loaded: LoadedModel, plan: QwenLayerStagePlan,
    request: QwenLayerStageRecordedRequest, reference: QwenLayerStageSoloPrefillReference,
    check: () throws -> Void
) throws -> QwenLayerStageSoloPrefillResult {
    var session: CBv2RequestSession?
    var finalLogits: MLXArray?
    var requestRetiredCleanly = false
    do {
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            let source = try admitQwenLayerStageSoloPrefill(loaded: loaded, plan: plan,
                request: request, reference: reference)
            var commits: [QwenLayerStageSoloPrefillCommit] = []
            commits.reserveCapacity(request.steps.count)
            try checked()
            let start = DispatchTime.now().uptimeNanoseconds
            let fresh = try CBv2RequestSession(loaded: loaded, promptCount: request.request.promptCount, outputCount: 1)
            session = fresh
            try checked()
            guard fresh.committedTokens == 0, fresh.committedPromptTokens == 0,
                  fresh.decodeForwardCount == 0, !fresh.isClosed, !fresh.isFailed else {
                throw ProbeError("Solo timing did not start with fresh request state")
            }
            for step in request.steps {
                let commit = try autoreleasepool {
                    guard fresh.committedTokens == step.frame.tokenOffset, step.frame.phase == .prefill else {
                        throw ProbeError("Solo prefill lost the agreed native prompt frontier")
                    }
                    let output = try fresh.prefillChunk(step.tokenIDs, final: step.frame.finalPromptChunk, check: checked)
                    let width = step.frame.finalPromptChunk ? request.vocabularySize : 1
                    guard fresh.committedTokens == step.committedTokens, output.shape == [1, width],
                          [.float16, .bfloat16, .float32].contains(output.dtype) else {
                        throw ProbeError("Solo prefill output differs from its narrowed native contract")
                    }
                    if step.frame.finalPromptChunk {
                        guard finalLogits == nil else { throw ProbeError("Solo prefill returned duplicate final logits") }
                        finalLogits = output
                    }
                    try checked()
                    return QwenLayerStageSoloPrefillCommit(frame: step.frame, committedTokens: fresh.committedTokens,
                        outputKind: step.frame.finalPromptChunk ? "logits" : "evaluation_handle",
                        outputShape: output.shape, outputDType: String(describing: output.dtype))
                }
                commits.append(commit)
            }
            let selection = try autoreleasepool {
                guard let logits = finalLogits, commits.count == request.steps.count,
                      fresh.committedTokens == request.request.promptCount,
                      fresh.committedPromptTokens == request.request.promptCount,
                      fresh.decodeForwardCount == 0, !fresh.isClosed, !fresh.isFailed else {
                    throw ProbeError("Solo token selection began before complete native prefill")
                }
                return try QwenLayerStageSoloPrefillObservation.select(logits, request: request,
                    frame: request.steps.last!.frame, check: checked)
            }
            let stop = DispatchTime.now().uptimeNanoseconds
            guard stop > start else { throw ProbeError("Solo first-token clock did not advance") }
            // All baseline comparison and full-state/logit-byte observation is
            // post-stop, matching v3's final capture placement.
            let logitMetadata = try autoreleasepool {
                try QwenLayerStageSoloPrefillObservation.capture(finalLogits!, request: request,
                    frame: request.steps.last!.frame, check: checked)
            }
            guard logitMetadata == reference.descriptor.finalLogits,
                  selection.tokenID == reference.descriptor.selection.tokenID,
                  selection.policy == reference.descriptor.selection.policy,
                  selection.allLogitsFinite else {
                throw ProbeError("Solo final native logit digest or selection differs from the pinned baseline")
            }
            let snapshot = try fresh.snapshot(includeBytes: false, check: checked)
            let state = try QwenRecordedState(snapshots: [snapshot], plan: plan, committedTokens: fresh.committedTokens)
            try reference.requireFinalState(state)
            finalLogits = nil
            try fresh.close()
            guard fresh.isClosed, !fresh.isFailed else { throw ProbeError("Solo request did not retire cleanly") }
            requestRetiredCleanly = true
            try checked()
            let closed = DispatchTime.now().uptimeNanoseconds
            guard closed >= stop else { throw ProbeError("Solo post-stop clock did not advance monotonically") }
            let elapsed = stop - start
            return .init(referenceFileSHA256: reference.fileSHA256,
                baselineEvidenceFingerprint: reference.descriptor.baselineEvidenceFingerprint,
                source: source, request: request, commits: commits, selection: selection,
                referenceSelectedTokenID: reference.descriptor.selection.tokenID,
                referenceMaximumTieCount: reference.descriptor.selection.maximumTieCount,
                finalLogits: logitMetadata, finalState: state,
                timing: .init(startUptimeNanoseconds: start, stopUptimeNanoseconds: stop, elapsedNanoseconds: elapsed,
                    promptTokensPerFirstTokenSecond: Double(request.request.promptCount) * 1e9 / Double(elapsed),
                    postStopThroughRequestCloseNanoseconds: closed - stop),
                completedFrames: commits.count, committedTokens: fresh.committedTokens)
        }
    } catch {
        let primary = error
        finalLogits = nil
        // A later deadline/clock/report failure cannot reopen already verified
        // retired state. Preserve that primary error without redundant cancel.
        if let session, !requestRetiredCleanly {
            do {
                try MLX.withError { cleanupError in
                    try session.cancel(); try cleanupError.check()
                }
            } catch { throw ProbeError("Solo prefill failed (\(primary)); request cleanup also failed (\(error))") }
            guard session.isClosed, session.isFailed else {
                throw ProbeError("Solo prefill failed (\(primary)); request was not failed and retired")
            }
        }
        throw primary
    }
}
