import Foundation
import MLX

/// The same synchronous owner call and scalar observer used by serial and
/// prepared prefill. No request/state lifetime or transport is introduced here.
enum Gemma4BenchmarkForward {
    static func run(frame: QwenLayerStageFrame, tokens: [Int], session: Gemma4OwnedForwardSession,
                    incoming: Gemma4ForwardBoundary?, check: () throws -> Void
    ) throws -> (output: Gemma4ForwardOutput, phases: [Gemma4BenchmarkPhase]) {
        var phases: [Gemma4BenchmarkPhase] = []
        let observer: CBv2OwnerPhaseObserver = { value in
            guard phases.count < CBv2OwnerPhase.allCases.count,
                  value.phase == CBv2OwnerPhase.allCases[phases.count], value.tokenCount == frame.tokenCount,
                  value.committedTokens == (value.phase == .validationCommitEnd
                    ? frame.tokenOffset + frame.tokenCount : frame.tokenOffset) else {
                throw ProbeError("Gemma scalar owner phase order/frontier differs")
            }
            phases.append(.init(name: value.phase.rawValue, timestampNanoseconds: DispatchTime.now().uptimeNanoseconds,
                                tokenCount: value.tokenCount, committedTokens: value.committedTokens))
        }
        let output: Gemma4ForwardOutput
        if frame.phase == .prefill {
            output = try session.prefillChunk(tokens, offset: frame.tokenOffset, final: frame.finalPromptChunk,
                incoming: incoming, observer: observer, check: check)
        } else {
            output = try session.decode(tokens[0], offset: frame.tokenOffset, incoming: incoming,
                                        observer: observer, check: check)
        }
        guard phases.count == CBv2OwnerPhase.allCases.count,
              session.committedTokens == frame.tokenOffset + frame.tokenCount else {
            throw ProbeError("Gemma benchmark forward did not complete all native/state phases")
        }
        return (output, phases)
    }
}
