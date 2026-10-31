import DarkbloomClusterPlacement
import DarkbloomClusterProtocol
import Foundation

/// What an incident or a telemetry record needs to know about one installed
/// session (PROD-PLAN S24): public identifiers, the plan's mode and cut, and
/// the bounded diagnostics its owners left. Names in `peerHosts` and
/// `peerUsers` are only ever used to redact text, never recorded.
public struct DistributedSessionFacts: Sendable, Equatable {
    public let clusterID: String
    public let memberID: String
    public let modelID: String
    /// The generation mode the saved setup selects (`pipeline_v1`, `phase_split_mtp_v1`, ...).
    public let mode: String
    /// The layers each rank holds, rank 0 first (`0-16|16-32`).
    public let cut: String
    /// The membership epoch of the running (or last attempted) launch.
    public let membershipEpoch: String?
    /// Each owner's bounded standard-error tail, rank order, newest bytes last.
    public let diagnostics: [String]
    /// How each owner that ended did end (`rank 1 owner exited with status 1`).
    public let terminations: [String]
    public let peerHosts: [String]
    public let peerUsers: [String]
    /// The members' setup IDs in rank order: speed records name which Mac held which range.
    public let ranks: [String]?

    public init(clusterID: String, memberID: String, modelID: String, mode: String, cut: String,
                membershipEpoch: String?, diagnostics: [String], terminations: [String],
                peerHosts: [String], peerUsers: [String], ranks: [String]? = nil) {
        self.clusterID = clusterID; self.memberID = memberID; self.modelID = modelID; self.mode = mode
        self.cut = cut; self.membershipEpoch = membershipEpoch; self.diagnostics = diagnostics
        self.terminations = terminations; self.peerHosts = peerHosts; self.peerUsers = peerUsers
        self.ranks = ranks
    }

    /// `0-16|16-32` from a partition's stages.
    public static func cut(_ stages: [(rank: Int, start: Int, end: Int)]) -> String {
        stages.sorted { $0.rank < $1.rank }.map { "\($0.start)-\($0.end)" }.joined(separator: "|")
    }

    /// The setup's cut as served-speed records name it: a partition's stages,
    /// or under tensor parallel every rank `0-<layers>` (each holds a share
    /// of every layer; the stages only say how the shards were read) with
    /// each rank's weight when the shares are unequal (`0-64@1|0-64@3`), so
    /// the planner credits what was served to the split that served it.
    public static func cut(_ stages: [(rank: Int, start: Int, end: Int)], mode: ClusterGenerationMode,
                           tensorShares: [Int]?) -> String {
        guard mode.usesTensorParallelPrefill, let layers = stages.map(\.end).max(), layers > 0 else { return cut(stages) }
        return ClusterServedSpeedRecords.Setup.cut([], layerCount: layers, mode: mode, ranks: stages.count, tensorShares: tensorShares)
    }

    static let maximumDiagnosticBytes = 4096

    /// The last `maximumDiagnosticBytes` of a tail, as text.
    static func tail(_ data: Data) -> String {
        String(decoding: data.suffix(maximumDiagnosticBytes), as: UTF8.self)
    }
}
