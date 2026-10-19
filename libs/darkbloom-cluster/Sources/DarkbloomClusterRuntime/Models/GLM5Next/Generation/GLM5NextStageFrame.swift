import Foundation
import MLX

/// Uses the existing authenticated header and native collective payload path.
/// Producer cache publication follows boundaryConsumed; receiver publication
/// occurs inside receiveBoundary, before that acknowledgement is emitted.
func runGLM5NextStageFrame(session: GLM5NextStageSession,
                          control: QwenLayerStageGenerationControl,
                          transport: QwenLayerStageGenerationTransport,
                          expected: QwenLayerStageGenerationBoundaryExpectation,
                          check: () throws -> Void) throws
    -> (QwenLayerStageGenerationBoundaryPacket, MLXArray?) {
    do {
        guard session.agreement.fingerprint == control.agreement.fingerprint,
              transport.agreement.fingerprint == control.agreement.fingerprint,
              session.identity.stageIndex == transport.rank,
              control.phase == .committingFrame, !control.isFailed, !transport.isFailed else {
            throw ProbeError("GLM session/control/transport agreements differ")
        }
        let request = control.agreement.request, frame = expected.frame
        let tokens: [Int]
        if frame.phase == .prefill {
            guard frame.tokenOffset >= 0, frame.tokenCount > 0,
                  frame.tokenOffset <= request.promptCount - frame.tokenCount else {
                throw ProbeError("GLM prefill range exceeds its admitted prompt")
            }
            tokens = Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
        } else {
            guard let token = control.lastTokenID else { throw ProbeError("GLM decode lacks an agreed token") }
            tokens = [token]
        }
        let localExpectation = try QwenLayerStageGenerationBoundaryExpectation(
            agreement: control.agreement, frame: frame, tokenIDs: tokens,
            previousTokenChainSHA256: control.tokenChainSHA256)
        guard expected == localExpectation else { throw ProbeError("GLM frame expectation changed") }
        if transport.rank == 0 {
            var sent: QwenLayerStageGenerationBoundaryPacket?
            _ = try session.forward(frame: frame, tokens: tokens, afterEvaluation: { output in
                guard case .hidden(let boundary) = output else { throw ProbeError("GLM producer did not return streams") }
                let packet = try QwenLayerStageGenerationBoundaryPacket(expected: expected,
                    payloadSHA256: boundary.payloadSHA256)
                try transport.sendBoundary(boundary, packet: packet, check: check)
                sent = packet
            }, check: check)
            guard let sent else { throw ProbeError("GLM producer frame was not acknowledged") }
            try control.acknowledgeFrame(rank: 0, packet: sent, nativeCommittedTokens: session.committedTokens)
            try control.acknowledgeFrame(rank: 1, packet: sent, nativeCommittedTokens: session.committedTokens)
            return (sent, nil)
        }
        let (row, packet): (MLXArray?, QwenLayerStageGenerationBoundaryPacket) = try transport.receiveBoundary(expected: expected, consume: { boundary, packet in
            let output = try session.forward(frame: frame, tokens: tokens, incoming: boundary,
                afterEvaluation: { _ in }, check: check)
            // The producer remains tentative until it receives this rank's consumed
            // acknowledgement. Control advances here only after the local native
            // commit; failure still poisons/fences the whole distributed request.
            try control.acknowledgeFrame(rank: 0, packet: packet,
                nativeCommittedTokens: frame.tokenOffset + frame.tokenCount)
            try control.acknowledgeFrame(rank: 1, packet: packet, nativeCommittedTokens: session.committedTokens)
            switch output {
            case .evaluationHandle where frame.phase == .prefill && !frame.finalPromptChunk: return nil
            case .logits(let row) where frame.phase == .decode || frame.finalPromptChunk: return row
            default: throw ProbeError("GLM consumer output differs from its admitted frame")
            }
        }, check: check)
        return (packet, row)
    } catch {
        session.invalidate()
        control.cancel()
        transport.retire()
        throw error
    }
}
