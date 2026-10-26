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

    /// A record for a retired request; nil for every other phase. `concurrentRequests`: the most other requests in
    /// flight while it ran (`DistributedPairOverlap`), nil when not counted.
    func record(_ observation: DistributedRequestObservation, concurrentRequests: Int? = nil,
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
            routeReason: observation.route?.reason, ranks: ranks, concurrentRequests: concurrentRequests)
    }

    /// The observer the engine calls: logs every observation, records retired ones with how many other requests
    /// shared the pair while each ran (one engine, one count).
    func observer() -> @Sendable (DistributedRequestObservation) -> Void {
        let overlap = DistributedPairOverlap()
        return { observation in
            DistributedRequestObservation.log(observation)
            let concurrent = overlap.note(observation.generation, phase: observation.phase)
            if let value = record(observation, concurrentRequests: concurrent) { log.record(value) }
        }
    }
}

/// Which requests shared the pair: from its reservation to its end, the most other requests in flight at once.
/// A request whose end was never observed (an overflowing sink drops observations) stops counting after
/// `staleSeconds`, so one lost end does not mark every later request as shared.
final class DistributedPairOverlap: @unchecked Sendable {
    static let staleSeconds: Double = 3_600
    private let lock = NSLock()
    private var inFlight: [UUID: Double] = [:]
    private var most: [UUID: Int] = [:]
    private let clock: @Sendable () -> Double

    init(clock: @escaping @Sendable () -> Double = { Date().timeIntervalSince1970 }) { self.clock = clock }

    /// Notes one observation; for `retired`, the most other requests in flight while that request ran (nil for a
    /// request this count never saw start).
    func note(_ generation: UUID, phase: DistributedRequestObservation.Phase) -> Int? {
        lock.withLock {
            let now = clock()
            inFlight = inFlight.filter { now - $0.value <= Self.staleSeconds }
            switch phase {
            case .reserved, .firstToken:
                if inFlight[generation] == nil { inFlight[generation] = now }
            case .terminal:
                inFlight[generation] = nil
            case .retired:
                inFlight[generation] = nil
                return most.removeValue(forKey: generation)
            }
            let others = max(0, inFlight.count - 1)
            for key in inFlight.keys { most[key] = max(most[key] ?? 0, others) }
            // Counts of requests whose retirement was never observed.
            if most.count > 1_024 { most = most.filter { inFlight[$0.key] != nil } }
            return nil
        }
    }
}
