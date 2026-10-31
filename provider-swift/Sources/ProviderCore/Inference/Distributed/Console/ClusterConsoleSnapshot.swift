import Foundation

/// Everything the `darkbloom cluster` console shows, as one refresh observed
/// it. Each field is produced by an operation named in
/// `handoff/TUI-wiring.md`. Something that could not be observed is absent or
/// carries the error text it failed with; nothing here has a default that
/// stands in for an observation.
public struct ClusterConsoleSnapshot: Encodable, Sendable {
    public static let schemaName = "darkbloom_cluster_console_v1"
    public let schema: String
    /// When this refresh finished, in UTC.
    public let observedAt: String
    public let link: ClusterLinkReadinessReport
    public let setup: ClusterConsoleLinkSetup
    public let diagnostics: ClusterDiagnosticsReport
    public let saved: ClusterConsoleSavedSetup
    /// A setup waiting for the operator's approval, when one was passed in.
    public let candidate: ClusterConsoleCandidateSetup?
    public let admittedModels: [ClusterConsoleAdmittedModel]

    init(observedAt: String, link: ClusterLinkReadinessReport, setup: ClusterConsoleLinkSetup,
         diagnostics: ClusterDiagnosticsReport, saved: ClusterConsoleSavedSetup,
         candidate: ClusterConsoleCandidateSetup?, admittedModels: [ClusterConsoleAdmittedModel]) {
        schema = Self.schemaName
        self.observedAt = observedAt; self.link = link; self.setup = setup
        self.diagnostics = diagnostics; self.saved = saved; self.candidate = candidate
        self.admittedModels = admittedModels
    }
}

/// One entry of `ClusterRuntimeAdapter.admittedModels`.
public struct ClusterConsoleAdmittedModel: Encodable, Sendable, Equatable {
    public let adapterID: String
    public let adapterVersion: Int
    public let runtimeModelID: String
}
