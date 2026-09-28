import Foundation

/// Scalar diagnostic bookkeeping, included in any reported first-token interval.
final class QwenLayerStagePrefillRankTrace {
    private let limit: Int
    private(set) var actions: [QwenLayerStagePrefillRankAction] = []

    init(frameCount: Int) throws {
        guard (1...128).contains(frameCount) else { throw ProbeError("Prefill trace requires a bounded prompt timeline") }
        limit = 24 * frameCount + 32
        actions.reserveCapacity(limit)
    }

    func record(_ action: String, frame: QwenLayerStageFrame? = nil,
                context: QwenLayerStagePrefillComputeContext?,
                transport: QwenLayerStagePrefillTransport, prepared: Bool) throws {
        guard actions.count < limit, action.utf8.count <= 96,
              (0...128).contains(transport.completedBoundaryCount) else {
            throw ProbeError("Prefill trace exceeds its fixed scalar bounds")
        }
        actions.append(.init(ordinal: actions.count, action: action,
            frameSequence: frame?.sequence, nativeCommittedTokens: context?.committedTokens ?? 0,
            completedBoundaryCount: transport.completedBoundaryCount,
            explicitPreparedBoundarySlots: prepared ? 1 : 0,
            pendingConsumedFrameSlots: transport.hasPendingConsumption ? 1 : 0))
    }
}
