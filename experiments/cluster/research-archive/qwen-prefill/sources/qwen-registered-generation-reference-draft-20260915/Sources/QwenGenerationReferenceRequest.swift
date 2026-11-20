import Foundation
import MLX

/// Runs one fresh full-model CBv2 request after the caller's verified model
/// load. No stage forward, teacher forcing, MTP, transport or sampling is used.
/// The mandatory resource callback is a live owner obligation; source metadata
/// and the old output-one receipt do not authorize this request's allocations.
func runQwenGenerationReference(loaded: LoadedModel,
    admission: QwenGenerationReferenceAdmission,
    admitResources: (QwenGenerationReferenceRequirements) throws -> Void,
    check: () throws -> Void
) throws -> QwenGenerationReferenceResult {
    var session: CBv2RequestSession?
    var finalLogits: QwenRecordedLogits?
    do {
        return try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try check(); try nativeError.check() }
            do {
                let request = admission.request
                let (source, receipt) = try admitQwenRegisteredGenerationReferenceSource(
                    loaded: loaded, admission: admission.source)
                guard try QwenLongPrefillArithmeticEnvironment.admit(ProcessInfo.processInfo.environment)
                    == admission.source.arithmetic else {
                    throw ProbeError("Generation reference process arithmetic changed after source admission")
                }
                try checked()
                try admitResources(admission.requirements)
                try checked()
                let start = DispatchTime.now().uptimeNanoseconds
                let owned = try CBv2RequestSession(loaded: loaded,
                    promptCount: request.promptCount, outputCount: request.outputCount)
                session = owned
                guard owned.committedTokens == 0, owned.committedPromptTokens == 0,
                      owned.decodeForwardCount == 0, !owned.isClosed, !owned.isFailed else {
                    throw ProbeError("Generation reference did not begin with fresh full-model state")
                }
                var tokens: [Int] = []
                var observations: [QwenGenerationReferenceTokenEvidence] = []
                var completedFrames = 0
                var firstSelected: UInt64?
                var lastSelected: UInt64?
                var reason: QwenLayerStageGenerationFinishReason?
                for sequence in 0..<request.forwardCount {
                    let frame = try request.frame(sequence: sequence)
                    let observation: (QwenGenerationReferenceTokenEvidence, QwenRecordedLogits, UInt64)? = try autoreleasepool {
                        try checked()
                        let output: MLXArray
                        switch frame.phase {
                        case .prefill:
                            let ids = Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
                            output = try owned.prefillChunk(ids, final: frame.finalPromptChunk, check: checked)
                        case .decode:
                            guard let previous = tokens.last else {
                                throw ProbeError("Generation reference decode lacks a selected target token")
                            }
                            output = try owned.decode(previous, check: checked)
                        }
                        let expectsLogits = frame.finalPromptChunk || frame.phase == .decode
                        guard owned.committedTokens == frame.tokenOffset + frame.tokenCount,
                              owned.committedPromptTokens == min(request.promptCount, owned.committedTokens),
                              owned.decodeForwardCount == max(0, owned.committedTokens - request.promptCount),
                              output.shape == [1, expectsLogits ? request.profile.vocabularySize : 1],
                              String(describing: output.dtype) == request.profile.activationDType else {
                            throw ProbeError("Generation reference forward differs from its exact frame")
                        }
                        try checked()
                        guard expectsLogits else { return nil }
                        let token = try QwenGenerationReferenceCapture.token(output, request: request, check: checked)
                        // Stop this timestamp before the complete-row CPU copy.
                        let selectedAt = DispatchTime.now().uptimeNanoseconds
                        let capture = try QwenGenerationReferenceCapture.evidence(output, request: request,
                            frame: frame, ordinal: tokens.count, token: token, check: checked)
                        return (capture.0, capture.1, selectedAt)
                    }
                    completedFrames += 1
                    if let (evidence, logits, selectedAt) = observation {
                        tokens.append(evidence.tokenID); observations.append(evidence); finalLogits = logits
                        if firstSelected == nil { firstSelected = selectedAt }
                        lastSelected = selectedAt
                        if request.stopTokenIDs.contains(evidence.tokenID) { reason = .eos }
                        else if tokens.count == request.outputCount { reason = .length }
                        if reason != nil { break }
                    }
                }
                guard let reason, let firstSelected, let lastSelected, let finalLogits else {
                    throw ProbeError("Generation reference ended without a selected-token completion")
                }
                let completion = try QwenGenerationReferenceCompletion(request: request, reason: reason,
                    selectedTokenIDs: tokens, completedFrames: completedFrames)
                try completion.requireSession(promptCount: request.promptCount, outputCount: request.outputCount,
                    committedPromptTokens: owned.committedPromptTokens, decodeForwardCount: owned.decodeForwardCount,
                    committedTokens: owned.committedTokens)
                let snapshot = try owned.snapshot(includeBytes: false, check: checked)
                let state = try QwenRecordedState(snapshots: [snapshot], plan: admission.source.plan,
                                                 committedTokens: completion.committedTokens)
                try checked()
                try owned.finishGeneration(completion)
                try checked()
                guard owned.isClosed, !owned.isFailed else {
                    throw ProbeError("Generation reference did not retire request state cleanly")
                }
                let retired = DispatchTime.now().uptimeNanoseconds
                guard start <= firstSelected, firstSelected <= lastSelected, lastSelected <= retired else {
                    throw ProbeError("Generation reference monotonic clock order differs")
                }
                return .init(source: source, sourceLoad: receipt,
                    promptFileSHA256: admission.source.promptFileSHA256,
                    promptTokenIDsSHA256: admission.source.promptTokenIDsSHA256,
                    requestID: request.requestID, requestFingerprint: request.fingerprint, profile: request.profile,
                    promptCount: request.promptCount, chunkSize: request.chunkSize,
                    requestedOutputCount: request.outputCount, maximumTokens: request.maximumTokens,
                    stopTokenIDs: request.stopTokenIDs.sorted(), requirements: admission.requirements,
                    selectedTokenIDs: tokens, selectedTokenIDsSHA256: qwenGenerationTokenHash(tokens),
                    finishReason: reason, completedFrames: completedFrames, committedTokens: completion.committedTokens,
                    tokens: observations, finalLogits: finalLogits, finalState: state,
                    timing: .init(requestStartNanoseconds: start, firstSelectedTokenNanoseconds: firstSelected,
                        finalSelectedTokenNanoseconds: lastSelected, retiredNanoseconds: retired))
            } catch {
                // A Swift validation/callback fault must not mask an already
                // recorded native fault; outer cleanup still preserves primary.
                try nativeError.check()
                throw error
            }
        }
    } catch {
        let primary = error
        finalLogits = nil
        var cleanup: [String] = []
        if let session {
            do {
                try MLX.withError { nativeError in
                    try session.cancel(); try nativeError.check()
                }
            } catch { cleanup.append(String(describing: error)) }
            if !session.isClosed || !session.isFailed { cleanup.append("full generation state was not failed and retired") }
        }
        if !cleanup.isEmpty {
            throw ProbeError("Full generation reference failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))")
        }
        throw primary
    }
}
