import Foundation
import MLX

/// Same full-model CBv2 session, frame/completion contract and finite native
/// argmax as the reference. This measurement path never asks for a CPU full-row
/// or state snapshot. The caller owns the loaded model, resource and time gates.
func runQwenResidentSoloRequest(loaded: LoadedModel, admission: QwenGenerationReferenceAdmission,
    expectedTokenIDs: [Int], admitResources: () throws -> Void, check: () throws -> Void
) throws -> QwenResidentSoloRequestResult {
    var session: CBv2RequestSession?
    do {
        return try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try check(); try nativeError.check() }
            do {
                let request = admission.request
                guard request.promptCount == 8192, request.chunkSize == 512, request.outputCount == 128,
                      request.maximumTokens == 8320, request.stopTokenIDs.isEmpty,
                      expectedTokenIDs.count == 128,
                      expectedTokenIDs.allSatisfy({ (0..<request.profile.vocabularySize).contains($0) }) else {
                    throw ProbeError("Resident solo differs from the matched 8K/128 geometry")
                }
                _ = try admitQwenRegisteredGenerationReferenceSource(loaded: loaded, admission: admission.source)
                guard try QwenLongPrefillArithmeticEnvironment.admit(ProcessInfo.processInfo.environment)
                    == admission.source.arithmetic else { throw ProbeError("Resident solo arithmetic changed") }
                try checked(); try admitResources(); try checked()
                let start = DispatchTime.now().uptimeNanoseconds
                let owned = try CBv2RequestSession(loaded: loaded, promptCount: 8192, outputCount: 128)
                session = owned
                guard owned.committedTokens == 0, owned.committedPromptTokens == 0,
                      owned.decodeForwardCount == 0, !owned.isClosed, !owned.isFailed else {
                    throw ProbeError("Resident solo did not begin with fresh request state")
                }
                var tokens: [Int] = [], stamps: [UInt64] = []
                var completedFrames = 0
                for sequence in 0..<request.forwardCount {
                    let frame = try request.frame(sequence: sequence)
                    let selected: (Int, UInt64)? = try autoreleasepool {
                        try checked()
                        let output: MLXArray
                        switch frame.phase {
                        case .prefill:
                            output = try owned.prefillChunk(Array(request.promptTokenIDs[
                                frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)]),
                                final: frame.finalPromptChunk, check: checked)
                        case .decode:
                            guard let prior = tokens.last else { throw ProbeError("Solo decode lacks its committed target token") }
                            output = try owned.decode(prior, check: checked)
                        }
                        let expectsLogits = frame.finalPromptChunk || frame.phase == .decode
                        guard owned.committedTokens == frame.tokenOffset + frame.tokenCount,
                              owned.committedPromptTokens == min(request.promptCount, owned.committedTokens),
                              owned.decodeForwardCount == max(0, owned.committedTokens - request.promptCount),
                              output.shape == [1, expectsLogits ? request.profile.vocabularySize : 1],
                              String(describing: output.dtype) == request.profile.activationDType else {
                            throw ProbeError("Resident solo forward differs from its exact committed frame")
                        }
                        try checked()
                        guard expectsLogits else { return nil }
                        let token = try QwenGenerationReferenceCapture.token(output, request: request, check: checked)
                        guard tokens.count < expectedTokenIDs.count, token == expectedTokenIDs[tokens.count] else {
                            throw ProbeError("Resident solo selected target differs from pinned expected sequence")
                        }
                        return (token, DispatchTime.now().uptimeNanoseconds)
                    }
                    completedFrames += 1
                    if let (token, stamp) = selected { tokens.append(token); stamps.append(stamp) }
                }
                let completion = try QwenGenerationReferenceCompletion(request: request, reason: .length,
                    selectedTokenIDs: tokens, completedFrames: completedFrames)
                try completion.requireSession(promptCount: 8192, outputCount: 128,
                    committedPromptTokens: owned.committedPromptTokens, decodeForwardCount: owned.decodeForwardCount,
                    committedTokens: owned.committedTokens)
                try checked(); try owned.finishGeneration(completion); try checked()
                guard owned.isClosed, !owned.isFailed, tokens == expectedTokenIDs else {
                    throw ProbeError("Resident solo state or token guard did not complete")
                }
                let timing = try QwenResidentSoloTiming(start: start, selected: stamps,
                    retired: DispatchTime.now().uptimeNanoseconds)
                return .init(requestID: request.requestID, requestFingerprint: request.fingerprint,
                    selectedTokenIDs: tokens, selectedTokenIDsSHA256: qwenGenerationTokenHash(tokens),
                    completedFrames: completedFrames, committedTokens: completion.committedTokens, timing: timing)
            } catch { try nativeError.check(); throw error }
        }
    } catch {
        let primary = error
        var cleanup: [String] = []
        if let session {
            do { try MLX.withError { fault in try session.cancel(); try fault.check() } }
            catch { cleanup.append(String(describing: error)) }
            if !session.isClosed || !session.isFailed { cleanup.append("solo request state was not failed and retired") }
        }
        if !cleanup.isEmpty { throw ProbeError("Resident solo request failed (\(primary)); cleanup: \(cleanup.joined(separator: "; "))") }
        throw primary
    }
}
