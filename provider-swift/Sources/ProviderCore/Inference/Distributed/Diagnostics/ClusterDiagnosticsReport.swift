import Foundation

public struct ClusterDiagnosticsReport: Encodable, Sendable {
    public enum ConfigurationState: String, Encodable, Sendable { case notConfigured, verified, invalid }
    public enum Outcome: String, Encodable, Sendable { case passed, failed, notRun, notObserved }
    public struct Check: Encodable, Sendable {
        public let name: String
        public let outcome: Outcome
        public let detail: String
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

    /// `localLink` is nil when no link inspection ran. `configuredLinkDevice`
    /// is the RDMA device the saved setup assigns to this Mac, when known.
    init(operation: String, configurationState: ConfigurationState, saved: ClusterStatusBinding?,
         live: ClusterLiveStatus?, deviceJournal: ClusterDeviceJournalObservation, checks: [Check],
         localLink: ClusterLinkReadinessReport?, configuredLinkDevice: String?) {
        self.operation = operation
        self.configurationState = configurationState
        self.saved = saved
        self.live = live
        self.deviceJournal = deviceJournal
        self.checks = checks + (localLink?.diagnosticChecks(configuredDevice: configuredLinkDevice) ?? [])
        localLinkInspectionPerformed = localLink != nil
    }
}
