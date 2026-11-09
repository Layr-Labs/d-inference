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
    /// follows comes from the leading Mac over the cable. `bounded`: a person's `cluster status` or `status`, which on
    /// the Mac that follows waits for that answer at most `leaderAnswerSeconds` and tells `bounded` when it is slow
    /// (`statusLines`), and on the leading Mac keeps the other Mac's refusal across this Mac's part restarts
    /// (`localNetworkRefusal`); nil waits as long as the answer takes and keeps the strict rule (a start's looks).
    static func live(config: String?, bounded slow: ClusterPairCommands.Say? = nil) async -> ClusterPairSummary {
        liveReadForTesting?(slow != nil)
        if let reader = testReader { return reader(true) }
        let noticeAfter = ClusterPairCommands.progressDelay
        return await Task.detached { liveFacts(config: config, bounded: slow, noticeAfter: noticeAfter) }.value
    }

    /// Tests see each `live` read: whether it asks for the bounded wait (`statusLines`).
    @TaskLocal static var liveReadForTesting: (@Sendable (_ bounded: Bool) -> Void)?

    /// The status lines `live` reads. Only a person's read (`slow`, which hears a slow answer) on the Mac that follows
    /// waits for the leading Mac's answer at most `seconds` (`boundedStatus`). Everywhere else it waits as long as the
    /// answer takes: on the leading Mac, whose status is its own, and in a script start's looks, whose wait has its own
    /// bound and lines (a look cut short would leave its forward running beside the next one).
    static func statusLines(leads: Bool, slow: ClusterPairCommands.Say?, within seconds: Double = leaderAnswerSeconds,
                            noticeAfter: Double, _ status: @escaping @Sendable () -> [String]) -> [String]? {
        guard !leads, let slow else { return status() }
        return boundedStatus(within: seconds, noticeAfter: noticeAfter, slow: slow, status)
    }

    /// How long `cluster status` and `status` wait for the leading Mac's answer on the Mac that follows. The forward
    /// itself gives up only after 30 s, and is sent again while leadership moves (`ClusterOnboardingLive.status`); the
    /// leading Mac answers its own in about a second.
    static let leaderAnswerSeconds: Double = 10

    /// For `--json`: a line on standard error, so standard output stays one JSON object.
    static let sayOnStandardError: ClusterPairCommands.Say = { printError($0) }

    /// The provider pid of the cluster's running part on this Mac, which writes the same daemon state as single-Mac
    /// serving (`ServiceDrain.soloProviderState`). Nil while a test gives the pair.
    static func runningPartPID() -> Int32? {
        guard readsThisMacsCluster else { return nil }
        return ClusterService.publishedLive().flatMap { $0.child.running ? $0.child.pid : nil }
    }

    /// The processes that serve this Mac's running pair (`pairProcesses(of:)`). Empty while a test gives the pair.
    static func runningPairProcesses() -> Set<Int32> {
        readsThisMacsCluster ? pairProcesses(of: ClusterService.publishedLive()) : []
    }

    /// The processes that serve the pair `status` publishes, while this Mac's part of it runs: the part's provider
    /// (`runningPartPID`), and the cluster service itself, whose relay answers a member's local API for the pair
    /// (`ClusterService.relayTick` writes `local.json` with the service's own pid).
    static func pairProcesses(of status: ClusterServiceStatus?) -> Set<Int32> {
        guard let status, status.child.running else { return [] }
        return Set([status.child.pid, status.servicePID].compactMap { $0 })
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
        summary.speculationNote = leadership.speculationNote
        let own = ClusterService.publishedLive()
        if leadership.scope.addsLocalAPI { summary.localAPI = localAPIFacts(own: own) }
        summary.localAPIBind = leadership.scope.localAPIBind
        summary.relaying = relayAddress(own: own, live: LocalEndpoint.readLiveInfo())
        summary.relayPortHeld = own?.relayPortHeld
        summary.relayWaitsForOffer = own?.relayWaitsForOffer == true
        summary.relayRankZeroAway = own?.relayRankZeroAway == true
        summary.relayRankZeroAPIDown = own?.relayRankZeroAPIDown == true
        (summary.state, summary.reason) = ownState(started: summary.started, own: own, localOnly: summary.localOnly)
        summary.pairRunning = summary.started && ClusterService.pairRuns(own)
        summary.pairNotRunning = own?.pairNotRunning
        summary.otherMacReachable = own?.control.map { !ClusterService.otherMacAbsentModes.contains($0.mode) } ?? false
        return summary
    }

    /// `status`'s lines (on the Mac that follows, the leading Mac's answer over the cable) within `seconds`; nil when
    /// they haven't come by then. A wait past `noticeAfter` is said to `slow`, and so is a wait that ran out.
    static func boundedStatus(within seconds: Double, noticeAfter: Double, slow: ClusterPairCommands.Say?,
                              _ status: @escaping @Sendable () -> [String]) -> [String]? {
        let answer = Answer()
        Thread.detachNewThread { answer.set(status()) }
        if let lines = answer.wait(noticeAfter) { return lines }
        slow?("  Waiting for the leading Mac's answer (\(ClusterPairCommands.upTo(seconds))).")
        if let lines = answer.wait(max(0, seconds - noticeAfter)) { return lines }
        slow?("  The leading Mac didn't answer in \(Int(seconds.rounded())) s; this is this Mac's own view.")
        return nil
    }

    /// One answer from another thread, waited for within a bound.
    private final class Answer: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var lines: [String]?
        func set(_ value: [String]) { lock.withLock { lines = value }; done.signal() }
        func wait(_ seconds: Double) -> [String]? {
            guard done.wait(timeout: .now() + seconds) == .success else { return nil }
            done.signal()
            return lock.withLock { lines }
        }
    }

    private static func liveFacts(config: String?, bounded slow: ClusterPairCommands.Say?, noticeAfter: Double) -> ClusterPairSummary {
        var summary = localFacts()
        guard summary.paired, summary.role != nil,
              let operations = try? ClusterOnboardingOperations.live(.clusterService(config: config, worker: nil)) else { return summary }
        // A bounded wait that ran out: this Mac's own view stands (the other Mac's answer unknown).
        if let status = statusLines(leads: summary.leads, slow: slow, noticeAfter: noticeAfter, operations.status) {
            summary.read(status: status, leaderMode: summary.leads ? ClusterService.publishedLive()?.control?.mode : nil)
        }
        // A person's status read (`slow`) keeps a refusal across this Mac's part restarts; a start's own looks don't.
        summary.read(localNetworkRefused: localNetworkRefusal(of: summary, acrossRestarts: slow != nil))
        return summary
    }

    /// Which Mac's follower macOS keeps off the local network, by the setup screens' rule: on the Mac that follows, its
    /// own service's state, as `start` reads it; on the leading Mac, the other Mac's status, asked only while the pair has
    /// been starting longer than one more dial takes (the ✗'s rule), or, for a status read (`acrossRestarts`), while this
    /// Mac's last part ran that long and its next one starts.
    private static func localNetworkRefusal(of summary: ClusterPairSummary, acrossRestarts: Bool) -> ClusterLocalNetworkAccess.Refused? {
        guard summary.started else { return nil }
        guard summary.leads else { return ClusterLocalNetworkAccess.serviceState() == .blocked ? .thisMac : nil }
        guard summary.state == .unknown || (summary.state == .loading && summary.lines.first?.hasPrefix("Starting ") == true)
        else { return nil }
        return ClusterLocalNetworkAccess.otherMacRefused(acrossRestarts: acrossRestarts) ? .otherMac : nil
    }

    /// This Mac's own view of the cluster, from its cluster service's last status (no other Mac is asked): stopped, the
    /// other Mac away, or what this Mac's part says (a coordinator-paired part's pair line, the leader's local session).
    /// `localOnly`: the pair serves locally only as asked. Otherwise a ready local session is a pair set to serve through
    /// Darkbloom that isn't offered (an offered pair's part reports its pair line instead), never serving.
    static func ownState(started: Bool, own: ClusterServiceStatus?, localOnly: Bool = false) -> (State, String?) {
        guard started else { return (.stopped, nil) }
        if let control = own?.control, otherMacAwayModes.contains(control.mode) { return (.otherMacAway, control.line) }
        if let text = own?.child.pair, let pair = ClusterOnboardingPairReport.state(text) {
            switch pair {
            case .serving:
                // Paired and answering, but the coordinator sends this pair no public request.
                if let reason = ClusterPublicServingCheck.ownerOnly(notice: own?.child.notice) { return (.notServing, reason) }
                return (.serving, nil)
            case .starting: return (.loading, nil)
            case .stopped(let why): return (.notServing, ClusterOnboardingNotServing.words(reason: why, mac: "one of the Macs"))
            }
        }
        // A part offered for a model the coordinator's catalog does not list: the coordinator never pairs it.
        if let refusal = ClusterLocalServing.pairRefusal(notice: own?.child.notice) { return (.notServing, refusal) }
        // A part registered with the coordinator as a pair member, before its pair line: the coordinator may still pair it.
        if own?.child.notice == ClusterLocalServing.offeredNotice { return (.loading, nil) }
        if let session = own?.session, session.observed {
            guard session.ready else { return (.loading, nil) }
            return localOnly ? (.serving, nil) : (.notServing, ClusterOnboardingReady.notOfferedReason(nil))
        }
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
