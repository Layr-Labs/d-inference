import Foundation
import MLX

/// One fresh owner. No timing, teacher/decode, intermediate numerical capture or
/// second model. The existing forward evaluates full recurrent/KV roots before
/// every commit; a final-only record does not weaken native frontier checks.
func runQwenLongPrefillReferenceRequest(loaded: LoadedModel,
    admission: QwenRegistered9BLongPrefillReferenceAdmission, check: () throws -> Void
) throws -> QwenLongPrefillReferenceRequestResult {
    var session: CBv2RequestSession?
    var finalLogits: MLXArray?
    var retiredCleanly = false
    do {
        return try MLX.withError { error in
            func checked() throws { try error.check(); try check(); try error.check() }
            let (source, receipt) = try admitQwenLongPrefillReferenceSource(loaded: loaded, admission: admission)
            try checked()
            let fresh = try CBv2RequestSession(loaded: loaded, promptCount: 8192, outputCount: 1)
            session = fresh
            try checked()
            guard fresh.committedTokens == 0, fresh.committedPromptTokens == 0,
                  fresh.decodeForwardCount == 0, !fresh.isClosed, !fresh.isFailed else {
                throw ProbeError("Long reference did not acquire exclusive fresh request state")
            }
            var commits: [QwenLayerStageSoloPrefillCommit] = []
            commits.reserveCapacity(16)
            for step in admission.request.steps {
                let commit = try autoreleasepool {
                    guard fresh.committedTokens == step.frame.tokenOffset,
                          step.frame.phase == .prefill, step.tokenIDs.count == 512 else {
                        throw ProbeError("Long reference lost its admitted prompt frontier")
                    }
                    let output = try fresh.prefillChunk(step.tokenIDs, final: step.frame.finalPromptChunk, check: checked)
                    let width = step.expectsLogits ? admission.request.vocabularySize : 1
                    guard fresh.committedTokens == step.committedTokens,
                          fresh.committedPromptTokens == step.committedTokens, fresh.decodeForwardCount == 0,
                          output.shape == [1, width], output.dtype == .bfloat16 else {
                        throw ProbeError("Long reference narrowed output/frontier or native dtype differs")
                    }
                    if step.expectsLogits {
                        guard finalLogits == nil else { throw ProbeError("Long reference duplicated its final row") }
                        finalLogits = output
                    }
                    try checked()
                    return QwenLayerStageSoloPrefillCommit(frame: step.frame, committedTokens: fresh.committedTokens,
                        outputKind: step.expectsLogits ? "logits" : "evaluation_handle",
                        outputShape: output.shape, outputDType: String(describing: output.dtype))
                }
                commits.append(commit)
            }
            guard commits.count == 16, fresh.committedTokens == 8192, fresh.committedPromptTokens == 8192,
                  fresh.decodeForwardCount == 0, !fresh.isClosed, !fresh.isFailed else {
                throw ProbeError("Long reference final capture began before all sixteen commits")
            }
            let (logits, selection) = try autoreleasepool {
                guard let finalLogits else { throw ProbeError("Long reference has no final native row") }
                return try captureQwenLongPrefillReferenceLogits(finalLogits, admission: admission, check: checked)
            }
            // The sole state snapshot retains metadata/digests only. The shared
            // capture hashes one copied component at a time, not a state history.
            let state = try autoreleasepool {
                let snapshot = try fresh.snapshot(includeBytes: false, check: checked)
                return try QwenRecordedState(snapshots: [snapshot], plan: admission.plan, committedTokens: 8192)
            }
            guard state.entries.count == 72, state.logicalByteCount == 319_946_784 else {
                throw ProbeError("Long reference final state has the wrong registered component/byte coverage")
            }
            finalLogits = nil
            try fresh.close()
            guard fresh.isClosed, !fresh.isFailed else { throw ProbeError("Long reference request did not retire cleanly") }
            retiredCleanly = true
            try checked()
            return .init(source: source, sourceLoad: receipt, request: admission.request,
                commits: commits, selection: selection, finalState: state, finalLogits: logits,
                completedFrames: commits.count, committedTokens: fresh.committedTokens)
        }
    } catch {
        let primary = error
        finalLogits = nil
        if let session, !retiredCleanly {
            do {
                try MLX.withError { cleanupError in
                    try session.cancel(); try cleanupError.check()
                }
            } catch { throw ProbeError("Long reference request failed (\(primary)); cleanup also failed (\(error))") }
            guard session.isClosed, session.isFailed else {
                throw ProbeError("Long reference request failed (\(primary)); owner was not failed and retired")
            }
        }
        throw primary
    }
}
