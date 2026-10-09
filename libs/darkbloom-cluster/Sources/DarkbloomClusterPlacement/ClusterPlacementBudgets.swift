import DarkbloomClusterProtocol
import Foundation

/// The margins that turn a measured time into a budget. Policy, typed on
/// purpose; a budget is always the prediction times a margin stated beside it.
public struct ClusterPlacementBudgetPolicy: Sendable {
    /// A rank may take this many times its predicted load before it is given up on.
    public var startupMargin = 5.0
    public var startupFloorSeconds = 30.0
    /// The fixed part of the first-token allowance.
    public var firstTokenBaseSeconds = 10.0
    /// A pair may be this much slower per prompt token than its slower Mac
    /// alone before the request is ended.
    public var firstTokenMargin = 1.25
    public init() {}
}

/// Owner-side time budgets of one placement, derived from what was measured
/// on its devices instead of one typed row per model. Nil terms are never
/// invented: a placement whose devices have no measured rate has no derived
/// budget, and the typed row stays in force.
public struct ClusterPlacementBudgets: Codable, Equatable, Sendable {
    /// Longest a rank may take from launch to ready, whole seconds.
    public let startupSeconds: Int
    /// The slowest rank's predicted load, and which rank that is.
    public let predictedStartupSeconds: Double
    public let slowestRank: Int
    public let firstTokenBaseMilliseconds: Int
    /// Per prompt token, in microseconds; the installed path rounds up to its own unit.
    public let firstTokenMicrosecondsPerPromptToken: Int
    /// Each term as prediction, margin and source, in plain words.
    public let basis: [String]

    public func firstTokenSeconds(promptTokens: Int) -> Double {
        Double(firstTokenBaseMilliseconds) / 1000 + Double(firstTokenMicrosecondsPerPromptToken) * Double(promptTokens) / 1e6
    }

    public static func derive(candidate: ClusterPlacementCandidate, devices: [ClusterPlacementDevice],
                              layout: ClusterModelLayout, policy: ClusterPlacementBudgetPolicy = .init()) -> ClusterPlacementBudgets? {
        let artifactBytes = layout.ingress.storedBytes + layout.egress.storedBytes + layout.excluded.storedBytes
            + layout.layers.reduce(0) { $0 + $1.weights.storedBytes }
        var slowest: (seconds: Double, rank: Int)?
        var slowestPrefill = Double.infinity
        for rank in candidate.ranks {
            guard let device = devices.first(where: { $0.label == rank.device }), device.speed.source == .measured,
                  let hash = device.speed.hashBytesPerSecond, let materialize = device.speed.materializeBytesPerSecond else { return nil }
            // Every stage a rank loads is loaded through the verified loader,
            // which hashes the whole artifact first; under a phase split the
            // last rank loads twice.
            let loads = candidate.mode == .phaseSplit && rank.rank == candidate.ranks.count - 1 ? candidate.ranks.count : 1
            let seconds = Double(loads) * Double(artifactBytes) / hash + Double(rank.weightsBytes) / materialize
            if seconds > (slowest?.seconds ?? 0) { slowest = (seconds, rank.rank) }
            let rates = [device.speed.rested.prefillTokensPerSecond] + (device.speed.sustained.map { [$0.prefillTokensPerSecond] } ?? [])
            slowestPrefill = min(slowestPrefill, rates.min() ?? .infinity)
        }
        guard let slowest, slowestPrefill.isFinite, slowestPrefill > 0 else { return nil }
        let startup = max(policy.startupFloorSeconds, (slowest.seconds * policy.startupMargin).rounded(.up))
        let perToken = Int((1e6 / slowestPrefill * policy.firstTokenMargin).rounded(.up))
        func text(_ value: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", value) }
        return .init(startupSeconds: Int(startup), predictedStartupSeconds: slowest.seconds, slowestRank: slowest.rank,
            firstTokenBaseMilliseconds: Int(policy.firstTokenBaseSeconds * 1000), firstTokenMicrosecondsPerPromptToken: perToken,
            basis: ["Startup \(Int(startup)) s: rank \(slowest.rank) is predicted ready in \(text(slowest.seconds, 1)) s "
                        + "(the artifact hashed and its stage materialized at that Mac's measured rates), times \(text(policy.startupMargin, 1)), "
                        + "at least \(Int(policy.startupFloorSeconds)) s.",
                    "First token \(text(policy.firstTokenBaseSeconds, 0)) s plus \(text(Double(perToken) / 1000, 3)) ms per prompt token: "
                        + "the slower Mac prefills this model alone at \(text(slowestPrefill, 0)) tok/s at its slowest measured state, "
                        + "and a pair may be \(text(policy.firstTokenMargin, 2)) times slower than that before the request is ended."])
    }
}
