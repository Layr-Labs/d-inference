import DarkbloomClusterRemote
import Foundation

public struct ClusterDiagnosticsReport: Encodable, Sendable {
    public enum ConfigurationState: String, Encodable, Sendable { case notConfigured, verified, invalid }
    public enum Outcome: String, Encodable, Sendable { case passed, failed, notRun, notObserved }
    public struct Check: Encodable, Sendable {
        public let name: String
        public let outcome: Outcome
        public let detail: String
    }
    /// An error as a check's detail: printable characters only, bounded.
    static func boundedDetail(_ error: Error) -> String {
        String(String(describing: error).filter { character in
            character.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
        }.prefix(1024))
    }

    public let schema = "darkbloom_cluster_diagnostics_v1"
    public let operation: String
    public let configurationState: ConfigurationState
    public let saved: ClusterStatusBinding?
    public let live: ClusterLiveStatus?
    public let deviceJournal: ClusterDeviceJournalObservation
    public let checks: [Check]
    /// These commands never run a new physical collective or change ownership.
    public let physicalProbePerformed = false
    public let recoveryPerformed = false
    /// Whether this Mac's own RDMA and interface state was read. That is not a
    /// physical probe: no peer is contacted and no collective runs.
    public let localLinkInspectionPerformed: Bool
    /// This Mac's incident log, the leader's pair telemetry and the mirrored
    /// follower status, read from `~/.darkbloom/cluster/` (S24). Absent when
    /// none of those files exists.
    public let observability: ClusterObservabilitySnapshot?
    /// The observability section as terminal lines (empty when absent).
    public var observabilityLines: [String] { observability?.lines ?? [] }

    /// `localLink` is nil when no link inspection ran. `configuredLinkDevice`
    /// is the RDMA device the saved setup assigns to this Mac, when known.
    init(operation: String, configurationState: ConfigurationState, saved: ClusterStatusBinding?,
         live: ClusterLiveStatus?, deviceJournal: ClusterDeviceJournalObservation, checks: [Check],
         localLink: ClusterLinkReadinessReport?, configuredLinkDevice: String?,
         observability: ClusterObservabilitySnapshot? = nil) {
        self.operation = operation
        self.configurationState = configurationState
        self.saved = saved
        self.live = live
        self.deviceJournal = deviceJournal
        self.checks = checks + (localLink?.diagnosticChecks(configuredDevice: configuredLinkDevice) ?? [])
        localLinkInspectionPerformed = localLink != nil
        self.observability = observability.flatMap { $0.isEmpty ? nil : $0 }
    }
}
