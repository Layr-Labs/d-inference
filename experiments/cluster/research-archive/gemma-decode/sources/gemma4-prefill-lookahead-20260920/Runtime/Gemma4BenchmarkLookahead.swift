import Foundation
import MLX

/// Reuses the qualified Qwen single-slot frontier guard. Only this producer
/// invokes the existing Gemma session; no local forward overlaps local P2P IO.
final class Gemma4BenchmarkLookahead {
    struct Observation {
        let startedNanoseconds: UInt64
        let phases: [Gemma4BenchmarkPhase]
        let committedTokens: Int
    }
    private struct Prepared {
        let boundary: Gemma4ForwardBoundary
        let observation: Observation
    }
    private let request: QwenLayerStageGenerationRequest
    private var window: QwenGenerationPrefillWindow
    private var prepared: Prepared?
    var isComplete: Bool { window.complete && prepared == nil }
    var summary: QwenGenerationPrefillSummary {
        .init(policy: QwenResidentPrefillPolicy.oneChunkLookahead.rawValue, rank: 0,
              preparedAheadFrames: window.preparedAheadFrames,
              maximumPreparedBoundaries: window.maximumPreparedBoundaries)
    }

    init(request: QwenLayerStageGenerationRequest) throws {
        self.request = request
        window = try .init(promptCount: request.promptCount, chunkSize: request.chunkSize)
    }
    func cancel() { prepared = nil; window.cancel() }

    private func prepare(_ sequence: Int, session: Gemma4OwnedForwardSession,
                         check: () throws -> Void) throws {
        guard prepared == nil else { throw ProbeError("Gemma lookahead prepared slot is occupied") }
        let frame = try Gemma4BenchmarkFrames.frame(sequence, request: request)
        guard frame.phase == .prefill else { throw ProbeError("Gemma lookahead cannot prepare decode") }
        try window.beginPreparation(sequence: sequence, nativeCommittedTokens: session.committedTokens)
        prepared = try autoreleasepool {
            try check()
            let started = DispatchTime.now().uptimeNanoseconds
            let tokens = Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
            let value = try Gemma4BenchmarkForward.run(frame: frame, tokens: tokens, session: session,
                                                       incoming: nil, check: check)
            guard case .residual(let boundary) = value.output, boundary.frame == frame else {
                throw ProbeError("Gemma lookahead lacks its actual committed ingress boundary")
            }
            try window.commitPreparation(sequence: sequence, nativeCommittedTokens: session.committedTokens)
            return .init(boundary: boundary, observation: .init(startedNanoseconds: started,
                phases: value.phases, committedTokens: session.committedTokens))
        }
    }

    func run(frame: QwenLayerStageFrame, session: Gemma4OwnedForwardSession,
             wire: Gemma4BenchmarkWire, check: () throws -> Void) throws -> Observation {
        do {
            guard wire.rank == 0, wire.input.job.prefill == .oneChunkLookahead,
                  frame.phase == .prefill else { throw ProbeError("Gemma lookahead producer policy/rank differs") }
            if prepared == nil { try prepare(frame.sequence, session: session, check: check) }
            weak var original: MLXArray?
            let sent: (Gemma4BenchmarkWire.SentFrameTicket, QwenGenerationPrefillWindow.Commit, Observation) = try autoreleasepool {
                guard let value = prepared, value.boundary.frame == frame,
                      session.committedTokens == value.observation.committedTokens else {
                    throw ProbeError("Gemma prepared boundary lost its captured native frontier")
                }
                let commit = try window.beginSend(sequence: frame.sequence,
                    nativeCommittedTokens: value.observation.committedTokens)
                original = value.boundary.array
                let ticket = try wire.sendFrameUntilSent(value.boundary, check: check)
                prepared = nil
                return (ticket, commit, value.observation)
            }
            guard original == nil, prepared == nil else { throw ProbeError("Gemma retained a sent boundary wrapper") }
            try window.completeSend(sent.1)
            if frame.sequence + 1 < window.frameCount {
                try prepare(frame.sequence + 1, session: session, check: check)
            }
            try wire.finishFrameConsumed(sent.0, check: check)
            // ACK k binds k's actual captured commit, even if local state is k+1.
            try window.consume(sent.1)
            return sent.2
        } catch {
            cancel(); wire.poison(); throw error
        }
    }
}
