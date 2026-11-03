import Foundation

/// One Mac's part in the pair's coordinated update (`ClusterPairUpdate`), as its cluster service supervisor writes it
/// and its cluster service reports it to the other Mac (`ClusterServiceStatus.pairUpdate`). Rewritten every
/// `ClusterPairUpdate.pollSeconds` while a cycle runs.
public struct ClusterPairUpdateProgress: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// No cycle runs; `detail` says how the last one ended.
        case idle
        /// Automatic updates are off on this Mac (`auto_update`, `DARKBLOOM_NO_UPDATE_CHECK`).
        case disabled
        /// The cycle asks the coordinator for its latest release and downloads it.
        case checking
        /// The release is verified and staged (or already installed) on this Mac; it still serves.
        case staged
        /// This Mac's part takes no new requests and finishes the accepted ones.
        case draining
        /// Nothing accepted is left on this Mac's part.
        case drained
        /// The release is installed; the cluster service restarts into it.
        case restarting
        /// This cycle was given up without installing; the next update slot tries again.
        case deferred
        /// The check, the download, the stage or the install failed; the next update slot tries again.
        case failed

        /// A phase a later build adds reads as `checking`: still working, never ready, stale once no longer rewritten.
        /// Failing on it would fail the other Mac's whole `ClusterServiceStatus`, which carries only plain values.
        public init(from decoder: any Decoder) throws {
            self = Phase(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .checking
        }
    }

    public var phase: Phase
    /// The release this cycle installs; nil before the coordinator answered.
    public var target: String?
    /// The version this Mac runs.
    public var running: String
    /// Epoch seconds this Mac's cycle started; nil outside a cycle.
    public var cycleStartedAt: Double?
    /// The `darkbloom update` request this cycle answers, if any (`ClusterPairUpdate.Request`).
    public var request: String?
    public var writtenAt: Double
    public var detail: String?

    public init(phase: Phase, target: String? = nil, running: String, cycleStartedAt: Double? = nil,
                request: String? = nil, writtenAt: Double, detail: String? = nil) {
        self.phase = phase
        self.target = target
        self.running = running
        self.cycleStartedAt = cycleStartedAt
        self.request = request
        self.writtenAt = writtenAt
        self.detail = detail
    }

    public var isEnd: Bool { phase == .deferred || phase == .failed }

    /// One line for the log and `darkbloom update`.
    public var line: String {
        let release = target.map { "v\($0)" } ?? "the release"
        let text: String
        switch phase {
        case .idle: text = "no update running"
        case .disabled: text = "automatic updates are off"
        case .checking: text = "checking for a release"
        case .staged: text = "\(release) staged; waiting for the other Mac"
        case .draining: text = "\(release) staged; finishing accepted requests"
        case .drained: text = "drained for \(release); waiting for the other Mac"
        case .restarting: text = "\(release) installed; restarting the cluster service"
        case .deferred: text = "\(release) deferred to the next update slot"
        case .failed: text = "\(release) failed; the next update slot tries again"
        }
        return detail.map { "\(text) (\($0))" } ?? text
    }
}
