import Foundation

/// Continuous batching on the pair: how many requests one loaded pipeline
/// serves at once.
///
/// The lane count shapes the graphs both ranks build (decode rows per step,
/// pool capacity), so both ranks bind it into the load agreement and a peer
/// launched with another count stops at the first exchange, before either
/// stage is read (the owner's oMLX rule: identical graph-shaping settings on
/// both ranks). Prefill frames always end on each request's own chunk grid,
/// one frame per step, so every prefill frame's arithmetic is the unbatched
/// one; batched decode rows round like an MTP verify window's rows (near-tie
/// lossless, see `QwenResidentRuntime+Batch.swift`).
public struct QwenBatchSettings: Equatable, Sendable {
    /// Requests served together, 1...8. One is the earlier one-request-at-a-time
    /// owner, unchanged.
    public let lanes: Int

    public static let lanesEnvironmentName = "DARKBLOOM_CLUSTER_BATCH_LANES"
    public static let single = QwenBatchSettings(lanes: 1)

    public init(lanes: Int) { self.lanes = lanes }

    public var batching: Bool { lanes > 1 }

    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        guard let raw = environment[lanesEnvironmentName]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return .single }
        guard let lanes = Int(raw), (1...QwenBatchWire.maximumLanes).contains(lanes) else {
            throw ProbeError("\(lanesEnvironmentName)=\(raw) is outside 1...\(QwenBatchWire.maximumLanes)")
        }
        return .init(lanes: lanes)
    }

    /// One lane keeps the agreement bytes it always had.
    var loadAgreementFields: [String] { lanes == 1 ? [] : ["qwen-batch-v1", "lanes=\(lanes)"] }
}
