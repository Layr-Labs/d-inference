import DarkbloomClusterRemote
import Foundation

/// Turns the engine's retired-request observations into pair telemetry
/// records (PROD-PLAN S24): the static facts of the session (model, mode,
/// cut) plus what the leader and the ranks measured of each request.
public struct DistributedPairTelemetryContext: Sendable {
    public let modelID: String
    /// The generation mode the session runs (`pipeline_v1`, `phase_split_v1`, ...).
    public let mode: String
    /// The layers each rank holds, rank 0 first (`0-16|16-32`).
    public let cut: String
    public let log: ClusterPairTelemetryLog
    /// The members in rank order (their setup IDs): a speed record names which Mac held which range.
    public let ranks: [String]?

    public init(modelID: String, mode: String, cut: String, log: ClusterPairTelemetryLog, ranks: [String]? = nil) {
        self.modelID = modelID; self.mode = mode; self.cut = cut; self.log = log; self.ranks = ranks
    }

    /// A record for a retired request; nil for every other phase.
    func record(_ observation: DistributedRequestObservation,
                now: @Sendable () -> Double = { Date().timeIntervalSince1970 }) -> ClusterPairRequestTelemetry? {
        guard observation.phase == .retired else { return nil }
        let rank = observation.rankTelemetry
        return .init(requestID: observation.generation.uuidString.lowercased(), finishedAt: now(), modelID: modelID,
            mode: mode, cut: cut, promptTokens: observation.promptTokens, cachedTokens: observation.reusedPromptTokens,
            completionTokens: observation.completionTokens,
            firstTokenMilliseconds: observation.firstTokenMilliseconds.map { ($0 * 100).rounded() / 100 },
            decodeTokensPerSecond: observation.decodeTokensPerSecond, handoffMilliseconds: rank?.handoffMilliseconds,
            handoffBytes: rank?.handoffBytes, mtpDrafted: rank?.mtpDrafted, mtpAccepted: rank?.mtpAccepted,
            outcome: observation.outcome ?? "unknown", route: observation.route?.label,
            routeReason: observation.route?.reason, ranks: ranks)
    }

    /// The observer the engine calls: logs every observation, records retired ones.
    func observer() -> @Sendable (DistributedRequestObservation) -> Void {
        { observation in
            DistributedRequestObservation.log(observation)
            if let value = record(observation) { log.record(value) }
        }
    }
}
