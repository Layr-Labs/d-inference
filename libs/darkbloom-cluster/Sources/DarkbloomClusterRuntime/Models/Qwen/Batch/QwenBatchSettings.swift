import Foundation

/// Continuous batching on the pair: how many requests one loaded pipeline
/// serves at once, and the graph-shaping terms both ranks must share.
///
/// Every term here changes what graphs the ranks build, so both ranks bind
/// them into the load agreement and a peer launched with different terms
/// stops at the first exchange, before either stage is read (the owner's
/// oMLX rule: identical graph-shaping settings on both ranks).
public struct QwenBatchSettings: Equatable, Sendable {
    /// Requests served together, 1...8. One is the earlier one-request-at-a-time
    /// owner, unchanged.
    public let lanes: Int
    /// Prompt tokens one prefill frame may run while other lanes decode
    /// (mixed prefill quantum). Prefill frames still end on each request's
    /// own chunk grid, so the arithmetic of every frame is the unbatched one.
    public let mixedPrefillTokens: Int

    public static let lanesEnvironmentName = "DARKBLOOM_CLUSTER_BATCH_LANES"
    public static let quantumEnvironmentName = "DARKBLOOM_CLUSTER_BATCH_PREFILL_QUANTUM"
    public static let single = QwenBatchSettings(lanes: 1, mixedPrefillTokens: 512)

    public init(lanes: Int, mixedPrefillTokens: Int = 512) {
        self.lanes = lanes; self.mixedPrefillTokens = mixedPrefillTokens
    }

    public var batching: Bool { lanes > 1 }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        func integer(_ name: String, default value: Int, range: ClosedRange<Int>) throws -> Int {
            guard let raw = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return value }
            guard let parsed = Int(raw), range.contains(parsed) else {
                throw ProbeError("\(name)=\(raw) is outside \(range.lowerBound)...\(range.upperBound)")
            }
            return parsed
        }
        let lanes = try integer(lanesEnvironmentName, default: 1, range: 1...8)
        let quantum = try integer(quantumEnvironmentName, default: 512, range: 16...4096)
        guard quantum % 16 == 0 else { throw ProbeError("\(quantumEnvironmentName) must be a multiple of 16") }
        return .init(lanes: lanes, mixedPrefillTokens: quantum)
    }

    /// One lane keeps the agreement bytes it always had.
    var loadAgreementFields: [String] {
        lanes == 1 ? [] : ["qwen-batch-v1", "lanes=\(lanes)", "quantum=\(mixedPrefillTokens)"]
    }
}
