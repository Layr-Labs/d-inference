import Foundation

/// Qwen pipeline token credits. The batch loop keeps exchanging steps while
/// answers are pending, so both ranks can admit a joining lane even when its
/// provider is waiting synchronously before handling an older token callback.
/// An unanswered lane never runs another forward or publishes another token.
struct QwenBatchDecisionProgress {
    private var pending = Set<UUID>()

    var pendingCount: Int { pending.count }

    func canForward(_ requestID: UUID) -> Bool { !pending.contains(requestID) }

    /// Retirement cancels only this lane's outstanding token credit.
    mutating func retired(_ requestID: UUID) { pending.remove(requestID) }

    mutating func published(_ requestID: UUID) throws {
        guard pending.insert(requestID).inserted else {
            throw ProbeError("Batch lane published another token before its decision")
        }
    }

    /// Executor-only, between native steps. Never blocks on an absent answer;
    /// the next no-work header/reply gives the other rank the same opportunity
    /// to service control. Native transport callbacks do not call this method.
    mutating func serviceAndPoll(_ host: QwenBatchServingHost) throws -> [UUID: Bool] {
        try host.serviceControl()
        var answered: [UUID: Bool] = [:]
        for id in pending.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let value = try host.pollDecision(id) { answered[id] = value }
        }
        for id in answered.keys { pending.remove(id) }
        return answered
    }
}
