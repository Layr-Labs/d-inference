import Foundation
import os
import ProviderCore

extension ClusterPairSummary {
    /// Tests give the commands a pair of their own (`live`: whether `cluster status` asked for the status lines).
    @TaskLocal static var readerForTesting: (@Sendable (_ live: Bool) -> ClusterPairSummary)?

    /// The pair for a test's whole child process when no `readerForTesting` is bound (the test sandbox sets
    /// "not in a cluster"). While a test gives a pair, nothing of this Mac's own cluster is read: its pairing,
    /// cluster service, login agents or running part.
    static var processReaderForTesting: (@Sendable (_ live: Bool) -> ClusterPairSummary)? {
        get { processReader.withLock { $0 } }
        set { processReader.withLock { $0 = newValue } }
    }

    private static let processReader = OSAllocatedUnfairLock<(@Sendable (_ live: Bool) -> ClusterPairSummary)?>(initialState: nil)

    private static var testReader: (@Sendable (_ live: Bool) -> ClusterPairSummary)? {
        readerForTesting ?? processReaderForTesting
    }

    /// False while a test gives the commands a pair: then nothing of this Mac's own cluster is read (also
    /// `darkbloom status`'s cluster service lines).
    static var readsThisMacsCluster: Bool { testReader == nil }

    /// What this Mac knows by itself, without asking the other Mac: the pairing, the leader's saved choice (model,
    /// split, how it serves, started or stopped), this Mac's cluster service and its own view of its part.
    static func local() -> ClusterPairSummary {
        if let reader = testReader { return reader(false) }
        return localFacts()
    }

    /// `darkbloom cluster status`: the local facts and the status `darkbloom cluster` shows, which on the Mac that
    /// follows comes from the leading Mac over the cable.
    static func live(config: String?) async -> ClusterPairSummary {
        if let reader = testReader { return reader(true) }
        return await Task.detached { liveFacts(config: config) }.value
    }

    /// The provider pid of the cluster's running part on this Mac, which writes the same daemon state as single-Mac
    /// serving (`ServiceDrain.soloProviderState`). Nil while a test gives the pair.
    static func runningPartPID() -> Int32? {
        guard readsThisMacsCluster else { return nil }
        return ClusterService.publishedLive().flatMap { $0.child.running ? $0.child.pid : nil }
    }

    private static func localFacts() -> ClusterPairSummary {
        let agents = ClusterServiceAgent.status()
        let running = ClusterService.running()
        let pairing: ClusterSetupLinkExchange.Pairing?, read: PairingRead
        do {
            pairing = try ClusterSetupLinkExchange.pairing()
            read = pairing == nil ? .none : .held
        } catch {
            pairing = nil
            read = .unreadable(shownReason(error))
        }
        var summary = membership(read, serviceRunning: running, loginAgentInstalled: !agents.isEmpty,
                                 startsAtLogin: agents.contains { $0.loaded })
        guard summary.paired else { return summary }
        summary.thisMacName = shownName(ClusterLocalNetworkAccess.computerName())
        guard !summary.pairingUnreadable, let paths = try? ClusterUserPaths() else { return summary }
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
              let operations = try? ClusterOnboardingOperations.live(.clusterService(config: config, worker: nil)) else { return summary }
        summary.read(status: operations.status(),
                     leaderMode: summary.leads ? ClusterService.publishedLive()?.control?.mode : nil)
        return summary
    }

    /// This Mac's own view of the cluster, from its cluster service's last status (no other Mac is asked): stopped, the
    /// other Mac away, or what this Mac's part says (a coordinator-paired part's pair line, the leader's local session).
    static func ownState(started: Bool, own: ClusterServiceStatus?) -> (State, String?) {
        guard started else { return (.stopped, nil) }
        if let control = own?.control, otherMacAwayModes.contains(control.mode) { return (.otherMacAway, control.line) }
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
              plain(name) else { return nil }
        return name
    }

    /// Why the pairing record couldn't be read, when the error's words can be said plainly in a line (the pairing
    /// store's own: "pairings.json could not be read"), without a final period.
    static func shownReason(_ error: Error) -> String? {
        let text = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 200, !text.contains("Error Domain="), plain(text) else { return nil }
        return text.hasSuffix(".") ? String(text.dropLast()) : text
    }

    private static func plain(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    /// Whether the cluster service of this Mac started this process (its solo part, `start --local`, serving alone).
    static func startedByClusterService(parent: Int32 = getppid()) -> Bool {
        guard readsThisMacsCluster, ClusterService.running(), let file = try? ClusterService.paths().pid,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) == parent
    }
}
