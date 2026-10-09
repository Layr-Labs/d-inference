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
    public let aliases: [ClusterConsoleLinkAlias]
    public let diagnostics: ClusterDiagnosticsReport
    public let saved: ClusterConsoleSavedSetup
    /// A setup waiting for the operator's approval, when one was passed in.
    public let candidate: ClusterConsoleCandidateSetup?
    public let admittedModels: [ClusterConsoleAdmittedModel]

    init(observedAt: String, link: ClusterLinkReadinessReport, setup: ClusterConsoleLinkSetup,
         aliases: [ClusterConsoleLinkAlias], diagnostics: ClusterDiagnosticsReport, saved: ClusterConsoleSavedSetup,
         candidate: ClusterConsoleCandidateSetup?, admittedModels: [ClusterConsoleAdmittedModel]) {
        schema = Self.schemaName
        self.observedAt = observedAt; self.link = link; self.setup = setup; self.aliases = aliases
        self.diagnostics = diagnostics; self.saved = saved; self.candidate = candidate
        self.admittedModels = admittedModels
    }
}

/// The guided link flow's reading of one link report: the same lines
/// `darkbloom cluster setup` prints, and what that flow would do next.
public struct ClusterConsoleLinkSetup: Encodable, Sendable, Equatable {
    public enum Next: String, Encodable, Sendable { case ready, awaitConnection, fix, stopped }
    public let lines: [String]
    public let next: Next
    /// The device the flow would fix; set only when `next` is `fix`.
    public let fixDevice: String?

    /// `mayPrompt` is the flow's own switch: with it the flow waits for a
    /// cable and plans the approval-gated fix; without it the flow only says
    /// what it found and what to run.
    static func make(report: ClusterLinkReadinessReport, mayPrompt: Bool) -> ClusterConsoleLinkSetup {
        var flow = ClusterLinkSetupFlow(mayPrompt: mayPrompt)
        let step = flow.observed(report)
        switch step.action {
        case .awaitConnection: return .init(lines: step.lines, next: .awaitConnection, fixDevice: nil)
        case .fix(let device): return .init(lines: step.lines, next: .fix, fixDevice: device)
        case .finish(let exitCode): return .init(lines: step.lines, next: exitCode == 0 ? .ready : .stopped, fixDevice: nil)
        case .inspect: return .init(lines: step.lines, next: .stopped, fixDevice: nil)
        }
    }
}

/// An address `cluster link --fix` recorded, by port name only.
public struct ClusterConsoleLinkAlias: Encodable, Sendable, Equatable {
    public enum Presence: String, Encodable, Sendable {
        /// The port still carries the recorded address.
        case present
        /// The port no longer carries it; the record is spent.
        case gone
        /// The interface listing could not be read.
        case unknown
    }
    public let interface: String
    public let presence: Presence

    /// Reads the owner-only record and one interface listing. It changes
    /// neither: a spent entry is cleared only by `cluster link --remove`.
    static func observe(paths: ClusterUserPaths, run: ClusterLinkToolRunner) throws -> [ClusterConsoleLinkAlias] {
        let record = try ClusterLinkAliasStore(paths: paths).load()
        guard !record.aliases.isEmpty else { return [] }
        guard case .output(let listing) = run(.interfaceList) else {
            return record.aliases.map { .init(interface: $0.interface, presence: .unknown) }
        }
        return record.aliases.map { alias in
            switch ClusterNetworkInterfaces.lists(alias.address, on: alias.interface, inListing: listing) {
            case true?: return .init(interface: alias.interface, presence: .present)
            case false?: return .init(interface: alias.interface, presence: .gone)
            case nil: return .init(interface: alias.interface, presence: .unknown)
            }
        }
    }
}

/// One entry of `ClusterRuntimeAdapter.admittedModels`.
public struct ClusterConsoleAdmittedModel: Encodable, Sendable, Equatable {
    public let adapterID: String
    public let adapterVersion: Int
    public let runtimeModelID: String
}

enum ClusterConsoleText {
    /// An error as one printable line of bounded length.
    static func bounded(_ error: Error) -> String { bounded(String(describing: error)) }

    static func bounded(_ text: String, maximum: Int = 512) -> String {
        String(text.map { character -> Character in
            character.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 } ? character : " "
        }.prefix(maximum))
    }

    /// `2026-10-09T06:45:12Z`.
    static func timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// The first twelve characters of a digest: enough to tell two apart.
    static func short(_ digest: String) -> String { String(digest.prefix(12)) }
}
