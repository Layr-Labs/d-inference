import DarkbloomClusterProtocol
import Foundation

extension QwenTensorParallelResidentRuntime {
    /// The installed singleton wire keeps its one token credit. Its native
    /// history nevertheless uses the same CBv2 execution as larger capacities.
    var usesRequestOwnedSingleton: Bool { batchLanes == 1 && batchBudget != nil }

    func startSingletonLane(requestID: UUID, channel: ClusterCommittedTokenChannel) throws -> QwenResidentGenerationCompletion {
        guard usesRequestOwnedSingleton, let reserved = batchBook.reservation(requestID) else {
            throw ProbeError("Singleton TP start has no matching request-owned reservation")
        }
        let host = QwenTensorParallelSingletonHost(request: reserved.request, channel: channel)
        try startLane(requestID: requestID)
        try serveBatch(host: host, retiredSelection: host.retiredSelection)
        return try host.completion()
    }
}

/// A capacity-one adapter, not a second decoder. Only rank zero publishes a
/// token and waits for its existing singleton wire credit; the shared driver
/// still performs both-rank selection, request-state settlement and retirement.
final class QwenTensorParallelSingletonHost: QwenBatchServingHost {
    private let request: QwenLayerStageGenerationRequest
    private let channel: ClusterCommittedTokenChannel
    private var decision: Bool?
    private var selected: [Int]?
    private var reason: ClusterWorkerFinishReason?
    private var finished = false
    private var reused = 0
    private var stored: [Int] = []
    private var telemetry: ClusterWorkerRequestTelemetry?

    init(request: QwenLayerStageGenerationRequest, channel: ClusterCommittedTokenChannel) {
        self.request = request; self.channel = channel
    }
    private func require(_ id: UUID) throws {
        guard id == request.requestID else { throw ProbeError("Singleton TP host received another request") }
    }
    func serviceControl() throws {} // The singleton worker's control reader owns cancellation.
    func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int) throws {
        try publishToken(requestID: requestID, ordinal: ordinal, tokenID: tokenID,
            committedTokens: committedTokens, logprobs: nil)
    }
    func publishToken(requestID: UUID, ordinal: Int, tokenID: Int, committedTokens: Int,
                      logprobs: ClusterWorkerTokenLogprobs?) throws {
        try require(requestID)
        guard decision == nil, !finished else { throw ProbeError("Singleton TP token exceeded its wire credit") }
        try channel.publishToken(ordinal, tokenID, committedTokens, logprobs)
        decision = try channel.answer()
    }
    func pollDecision(_ requestID: UUID) throws -> Bool? {
        try require(requestID)
        let value = decision; decision = nil
        return value
    }
    func awaitDecision(_ requestID: UUID) throws -> Bool {
        guard let value = try pollDecision(requestID) else { throw ProbeError("Singleton TP has no published token decision") }
        return value
    }
    func awaitDecisions(_ requestIDs: [UUID]) throws -> [UUID: Bool] {
        guard requestIDs == [request.requestID] else { throw ProbeError("Singleton TP has no wider wire cohort") }
        return [request.requestID: try awaitDecision(request.requestID)]
    }
    func publishPromptCache(requestID: UUID, reusedTokens: Int, storedFrontiers: [Int]) throws {
        try require(requestID); reused = reusedTokens; stored = storedFrontiers
    }
    func publishTelemetry(requestID: UUID, telemetry: ClusterWorkerRequestTelemetry) throws {
        try require(requestID); self.telemetry = telemetry
    }
    /// The driver calls this only after both ranks retired a clean finish.
    func retiredSelection(_ id: UUID, tokens: [Int], reason: QwenLayerStageGenerationFinishReason) throws {
        try require(id)
        guard selected == nil, let converted = ClusterWorkerFinishReason(rawValue: reason.rawValue) else {
            throw ProbeError("Singleton TP request retired twice or with an unknown reason")
        }
        selected = tokens; self.reason = converted
    }
    func publishFinished(requestID: UUID, reason: ClusterWorkerFinishReason) throws {
        try require(requestID)
        guard selected != nil, self.reason == reason, !finished else {
            throw ProbeError("Singleton TP completion preceded bilateral retirement")
        }
        finished = true
    }
    func publishLeft(requestID: UUID) throws {
        try require(requestID)
        // The lane is already unbooked and retired on both ranks; preserve the
        // singleton wire's existing failed/cancelled unwind.
        throw ProbeError("Singleton TP request cancelled before clean completion")
    }
    func completion() throws -> QwenResidentGenerationCompletion {
        guard finished, let selected, let reason else { throw ProbeError("Singleton TP returned without native retirement") }
        return .init(requestID: request.requestID, finishReason: reason,
            selectedTokenIDs: selected, completedFrames: selected.count,
            committedTokens: request.promptCount + selected.count,
            tokenChainSHA256: sha256(try canonicalJSONData(selected.map(String.init))),
            bothRequestStatesRetired: true, reusedPromptTokens: reused,
            storedPromptFrontiers: stored, telemetry: telemetry)
    }
}
