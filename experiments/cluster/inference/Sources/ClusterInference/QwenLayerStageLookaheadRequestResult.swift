import Foundation

/// CPU-only host action order. Counts describe application owner slots and pure
/// schedule frontiers, not physical allocation totals or simultaneous GPU work.
struct QwenLayerStageLookaheadActionRecord: Encodable {
    let ordinal: Int
    let action: String
    let frameSequence: Int?
    let headerSHA256: String?
    let scheduleActivity: String
    let nativeCommittedTokens: Int
    let producedFrames: Int?
    let receivedFrames: Int?
    let completedFrames: Int
    let receiverCommittedFrames: Int?
    let explicitNativeBoundarySlots: Int
    let pendingConsumedFrameSlots: Int
}

struct QwenLayerStageLookaheadRequestResult: Encodable {
    let kind = "qwen_layer_stage_lookahead_request"
    let flow = QwenLayerStageOverlapFlow.name
    let identity: QwenLayerStageSessionIdentity
    let recordedRequestFingerprint: String
    let decodeAdmission: String
    let completions: [QwenLayerStageRankFrameCompletion]
    let actions: [QwenLayerStageLookaheadActionRecord]
    let finalCommittedTokens: Int
    let completedFrames: Int
    /// Sender-only fields are absent on rank one; the receiver does not infer
    /// how many producer preparations actually overlapped its consumption.
    let producedFrames: Int?
    let receivedFrames: Int?
    let promptLookaheadCount: Int?
    let maximumProducedMinusReceived: Int?
    let maximumReceivedMinusCompleted: Int?
    let maximumProducedMinusCompleted: Int?
    let maximumExplicitNativeBoundarySlots: Int
    let releasedOriginalArrayHandles: Int
    let allRequestStateRetired: Bool
}

/// Bounded scalar records only; it cannot retain a context, array or callback.
final class QwenLayerStageLookaheadActionTrace {
    let limit: Int
    private(set) var records: [QwenLayerStageLookaheadActionRecord] = []
    private(set) var maximumProducedMinusReceived = 0
    private(set) var maximumReceivedMinusCompleted = 0
    private(set) var maximumProducedMinusCompleted = 0
    private(set) var maximumExplicitNativeBoundarySlots = 0

    init(frameCount: Int) throws {
        guard (1...QwenLayerStageOverlapFlow.maximumFrames).contains(frameCount) else {
            throw ProbeError("Lookahead action trace requires a bounded admitted timeline")
        }
        limit = 24 * frameCount + 8
        records.reserveCapacity(limit)
    }

    func sender(_ action: String, frame: QwenLayerStageFrame?, ticket: QwenLayerStageOverlapTicket? = nil,
        machine: QwenLayerStageOverlapSender, nativeCommittedTokens: Int, ownsNativeBoundary: Bool
    ) throws {
        let producedGap = machine.producedFrames - machine.receivedFrames
        let receivedGap = machine.receivedFrames - machine.completedFrames
        let totalGap = machine.producedFrames - machine.completedFrames
        guard (0...1).contains(producedGap), (0...1).contains(receivedGap), (0...2).contains(totalGap) else {
            throw ProbeError("Lookahead sender exceeded its one received and one prepared frame bounds")
        }
        maximumProducedMinusReceived = max(maximumProducedMinusReceived, producedGap)
        maximumReceivedMinusCompleted = max(maximumReceivedMinusCompleted, receivedGap)
        maximumProducedMinusCompleted = max(maximumProducedMinusCompleted, totalGap)
        try append(action: action, frame: frame, ticket: ticket, activity: machine.activity.rawValue,
            nativeCommittedTokens: nativeCommittedTokens, produced: machine.producedFrames,
            received: machine.receivedFrames, completed: machine.completedFrames,
            receiverCommitted: nil, boundarySlots: ownsNativeBoundary ? 1 : 0,
            pendingSlots: machine.pendingConsumed == nil ? 0 : 1)
    }

    func receiver(_ action: String, frame: QwenLayerStageFrame?, ticket: QwenLayerStageOverlapTicket? = nil,
        machine: QwenLayerStageOverlapReceiver, nativeCommittedTokens: Int
    ) throws {
        guard (0...1).contains(machine.committedFrames - machine.completedFrames) else {
            throw ProbeError("Lookahead receiver exceeded its single consumed frame slot")
        }
        try append(action: action, frame: frame, ticket: ticket, activity: machine.activity.rawValue,
            nativeCommittedTokens: nativeCommittedTokens, produced: nil, received: nil,
            completed: machine.completedFrames, receiverCommitted: machine.committedFrames,
            boundarySlots: machine.ownsBoundary ? 1 : 0, pendingSlots: machine.current == nil ? 0 : 1)
    }

    private func append(action: String, frame: QwenLayerStageFrame?, ticket: QwenLayerStageOverlapTicket?,
        activity: String, nativeCommittedTokens: Int, produced: Int?, received: Int?, completed: Int,
        receiverCommitted: Int?, boundarySlots: Int, pendingSlots: Int
    ) throws {
        guard records.count < limit, limit <= 4096, (0...1).contains(boundarySlots),
              (0...1).contains(pendingSlots), action.utf8.count <= 96 else {
            throw ProbeError("Lookahead action trace exceeded its bounded scalar record limit")
        }
        maximumExplicitNativeBoundarySlots = max(maximumExplicitNativeBoundarySlots, boundarySlots)
        records.append(.init(ordinal: records.count, action: action, frameSequence: frame?.sequence,
            headerSHA256: ticket?.headerSHA256, scheduleActivity: activity, nativeCommittedTokens: nativeCommittedTokens,
            producedFrames: produced, receivedFrames: received, completedFrames: completed,
            receiverCommittedFrames: receiverCommitted, explicitNativeBoundarySlots: boundarySlots,
            pendingConsumedFrameSlots: pendingSlots))
    }
}
