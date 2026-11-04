import Foundation
import ProviderCore

extension ClusterPairSummary {
    /// Tests give the commands a pair of their own (`live`: whether `cluster status` asked for the status lines).
    @TaskLocal static var readerForTesting: (@Sendable (_ live: Bool) -> ClusterPairSummary)?

    /// What this Mac knows by itself, without asking the other Mac: the pairing, the leader's saved choice (model,
    /// split, how it serves, started or stopped), this Mac's cluster service and its own view of its part.
    static func local(config: String? = nil) -> ClusterPairSummary {
        if let reader = readerForTesting { return reader(false) }
        return localFacts()
    }

    /// `darkbloom cluster status`: the local facts and the status `darkbloom cluster` shows, which on the Mac that
    /// follows comes from the leading Mac over the cable.
    static func live(config: String?) async -> ClusterPairSummary {
        if let reader = readerForTesting { return reader(true) }
        return await Task.detached { liveFacts(config: config) }.value
    }

    /// A Mac is in a cluster when it holds a pairing, or its cluster service runs or is set to start at login (UX audit
    /// P4: `ClusterService.holdsNoPairing`, `ClusterServiceAgent.status`).
    private static func localFacts() -> ClusterPairSummary {
        let agents = ClusterServiceAgent.status()
        let running = ClusterService.running()
        let pairing = try? ClusterSetupLinkExchange.pairing()
        guard pairing != nil || running || !agents.isEmpty else { return .notPaired }
        var summary = ClusterPairSummary(paired: true)
        summary.serviceRunning = running
        summary.startsAtLogin = agents.contains { $0.loaded }
        summary.thisMacName = shownName(ClusterLocalNetworkAccess.computerName())
        guard let paths = try? ClusterUserPaths() else { return summary }
        let store = ClusterSetupStore(paths: .init(paths: paths))
        let record = try? store.readRecord()
        // As `darkbloom cluster` reads it (`OnboardingLive.resume`): the record of this pairing only, and after
        // onboarding the role is the derived control leadership.
        guard let leadership = record?.leadership, let pairing, pairing.peerPin == leadership.peerPin else { return summary }
        summary.otherMacName = leadership.peerName.isEmpty ? nil : leadership.peerName
        summary.role = Role(rawValue: leadership.role)
        if let claim = record?.control?.claim(localID: pairing.localMemberID, peerID: pairing.peerMemberID) {
            summary.role = claim.leaderID == pairing.localMemberID ? .leader : .member
        }
        summary.started = leadership.serving
        summary.localOnly = leadership.scope.isLocalOnly
        summary.modelID = leadership.modelName
        summary.modelName = leadership.modelName.flatMap { modelName($0, directory: store.paths.directory) }
        summary.deployment = leadership.deployment
        let own = ClusterService.publishedLive()
        (summary.state, summary.reason) = ownState(started: summary.started, own: own)
        return summary
    }

    private static func liveFacts(config: String?) -> ClusterPairSummary {
        var summary = localFacts()
        guard summary.paired, summary.role != nil,
              let settings = try? Cluster.Setup.serviceSettings(config: config, modelDir: nil, worker: nil),
              let operations = try? ClusterOnboardingOperations.live(.init(service: settings,
                  serviceArguments: ClusterServiceAgentPlan.childArguments(
                      serviceOptions: ClusterServiceAgentPlan.serviceOptions(config: config, worker: nil)))) else { return summary }
        summary.lines = operations.status().filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let mode = summary.leads ? ClusterService.publishedLive()?.control?.mode : nil
        (summary.state, summary.reason) = state(ofStatus: summary.lines, started: summary.started, leaderMode: mode)
        if summary.role == .member {
            // The lines came from the leading Mac when it answered.
            summary.otherMacAnswers = !(summary.lines.first?.contains("did not answer over the cable") ?? true)
        } else if summary.state == .otherMacAway {
            summary.otherMacAnswers = false
        }
        return summary
    }

    /// This Mac's own view of the cluster, from its cluster service's last status (no other Mac is asked): stopped, the
    /// other Mac away, or what this Mac's part says (a coordinator-paired part's pair line, the leader's local session).
    static func ownState(started: Bool, own: ClusterServiceStatus?) -> (State, String?) {
        guard started else { return (.stopped, nil) }
        if let control = own?.control, ["waiting", "alone", "cannotServe"].contains(control.mode) { return (.otherMacAway, control.line) }
        if let text = own?.child.pair, let pair = ClusterOnboardingPairReport.state(text) {
            switch pair {
            case .serving: return (.serving, nil)
            case .starting: return (.loading, nil)
            case .stopped(let why): return (.notServing, ClusterOnboardingNotServing.words(reason: why, mac: "one of the Macs"))
            }
        }
        if let session = own?.session, session.observed { return (session.ready ? .serving : .loading, nil) }
        return (.unknown, nil)
    }

    /// The catalog name the screens use for a model id (the catalog `darkbloom cluster` last read), nil when none.
    private static func modelName(_ modelID: String, directory: URL) -> String? {
        let file = directory.appendingPathComponent("catalog.json")
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int, size <= 4 << 20,
              let data = try? Data(contentsOf: file), let catalog = try? JSONDecoder().decode([CatalogModel].self, from: data)
        else { return nil }
        let title = ClusterOnboardingDeployment.title(modelID: modelID,
            displayNames: Dictionary(catalog.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first }))
        return title == modelID ? nil : title
    }

    /// This Mac's own name when it can be said plainly in a line (as the `darkbloom cluster` banner shows it).
    static func shownName(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name.count <= 40,
              !name.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }) else { return nil }
        return name
    }

    /// Whether the cluster service of this Mac started this process (its solo part, `start --local`, serving alone).
    static func startedByClusterService(parent: Int32 = getppid()) -> Bool {
        guard ClusterService.running(), let file = try? ClusterService.paths().pid,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) == parent
    }
}
