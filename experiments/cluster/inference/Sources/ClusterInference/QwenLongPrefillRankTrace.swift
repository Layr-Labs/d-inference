import Foundation

/// These actual scalar observations are included in the diagnostic interval,
/// except readiness and post-stop events. No per-frame state/logit capture.
final class QwenLongPrefillRankTrace {
    private let limit = 24 * 16 + 32
    private let phaseRecorder: QwenPrefillPhaseRecorder?
    private(set) var actions: [QwenLongPrefillRankAction] = []

    init(frameCount: Int, phaseRecorder: QwenPrefillPhaseRecorder? = nil) throws {
        guard frameCount == 16 else { throw ProbeError("Long rank trace requires exactly sixteen prompt frames") }
        self.phaseRecorder = phaseRecorder
        actions.reserveCapacity(limit)
    }

    func record(_ action: String, frame: QwenLayerStageFrame? = nil,
                context: QwenLayerStageProfiledPrefillComputeContext?,
                transport: QwenLayerStageProfiledPrefillTransport, prepared: Bool) throws {
        let tokens = context?.committedTokens ?? 0
        let completed = transport.completedBoundaryCount
        let pending = transport.hasPendingConsumption
        guard actions.count < limit, !action.isEmpty, action.utf8.count <= 96,
              (0...16).contains(completed), (0...8192).contains(tokens), tokens % 512 == 0,
              tokens >= completed * 512,
              tokens <= min(8192, (completed + (transport.rank == 0 ? 2 : 1)) * 512),
              !prepared || transport.rank == 0, !pending || transport.rank == 0,
              frame == nil || (0..<16).contains(frame!.sequence) else {
            throw ProbeError("Long rank trace exceeds admitted scalar ownership/frontier bounds")
        }
        actions.append(.init(ordinal: actions.count, action: action, frameSequence: frame?.sequence,
            nativeCommittedTokens: tokens, completedBoundaryCount: completed,
            explicitPreparedBoundarySlots: prepared ? 1 : 0, pendingConsumedFrameSlots: pending ? 1 : 0))
        try phaseRecorder?.observe(phase: action, frameSequence: frame?.sequence, committedTokens: tokens)
    }
}
